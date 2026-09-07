# frozen_string_literal: true

require "fileutils"
require "stringio"

module Constable
  module Importer
    # The opt-in AST rewrite: RSpec/Minitest source into the native Constable DSL.
    #
    # This mode is opt-in, and reopen is the default, for one reason. A rewrite that gets
    # a conversion subtly wrong still parses, still compiles and still runs -- it just
    # asserts something slightly different from what the author wrote, and nothing tells
    # you. A superclass swap has no such failure mode. So everything here is built around
    # refusing to guess:
    #
    #   * `Parser::Source::TreeRewriter` edits byte ranges, so every line we don't
    #     explicitly convert keeps its exact original formatting.
    #   * Anything ambiguous (`before(:all)`, `let!`, `it { is_expected.to ... }`, mocks)
    #     is *flagged* and left exactly as it was -- never silently reshaped.
    #   * `shared_examples` and custom matcher definitions are left alone and logged.
    #   * The rewritten source is re-parsed before it is written anywhere. If it doesn't
    #     parse, nothing is written and the file is reported as failed.
    #   * Nothing is written at all unless the caller asks (`write:`); the deliverable of
    #     a partial conversion is `constable_modernize_report.md`.
    class Modernizer
      REPORT_FILENAME = "constable_modernize_report.md"

      # :none      -- dry run. Report only. The default.
      # :alongside -- write foo_spec.rb's conversion to foo_case.rb, never clobbering.
      # :in_place  -- overwrite the original file.
      WRITE_MODES = %i[none alongside in_place].freeze

      GROUP_METHODS       = %i[describe context xdescribe xcontext fdescribe fcontext feature].freeze
      EXAMPLE_METHODS     = %i[it specify example scenario].freeze
      SKIPPED_EXAMPLES    = %i[xit fit xspecify xexample pending].freeze
      SHARED_DEFINITIONS  = %i[shared_examples shared_examples_for shared_context].freeze
      SHARED_USES         = %i[it_behaves_like it_should_behave_like include_examples include_context].freeze
      MOCK_METHODS        = %i[receive receive_messages have_received receive_message_chain].freeze
      MOCK_ENTRY_POINTS   = %i[allow allow_any_instance_of expect_any_instance_of double instance_double
                               class_double spy stub_const].freeze
      HOOK_SCOPES_OK      = [nil, :each, :example].freeze
      MINITEST_SUPERCLASS = /(?:Test|TestCase)\z/.freeze
      SPEC_HELPERS        = %w[spec_helper rails_helper test_helper].freeze

      # One converted file. Responds to #[] and #to_h, so callers can treat it either as
      # `result.source` or as the documented `{ source:, flags:, converted: }` hash.
      Result = Struct.new(
        :path, :relative_path, :dialect, :class_name, :original, :source,
        :converted, :flags, :untouched, :error, :write_mode, :written_to,
        keyword_init: true
      ) do
        def ok?       = error.nil?
        def changed?  = ok? && source != original
        def flagged?  = !Array(flags).empty?
        def partial?  = flagged? || !Array(untouched).empty?
        def written?  = !written_to.nil?
        def counts    = { converted: Array(converted).size, flagged: Array(flags).size, untouched: Array(untouched).size }
      end

      # An aggregate over one `constable modernize` invocation.
      Run = Struct.new(:results, :report, :report_path, :write_mode, keyword_init: true) do
        def ok?       = results.all?(&:ok?)
        def failed    = results.reject(&:ok?)
        def flagged   = results.select(&:flagged?)
        def written   = results.select(&:written?)
        def to_h      = { write_mode: write_mode, report_path: report_path, results: results.map(&:to_h) }
      end

      attr_reader :path, :relative_path, :root, :config

      def initialize(path, config: Constable.config, root: nil, source: nil)
        @config = config
        @root = (root || config&.root || Constable.root).to_s
        @path = File.absolute_path?(path.to_s) ? path.to_s : File.join(@root, path.to_s)
        @relative_path = @path.delete_prefix("#{@root}/")
        @given_source = source
        @dialect = nil
      end

      # Rewrites a single file in memory. Writes nothing, ever -- see .run for that.
      def call
        source = @given_source || read_source
        return failure(source, "file not found") if source.nil?

        self.class.load_parser!
        reset!(source)

        ast = parse(source)
        return failure(source, @error) if ast.nil?

        @dialect = detect_dialect(ast)
        visit(ast, in_case: false)
        rewritten = @rewriter.process

        if rewritten != source && parse(rewritten).nil?
          # Belt and braces: a rewrite that doesn't parse is a bug in this file, not in
          # the user's spec. Hand back the original and say so rather than writing it.
          return failure(source, "rewritten source did not parse (#{@error}); nothing was changed")
        end

        build_result(source, rewritten)
      end

      class << self
        # The CLI entry point. `paths` may be files, directories or globs.
        def run(paths, config: Constable.config, root: nil, write: :none, report: true)
          root = (root || config&.root || Constable.root).to_s
          write = (write || :none).to_sym
          raise ArgumentError, "unknown write mode #{write.inspect} (expected #{WRITE_MODES.join(", ")})" unless WRITE_MODES.include?(write)

          results = expand(paths, root).map do |file|
            result = new(file, config: config, root: root).call
            result.write_mode = write
            persist(result, root, write)
            result
          end

          text = report_for(results, write_mode: write)
          report_path = nil
          if report
            report_path = File.join(root, REPORT_FILENAME)
            File.write(report_path, text)
          end
          Run.new(results: results, report: text, report_path: report_path, write_mode: write)
        end

        # `constable modernize` is useless without the parser gem, but Constable itself
        # boots fine without it, so the require is lazy and the failure is a sentence.
        def load_parser!
          return if defined?(::Parser::CurrentRuby)

          begin
            # parser/current prints a version-skew notice for every patch-level mismatch.
            # It's noise on a CLI and there is nothing the user can do about it.
            captured = $stderr
            $stderr = StringIO.new
            require "parser/current"
          ensure
            $stderr = captured
          end
        rescue LoadError
          raise Constable::Error,
                "constable modernize needs the `parser` gem (a runtime dependency of " \
                "constable-rails). Run `bundle install`, or use `constable import` -- " \
                "the default reopen mode needs no parser at all."
        end

        def report_for(results, write_mode: :none)
          Report.new(results, write_mode: write_mode).to_markdown
        end

        def expand(paths, root)
          Array(paths).flat_map do |entry|
            absolute = File.absolute_path?(entry.to_s) ? entry.to_s : File.join(root, entry.to_s)
            if File.directory?(absolute)
              Dir.glob(File.join(absolute, "**", "*{_spec,_test}.rb")).sort
            elsif absolute.include?("*")
              Dir.glob(absolute).sort
            else
              [absolute]
            end
          end.uniq
        end

        # Output path for :alongside -- users_controller_spec.rb -> users_controller_case.rb.
        def alongside_path(path)
          dir = File.dirname(path)
          base = File.basename(path, ".rb").sub(/_(?:spec|test)\z/, "")
          File.join(dir, "#{base}_case.rb")
        end

        private

        def persist(result, root, write)
          return unless result.ok? && result.changed?

          case write
          when :in_place
            File.write(result.path, result.source)
            result.written_to = result.relative_path
          when :alongside
            target = alongside_path(result.path)
            if File.exist?(target)
              result.error = "refusing to overwrite #{target.delete_prefix("#{root}/")}; " \
                             "move it aside, or use write: :in_place"
            else
              FileUtils.mkdir_p(File.dirname(target))
              File.write(target, result.source)
              result.written_to = target.delete_prefix("#{root}/")
            end
          end
        end
      end

      private

      def read_source
        File.read(@path)
      rescue StandardError
        nil
      end

      def reset!(source)
        @source = source
        @error = nil
        @converted = []
        @flags = []
        @untouched = []
        @class_name = nil
        @buffer = ::Parser::Source::Buffer.new(@relative_path, source: source)
        @rewriter = ::Parser::Source::TreeRewriter.new(@buffer)
      end

      def parse(source)
        buffer = ::Parser::Source::Buffer.new(@relative_path, source: source)
        parser = ::Parser::CurrentRuby.new
        parser.diagnostics.all_errors_are_fatal = true
        parser.diagnostics.consumer = ->(_diagnostic) {}
        parser.parse(buffer)
      rescue ::Parser::SyntaxError => e
        @error = "syntax error: #{e.message}"
        nil
      rescue StandardError => e
        @error = "could not parse: #{e.message}"
        nil
      end

      def failure(source, message)
        Result.new(path: @path, relative_path: @relative_path, dialect: @dialect,
                   class_name: nil, original: source, source: source,
                   converted: [], flags: [], untouched: [], error: message)
      end

      def build_result(source, rewritten)
        Result.new(
          path: @path, relative_path: @relative_path, dialect: @dialect,
          class_name: @class_name, original: source, source: rewritten,
          converted: @converted.sort_by { |c| c[:line] },
          flags: @flags.sort_by { |f| f[:line] },
          untouched: @untouched.sort_by { |u| u[:line] },
          error: nil
        )
      end

      # ---- dialect -----------------------------------------------------------------

      def detect_dialect(ast)
        return :rspec if find_node(ast) { |n| n.type == :block && group_call?(n.children[0]) }
        return :minitest if find_node(ast) { |n| n.type == :def && n.children[0].to_s.start_with?("test_") }
        return :minitest if find_node(ast) { |n| n.type == :class && minitest_superclass?(n.children[1]) }

        :unknown
      end

      def find_node(node, &block)
        return nil unless node.is_a?(::Parser::AST::Node)
        return node if block.call(node)

        node.children.each do |child|
          found = find_node(child, &block)
          return found if found
        end
        nil
      end

      # ---- the walk ----------------------------------------------------------------

      def visit(node, in_case:)
        return unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :block then visit_block(node, in_case: in_case)
        when :class then visit_class(node, in_case: in_case)
        when :def   then visit_def(node, in_case: in_case)
        when :send  then visit_send(node, in_case: in_case)
        else visit_children(node, in_case: in_case)
        end
      end

      def visit_children(node, in_case:)
        node.children.each { |child| visit(child, in_case: in_case) }
      end

      def visit_block(node, in_case:)
        send_node, block_args, _body = node.children
        return visit_children(node, in_case: in_case) unless send_node.is_a?(::Parser::AST::Node) && send_node.type == :send

        name = send_node.children[1]

        return handle_group(node, send_node, in_case: in_case)      if group_call?(send_node)
        return handle_shared_definition(node, send_node)            if SHARED_DEFINITIONS.include?(name)
        return handle_matcher_definition(node, send_node)           if matcher_definition?(send_node)
        return handle_example(node, send_node, block_args)          if EXAMPLE_METHODS.include?(name) && send_node.children[0].nil?
        return handle_skipped_example(node, send_node)              if SKIPPED_EXAMPLES.include?(name) && send_node.children[0].nil?
        return handle_let(node, send_node)                          if %i[let let!].include?(name) && send_node.children[0].nil?
        return handle_subject(node, send_node)                      if %i[subject subject!].include?(name) && send_node.children[0].nil?
        return handle_hook(node, send_node)                         if %i[before after around append_after prepend_before].include?(name) && send_node.children[0].nil?
        return handle_its(node, send_node)                          if name == :its && send_node.children[0].nil?

        visit_children(node, in_case: in_case)
      end

      # `describe X do` at the top of a file becomes the case class; anything nested
      # inside it becomes a docket, which is the DSL's own grouping construct.
      def handle_group(node, send_node, in_case:)
        if in_case
          convert_to_docket(node, send_node)
        else
          convert_to_case_class(node, send_node)
        end
        visit_children_of_block(node, in_case: true)
      end

      def convert_to_case_class(node, send_node)
        args = send_node.children[2..] || []
        @class_name = case_class_name(args.first)
        replace(block_head(node), "class #{@class_name} < Constable::Case")
        close_brace_block(node)
        record_converted(:case_class, node, "#{source_of(send_node)} do", "class #{@class_name} < Constable::Case")
        return if args.size <= 1

        note_untouched(:describe_metadata, node,
                       "extra arguments to `#{send_node.children[1]}` (#{args[1..].map { |a| source_of(a) }.join(", ")}) " \
                       "were dropped -- Constable has no example metadata")
      end

      def convert_to_docket(node, send_node)
        args = send_node.children[2..] || []
        description = docket_description(args.first, send_node)
        replace(send_node.loc.expression, "docket #{description}")
        record_converted(:docket, node, source_of(send_node), "docket #{description}")
      end

      def handle_example(node, send_node, block_args)
        args = send_node.children[2..] || []
        if args.empty?
          # `it { is_expected.to be_valid }` -- there is no description to carry over and
          # no subject in the native DSL. Naming it for the user would be inventing an
          # assertion's intent, so it stays exactly as written.
          return flag(:one_liner_example, node,
                      "`#{send_node.children[1]} { ... }` has no description and relies on an implicit " \
                      "subject. Write it as `investigate \"...\" do attest(subject).to ... end`.")
        end
        unless args.size == 1 && args.first.type == :str
          return flag(:example_metadata, node,
                      "`#{source_of(send_node)}` carries metadata or a non-literal description; " \
                      "Constable's `investigate` takes a plain string only.")
        end
        unless block_args.children.empty?
          return flag(:example_block_args, node,
                      "`#{source_of(send_node)}` yields block arguments; `investigate` runs its block " \
                      "in a fresh case instance and yields nothing.")
        end

        replace(send_node.loc.selector, "investigate")
        record_converted(:investigate, node, "#{send_node.children[1]} #{source_of(args.first)}",
                         "investigate #{source_of(args.first)}")
        visit_children_of_block(node, in_case: true)
      end

      def handle_skipped_example(node, send_node)
        flag(:skipped_example, node,
             "`#{send_node.children[1]}` is an RSpec skip/focus marker. Constable has no equivalent -- " \
             "convert it to `investigate` and jail it (`constable test --jail`) if it should not run yet.")
      end

      def handle_let(node, send_node)
        name = send_node.children[1]
        args = send_node.children[2..] || []

        if name == :let!
          # `let!` runs eagerly before every example; `witness` is lazy and memoized
          # per-test. Swapping one for the other changes when the record is created,
          # which is exactly the kind of silent behaviour change this tool won't make.
          return flag(:eager_let, node,
                      "`let!` is eager -- it runs before every example whether or not it is referenced. " \
                      "`witness` is lazy. Move the side effect into a `briefing` block, then declare the " \
                      "value as `witness`.")
        end
        unless args.size == 1 && %i[sym str].include?(args.first.type)
          return flag(:dynamic_let, node, "`#{source_of(send_node)}` does not name a single literal helper.")
        end

        replace(send_node.loc.selector, "witness")
        record_converted(:witness, node, source_of(send_node), "witness(#{source_of(args.first)})")
        visit_children_of_block(node, in_case: true)
      end

      def handle_subject(node, send_node)
        name = send_node.children[1]
        args = send_node.children[2..] || []

        if name == :subject!
          return flag(:eager_subject, node, "`subject!` is eager, like `let!`. Split it into a `briefing` " \
                                            "side effect plus a lazy `witness`.")
        end

        if args.empty?
          # An anonymous `subject` is just a witness with a well-known name. That is a
          # faithful conversion, so it happens -- and the report says it happened.
          replace(send_node.loc.expression, "witness(:subject)")
          record_converted(:subject, node, "subject", "witness(:subject)",
                           note: "an anonymous `subject` became `witness(:subject)`; `is_expected` and " \
                                 "`should` have no equivalent and are flagged separately")
        elsif args.size == 1 && %i[sym str].include?(args.first.type)
          replace(send_node.loc.selector, "witness")
          record_converted(:subject, node, source_of(send_node), "witness(#{source_of(args.first)})")
        else
          return flag(:dynamic_subject, node, "`#{source_of(send_node)}` does not name a single literal subject.")
        end
        visit_children_of_block(node, in_case: true)
      end

      def handle_hook(node, send_node)
        name = send_node.children[1]
        args = send_node.children[2..] || []
        scope = args.first && args.first.type == :sym ? args.first.children[0] : nil

        if name != :before || args.size > 1 || !HOOK_SCOPES_OK.include?(scope)
          return flag(hook_flag_kind(name, scope), node, hook_flag_reason(name, scope, send_node))
        end

        replace(send_node.loc.expression, "briefing")
        to_do_end(node)
        record_converted(:briefing, node, "#{source_of(send_node)} #{node.loc.begin.source}",
                         "briefing do")
        visit_children_of_block(node, in_case: true)
      end

      def hook_flag_kind(name, scope)
        return :before_all if name == :before && %i[all context suite].include?(scope)

        name == :around ? :around_hook : :"#{name}_hook"
      end

      def hook_flag_reason(name, scope, send_node)
        if name == :before && %i[all context suite].include?(scope)
          "`before(:#{scope})` runs once for a whole group and shares its state across examples. " \
            "Constable has no equivalent by design -- isolation is the point. Decide per case whether " \
            "the setup is cheap enough to move into `briefing` (runs per test) or belongs in a fixture."
        elsif name == :after
          "`after` has no `briefing` counterpart. Native cases roll back their transaction and restore " \
            "DSL global state automatically, so most `after` blocks are redundant -- check this one and delete it."
        elsif name == :around
          "`around` wraps an example; Constable owns the wrapping (transaction, isolation, timing) and " \
            "exposes no hook for it. Move the setup half into `briefing`."
        else
          "`#{source_of(send_node)}` is a hook form Constable does not model."
        end
      end

      def handle_its(node, send_node)
        flag(:its, node, "`its(#{source_of(send_node.children[2])})` is an implicit-subject one-liner. " \
                         "Write it as `investigate \"...\" do attest(subject.#{literal_value(send_node.children[2])}).to ... end`.")
      end

      def handle_shared_definition(node, send_node)
        note_untouched(:shared_examples, node,
                       "`#{source_of(send_node)}` left untouched. Constable has no shared-examples DSL on " \
                       "purpose -- shared behaviour is a plain Ruby module in test/support that each case " \
                       "`include`s. Extract it by hand.")
      end

      def handle_matcher_definition(node, send_node)
        note_untouched(:custom_matcher, node,
                       "`#{source_of(send_node)}` left untouched. Port it to " \
                       "`Constable::Matchers.define(:name) { |actual, *args| ... }` in test/support.")
      end

      def matcher_definition?(send_node)
        receiver, name, * = send_node.children
        return true if name == :define && receiver && source_of(receiver).end_with?("Matchers")
        return true if name == :matcher && receiver.nil?

        false
      end

      # ---- send-level rewrites -----------------------------------------------------

      def visit_send(node, in_case:)
        receiver, name, *args = node.children

        if %i[to not_to to_not].include?(name) && mock_expectation?(args.first)
          return note_untouched(:rspec_mocks, node,
                                "`#{first_line(node)}` is an RSpec message expectation. Constable ships no " \
                                "mocking library -- keep rspec-mocks via a cold case, or replace it with a " \
                                "stub object.")
        end

        if MOCK_ENTRY_POINTS.include?(name) && receiver.nil?
          note_untouched(:rspec_mocks, node,
                         "`#{first_line(node)}` uses rspec-mocks. Constable has no equivalent; convert it by hand.")
          return
        end

        if SHARED_USES.include?(name) && receiver.nil?
          note_untouched(:shared_examples, node,
                         "`#{first_line(node)}` pulls in shared examples. Replace with a plain module `include`.")
          return
        end

        case name
        when :expect
          replace(node.loc.selector, "attest") if receiver.nil?
          record_converted(:attest, node, "expect", "attest") if receiver.nil?
        when :is_expected
          flag(:is_expected, node,
               "`is_expected` needs RSpec's implicit subject. Use `attest(subject)` -- an anonymous " \
               "`subject` block is converted to `witness(:subject)` for you.") if receiver.nil?
        when :should, :should_not
          flag(:should_syntax, node, "`#{name}` is RSpec's monkey-patched expectation syntax. Use `attest(...).to`.")
        when :described_class
          flag(:described_class, node,
               "`described_class` has no meaning once `describe X` is a real class. Name the class directly.") if receiver.nil?
        when :to_not
          replace(node.loc.selector, "not_to")
          record_converted(:not_to, node, "to_not", "not_to")
        when :require, :require_relative
          convert_helper_require(node, args.first)
        end

        visit_children(node, in_case: in_case)
      end

      def convert_helper_require(node, arg)
        return unless arg.is_a?(::Parser::AST::Node) && arg.type == :str

        value = arg.children[0].to_s
        return unless SPEC_HELPERS.include?(File.basename(value))

        replaced = value.sub(/#{Regexp.escape(File.basename(value))}\z/, "case_helper")
        replace(arg.loc.expression, replaced.inspect)
        record_converted(:helper_require, node, value, replaced)
      end

      def mock_expectation?(node)
        return false unless node.is_a?(::Parser::AST::Node)

        !!find_node(node) { |n| n.type == :send && MOCK_METHODS.include?(n.children[1]) }
      end

      # ---- Minitest ----------------------------------------------------------------

      def visit_class(node, in_case:)
        name_node, superclass, body = node.children

        unless minitest_superclass?(superclass)
          return visit_children(node, in_case: in_case)
        end

        @class_name = minitest_class_name(name_node)
        replace(name_node.loc.expression, @class_name) if @class_name != source_of(name_node)
        replace(superclass.loc.expression, "Constable::Case")
        record_converted(:case_class, node, "class #{source_of(name_node)} < #{source_of(superclass)}",
                         "class #{@class_name} < Constable::Case")
        visit(body, in_case: true)
      end

      def minitest_superclass?(node)
        return false unless node.is_a?(::Parser::AST::Node) && %i[const send].include?(node.type)

        source_of(node).match?(MINITEST_SUPERCLASS)
      end

      def minitest_class_name(name_node)
        source_of(name_node).sub(/Test\z/, "Case").then { |n| n.end_with?("Case") ? n : "#{n}Case" }
      end

      def visit_def(node, in_case:)
        name, args, body = node.children
        return visit_children(node, in_case: in_case) unless in_case

        if name.to_s.start_with?("test_")
          convert_test_method(node, name, args, body)
        elsif name == :setup
          convert_setup_method(node, args, body)
        elsif name == :teardown
          flag(:teardown, node,
               "`teardown` has no Constable equivalent -- isolation is restored automatically. " \
               "Delete it, or move anything genuinely needed into the `investigate` body.")
        else
          note_untouched(:helper_method, node,
                         "`def #{name}` left as an ordinary instance method -- that works unchanged on a " \
                         "`Constable::Case`.")
          visit_children(node, in_case: in_case)
        end
      end

      def convert_test_method(node, name, args, body)
        description = name.to_s.delete_prefix("test_").tr("_", " ").strip
        return flag(:endless_def, node, "`def #{name} = ...` is an endless method; rewrite it as a block first.") if node.loc.end.nil?
        return flag(:test_method_args, node, "`def #{name}` takes arguments; `investigate` yields nothing.") unless args.children.empty?
        return flag(:super_in_test, node, "`def #{name}` calls `super`; inside an `investigate` block `super` " \
                                          "would resolve against the block's enclosing scope, not the test.") if calls_super?(body)

        replace(def_head(node), "investigate #{description.inspect} do")
        record_converted(:investigate, node, "def #{name}", "investigate #{description.inspect} do")
        visit(body, in_case: true)
      end

      def convert_setup_method(node, args, body)
        return flag(:endless_def, node, "`def setup = ...` is an endless method; rewrite it as a block first.") if node.loc.end.nil?
        return flag(:setup_args, node, "`def setup` takes arguments, which `briefing` cannot supply.") unless args.children.empty?
        return flag(:super_in_setup, node, "`def setup` calls `super`; `briefing` blocks already chain from " \
                                           "parent to child, so the `super` call must be removed by hand.") if calls_super?(body)

        replace(def_head(node), "briefing do")
        record_converted(:briefing, node, "def setup", "briefing do")
        visit(body, in_case: true)
      end

      def calls_super?(body)
        !!find_node(body) { |n| %i[super zsuper].include?(n.type) }
      end

      def def_head(node) = range(node.loc.keyword.begin_pos, node.loc.name.end_pos)

      # ---- rewriting primitives ----------------------------------------------------

      def replace(range_or_loc, text) = @rewriter.replace(range_or_loc, text)

      def range(from, to) = ::Parser::Source::Range.new(@buffer, from, to)

      # `describe X do` -- everything up to and including the block opener.
      def block_head(node) = range(node.loc.expression.begin_pos, node.loc.begin.end_pos)

      # A `{ }` block whose head we replaced with a `class`/`do` opener needs its closer
      # turned into `end` too.
      def close_brace_block(node)
        replace(node.loc.end, "end") if node.loc.begin.source == "{"
      end

      def to_do_end(node)
        return unless node.loc.begin.source == "{"

        replace(node.loc.begin, "do")
        replace(node.loc.end, "end")
      end

      def visit_children_of_block(node, in_case:)
        visit(node.children[2], in_case: in_case)
      end

      def group_call?(send_node)
        return false unless send_node.is_a?(::Parser::AST::Node) && send_node.type == :send

        receiver, name, * = send_node.children
        return false unless GROUP_METHODS.include?(name)
        return true if receiver.nil?

        receiver.type == :const && receiver.children[1] == :RSpec
      end

      # ---- naming ------------------------------------------------------------------

      # `describe UsersController` -> UsersControllerCase, per SPEC.md's `class XCase`.
      # A namespaced constant keeps its namespace: `describe Admin::Users` -> Admin::UsersCase.
      def case_class_name(arg)
        base =
          case arg&.type
          when :const then source_of(arg)
          when :str   then Reopener.camelize(arg.children[0].to_s)
          when :sym   then Reopener.camelize(arg.children[0].to_s)
          else Reopener.camelize(File.basename(@relative_path, ".rb").sub(/_(?:spec|test)\z/, ""))
          end
        base = Reopener.camelize(File.basename(@relative_path, ".rb")) if base.to_s.empty?
        base.end_with?("Case") ? base : "#{base}Case"
      end

      def docket_description(arg, send_node)
        case arg&.type
        when :str then source_of(arg)
        when :sym then arg.children[0].to_s.inspect
        when nil  then send_node.children[1].to_s.inspect
        else source_of(arg).inspect
        end
      end

      def literal_value(node)
        return node.children[0].to_s if node.is_a?(::Parser::AST::Node) && %i[str sym].include?(node.type)

        source_of(node)
      end

      # ---- bookkeeping -------------------------------------------------------------

      def source_of(node)
        return "" unless node.is_a?(::Parser::AST::Node) && node.loc&.expression

        node.loc.expression.source
      end

      def first_line(node) = source_of(node).lines.first.to_s.strip

      def line_of(node) = node.loc.expression.line

      def location(node) = "#{@relative_path}:#{line_of(node)}"

      def record_converted(kind, node, from, to, note: nil)
        @converted << { kind: kind, location: location(node), line: line_of(node),
                        from: from, to: to, note: note }
      end

      def flag(kind, node, reason)
        @flags << { kind: kind, location: location(node), line: line_of(node),
                    source: first_line(node), reason: reason }
        nil
      end

      def note_untouched(kind, node, reason)
        @untouched << { kind: kind, location: location(node), line: line_of(node),
                        source: first_line(node), reason: reason }
        nil
      end

      # Renders constable_modernize_report.md. When a conversion is partial -- and it
      # usually is -- this file, not the rewritten source, is the deliverable.
      class Report
        def initialize(results, write_mode: :none)
          @results = Array(results)
          @write_mode = write_mode
        end

        def to_markdown
          out = +"# Constable modernize report\n\n"
          out << preamble
          out << headline
          @results.each { |result| out << file_section(result) }
          out
        end

        private

        def preamble
          <<~TEXT
            `constable modernize` rewrites RSpec/Minitest source into the native Constable DSL
            using an AST rewriter, so every line it does not explicitly convert keeps its exact
            original formatting. It converts only what it can convert faithfully. **Everything
            listed under _Flagged_ below was left exactly as written** -- a rewrite that guesses
            wrong still parses and still passes, which is precisely the failure this tool refuses
            to risk. Work the flags by hand.

            Nothing here is required. `constable import` reopens these files verbatim as cold
            cases, and cold cases run alongside native ones forever.

            Write mode: **#{write_mode_label}**

          TEXT
        end

        def write_mode_label
          case @write_mode
          when :in_place  then "in place -- the original files were overwritten"
          when :alongside then "alongside -- conversions were written to `*_case.rb` next to the originals"
          else "dry run -- no source file was written; this report is the only output"
          end
        end

        def headline
          converted = @results.sum { |r| Array(r.converted).size }
          flagged   = @results.sum { |r| Array(r.flags).size }
          untouched = @results.sum { |r| Array(r.untouched).size }
          failed    = @results.count { |r| !r.ok? }

          out = +"## Summary\n\n"
          out << "| Files | Converted | Flagged | Left untouched | Failed |\n"
          out << "|---|---|---|---|---|\n"
          out << "| #{@results.size} | #{converted} | #{flagged} | #{untouched} | #{failed} |\n\n"
          out
        end

        def file_section(result)
          out = +"## `#{result.relative_path}`\n\n"

          unless result.ok?
            out << "**Not converted.** #{result.error}\n\n"
            out << "The file was left exactly as it was. Reopen it instead: `constable import`.\n\n"
            return out
          end

          out << "- dialect: `#{result.dialect}`\n"
          out << "- case class: `#{result.class_name}`\n" if result.class_name
          out << "- written to: #{result.written_to ? "`#{result.written_to}`" : "nothing (dry run)"}\n"
          out << "- status: #{status_line(result)}\n\n"

          out << list("Converted", result.converted) { |item| "`#{squish(item[:from])}` -> `#{squish(item[:to])}`#{" -- #{item[:note]}" if item[:note]}" }
          out << list("Flagged -- NOT converted, still as written", result.flags) { |item| "**#{item[:kind]}** `#{squish(item[:source])}` -- #{item[:reason]}" }
          out << list("Left untouched", result.untouched) { |item| "**#{item[:kind]}** `#{squish(item[:source])}` -- #{item[:reason]}" }
          out
        end

        def status_line(result)
          return "no change -- nothing in this file needed converting" unless result.changed?
          return "**partial** -- #{Array(result.flags).size} flag(s) need a human decision" if result.flagged?

          "converted cleanly"
        end

        def list(title, items)
          items = Array(items)
          return "" if items.empty?

          out = +"### #{title} (#{items.size})\n\n"
          items.each { |item| out << "- `#{item[:location]}` #{yield(item)}\n" }
          out << "\n"
          out
        end

        def squish(text) = text.to_s.gsub(/\s+/, " ").strip
      end
    end
  end
end
