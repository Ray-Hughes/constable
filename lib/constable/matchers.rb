# frozen_string_literal: true

module Constable
  # `attest(actual).to matcher` -- fluent sugar layered over the plain assertion
  # primitives, which are always available too.
  #
  # A matcher is a *value*, not a method call. Inside a case, `be_created` and
  # `exist(email: "a@b.com")` are bare method calls with no receiver: they fall through
  # Expectations#method_missing, which builds a Deferred capturing nothing but the
  # matcher's name, arguments and block. Nothing runs until `.to` / `.not_to` hands the
  # Deferred the actual value. That deferral is the whole point -- the same object has to
  # be able to phrase both "expected X to eq 1" and "expected X not to eq 1", and it can
  # only do that if it still knows what it was asked to check when the failure happens.
  #
  # Failure messages always name both sides. Where the actual carries something a human
  # would want to see -- a response body, a record's attributes, validation errors -- it
  # is attached as `context:` on the raised AssertionFailed, because the reporter prints
  # context underneath the failure message.
  module Matchers
    # A registered matcher. `deferred_class` lets a matcher whose grammar is richer than
    # "name plus arguments" (only `change`, so far) supply its own Deferred subclass.
    Matcher = Struct.new(:name, :block, :deferred_class)

    # Enough of the status table to be useful without dragging in Rack just to translate
    # :created into 201. Rails apps get the same answer either way.
    HTTP_STATUS_CODES = {
      continue: 100, switching_protocols: 101,
      ok: 200, created: 201, accepted: 202, non_authoritative_information: 203,
      no_content: 204, reset_content: 205, partial_content: 206,
      multiple_choices: 300, moved_permanently: 301, found: 302, see_other: 303,
      not_modified: 304, temporary_redirect: 307, permanent_redirect: 308,
      bad_request: 400, unauthorized: 401, payment_required: 402, forbidden: 403,
      not_found: 404, method_not_allowed: 405, not_acceptable: 406,
      request_timeout: 408, conflict: 409, gone: 410, precondition_failed: 412,
      payload_too_large: 413, unsupported_media_type: 415, im_a_teapot: 418,
      unprocessable_entity: 422, unprocessable_content: 422, locked: 423, too_many_requests: 429,
      internal_server_error: 500, not_implemented: 501, bad_gateway: 502,
      service_unavailable: 503, gateway_timeout: 504
    }.freeze

    HTTP_STATUS_GROUPS = {
      informational: (100..199), success: (200..299), successful: (200..299),
      redirect: (300..399), missing: (404..404), client_error: (400..499),
      error: (500..599), server_error: (500..599)
    }.freeze

    # Rack renames statuses -- 422 became :unprocessable_content in Rack 3.1, and Rails
    # 8.1 deprecates the old spelling -- so the table above is a floor, not the whole
    # truth. Anything Rack knows is accepted, which means a rename costs no release here.
    def self.rack_status_codes
      return @rack_status_codes if defined?(@rack_status_codes)

      @rack_status_codes =
        if defined?(::Rack::Utils::SYMBOL_TO_STATUS_CODE)
          ::Rack::Utils::SYMBOL_TO_STATUS_CODE.transform_keys(&:to_sym)
        else
          {}
        end
    rescue StandardError
      @rack_status_codes = {}
    end

    MAX_INSPECT = 200
    MAX_BODY    = 800

    class << self
      # Constable::Matchers.define(:be_created) { |response| response.status == 201 }
      #
      # A truthy return passes. A block may instead return [bool, message, context] when
      # it can say something more useful about the failure than the generic phrasing.
      def define(name, deferred_class: Deferred, &block)
        raise ArgumentError, "Constable::Matchers.define(:#{name}) requires a block" unless block

        custom[name.to_sym] = Matcher.new(name.to_sym, block, deferred_class)
        name.to_sym
      end

      def matcher_for(name)
        custom[name.to_sym] || builtins[name.to_sym]
      end

      def registered?(name)
        !matcher_for(name).nil?
      end

      # Drops every user-defined matcher and restores the built-ins any override shadowed.
      # Built-ins are kept in their own table precisely so this can be a clean reset rather
      # than a wipe that leaves `eq` undefined for the rest of the process.
      def clear!
        @custom = {}
        self
      end

      def names
        (builtins.keys + custom.keys).uniq.sort
      end

      def custom   = (@custom ||= {})
      def builtins = (@builtins ||= {})

      # Names a bare call inside a case is allowed to resolve as a matcher: anything
      # registered, plus the be_*/have_* predicate fallbacks. Deliberately narrow -- a
      # typo'd method should still raise NoMethodError, not silently become a matcher.
      def matcher_name?(name)
        return true if registered?(name)

        name.to_s.match?(/\A(?:be|have)_[a-z_][a-z0-9_]*\z/)
      end

      def deferred_for(name, args = [], block = nil)
        matcher = matcher_for(name)
        return matcher.deferred_class.new(name, args, block, matcher: matcher) if matcher

        predicate = predicate_for(name)
        unless predicate
          raise Constable::Error,
                "no matcher named :#{name} is registered -- define one with " \
                "Constable::Matchers.define(:#{name}) { |actual, *args| ... }"
        end

        PredicateDeferred.new(name, args, block, predicate: predicate)
      end

      # be_created -> #created?, have_timed_out -> #has_timed_out?
      def predicate_for(name)
        case name.to_s
        when /\Abe_(.+)\z/   then "#{Regexp.last_match(1)}?"
        when /\Ahave_(.+)\z/ then "has_#{Regexp.last_match(1)}?"
        end
      end

      def fail!(message, context = nil)
        raise Constable::AssertionFailed.new(message, context: context)
      end

      def truthy?(value)
        !value.nil? && value != false
      end

      # A matcher block's return value, in either of the two supported shapes. The rich
      # form is recognised narrowly -- [bool, String-or-nil, anything] -- so a matcher that
      # legitimately returns an array of results isn't misread as a failure tuple.
      def normalize_result(result)
        if result.is_a?(Array) && (2..3).cover?(result.size) &&
           [true, false].include?(result[0]) &&
           (result[1].nil? || result[1].is_a?(String))
          [result[0], result[1], result[2]]
        else
          [truthy?(result), nil, nil]
        end
      end

      # How the actual is named in a message. Responses and classes get their own name;
      # everything else gets a bounded #inspect so a fat object can't drown the summary.
      def describe(actual)
        return "the block" if actual.is_a?(Proc)
        return "response"  if response_like?(actual)
        return actual.name if actual.is_a?(Module) && actual.name

        truncate(actual.inspect, MAX_INSPECT)
      rescue StandardError
        "a #{actual.class}"
      end

      # Reads the way the call site was written: `eq 1`, `exist email: "a@b.com"`.
      def format_args(args)
        args.empty? ? "" : " #{format_list(args)}"
      end

      def format_list(args)
        args.map { |a| a.is_a?(Hash) ? format_hash(a) : a.inspect }.join(", ")
      end

      def format_hash(hash)
        hash.map { |k, v| k.is_a?(Symbol) ? "#{k}: #{v.inspect}" : "#{k.inspect} => #{v.inspect}" }.join(", ")
      end

      def truncate(string, limit)
        str = string.to_s
        str.length > limit ? "#{str[0, limit]}…" : str
      end

      # Whatever the failure is about, this is what someone staring at the summary
      # actually wants to see. Every probe is defensive: an object that raises from
      # #body simply contributes nothing.
      def context_for(actual)
        context = {}
        add_body_context(context, actual)
        add_attributes_context(context, actual)
        add_errors_context(context, actual)
        context.empty? ? nil : context
      end

      def merge_context(*contexts)
        merged = contexts.compact.reduce({}) do |acc, ctx|
          ctx.is_a?(Hash) ? acc.merge(ctx) : acc.merge("Detail" => ctx.to_s)
        end
        merged.empty? ? nil : merged
      end

      def response_like?(actual)
        actual.respond_to?(:status) && actual.respond_to?(:body) && !actual.is_a?(Module)
      rescue StandardError
        false
      end

      # 200 from anything that plausibly models an HTTP response, or nil if it isn't one.
      def response_status(actual)
        return actual if actual.is_a?(Integer)
        return actual.status.to_i if actual.respond_to?(:status) && actual.status.respond_to?(:to_i)
        return actual.code.to_i   if actual.respond_to?(:code) && actual.code.to_s.match?(/\A\d+\z/)

        nil
      rescue StandardError
        nil
      end

      def status_name(code)
        HTTP_STATUS_CODES.key(code) || code
      end

      def status_label(code)
        return "no status" if code.nil?

        name = HTTP_STATUS_CODES.key(code)
        name ? ":#{name} (#{code})" : code.to_s
      end

      def expected_status_label(expected)
        group = HTTP_STATUS_GROUPS[expected.to_s.to_sym] if expected.is_a?(Symbol) || expected.is_a?(String)
        return ":#{expected} (#{group.first}-#{group.last})" if group && !HTTP_STATUS_CODES.key?(expected.to_s.to_sym)

        code = status_code_for(expected)
        code ? status_label(code) : expected.inspect
      end

      def status_code_for(expected)
        case expected
        when Integer then expected
        when /\A\d+\z/ then expected.to_i
        else
          name = expected.to_s.to_sym
          HTTP_STATUS_CODES[name] || Matchers.rack_status_codes[name]
        end
      end

      def status_matches?(code, expected)
        return false if code.nil?

        key = expected.is_a?(Symbol) || expected.is_a?(String) ? expected.to_s.to_sym : nil
        if key && HTTP_STATUS_GROUPS.key?(key) && !HTTP_STATUS_CODES.key?(key)
          return HTTP_STATUS_GROUPS[key].cover?(code)
        end

        expected_code = status_code_for(expected)
        !expected_code.nil? && expected_code == code
      end

      def response_location(actual)
        return actual.location.to_s if actual.respond_to?(:location) && actual.location

        headers = actual.respond_to?(:headers) ? actual.headers : nil
        headers ||= actual.respond_to?(:header) ? actual.header : nil
        return nil unless headers.respond_to?(:[])

        (headers["Location"] || headers["location"])&.to_s
      rescue StandardError
        nil
      end

      # "http://example.test/sessions/new" and "/sessions/new" describe the same redirect.
      def location_path(location)
        location.to_s.sub(%r{\Ahttps?://[^/]+}, "")
      end

      # The text between a block's braces, used so a `change` failure can say
      # `User.count` instead of "the value". Best-effort by design.
      def block_source(block)
        return nil unless block.is_a?(Proc)
        return nil unless defined?(RubyVM::AbstractSyntaxTree)

        source = RubyVM::AbstractSyntaxTree.of(block, keep_script_lines: true)&.source
        return nil unless source

        inner = source[/\{(.*)\}/m, 1] || source[/\bdo\b(.*)\bend\b/m, 1]
        inner = inner&.strip
        inner && !inner.empty? ? inner.gsub(/\s+/, " ") : nil
      rescue StandardError, ScriptError
        nil
      end

      private

      def add_body_context(context, actual)
        return unless actual.respond_to?(:body) && !actual.is_a?(Proc)

        body = actual.body
        return if body.nil?

        text = body.respond_to?(:read) ? body.read : body.to_s
        context["Response body"] = truncate(text, MAX_BODY) unless text.strip.empty?
      rescue StandardError
        nil
      end

      def add_attributes_context(context, actual)
        return unless actual.respond_to?(:attributes)

        attributes = actual.attributes
        context["Attributes"] = truncate(attributes.inspect, MAX_BODY) if attributes.is_a?(Hash) && !attributes.empty?
      rescue StandardError
        nil
      end

      def add_errors_context(context, actual)
        return unless actual.respond_to?(:errors)

        errors = actual.errors
        messages = errors.respond_to?(:full_messages) ? errors.full_messages : nil
        context["Errors"] = messages.join(", ") if messages.respond_to?(:join) && !messages.empty?
      rescue StandardError
        nil
      end
    end

    # A matcher that knows its name and arguments but not yet its subject.
    class Deferred
      attr_reader :name, :args, :block, :matcher

      def initialize(name, args = [], block = nil, matcher: nil)
        @name    = name.to_sym
        @args    = Array(args)
        @block   = block
        @matcher = matcher
      end

      # => [passed, message, context]
      def matches?(actual)
        Matchers.normalize_result(invoke(actual))
      end

      def invoke(actual)
        @matcher.block.call(actual, *@args, &@block)
      end

      # "eq 1", "be a String", "exist email: \"a@b.com\"" -- the phrase both the positive
      # and the negated message are built around, so negation never needs its own matcher.
      def description
        phrase = @name.to_s.sub(/\Abe_/, "be ").sub(/\Ahave_/, "have ").tr("_", " ")
        "#{phrase}#{Matchers.format_args(@args)}"
      end

      def failure_message(actual)
        "expected #{Matchers.describe(actual)} to #{description}"
      end

      def negated_failure_message(actual)
        "expected #{Matchers.describe(actual)} not to #{description}"
      end

      def context_for(actual)
        Matchers.context_for(actual)
      end
    end

    # `be_within(0.5).of(10)` -- a matcher spelled across two calls, so it has to survive
    # the first one and collect its subject on the second.
    #
    # Registering it matters for a second reason: without an entry, `be_within` fell
    # through to the be_*/have_* predicate fallback, which happily built a
    # PredicateDeferred and then blew up on `.of` with a NoMethodError naming an internal
    # class rather than the matcher the author actually wrote.
    class WithinDeferred < Deferred
      def of(expected)
        @expected = expected
        @expected_set = true
        self
      end

      def matches?(actual)
        unless @expected_set
          return [false, "be_within(#{@args.first.inspect}) is incomplete -- it needs .of: " \
                         "attest(value).to be_within(0.5).of(10)", nil]
        end

        delta = @args.first
        difference = (actual - @expected).abs
        return true if difference <= delta

        [false, "expected #{Matchers.describe(actual)} to be within #{delta.inspect} of " \
                "#{Matchers.describe(@expected)}, but it differed by #{difference}", nil]
      rescue NoMethodError, TypeError, ArgumentError
        [false, "expected #{Matchers.describe(actual)} to be within #{delta.inspect} of " \
                "#{Matchers.describe(@expected)}, but a #{actual.class} cannot be subtracted", nil]
      end

      def description
        return "be within #{@args.first.inspect} of #{Matchers.describe(@expected)}" if @expected_set

        "be within #{@args.first.inspect} of (nothing -- .of was never called)"
      end
    end

    # `be`, in its three RSpec spellings:
    #
    #   attest(x).to be(other)   identity -- the same object, not merely equal
    #   attest(x).to be >= 0     an operator comparison
    #   attest(x).to be          truthiness
    #
    # `==` is deliberately not among the operators. Defining it on a matcher object
    # breaks equality everywhere the object is compared, and `eq` already says it.
    class BeDeferred < Deferred
      COMPARISONS = %i[< <= > >=].freeze

      COMPARISONS.each do |operator|
        define_method(operator) do |operand|
          @operator = operator
          @operand  = operand
          self
        end
      end

      def matches?(actual)
        return compare(actual) if @operator
        # `.empty?`, not `.any?`: `[nil].any?` is false, which would send `be(nil)` down
        # the truthiness branch and assert the opposite of what was written.
        return identity(actual) unless @args.empty?
        return true if actual

        [false, "expected a truthy value, but got #{actual.inspect}", nil]
      end

      def description
        return "be #{@operator} #{Matchers.describe(@operand)}" if @operator
        return "be #{Matchers.describe(@args.first)}" unless @args.empty?

        "be truthy"
      end

      private

      def compare(actual)
        return true if actual.public_send(@operator, @operand)

        [false, "expected #{Matchers.describe(actual)} to be #{@operator} " \
                "#{Matchers.describe(@operand)}", nil]
      rescue NoMethodError, ArgumentError, TypeError
        [false, "expected #{Matchers.describe(actual)} to be #{@operator} " \
                "#{Matchers.describe(@operand)}, but a #{actual.class} cannot be compared", nil]
      end

      # `be` is identity, not equality -- that distinction is the only reason to reach for
      # it over `eq`, so the failure message says which one failed.
      def identity(actual)
        expected = @args.first
        return true if actual.equal?(expected)

        hint = actual == expected ? " (they are equal, but not the same object)" : ""
        [false, "expected #{Matchers.describe(actual)} to be the same object as " \
                "#{Matchers.describe(expected)}#{hint}", nil]
      end
    end

    # The be_*/have_* fallback: with no matcher registered under the name, the name itself
    # is the assertion -- `be_created` asks the actual whether it is `created?`.
    class PredicateDeferred < Deferred
      attr_reader :predicate

      def initialize(name, args = [], block = nil, predicate:)
        super(name, args, block)
        @predicate = predicate
      end

      def matches?(actual)
        unless actual.respond_to?(@predicate)
          return [false, "expected #{Matchers.describe(actual)} to respond to ##{@predicate} " \
                         "(no matcher named :#{@name} is registered), but it does not",
                  Matchers.context_for(actual)]
        end

        passed = Matchers.truthy?(actual.public_send(@predicate, *@args, &@block))
        [passed, passed ? nil : failure_message(actual), Matchers.context_for(actual)]
      end

      def failure_message(actual)
        "#{super}, but #{owner_name(actual)}##{@predicate} returned false"
      end

      def negated_failure_message(actual)
        "#{super}, but #{owner_name(actual)}##{@predicate} returned true"
      end

      private

      def owner_name(actual)
        actual.is_a?(Module) ? actual.name.to_s : actual.class.name.to_s
      end
    end

    # `change` is the one matcher whose grammar is more than name-plus-arguments: it needs
    # a before/after sampling around the action, and .by/.from/.to chaining to say what
    # kind of change it wanted.
    class ChangeMatcher < Deferred
      def initialize(name, args = [], block = nil, matcher: nil)
        super
        @by_set = @from_set = @to_set = false
      end

      def by(delta)
        @by = delta
        @by_set = true
        self
      end

      def from(value)
        @from = value
        @from_set = true
        self
      end

      def to(value)
        @to = value
        @to_set = true
        self
      end

      def matches?(action)
        unless action.respond_to?(:call)
          raise Constable::Error,
                "change needs the block form: attest { ... }.to change { #{expression} }"
        end

        @before = sample
        action.call
        @after = sample

        evaluate
      end

      def description
        parts = ["change #{expression}"]
        parts << "by #{@by.inspect}" if @by_set
        parts << "from #{@from.inspect}" if @from_set
        parts << "to #{@to.inspect}" if @to_set
        parts.join(" ")
      end

      def negated_failure_message(_action)
        "expected the block not to #{description}, " \
          "but #{expression} changed from #{@before.inspect} to #{@after.inspect}"
      end

      def context_for(_action) = nil

      private

      # The thing being watched: change { User.count } or change(user, :name).
      # Duplicated on the way out: a matcher that watches a mutable object would otherwise
      # compare it against itself and conclude nothing ever changes.
      def sample
        value = @block ? @block.call : @args[0].public_send(@args[1])
        begin
          value.dup
        rescue StandardError
          value
        end
      end

      def expression
        @expression ||= if @block
                          src = Matchers.block_source(@block)
                          src ? "`#{src}`" : "the value"
                        else
                          "#{Matchers.describe(@args[0])}##{@args[1]}"
                        end
      end

      def evaluate
        return from_mismatch if @from_set && @before != @from
        return by_result if @by_set
        return to_result if @to_set

        return [true, nil, nil] if @before != @after

        [false, "expected the block to #{description}, " \
                "but #{expression} stayed at #{@before.inspect}", nil]
      end

      def from_mismatch
        [false, "expected the block to #{description}, " \
                "but #{expression} started at #{@before.inspect}, not #{@from.inspect}", nil]
      end

      def by_result
        delta = begin
          @after - @before
        rescue StandardError
          nil
        end
        return [true, nil, nil] if delta == @by

        [false, "expected the block to #{description}, but #{expression} changed by " \
                "#{delta.inspect} (#{@before.inspect} to #{@after.inspect})", nil]
      end

      def to_result
        return [true, nil, nil] if @after == @to && @before != @after

        [false, "expected the block to #{description}, but #{expression} " \
                "went from #{@before.inspect} to #{@after.inspect}", nil]
      end
    end

    # What `attest` returns. Holds the actual (or, in block form, the action) and does the
    # raising, so matchers only ever have to answer "did this pass, and what would you say
    # about it if it didn't".
    class Expectation
      NOTHING = Object.new.freeze

      attr_reader :actual, :block

      def initialize(actual = NOTHING, block: nil)
        @actual = actual
        @block  = block
      end

      def block_form? = !@block.nil?

      # In block form the matcher's subject is the action itself -- change and raise_error
      # need to run it, not look at its result.
      def target = block_form? ? @block : @actual

      def to(matcher)
        matcher = coerce(matcher)
        passed, message, context = matcher.matches?(target)
        return satisfied if passed

        Matchers.fail!(message || matcher.failure_message(target),
                       Matchers.merge_context(matcher.context_for(target), context))
      end

      def not_to(matcher)
        matcher = coerce(matcher)
        passed, _message, context = matcher.matches?(target)
        return satisfied unless passed

        Matchers.fail!(matcher.negated_failure_message(target),
                       Matchers.merge_context(matcher.context_for(target), context))
      end
      alias to_not not_to

      private

      # Handing the actual back makes `user = attest(build_user).to be_valid` read fine;
      # in block form there is no actual to hand back.
      def satisfied = block_form? ? self : @actual

      def coerce(matcher)
        return matcher if matcher.respond_to?(:matches?)

        raise Constable::Error,
              "attest(...).to expects a matcher, got #{matcher.inspect}. " \
              "Did you mean `attest(x).to eq(#{matcher.inspect})`?"
      end
    end

    # Mixed into Constable::Case. Everything a case needs to write `attest(response).to
    # be_created` -- including the bare `be_created`, which lands here.
    module Expectations
      def attest(actual = Expectation::NOTHING, &block)
        if block
          Expectation.new(block: block)
        elsif !actual.equal?(Expectation::NOTHING)
          Expectation.new(actual)
        else
          raise Constable::Error,
                "attest needs a value or a block: attest(response).to be_created, " \
                "or attest { ... }.to change { User.count }"
        end
      end

      # Explicit escape hatch for a matcher whose name collides with a real method.
      def matcher(name, *args, &block)
        Matchers.deferred_for(name, args, block)
      end

      private

      def method_missing(name, *args, &block)
        return super unless Matchers.matcher_name?(name)

        Matchers.deferred_for(name, args, block)
      end

      def respond_to_missing?(name, include_private = false)
        Matchers.matcher_name?(name) || super
      end
    end

    # -- Built-ins ---------------------------------------------------------------------
    #
    # Registered into their own table (never `custom`), so Matchers.clear! is a reset to
    # this set rather than a wipe. Each one degrades gracefully when Rails is absent: they
    # duck-type responses and records instead of naming ActionDispatch or ActiveRecord.

    def self.define_builtin(name, deferred_class: Deferred, &block)
      builtins[name.to_sym] = Matcher.new(name.to_sym, block, deferred_class)
    end
    private_class_method :define_builtin

    define_builtin(:eq) do |actual, expected|
      next true if actual == expected

      note = actual.instance_of?(expected.class) ? "" : " (#{actual.class} vs #{expected.class})"
      [false, "expected #{Matchers.describe(actual)} to eq #{expected.inspect}#{note}", nil]
    end

    define_builtin(:eql) do |actual, expected|
      next true if actual.eql?(expected)

      [false, "expected #{Matchers.describe(actual)} to eql #{expected.inspect} " \
              "(eql? compares value and type; #{actual.class} vs #{expected.class})", nil]
    end

    define_builtin(:include) do |actual, *expected|
      unless actual.respond_to?(:include?)
        next [false, "expected #{Matchers.describe(actual)} to include " \
                     "#{expected.map(&:inspect).join(", ")}, but a #{actual.class} has no #include?", nil]
      end

      missing = expected.reject do |item|
        if actual.is_a?(Hash) && item.is_a?(Hash)
          item.all? { |k, v| actual.key?(k) && actual[k] == v }
        elsif actual.is_a?(Hash)
          actual.key?(item)
        else
          actual.include?(item)
        end
      end
      next true if missing.empty?

      [false, "expected #{Matchers.describe(actual)} to include " \
              "#{expected.map(&:inspect).join(", ")}, but #{missing.map(&:inspect).join(", ")} " \
              "#{missing.one? ? "is" : "are"} missing", nil]
    end

    define_builtin(:match) do |actual, pattern|
      matched =
        if pattern.is_a?(Regexp)
          actual.is_a?(String) || actual.is_a?(Symbol) ? pattern.match?(actual.to_s) : false
        elsif actual.respond_to?(:match?)
          actual.match?(pattern)
        else
          actual == pattern
        end
      next true if matched

      [false, "expected #{Matchers.describe(actual)} to match #{pattern.inspect}", nil]
    end

    define_builtin(:raise_error) do |actual, *args|
      unless actual.respond_to?(:call)
        next [false, "raise_error needs the block form: attest { ... }.to raise_error(...), " \
                     "got #{Matchers.describe(actual)}", nil]
      end

      expected_class   = args.find { |a| a.is_a?(Class) } || StandardError
      expected_message = args.find { |a| a.is_a?(String) || a.is_a?(Regexp) }

      begin
        actual.call
        [false, "expected the block to raise #{expected_class}, but nothing was raised", nil]
      rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised below unless it is the one asked for
        raise if e.is_a?(SystemExit) || e.is_a?(Interrupt) || e.is_a?(SignalException) || e.is_a?(NoMemoryError)

        context = { "Raised" => "#{e.class}: #{e.message}" }
        message_matched =
          expected_message.nil? ||
          (expected_message.is_a?(Regexp) ? expected_message.match?(e.message) : e.message == expected_message)

        if !e.is_a?(expected_class)
          [false, "expected the block to raise #{expected_class}, but it raised #{e.class}: #{e.message}", context]
        elsif !message_matched
          [false, "expected the block to raise #{expected_class} with message #{expected_message.inspect}, " \
                  "but the message was #{e.message.inspect}", context]
        else
          [true, nil, context]
        end
      end
    end

    define_builtin(:have_attributes) do |actual, expected|
      unless expected.is_a?(Hash)
        next [false, "have_attributes expects a hash of attributes, got #{expected.inspect}", nil]
      end

      mismatches = expected.filter_map do |key, value|
        if actual.respond_to?(key)
          got = actual.public_send(key)
          "#{key}: expected #{value.inspect}, got #{got.inspect}" unless got == value
        elsif actual.respond_to?(:[])
          got = actual[key]
          "#{key}: expected #{value.inspect}, got #{got.inspect}" unless got == value
        else
          "#{key}: #{Matchers.describe(actual)} does not respond to ##{key}"
        end
      end
      next true if mismatches.empty?

      [false, "expected #{Matchers.describe(actual)} to have attributes " \
              "#{Matchers.format_hash(expected)}, but #{mismatches.join("; ")}", nil]
    end

    define_builtin(:exist) do |actual, *args|
      if actual.respond_to?(:exists?)
        passed = args.empty? ? actual.exists? : actual.exists?(*args)
        next true if passed

        criteria = args.empty? ? "any record" : "a record matching #{Matchers.format_list(args)}"
        context = begin
          actual.respond_to?(:count) ? { "Rows in table" => actual.count.to_s } : nil
        rescue StandardError
          nil
        end
        next [false, "expected #{Matchers.describe(actual)} to have #{criteria}, but none exists", context]
      end

      if actual.respond_to?(:exist?)
        next true if actual.exist?

        next [false, "expected #{Matchers.describe(actual)} to exist on disk, but it does not", nil]
      end

      if actual.is_a?(String)
        next true if File.exist?(actual)

        next [false, "expected the path #{actual.inspect} to exist, but no such file or directory", nil]
      end

      [false, "expected #{Matchers.describe(actual)} to exist, but a #{actual.class} " \
              "responds to neither #exists? nor #exist?", nil]
    end

    # Registered even though be_* would fall back to #created? anyway: a response's status
    # is the common case, and "got :unprocessable_entity (422)" beats "created? was false".
    define_builtin(:be_created) do |actual|
      code = Matchers.response_status(actual)
      if code
        next true if code == 201

        next [false, "expected response to be created (201), but got #{Matchers.status_label(code)}",
              Matchers.context_for(actual)]
      end

      unless actual.respond_to?(:created?)
        next [false, "expected #{Matchers.describe(actual)} to be created, but a #{actual.class} " \
                     "responds to neither #status nor #created?", nil]
      end

      next true if actual.created?

      [false, "expected #{Matchers.describe(actual)} to be created, but " \
              "#{actual.class}#created? returned false", Matchers.context_for(actual)]
    end

    define_builtin(:redirect_to) do |actual, target|
      code     = Matchers.response_status(actual)
      location = Matchers.response_location(actual)

      if code.nil?
        next [false, "expected #{Matchers.describe(actual)} to redirect to #{target.inspect}, " \
                     "but a #{actual.class} has no HTTP status", nil]
      end

      unless (300..399).cover?(code)
        next [false, "expected response to redirect to #{target.inspect}, but it returned " \
                     "#{Matchers.status_label(code)} with no redirect", Matchers.context_for(actual)]
      end

      matched =
        if target.is_a?(Regexp)
          location && target.match?(location)
        else
          location == target.to_s || Matchers.location_path(location) == Matchers.location_path(target.to_s)
        end
      next true if matched

      [false, "expected response to redirect to #{target.inspect}, but it redirected to " \
              "#{location.inspect}", Matchers.context_for(actual)]
    end

    define_builtin(:have_http_status) do |actual, expected|
      code = Matchers.response_status(actual)
      if code.nil?
        next [false, "expected #{Matchers.describe(actual)} to have HTTP status " \
                     "#{Matchers.expected_status_label(expected)}, but a #{actual.class} has no status", nil]
      end
      next true if Matchers.status_matches?(code, expected)

      if Matchers.status_code_for(expected).nil? && !Matchers::HTTP_STATUS_GROUPS.key?(expected.to_s.to_sym)
        known = Matchers::HTTP_STATUS_CODES.keys.first(5).map(&:inspect).join(", ")
        next [false, "have_http_status does not know the status #{expected.inspect}; " \
                     "use an integer or one of #{known}, …", nil]
      end

      [false, "expected response to have HTTP status #{Matchers.expected_status_label(expected)}, " \
              "but got #{Matchers.status_label(code)}", Matchers.context_for(actual)]
    end

    define_builtin(:change, deferred_class: ChangeMatcher) do |_actual, *_args|
      raise Constable::Error, "change is only usable through attest { ... }.to change { ... }"
    end

    # Order-independent collection equality. `modernize` converts
    # `expect(x).to contain_exactly(a, b)` verbatim, so not having it turned every
    # converted spec that used it into a NoMethodError.
    define_builtin(:contain_exactly) do |actual, *expected|
      unless actual.respond_to?(:to_a)
        next [false, "expected #{Matchers.describe(actual)} to be a collection, " \
                     "but a #{actual.class} does not respond to #to_a", nil]
      end

      items = actual.to_a
      missing = expected.dup
      extra   = []
      items.each do |item|
        index = missing.index { |candidate| candidate == item }
        index ? missing.delete_at(index) : extra << item
      end
      next true if missing.empty? && extra.empty?

      parts = []
      parts << "missing #{Matchers.describe(missing)}" unless missing.empty?
      parts << "unexpected #{Matchers.describe(extra)}" unless extra.empty?
      [false, "expected the collection to contain exactly #{expected.size} " \
              "#{expected.size == 1 ? "item" : "items"}: #{parts.join(", ")}",
       { "Actual" => Matchers.describe(items) }]
    end
    # Not an alias: RSpec's match_array takes one array where contain_exactly takes
    # varargs, so aliasing them makes match_array([1, 2]) assert that the collection
    # holds a single element which is itself the array [1, 2].
    define_builtin(:match_array) do |actual, expected|
      unless expected.respond_to?(:to_a)
        next [false, "match_array takes an array: attest(list).to match_array([1, 2])", nil]
      end

      Matchers.matcher_for(:contain_exactly).block.call(actual, *expected.to_a)
    end

    define_builtin(:start_with) do |actual, prefix|
      unless actual.respond_to?(:start_with?) || actual.respond_to?(:first)
        next [false, "expected #{Matchers.describe(actual)} to start with " \
                     "#{Matchers.describe(prefix)}, but a #{actual.class} cannot say", nil]
      end
      passed = if actual.respond_to?(:start_with?)
                 actual.start_with?(prefix)
               else
                 actual.first(Array(prefix).size) == Array(prefix)
               end
      next true if passed

      [false, "expected #{Matchers.describe(actual)} to start with #{Matchers.describe(prefix)}", nil]
    end

    define_builtin(:end_with) do |actual, suffix|
      unless actual.respond_to?(:end_with?) || actual.respond_to?(:last)
        next [false, "expected #{Matchers.describe(actual)} to end with " \
                     "#{Matchers.describe(suffix)}, but a #{actual.class} cannot say", nil]
      end
      passed = if actual.respond_to?(:end_with?)
                 actual.end_with?(suffix)
               else
                 actual.last(Array(suffix).size) == Array(suffix)
               end
      next true if passed

      [false, "expected #{Matchers.describe(actual)} to end with #{Matchers.describe(suffix)}", nil]
    end

    define_builtin(:be_between) do |actual, low, high|
      next true if actual.between?(low, high)

      [false, "expected #{Matchers.describe(actual)} to be between " \
              "#{Matchers.describe(low)} and #{Matchers.describe(high)}", nil]
    end

    define_builtin(:satisfy) do |actual, &block|
      next [false, "satisfy needs a block: attest(x).to satisfy { |value| ... }", nil] unless block
      next true if block.call(actual)

      [false, "expected #{Matchers.describe(actual)} to satisfy the block", nil]
    end

    define_builtin(:be_within, deferred_class: WithinDeferred) do |_actual, *_args|
      raise Constable::Error, "be_within needs .of: attest(value).to be_within(0.5).of(10)"
    end

    define_builtin(:be, deferred_class: BeDeferred) do |_actual, *_args|
      raise Constable::Error, "be is handled by BeDeferred and should never invoke its block"
    end

    define_builtin(:be_a) do |actual, klass|
      next true if actual.is_a?(klass)

      [false, "expected #{Matchers.describe(actual)} to be a #{klass}, but it is a #{actual.class}", nil]
    end
    builtins[:be_an]      = builtins[:be_a]
    builtins[:be_kind_of] = builtins[:be_a]

    define_builtin(:be_nil) do |actual|
      next true if actual.nil?

      [false, "expected nil, but got #{Matchers.describe(actual)} (#{actual.class})", nil]
    end

    define_builtin(:be_empty) do |actual|
      unless actual.respond_to?(:empty?)
        next [false, "expected #{Matchers.describe(actual)} to be empty, but a #{actual.class} has no #empty?", nil]
      end
      next true if actual.empty?

      size = actual.respond_to?(:size) ? " (#{actual.size} entries)" : ""
      [false, "expected #{Matchers.describe(actual)} to be empty, but it is not#{size}", nil]
    end

    define_builtin(:be_truthy) do |actual|
      next true if actual

      [false, "expected a truthy value, but got #{actual.inspect}", nil]
    end

    define_builtin(:be_falsey) do |actual|
      next true unless actual

      [false, "expected a falsey value, but got #{Matchers.describe(actual)}", nil]
    end
  end
end
