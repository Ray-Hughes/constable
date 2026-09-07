# frozen_string_literal: true

require "date"
require "time"
require "ripper"

module Constable
  # The runtime DSL -- everything an investigator can reach for from inside an
  # `investigate` or `briefing` block that isn't an assertion matcher.
  #
  # Three of these methods exist to remove a source of nondeterminism (`freeze_time`,
  # `travel_to`, `stub_network!`), one exists only under supervision (`wait_for`), and
  # one is the single sanctioned way to bend the rules (`unsafe`). Every rule bent
  # through `unsafe` is reported, every run, without exception -- philosophy point 4.
  #
  # Nothing here requires Rails. ActiveSupport is used when it happens to be loaded and
  # is never required by us: a `:unit` tier run has to boot without an app.
  #
  # The Runner must call {#_constable_dsl_teardown} after every investigation. That one
  # call unfreezes time, lifts the network guard and clears any lingering unsafe state.
  module DSL
    UNSAFE_KEY = :constable_unsafe_stack

    class << self
      # Testing seam. :auto prefers ActiveSupport's time helpers when they are already
      # loaded; :standalone forces Constable's own stubs even in a Rails app.
      attr_accessor :time_strategy

      # True while control is inside an `unsafe` block on this thread. The sleep guard,
      # `wait_for` and the network guard all consult this; so may anything else that
      # wants to know whether the rules are currently suspended.
      def unsafe?
        !unsafe_stack.empty?
      end

      # The reason attached to the innermost active `unsafe` block, or nil.
      def unsafe_reason
        unsafe_stack.last&.fetch(:reason, nil)
      end

      # The file:line of the innermost active `unsafe` block, or nil.
      def unsafe_location
        unsafe_stack.last&.fetch(:location, nil)
      end

      def unsafe_stack
        Thread.current[UNSAFE_KEY] ||= []
      end

      def clear_unsafe!
        Thread.current[UNSAFE_KEY] = nil
      end

      # ActiveSupport is a guest, not a dependency: we look for it, we never load it.
      def activesupport_time_helpers?
        return false if time_strategy == :standalone

        defined?(::ActiveSupport::Testing::TimeHelpers) ? true : false
      rescue NameError
        false
      end
    end

    self.time_strategy = :auto

    # ------------------------------------------------------------------------------
    # Time
    # ------------------------------------------------------------------------------

    # Freezes the clock. With a block, only for the block; without one, until the end of
    # the test, at which point the Runner's teardown call unfreezes it. There is no way
    # to leave a test with the clock still stopped.
    def freeze_time(time = ::Time.now, &)
      travel_to(time, &)
    end

    # Moves the clock to a specific point. Same lifetime rules as freeze_time.
    def travel_to(time, &)
      _constable_time_machine.travel_to(time, &)
    end

    # Puts the clock back. Safe to call when time was never frozen.
    def travel_back
      _constable_time_machine.travel_back
    end
    alias unfreeze_time travel_back

    def time_frozen?
      _constable_time_machine.frozen?
    end

    # ------------------------------------------------------------------------------
    # Network
    # ------------------------------------------------------------------------------

    # Bars the door: any real outbound HTTP from here to the end of the test raises,
    # naming the host it tried to reach. Idempotent -- call it in a briefing and again
    # in an investigation and nothing doubles up.
    def stub_network!
      NetworkGuard.enable!
      true
    end

    def network_stubbed?
      NetworkGuard.enabled?
    end

    # ------------------------------------------------------------------------------
    # The escape hatch
    # ------------------------------------------------------------------------------

    # Suppresses the runtime guards for one call, and says so out loud. Always.
    #
    #   unsafe { sleep(0.1) } # testing an actual timeout path, not a code smell
    #
    # With no explicit reason we read the adjacent comment off the call site, because
    # the reporter prints it and a bare "unsafe block" tells a reviewer nothing.
    def unsafe(reason = nil, &block)
      raise ::Constable::Error, "unsafe requires a block -- there is nothing to make an exception for" unless block

      location = caller_locations(1, 1)&.first
      site     = SourceSite.at(location)
      reason ||= site.reason

      ::Constable.warn!(site.warning_message(reason), location: site.location, kind: :unsafe)

      DSL.unsafe_stack.push(reason: reason, location: site.location)
      begin
        block.call
      ensure
        DSL.unsafe_stack.pop
      end
    end

    def unsafe?
      DSL.unsafe?
    end

    # A bare sleep is the single most common source of a slow, flaky suite. The linter
    # catches it statically; this catches it at runtime when the linter was bypassed.
    def sleep(seconds = nil)
      unless DSL.unsafe?
        raise ::Constable::Error, <<~MSG.strip
          Bare sleep in a native case. A sleep is a guess about timing, and a guess about
          timing is a flake waiting for a slow CI box.

          Freeze the clock with `freeze_time` / `travel_to`, or drive the async thing to a
          deterministic finish. If you are genuinely testing a real timeout path, say so:

            unsafe { sleep(#{seconds.inspect}) } # why this test needs real elapsed time
        MSG
      end

      seconds.nil? ? Kernel.sleep : Kernel.sleep(seconds)
    end

    # Bounded polling, for something genuinely asynchronous that cannot be driven to a
    # finish. Legal only inside `unsafe`, because a retry loop is precisely the habit
    # this framework exists to remove.
    def wait_for(timeout: 2, interval: 0.05)
      unless DSL.unsafe?
        raise ::Constable::Error, <<~MSG.strip
          wait_for outside an `unsafe` block.

          Retry-until-it-passes is exactly what Constable exists to eliminate: it converts a
          real race into a slow test that fails only on someone else's machine. Make the
          thing deterministic instead -- freeze the clock, run the job inline, await the
          worker, assert on the state you control.

          If this is a genuine, irreducible asynchrony, ask for it explicitly and take the
          warning that comes with it:

            unsafe { wait_for { page.has_css?(".done") } } # real browser paint, nothing to await
        MSG
      end

      raise ::Constable::Error, "wait_for requires a block to poll" unless block_given?

      deadline  = _constable_monotonic + timeout.to_f
      attempts  = 0
      last_error = nil

      loop do
        attempts += 1
        begin
          value = yield
          return value if value
        rescue StandardError => e
          last_error = e
        end

        break if _constable_monotonic >= deadline

        Kernel.sleep(interval.to_f)
      end

      message = "wait_for gave up after #{timeout}s (#{attempts} attempt#{"s" unless attempts == 1})"
      message += ": the block never returned a truthy value" unless last_error
      message += "; last error was #{last_error.class}: #{last_error.message}" if last_error
      raise ::Constable::Error, message
    end

    # ------------------------------------------------------------------------------
    # Assertion primitives
    #
    # `attest` is sugar; these are always here underneath it. Every failure names both
    # sides -- "Expected X, got Y" -- because a failure message that says "assertion
    # failed" costs the reader a round trip to the source.
    # ------------------------------------------------------------------------------

    def assertion_count
      @assertion_count ||= 0
    end
    alias _constable_assertion_count assertion_count

    def assert(value, message = nil)
      _constable_assertion!
      return true if value

      _constable_fail(message || "Expected a truthy value, got #{_constable_show(value)}.")
    end

    def refute(value, message = nil)
      _constable_assertion!
      return true unless value

      _constable_fail(message || "Expected a falsey value, got #{_constable_show(value)}.")
    end

    def assert_equal(expected, actual, message = nil)
      _constable_assertion!
      return true if expected == actual

      _constable_fail(
        message || "Expected #{_constable_show(expected)}, got #{_constable_show(actual)}.",
        context: _constable_comparison_context(expected, actual)
      )
    end

    def refute_equal(unexpected, actual, message = nil)
      _constable_assertion!
      return true unless unexpected == actual

      _constable_fail(message || "Expected something other than #{_constable_show(unexpected)}, got it anyway.")
    end

    def assert_nil(actual, message = nil)
      _constable_assertion!
      return true if actual.nil?

      _constable_fail(message || "Expected nil, got #{_constable_show(actual)}.")
    end

    def refute_nil(actual, message = nil)
      _constable_assertion!
      return true unless actual.nil?

      _constable_fail(message || "Expected a value, got nil.")
    end

    def assert_empty(collection, message = nil)
      _constable_assertion!
      unless collection.respond_to?(:empty?)
        _constable_fail(message ||
          "Expected #{_constable_show(collection)} to be empty, but #{collection.class} has no #empty?.")
      end
      return true if collection.empty?

      size  = collection.respond_to?(:size) ? collection.size : nil
      held  = if size
                "#{size} #{size == 1 ? "entry" : "entries"}"
              else
                "something"
              end
      _constable_fail(
        message || "Expected #{_constable_show(collection)} to be empty, but it holds #{held}.",
        context: _constable_inspect(collection, limit: 1_000)
      )
    end

    def assert_includes(collection, item, message = nil)
      _constable_assertion!
      unless collection.respond_to?(:include?)
        _constable_fail(message ||
          "Expected #{_constable_show(collection)} to include #{_constable_show(item)}, " \
          "but #{collection.class} has no #include?.")
      end
      return true if collection.include?(item)

      _constable_fail(
        message || "Expected #{_constable_show(collection)} to include #{_constable_show(item)}, and it does not.",
        context: _constable_inspect(collection, limit: 1_000)
      )
    end

    def refute_includes(collection, item, message = nil)
      _constable_assertion!
      return true unless collection.respond_to?(:include?) && collection.include?(item)

      _constable_fail(
        message || "Expected #{_constable_show(collection)} not to include #{_constable_show(item)}, but it does.",
        context: _constable_inspect(collection, limit: 1_000)
      )
    end

    # Returns the exception, so the caller can go on to inspect its message or attributes.
    def assert_raises(*expected, &block)
      message  = expected.pop if expected.last.is_a?(::String)
      expected = [::StandardError] if expected.empty?
      _constable_assertion!

      raise ::Constable::Error, "assert_raises requires a block" unless block

      names = expected.map { |klass| klass.is_a?(::Module) ? klass.name : klass.inspect }.join(" or ")

      begin
        block.call
      rescue ::Exception => e # rubocop:disable Lint/RescueException -- classified by hand just below
        raise if e.is_a?(::SystemExit) || e.is_a?(::Interrupt) || e.is_a?(::SignalException)
        # An assertion failing inside the block is that assertion's news, not ours --
        # unless the caller genuinely came here to catch one.
        raise if e.is_a?(::Constable::AssertionFailed) &&
                 expected.none? { |k| k.is_a?(::Module) && k <= ::Constable::Error }
        return e if expected.any? { |klass| klass.is_a?(::Module) && e.is_a?(klass) }

        _constable_fail(
          message || "Expected #{names} to be raised, got #{e.class}: #{e.message}",
          context: ::Constable::Backtrace.clean(e.backtrace).join("\n")
        )
      end

      _constable_fail(message || "Expected #{names} to be raised, but the block completed without raising.")
    end

    def assert_predicate(object, predicate, message = nil)
      _constable_assertion!
      unless object.respond_to?(predicate)
        _constable_fail(message ||
          "Expected #{_constable_show(object)} to answer ##{predicate}, " \
          "but #{object.class} does not respond to it.")
      end
      return true if object.public_send(predicate)

      _constable_fail(message ||
        "Expected #{_constable_show(object)} to be #{predicate}, but ##{predicate} returned false.")
    end

    def refute_predicate(object, predicate, message = nil)
      _constable_assertion!
      return true unless object.respond_to?(predicate) && object.public_send(predicate)

      _constable_fail(message ||
        "Expected #{_constable_show(object)} not to be #{predicate}, but ##{predicate} returned true.")
    end

    def assert_match(pattern, string, message = nil)
      _constable_assertion!
      regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
      return true if regexp.match?(string.to_s)

      _constable_fail(
        message || "Expected #{_constable_show(string)} to match #{regexp.inspect}, and it does not.",
        context: _constable_inspect(string, limit: 1_000)
      )
    end

    def refute_match(pattern, string, message = nil)
      _constable_assertion!
      regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern.to_s))
      return true unless regexp.match?(string.to_s)

      _constable_fail(message || "Expected #{_constable_show(string)} not to match #{regexp.inspect}, but it does.")
    end

    # Rails-shaped: the expression may be a String evaluated in the block's own binding,
    # anything callable, or an Array of either.
    def assert_difference(expression, difference = 1, message = nil, &block)
      raise ::Constable::Error, "assert_difference requires a block" unless block

      expressions = expression.is_a?(::Array) ? expression : [expression]
      before      = expressions.map { |exp| _constable_evaluate(exp, block) }

      result = block.call

      expressions.each_with_index do |exp, index|
        _constable_assertion!
        after  = _constable_evaluate(exp, block)
        actual = after - before[index]
        next if actual == difference

        _constable_fail(
          message || "Expected #{_constable_describe(exp)} to change by #{difference}, but it changed by #{actual} " \
                     "(#{_constable_show(before[index])} → #{_constable_show(after)})."
        )
      end

      result
    end

    def assert_no_difference(expression, message = nil, &block)
      raise ::Constable::Error, "assert_no_difference requires a block" unless block

      expressions = expression.is_a?(::Array) ? expression : [expression]
      before      = expressions.map { |exp| _constable_evaluate(exp, block) }

      result = block.call

      expressions.each_with_index do |exp, index|
        _constable_assertion!
        after = _constable_evaluate(exp, block)
        next if after == before[index]

        _constable_fail(
          message || "Expected #{_constable_describe(exp)} not to change, but it changed by " \
                     "#{after - before[index]} (#{_constable_show(before[index])} → #{_constable_show(after)})."
        )
      end

      result
    end

    # ------------------------------------------------------------------------------
    # Runner interface
    # ------------------------------------------------------------------------------

    # The single cleanup entry point. The Runner calls this after every investigation,
    # passed or failed, so no test can hand the next one a stopped clock, a barred
    # network or a half-open unsafe block.
    def _constable_dsl_teardown
      @_constable_time_machine&.travel_back
      @_constable_time_machine = nil
      NetworkGuard.disable!
      DSL.clear_unsafe!
      nil
    end

    private

    def _constable_time_machine
      @_constable_time_machine ||= TimeMachine.build
    end

    def _constable_monotonic
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    def _constable_assertion!
      @assertion_count = assertion_count + 1
    end

    def _constable_fail(message, context: nil)
      raise ::Constable::AssertionFailed.new(message, context: context)
    end

    def _constable_show(value)
      _constable_inspect(value, limit: 120)
    end

    def _constable_inspect(value, limit: 120)
      text = begin
        value.inspect
      rescue StandardError
        "#<#{value.class} (inspect raised)>"
      end
      text.length > limit ? "#{text[0, limit]}…" : text
    end

    # Only worth showing when the one-line message had to truncate or wrap.
    def _constable_comparison_context(expected, actual)
      pair = [expected, actual].map { |v| _constable_inspect(v, limit: 2_000) }
      return nil unless pair.any? { |text| text.length > 60 || text.include?("\n") }

      "expected: #{pair[0]}\n  actual: #{pair[1]}"
    end

    def _constable_evaluate(expression, block)
      case expression
      when ::String, ::Symbol then eval(expression.to_s, block.binding) # rubocop:disable Security/Eval
      else
        unless expression.respond_to?(:call)
          raise ::Constable::Error,
                "assert_difference needs a String or something callable, got #{expression.class}"
        end

        expression.call
      end
    end

    def _constable_describe(expression)
      expression.is_a?(::String) || expression.is_a?(::Symbol) ? expression.to_s.inspect : "the block's value"
    end

    # --------------------------------------------------------------------------------
    # Time machinery
    # --------------------------------------------------------------------------------

    # A single instant, pre-computed in every shape the stubs hand back.
    class Point
      attr_reader :time, :date, :datetime

      def initialize(time)
        @time     = time
        @date     = ::Date.new(time.year, time.month, time.day)
        @datetime = ::DateTime.new(time.year, time.month, time.day, time.hour, time.min, time.sec,
                                   Rational(time.utc_offset, 86_400))
      end
    end

    # Two strategies, one interface. In a Rails app ActiveSupport already owns this job
    # and does it well -- we borrow it rather than fight it for the same singleton
    # methods. Without ActiveSupport we do it ourselves, since a :unit tier run has no
    # Rails to lean on.
    class TimeMachine
      def self.build
        DSL.activesupport_time_helpers? ? ActiveSupportMachine.new : StandaloneMachine.new
      end

      def frozen? = false

      # Whole seconds only, matching ActiveSupport: sub-second precision survives a Ruby
      # round trip but not a MySQL one, and a test should not care which it hit.
      def coerce(value)
        time = case value
               when ::Time     then value
               when ::String   then ::Time.parse(value)
               when ::Numeric  then ::Time.at(value)
               else
                 unless value.respond_to?(:to_time)
                   raise ::Constable::Error, "Cannot travel to #{value.inspect} (#{value.class}) -- " \
                                             "give me a Time, Date, String or epoch seconds"
                 end

                 value.to_time
               end
        ::Time.at(time.getlocal.to_i)
      end
    end

    # Delegates to ActiveSupport::Testing::TimeHelpers through a private carrier object,
    # so its `travel_to`/`freeze_time` never collide with ours in the Case's ancestry.
    class ActiveSupportMachine < TimeMachine
      def initialize
        super
        @depth = 0
      end

      def frozen? = @depth.positive?

      def travel_to(time, &block)
        @depth += 1
        if block
          begin
            helper.travel_to(time, &block)
          ensure
            @depth -= 1
          end
        else
          helper.travel_to(time)
        end
      end

      def travel_back
        return unless @depth.positive?

        helper.travel_back
        @depth = 0
      end

      private

      def helper
        @helper ||= ::Object.new.extend(::ActiveSupport::Testing::TimeHelpers)
      end
    end

    # The Rails-free implementation: swap the singleton methods, remember exactly what
    # was there before, and put it all back on the way out.
    class StandaloneMachine < TimeMachine
      def initialize
        super
        @point     = nil
        @installed = false
        @originals = []
      end

      attr_reader :point

      def frozen? = @installed

      def travel_to(time, &block)
        previous = @point
        @point   = Point.new(coerce(time))
        install unless @installed
        return @point.time unless block

        begin
          block.call
        ensure
          if previous
            @point = previous
          else
            travel_back
          end
        end
      end

      def travel_back
        return unless @installed

        @originals.reverse_each do |target, name, original, owned|
          singleton = target.singleton_class
          singleton.send(:remove_method, name) if singleton.method_defined?(name, false)
          singleton.send(:define_method, name, original) if owned && original
        end
        @originals.clear
        @installed = false
        @point     = nil
      end

      private

      def install
        machine = self

        stub(::Time, :now) { machine.point.time }
        stub(::Date, :today) { machine.point.date }
        stub(::DateTime, :now) { machine.point.datetime }

        # Only present when ActiveSupport's core extensions are loaded; honour the
        # application time zone if one is set, since that is what Time.current means.
        if ::Time.respond_to?(:current)
          stub(::Time, :current) do
            zone = ::Time.respond_to?(:zone) ? ::Time.zone : nil
            zone ? zone.at(machine.point.time) : machine.point.time
          end
        end
        stub(::Date, :current) { machine.point.date } if ::Date.respond_to?(:current)

        @installed = true
      end

      def stub(target, name, &)
        singleton = target.singleton_class
        original  = singleton.instance_method(name)
        owned     = singleton.method_defined?(name, false)
        @originals << [target, name, original, owned]
        target.define_singleton_method(name, &)
      end
    end

    # --------------------------------------------------------------------------------
    # Network guard
    # --------------------------------------------------------------------------------

    # Blocks real outbound HTTP for the duration of a test.
    #
    # A prepended module cannot be un-prepended in Ruby, so the patch goes on once and
    # stays; what the teardown flips is whether it bites. When WebMock (or anything
    # WebMock-shaped) is loaded it already owns Net::HTTP, and two libraries wrestling
    # over the same method is how mysterious test failures are born -- so we hand it the
    # job and take it back at teardown.
    module NetworkGuard
      class << self
        def enabled?
          @enabled ||= false
        end

        def enable!
          return true if enabled?

          if webmock?
            @webmock_engaged = true
            ::WebMock.enable! if ::WebMock.respond_to?(:enable!)
            ::WebMock.disable_net_connect!(allow_localhost: false)
          else
            install!
          end

          @enabled = true
        end

        def disable!
          return false unless enabled?

          if @webmock_engaged
            ::WebMock.allow_net_connect! if defined?(::WebMock) && ::WebMock.respond_to?(:allow_net_connect!)
            @webmock_engaged = false
          end

          @enabled = false
          true
        end

        # The guard steps aside inside an `unsafe` block -- that is what unsafe is for,
        # and the warning has already been filed.
        def blocking?
          enabled? && !DSL.unsafe?
        end

        def intercept!(address, port = nil)
          host = port ? "#{address}:#{port}" : address.to_s
          raise ::Constable::Error, <<~MSG.strip
            Real HTTP connection attempted to #{host} while stub_network! is in force.

            A test that talks to the network is a test that fails when someone else's server
            is slow. Stub this request instead -- a WebMock/VCR stub, or a double on the
            client object -- so the response is yours to control.

            If this test genuinely must reach #{address}, say so out loud:

              unsafe { ... } # why this test really does need the network
          MSG
        end

        private

        def webmock?
          defined?(::WebMock) && ::WebMock.respond_to?(:disable_net_connect!)
        end

        def install!
          return true if @installed

          require "net/http"
          ::Net::HTTP.prepend(NetHTTPGuard)
          @installed = true
        end
      end
    end

    # Net::HTTP#start covers nearly everything (Net::HTTP.get, .get_response and a bare
    # #request on an unstarted connection all route through it); #request is hooked too
    # so an already-open connection cannot slip past.
    module NetHTTPGuard
      def start(*args, **kwargs, &)
        NetworkGuard.intercept!(address, port) if NetworkGuard.blocking?
        super
      end

      def request(*args, &)
        NetworkGuard.intercept!(address, port) if NetworkGuard.blocking?
        super
      end
    end

    # --------------------------------------------------------------------------------
    # Call sites
    # --------------------------------------------------------------------------------

    # Where an `unsafe` block was written, and what the author said about it.
    #
    # The reporter prints the reason verbatim, so an unexplained escape hatch reads as
    # exactly that in the summary -- which is the pressure that gets it removed.
    SourceSite = Struct.new(:path, :line, :snippet, :comment) do
      CACHE = {} # rubocop:disable Lint/ConstantDefinitionInBlock, Style/MutableConstant

      def self.at(location)
        return new(nil, nil, "unsafe block", nil) unless location

        path = location.absolute_path || location.path
        line = location.lineno
        text = source_line(path, line)
        return new(path, line, "unsafe block", nil) unless text

        snippet, comment = split(text)
        comment ||= preceding_comment(path, line)
        new(path, line, snippet, comment)
      end

      # The trailing comment on the call's own line, else a whole-line comment directly
      # above it -- "adjacent", the same rule the UnsafeBlockVisibility cop enforces.
      def self.split(text)
        tokens = begin
          ::Ripper.lex(text)
        rescue StandardError
          []
        end
        found = tokens.find { |(_pos, type, _tok)| type == :on_comment }
        return [text.strip, nil] unless found

        column = found[0][1]
        [text[0...column].strip, found[2].to_s.sub(/\A#+\s*/, "").strip]
      end

      def self.preceding_comment(path, line)
        text = source_line(path, line - 1).to_s.strip
        return nil unless text.start_with?("#")

        stripped = text.sub(/\A#+\s*/, "").strip
        stripped.empty? ? nil : stripped
      end

      def self.source_line(path, line)
        return nil if path.nil? || line.nil? || line < 1

        lines = CACHE[path] ||= (File.readlines(path) if File.file?(path)) || []
        lines[line - 1]&.chomp
      rescue StandardError
        nil
      end

      def reason
        comment
      end

      def location
        return nil unless path

        root = ::Constable.root.to_s
        shown = path.to_s
        shown = shown.delete_prefix("#{root}/") if root != "" && shown.start_with?("#{root}/")
        "#{shown}:#{line}"
      end

      # Reads back in the summary as, e.g.:
      #   unsafe { sleep(0.1) } — "testing an actual timeout path, not a code smell"
      def warning_message(reason)
        code = snippet.to_s.empty? ? "unsafe block" : truncate(snippet)
        if reason.to_s.strip.empty?
          "#{code} — no reason given; add a trailing comment or unsafe(\"why\")"
        else
          "#{code} — \"#{reason.to_s.strip}\""
        end
      end

      private

      def truncate(text, limit = 100)
        text.length > limit ? "#{text[0, limit]}…" : text
      end
    end
  end
end
