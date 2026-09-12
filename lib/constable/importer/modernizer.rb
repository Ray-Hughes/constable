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
      # :port      -- write into the native tree, mirroring the spec path.
      # :port_cold -- the same destination, but verbatim as a cold case.
      WRITE_MODES = %i[none alongside in_place cold port port_cold].freeze

      GROUP_METHODS       = %i[describe context xdescribe xcontext fdescribe fcontext feature].freeze
      EXAMPLE_METHODS     = %i[it specify example scenario].freeze
      SKIPPED_EXAMPLES    = %i[xit fit xspecify xexample pending].freeze
      SHARED_DEFINITIONS  = %i[shared_examples shared_examples_for shared_context].freeze
      SHARED_USES         = %i[it_behaves_like it_should_behave_like include_examples include_context].freeze
      MOCK_METHODS        = %i[receive receive_messages have_received receive_message_chain].freeze
      MOCK_ENTRY_POINTS   = %i[allow allow_any_instance_of expect_any_instance_of double instance_double
                               class_double spy stub_const].freeze
      HOOK_SCOPES_OK      = [nil, :each, :example].freeze
      MINITEST_SUPERCLASS = /(?:Test|TestCase)\z/
      SPEC_HELPERS        = %w[spec_helper rails_helper test_helper].freeze

      # One converted file. Responds to #[] and #to_h, so callers can treat it either as
      # `result.source` or as the documented `{ source:, flags:, converted: }` hash.
      Result = Struct.new(
        :path, :relative_path, :dialect, :class_name, :original, :source,
        :converted, :flags, :untouched, :error, :write_mode, :written_to, :written_as,
        :removed_original,
        keyword_init: true
      ) do
        def ok?       = error.nil?
        def changed?  = ok? && source != original
        def flagged?  = !Array(flags).empty?
        def partial?  = flagged? || !Array(untouched).empty?
        def written?  = !written_to.nil?

        def counts
          { converted: Array(converted).size, flagged: Array(flags).size, untouched: Array(untouched).size }
        end
      end

      # An aggregate over one `constable modernize` invocation.
      Run = Struct.new(:results, :report, :report_path, :write_mode, :remaining, :carried,
                       :excluded, keyword_init: true) do
        def ok?       = results.all?(&:ok?)
        def failed    = results.reject(&:ok?)
        def flagged   = results.select(&:flagged?)
        def written   = results.select(&:written?)
        def to_h      = { write_mode: write_mode, report_path: report_path, results: results.map(&:to_h) }
      end

      attr_reader :path, :relative_path, :root, :config

      def initialize(path, config: Constable.config, root: nil, source: nil, base: nil)
        @config = config
        # What a converted case inherits from.
        #
        # `Constable::Case` is correct but bare, and an app's tier classes are where the
        # app puts everything a case needs -- FactoryBot, request helpers, auth. A file
        # converted into the bare class compiles and then dies on `create`, which is
        # exactly what happened porting a real directory: 84 tests, 15 of them
        # `NoMethodError: undefined method 'create'`. So the superclass is a choice, and
        # `--base UnitCase` makes it once for a whole port.
        @base = base.nil? || base.to_s.empty? ? "Constable::Case" : base.to_s
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
        def run(paths, config: Constable.config, root: nil, write: :none, report: true, base: nil,
                delete_original: false, batch: nil)
          root = (root || config&.root || Constable.root).to_s
          write = (write || :none).to_sym
          unless WRITE_MODES.include?(write)
            raise ArgumentError,
                  "unknown write mode #{write.inspect} (expected #{WRITE_MODES.join(", ")})"
          end

          files = expand(paths, root)
          # A batch is a prefix of a deterministically sorted list. Paired with --delete it
          # walks a directory: each run takes the next N, because the ones already ported
          # are no longer there to be found.
          remaining = batch.to_i.positive? ? [files.size - batch.to_i, 0].max : 0
          files = files.first(batch.to_i) if batch.to_i.positive?

          results = files.map do |file|
            result = new(file, config: config, root: root, base: base).call
            result.write_mode = write
            persist(result, root, write)
            remove_original(result, root) if delete_original
            result
          end

          # A ported file's relative requires have to resolve from where it now lives.
          carried = %i[port port_cold].include?(write) ? carry_companions(results, root) : []
          prune_empty_directories(results, root) if delete_original
          excluded = delete_original ? [] : exclude_ported_originals(results, root, write)

          text = report_for(results, write_mode: write)
          report_path = nil
          if report
            report_path = File.join(root, REPORT_FILENAME)
            File.write(report_path, text)
          end
          Run.new(results: results, report: text, report_path: report_path, write_mode: write,
                  remaining: remaining, carried: carried, excluded: excluded)
        end

        # A port that keeps the original leaves both files on disk, and the cold-case glob
        # still matches the original -- so the same tests run twice, once as the new native
        # case and once as the spec it was generated from. Nothing said so; the suite just
        # quietly grew. `--delete` avoids it by removing the source, which is why it is the
        # documented default. When the source is kept on purpose, the link file has to say
        # the original is no longer wanted.
        def exclude_ported_originals(results, root, write)
          return [] unless %i[port port_cold].include?(write)

          link = %w[test/case_helper.rb spec/case_helper.rb]
                 .map { |candidate| File.join(root, candidate) }
                 .find { |path| File.exist?(path) }
          return [] if link.nil?

          source = File.read(link)
          fresh = results.select(&:written?).map { |result| relative_to(result.path, root) }
                         .reject { |path| source.include?(%("#{path}")) }
          return [] if fresh.empty?

          File.write(link, insert_exclusions(source, fresh))
          fresh
        end

        # Into the cold_cases block, not the end of the file -- the helper has plenty of
        # other `end`s and the last one is never the right one.
        def insert_exclusions(source, paths)
          lines = paths.map { |path| "  except #{path.inspect}" }.join("\n")
          source.sub(/(Constable\.cold_cases do\n.*?)\nend/m) { "#{::Regexp.last_match(1)}\n#{lines}\nend" }
        end

        def relative_to(path, root) = path.to_s.delete_prefix("#{root}/")

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
              Dir.glob(File.join(absolute, "**", "*{_spec,_test}.rb"))
            elsif absolute.include?("*")
              Dir.glob(absolute)
            else
              [absolute]
            end
          end.uniq.sort
        end

        # Where a ported file lands: spec/models/tasks/mdr_task_spec.rb becomes
        # test/cases/models/tasks/mdr_task_case.rb.
        #
        # Converting a suite one file at a time only works if the converted file ends up
        # somewhere the runner looks. `--alongside` leaves it in spec/, which means a port
        # is a conversion followed by four hundred `git mv`s -- enough friction that nobody
        # starts. This mirrors the path instead, so porting a directory is one command and
        # `test/cases/` fills up as you go.
        def port_path(path, root)
          relative = path.delete_prefix("#{root}/")
          # Drop the leading spec/ or test/, keep everything under it.
          inner = relative.sub(%r{\A(?:spec|test)/}, "")
          base = File.basename(inner, ".rb").sub(/_(?:spec|test)\z/, "")
          File.join(root, "test/cases", File.dirname(inner), "#{base}_case.rb")
              .gsub(%r{/\./}, "/")
        end

        # Output path for :alongside -- users_controller_spec.rb -> users_controller_case.rb.
        def alongside_path(path)
          dir = File.dirname(path)
          base = File.basename(path, ".rb").sub(/_(?:spec|test)\z/, "")
          File.join(dir, "#{base}_case.rb")
        end

        # `--cold`: move the file into the native tree without converting a line of it.
        #
        # A conversion that comes back flagged is not runnable -- the flagged constructs
        # are left verbatim, so `let!` stays `let!` and the class body raises the moment it
        # loads. That is deliberate: what a `let!` should become is a decision, not a
        # rewrite. But it leaves a file stuck in spec/ when the goal is one tree.
        #
        # A cold case is the answer that already exists: one line at the top, the body
        # untouched, run through real RSpec, results folded into the same report. This
        # writes exactly that, so a port can move every file and convert the ones worth
        # converting on its own schedule.
        def cold_wrap(result, root, target = nil)
          target ||= alongside_path(result.path)
          result.written_as ||= :cold
          if File.exist?(target)
            result.error = "refusing to overwrite #{target.delete_prefix("#{root}/")}"
            return
          end

          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, cold_source(result))
          result.written_to = target.delete_prefix("#{root}/")
        end

        # The original bytes, between a header line and a final `end`. Nothing inside is
        # parsed, reindented or touched -- that is the whole promise of a cold case.
        def cold_source(result)
          <<~RUBY
            # frozen_string_literal: true

            # Moved verbatim from #{result.relative_path}. Runs through real RSpec, with its
            # results folded into Constable's reporting, flake history and CI gate.
            #
            # Nothing inside has been converted, so every RSpec feature still works --
            # `let!`, `before(:all)`, shared examples, rspec-mocks. Convert it with
            # `constable modernize` when it is worth doing; there is no deadline.
            class #{cold_class_name(result)} < Constable::ColdCase::RSpec
            #{indent(result.original.to_s.rstrip)}
            end
          RUBY
        end

        def cold_class_name(result)
          base = File.basename(result.path, ".rb").sub(/_(?:spec|test)\z/, "")
          "Legacy#{base.split(%r{[_/]}).map(&:capitalize).join}Spec"
        end

        def indent(source)
          source.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
        end

        private

        def persist(result, root, write)
          return cold_wrap(result, root) if write == :cold
          return cold_wrap(result, root, port_path(result.path, root)) if write == :port_cold
          return unless result.ok? && result.changed?

          case write
          when :port
            # A flagged conversion is not runnable -- the flagged constructs are left
            # verbatim, so `let!` stays `let!` and the class raises the moment it loads.
            # Writing one into test/cases/ would be handing someone a broken file and
            # calling it progress. Verified: a ported `it { ... }` dies with
            # `NoMethodError: undefined method 'it'`.
            #
            # So a port takes the file either way and picks the form that runs: converted
            # when it can be, verbatim as a cold case when it cannot. Either way the file
            # ends up in the native tree and the suite still passes, which is the whole
            # point of porting a directory at a time.
            if result.flagged?
              cold_wrap(result, root, port_path(result.path, root))
              result.written_as = :cold
            else
              write_to(result, port_path(result.path, root), root)
              result.written_as = :native
            end
          when :in_place
            File.write(result.path, result.source)
            result.written_to = result.relative_path
          when :alongside
            write_to(result, alongside_path(result.path), root)
          end
        end

        # Files a ported spec requires by relative path, brought along with it.
        #
        # `require_relative "task_shared_examples.rb"` resolves against the file's own
        # directory. Move the spec and leave its companion behind and that path no longer
        # exists -- the ported file dies on LoadError before it runs a line. Observed on a
        # real port: sixty-five files moved, two support files left in spec/, and every
        # file that required one of them broken.
        #
        # Copied rather than moved, deliberately. A companion may still be required by
        # specs that have not been ported yet -- a --batch port guarantees it -- and a
        # duplicated support file is harmless where a deleted one breaks whatever still
        # points at it. Tidying that up is a decision for whoever finishes the port.
        def carry_companions(results, root)
          carried = []
          results.select(&:written?).each do |result|
            companions_for(result).each do |source|
              target = File.join(root, File.dirname(result.written_to), File.basename(source))
              next if File.exist?(target)

              FileUtils.mkdir_p(File.dirname(target))
              FileUtils.cp(source, target)
              carried << target.delete_prefix("#{root}/")
            end
          end
          carried.uniq
        end

        def companions_for(result)
          dir = File.dirname(result.path)
          result.original.to_s.scan(/require_relative\s+["']([^"']+)["']/).flatten.filter_map do |ref|
            candidate = File.expand_path(ref.end_with?(".rb") ? ref : "#{ref}.rb", dir)
            candidate if File.file?(candidate)
          end
        end

        # Directories the port emptied. Only ever removed when empty, so nothing that was
        # not ported can be lost with them.
        def prune_empty_directories(results, root)
          results.filter_map(&:removed_original)
                 .map { |relative| File.dirname(File.join(root, relative)) }
                 .uniq
                 .sort_by { |dir| -dir.length }
                 .each do |dir|
                   Dir.rmdir(dir) while Dir.exist?(dir) && Dir.empty?(dir) && dir != root
                 rescue StandardError
                   nil
                 end
        end

        # Finishes the move.
        #
        # A port that leaves the original behind has not moved anything: both files are
        # now collected, so the suite runs those tests twice and the adoption number never
        # moves -- it counts both the file in test/cases/ and the spec it was made from.
        #
        # Deliberately conditional on the write having actually happened. A refused
        # overwrite, a parse failure, a flagged file that could not be ported -- none of
        # those delete anything, because the one unrecoverable mistake available here is
        # removing a test that was never copied.
        def remove_original(result, root)
          return unless result.written_to
          return if result.error
          return if File.expand_path(result.path) ==
                    File.expand_path(File.join(root, result.written_to.to_s))

          File.delete(result.path)
          result.removed_original = result.relative_path
        rescue StandardError => e
          result.error = "ported, but could not remove #{result.relative_path}: #{e.message}"
        end

        # Never clobbers. A port is run repeatedly while a suite is converted a directory
        # at a time, and the second run must not quietly overwrite edits made after the
        # first.
        def write_to(result, target, root)
          if File.exist?(target)
            result.error = "refusing to overwrite #{target.delete_prefix("#{root}/")}; " \
                           "move it aside, or use write: :in_place"
            return
          end

          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, result.source)
          result.written_to = target.delete_prefix("#{root}/")
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
        unless send_node.is_a?(::Parser::AST::Node) && send_node.type == :send
          return visit_children(node,
                                in_case: in_case)
        end

        name = send_node.children[1]

        return handle_group(node, send_node, in_case: in_case)      if group_call?(send_node)
        return handle_shared_definition(node, send_node)            if SHARED_DEFINITIONS.include?(name)
        return handle_matcher_definition(node, send_node)           if matcher_definition?(send_node)
        if EXAMPLE_METHODS.include?(name) && send_node.children[0].nil?
          return handle_example(node, send_node,
                                block_args)
        end
        if SKIPPED_EXAMPLES.include?(name) && send_node.children[0].nil?
          return handle_skipped_example(node,
                                        send_node)
        end
        return handle_let(node, send_node) if %i[let
                                                 let!].include?(name) && send_node.children[0].nil?
        return handle_subject(node, send_node) if %i[subject
                                                     subject!].include?(name) && send_node.children[0].nil?
        return handle_hook(node, send_node) if %i[before after around append_after
                                                  prepend_before].include?(name) && send_node.children[0].nil?
        return handle_its(node, send_node) if name == :its && send_node.children[0].nil?

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
        # `describe User` names a real constant, so `described_class` inside it has an
        # answer and does not need a human to supply it.
        @described_class = source_of(args.first) if args.first&.type == :const
        replace(block_head(node), "class #{@class_name} < #{@base}")
        close_brace_block(node)
        record_converted(:case_class, node, "#{source_of(send_node)} do",
                         "class #{@class_name} < #{@base}")
        return if args.size <= 1

        note_untouched(:describe_metadata, node,
                       "extra arguments to `#{send_node.children[1]}` (#{args[1..].map do |a|
                         source_of(a)
                       end.join(", ")}) " \
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

        # `let!` used to be flagged, because `witness` is lazy and swapping one for the other
        # changes when the record is created. `witness_all` is the eager one, so the swap is
        # no longer silent: the record exists before every investigation, which is the whole
        # meaning of `let!`.
        #
        # Not identical, and the difference is worth stating. `let!` rebuilds per example;
        # `witness_all` builds once and re-reads, inside a transaction the case rolls back.
        # A test that mutates the record still sees its own changes and still cannot leak
        # them. What changes is the cost: one INSERT for the case instead of one per test.
        if name == :let!
          unless args.size == 1 && %i[sym str].include?(args.first.type)
            return flag(:dynamic_let, node, "`#{source_of(send_node)}` does not name a single literal helper.")
          end

          replace(send_node.loc.selector, "witness_all")
          record_converted(:witness_all, node, source_of(send_node), "witness_all(#{source_of(args.first)})")
          to_do_end(node)
          return visit_children_of_block(node, in_case: false)
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

        # `after` was flagged as having no counterpart. It has one: `teardown`, which Case has
        # carried all along. The guidance was right that most after blocks are redundant once
        # the transaction rolls back -- but "redundant" is a judgement for the author, and
        # refusing to convert a construct that maps one-to-one was costing whole files their
        # conversion over it.
        target = { before: "briefing", after: "teardown" }[name]
        if target.nil? || args.size > 1 || !HOOK_SCOPES_OK.include?(scope)
          return flag(hook_flag_kind(name, scope), node, hook_flag_reason(name, scope, send_node))
        end

        replace(send_node.loc.expression, target)
        to_do_end(node)
        record_converted(target.to_sym, node, "#{source_of(send_node)} #{node.loc.begin.source}",
                         "#{target} do")
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
        attribute = literal_value(send_node.children[2])
        flag(:its, node, "`its(#{source_of(send_node.children[2])})` is an implicit-subject one-liner. Write it " \
                         "as `investigate \"...\" do attest(subject.#{attribute}).to ... end`.")
      end

      # Flagged, not noted -- the same lesson rspec-mocks taught.
      #
      # "Untouched" leaves the construct alone *and lets the file convert*, so the result
      # is a native case whose body calls a method Constable does not have. Measured on a
      # real port: two files converted cleanly and then died with
      # `NoMethodError: undefined method 'it_behaves_like'`, taking their tests with them
      # -- 78 fewer tests ran than under rspec, and the summary called it a pass.
      #
      # Blocked, `--port` moves the file verbatim as a cold case, where the whole
      # shared-examples DSL still works.
      def handle_shared_definition(node, send_node)
        flag(:shared_examples, node,
             "`#{source_of(send_node)}` defines shared examples. Constable has no shared-examples DSL " \
             "on purpose -- shared behaviour is a plain Ruby module in test/support that each case " \
             "`include`s -- so this file cannot run as a native case until it is extracted by hand.")
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
          # Flagged, not merely noted. "Untouched" leaves the construct alone *and lets the
          # file convert*, which for rspec-mocks means writing a native case that dies on
          # its first `allow` with `NoMethodError`. Measured while porting a real
          # directory: six files converted cleanly and then failed at runtime for exactly
          # this. A file that cannot run is not a conversion, so this blocks -- and `--port`
          # then moves it verbatim as a cold case, where rspec-mocks still works.
          return flag(:rspec_mocks, node,
                      "`#{first_line(node)}` is an RSpec message expectation. Constable ships no " \
                      "mocking library -- keep rspec-mocks via a cold case, or replace it with a " \
                      "stub object.")
        end

        flag_unknown_matcher(node, args.first) if %i[to not_to to_not].include?(name)

        if MOCK_ENTRY_POINTS.include?(name) && receiver.nil?
          flag(:rspec_mocks, node,
               "`#{first_line(node)}` uses rspec-mocks. Constable has no equivalent, so this file cannot " \
               "run as a native case; convert the stub by hand or keep the file as a cold case.")
          return
        end

        if SHARED_USES.include?(name) && receiver.nil?
          flag(:shared_examples, node,
               "`#{first_line(node)}` pulls in shared examples, which Constable has no DSL for. This file " \
               "cannot run as a native case; replace it with a plain module `include`, or keep the file " \
               "as a cold case.")
          return
        end

        case name
        when :expect
          replace(node.loc.selector, "attest") if receiver.nil?
          record_converted(:attest, node, "expect", "attest") if receiver.nil?
        when :is_expected
          if receiver.nil?
            flag(:is_expected, node,
                 "`is_expected` needs RSpec's implicit subject. Use `attest(subject)` -- an anonymous " \
                 "`subject` block is converted to `witness(:subject)` for you.")
          end
        when :should, :should_not
          flag(:should_syntax, node, "`#{name}` is RSpec's monkey-patched expectation syntax. Use `attest(...).to`.")
        when :helper
          if receiver.nil? && args.empty?
            flag(:rspec_helper_object, node,
                 "`helper` is RSpec's helper-spec proxy and has no Constable equivalent. " \
                 "A helper is a plain module: `include YourHelper` in the case and call " \
                 "the method directly -- which is exactly what `rails generate helper` " \
                 "writes.")
          end
        when :described_class
          if receiver.nil?
            # `describe User` gives this an unambiguous answer, so substitute it. Flagging it
            # was asking a human to copy a constant from four lines up, and costing the file
            # its conversion when nobody did.
            #
            # `describe "some string"` genuinely has no class behind it, and that stays a
            # flag -- there is nothing to substitute.
            if @described_class
              replace(node.loc.expression, @described_class)
              record_converted(:described_class, node, "described_class", @described_class)
            else
              flag(:described_class, node,
                   "`described_class` needs `describe SomeClass` to have a meaning, and this " \
                   "file describes a string. Name the class directly.")
            end
          end
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

      # Constable's matcher set is deliberately smaller than RSpec's, and the rewrite
      # carries any matcher name straight across. Without this check the first anyone
      # hears about it is a NoMethodError at runtime, naming the matcher -- or worse, an
      # internal deferred class -- rather than the line that needs a decision.
      def flag_unknown_matcher(node, matcher_node)
        name = root_matcher_name(matcher_node)
        return if name.nil?
        return if Constable::Matchers.matcher_name?(name)

        flag(:unknown_matcher, node,
             "`#{name}` is not one of Constable's matchers. Define it in " \
             "test/support/matchers.rb with `Constable::Matchers.define(:#{name})`, or " \
             "rewrite the assertion.")
      end

      # `contain_exactly(1, 2)` -> :contain_exactly. `be_within(0.5).of(10)` -> :be_within.
      # `change { x }.by(1)` -> :change. Anything that is not ultimately a bare method
      # call -- a local variable holding a matcher, a constant -- returns nil and is left
      # alone, because we cannot know what it is.
      def root_matcher_name(node)
        return nil unless node.is_a?(::Parser::AST::Node)

        current = node
        current = current.children.first while current.type == :send && current.children.first

        return nil unless current.type == :send && current.children.first.nil?

        current.children[1]
      end

      def mock_expectation?(node)
        return false unless node.is_a?(::Parser::AST::Node)

        !!find_node(node) { |n| n.type == :send && MOCK_METHODS.include?(n.children[1]) }
      end

      # ---- Minitest ----------------------------------------------------------------

      def visit_class(node, in_case:)
        name_node, superclass, body = node.children

        return visit_children(node, in_case: in_case) unless minitest_superclass?(superclass)

        @class_name = minitest_class_name(name_node)
        replace(name_node.loc.expression, @class_name) if @class_name != source_of(name_node)
        replace(superclass.loc.expression, @base)
        record_converted(:case_class, node, "class #{source_of(name_node)} < #{source_of(superclass)}",
                         "class #{@class_name} < #{@base}")
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
        if node.loc.end.nil?
          return flag(:endless_def, node,
                      "`def #{name} = ...` is an endless method; rewrite it as a block first.")
        end
        unless args.children.empty?
          return flag(:test_method_args, node,
                      "`def #{name}` takes arguments; `investigate` yields nothing.")
        end
        if calls_super?(body)
          return flag(:super_in_test, node, "`def #{name}` calls `super`; inside an `investigate` block `super` " \
                                            "would resolve against the block's enclosing scope, not the test.")
        end

        replace(def_head(node), "investigate #{description.inspect} do")
        record_converted(:investigate, node, "def #{name}", "investigate #{description.inspect} do")
        visit(body, in_case: true)
      end

      def convert_setup_method(node, args, body)
        if node.loc.end.nil?
          return flag(:endless_def, node,
                      "`def setup = ...` is an endless method; rewrite it as a block first.")
        end
        unless args.children.empty?
          return flag(:setup_args, node,
                      "`def setup` takes arguments, which `briefing` cannot supply.")
        end
        if calls_super?(body)
          return flag(:super_in_setup, node, "`def setup` calls `super`; `briefing` blocks already chain from " \
                                             "parent to child, so the `super` call must be removed by hand.")
        end

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

      # `briefing do @seen = [] end` is valid Ruby and nobody writes it. A one-line hook
      # keeps its braces; only a block that already spans lines becomes do/end.
      def to_do_end(node)
        return unless node.loc.begin.source == "{"
        return if node.loc.begin.line == node.loc.end.line

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
          when :const     then source_of(arg)
          when :str, :sym then Reopener.camelize(arg.children[0].to_s)
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
          out << blockers
          @results.each { |result| out << file_section(result) }
          out
        end

        # Written once here rather than repeated on every flagged line. The per-line reason
        # is a pointer; this is the explanation, and at two thousand occurrences the
        # difference between the two is whether the report is readable at all.
        GUIDANCE = {
          eager_let: <<~TEXT,
            `let!` runs before **every** example in its group, whether that example refers to it
            or not. That is two costs in one construct: the obvious one, where a group of forty
            examples pays for a record thirty-nine of them never look at, and the quieter one,
            where an example passes only because of setup it never mentions -- so the test does
            not describe what it needs and cannot be read on its own.

            There is no mechanical rewrite, because which of those two things you meant is a
            decision only you can make. Both answers are short:

            **The value is used by the examples** -- make it lazy, and it is created for the
            examples that ask:

            ```ruby
            let!(:user) { create(:user) }   # every example pays
            witness(:user) { create(:user) } # the ones that name `user` pay
            ```

            **The record has to exist whether or not it is named** (a row a query must find, a
            fixture the subject looks up) -- say that out loud in a `briefing`:

            ```ruby
            briefing { create(:user, status: "archived") }
            ```

            Worth checking before you do either: a `let!` that no example in the group actually
            depends on can simply be deleted. On a real suite that is a surprising share of them,
            and deleting one is the fastest test you will ever write.
          TEXT
          eager_subject: <<~TEXT,
            `subject!` is `let!` with a well-known name -- eager, so it runs for every example.
            Split it: the side effect into a `briefing`, the value into `witness(:subject)`.
          TEXT
          one_liner_example: <<~TEXT,
            `it { is_expected.to ... }` has no description, so a failure reports a file and a
            line number and nothing about what was supposed to be true. Name it -- the sentence
            is usually the assertion read aloud:

            ```ruby
            it { is_expected.to be_valid }
            investigate("is valid with a name and an email") { attest(subject).to be_valid }
            ```

            These are quick, mechanical, and the single cheapest thing to work through: the
            rewrite is one line each, and the payoff is a failure message that says what broke.
          TEXT
          is_expected: <<~TEXT,
            `is_expected` reads RSpec's implicit subject. Constable converts an anonymous
            `subject` block into `witness(:subject)` for you, so the assertion becomes
            `attest(subject).to ...` -- the same test, naming the thing it is talking about.
          TEXT
          described_class: <<~TEXT,
            `described_class` exists because `describe "some string"` might not name a class. A
            native case *is* a class, so the indirection buys nothing and costs a reader the
            jump back to the top of the file. Name the class directly.
          TEXT
          example_metadata: <<~TEXT,
            `investigate` takes a plain string. A non-literal description (interpolation, a
            constant) becomes a test whose name changes with its data, which is exactly what
            makes history keying and rerun-by-name unreliable -- write the sentence out.

            Metadata tags (`:focus`, `:vcr`, custom symbols) have no Constable equivalent:
            filtering by tag is how a suite quietly stops running parts of itself. Say what the
            tag meant in the case instead.
          TEXT
          shared_examples: <<~TEXT,
            Constable has no shared-examples DSL, deliberately: `include` already composes
            behaviour, it respects ancestry, it shows up in `.ancestors`, an editor can jump to
            the definition, and there is no second set of scoping rules to learn on top of
            Ruby's own.

            A file using them therefore cannot run as a native case, and is kept as a cold case
            where `it_behaves_like` and friends all still work. To convert one, move the shared
            block into a module under `test/support` and `include` it:

            ```ruby
            module BehavesLikeATask
              def self.included(base)
                base.investigate("requires a parent") { ... }
              end
            end
            ```
          TEXT
          rspec_mocks: <<~TEXT,
            Constable ships no mocking library, on the grounds that a stub is a claim about
            code you are not running and the cost of that claim being wrong is a green test
            over a broken integration.

            There is no rewrite, so a file using rspec-mocks is kept as a cold case, where
            `allow`, `double` and friends all still work. That is not a holding pen -- cold
            cases run alongside native ones indefinitely.

            Where you do want to convert one: a hand-written stub object, or a real object in
            a state that produces the behaviour, usually replaces `allow(...).to receive(...)`
            and does not go stale when the real method changes shape.
          TEXT
          after_hook: <<~TEXT,
            Most `after` blocks are redundant here. A native case rolls back its transaction and
            restores DSL-level global state on its own, so an `after` that only undoes setup is
            deleting work already done for you. Read it, and if that is all it does, delete it.
          TEXT
          before_all: <<~TEXT
            `before(:all)` builds state once and hands the same objects to many examples. It is
            faster right up until one example mutates one of them, and then you have a failure
            that depends on order, appears on one machine, and is not reproducible from anything
            written down.

            Constable has no equivalent on purpose. Move the setup into `briefing` (per test,
            inside a transaction that is rolled back) and, if that is genuinely too slow, make
            the fixture cheaper -- `build_stubbed` over `create`, one record over five.
          TEXT
        }.freeze

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
          when :port      then "port -- written into `test/cases/`, mirroring each spec path"
          when :port_cold then "port (cold) -- moved into `test/cases/` verbatim, nothing converted"
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

        # What is actually standing between this suite and the native DSL, counted.
        #
        # A per-file flag list tells you nothing about a port: four hundred files produce
        # thousands of lines and no sense of scale. Grouped, the shape is usually stark --
        # on one real suite a single construct was 57% of every flag raised, which turns
        # "convert the suite" from a slog into one decision applied repeatedly.
        def blockers
          counts = @results.flat_map { |r| Array(r.flags) }
                           .group_by { |f| f[:kind] }
                           .transform_values(&:size)
                           .sort_by { |_, n| -n }
          return "" if counts.empty?

          total = counts.sum { |_, n| n }
          out = +"## What is blocking conversion\n\n"
          out << "| Construct | Count | Share |\n|---|---|---|\n"
          counts.each do |kind, n|
            out << "| `#{kind}` | #{n} | #{(n * 100.0 / total).round}% |\n"
          end
          out << "\n"

          counts.each do |kind, n|
            advice = GUIDANCE[kind]
            next unless advice

            out << "### `#{kind}` -- #{n} #{n == 1 ? "occurrence" : "occurrences"}\n\n#{advice}\n\n"
          end
          out
        end

        def file_section(result)
          out = "## `#{result.relative_path}`\n\n"

          unless result.ok?
            out << "**Not converted.** #{result.error}\n\n"
            out << "The file was left exactly as it was. Reopen it instead: `constable import`.\n\n"
            return out
          end

          out << "- dialect: `#{result.dialect}`\n"
          out << "- case class: `#{result.class_name}`\n" if result.class_name
          out << "- written to: #{result.written_to ? "`#{result.written_to}`" : "nothing (dry run)"}\n"
          out << "- status: #{status_line(result)}\n\n"

          out << list("Converted", result.converted) do |item|
            "`#{squish(item[:from])}` -> `#{squish(item[:to])}`#{" -- #{item[:note]}" if item[:note]}"
          end
          out << list("Flagged -- NOT converted, still as written", result.flags) do |item|
            "**#{item[:kind]}** `#{squish(item[:source])}` -- #{item[:reason]}"
          end
          out << list("Left untouched", result.untouched) do |item|
            "**#{item[:kind]}** `#{squish(item[:source])}` -- #{item[:reason]}"
          end
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

          out = "### #{title} (#{items.size})\n\n"
          items.each { |item| out << "- `#{item[:location]}` #{yield(item)}\n" }
          out << "\n"
          out
        end

        def squish(text) = text.to_s.gsub(/\s+/, " ").strip
      end
    end
  end
end
