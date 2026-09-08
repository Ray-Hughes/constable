# frozen_string_literal: true

require "fileutils"
require "set"
require "yaml"

module Constable
  module Importer
    # The default import mode: make an existing RSpec/Minitest suite run under Constable
    # today, verbatim, with zero chance of a broken conversion.
    #
    # Two routes, and the cheaper one wins:
    #
    #   1. **Config path match** -- add a glob to `cold_cases:` in .constable/config.yml.
    #      Zero files changed. Preferred whenever a single glob cleanly covers a whole
    #      directory, because the smallest diff that achieves the goal is the right diff.
    #   2. **Superclass swap** -- wrap the file in `class LegacyFooSpec < ColdCase::RSpec`.
    #      The original bytes are re-emitted untouched between a header line and a final
    #      `end`; nothing inside is parsed, reformatted or reindented.
    #
    # Route 2 exists for the leftovers -- one legacy file in a directory that is otherwise
    # already modernized, where a glob would over-reach and silently swallow future files.
    class Reopener
      STRATEGIES = %i[auto config superclass].freeze

      ENGINES = {
        rspec: {
          glob: "spec/**/*_spec.rb",
          suffix: "_spec.rb",
          roots: ["spec"],
          superclass: "Constable::ColdCase::RSpec"
        },
        minitest: {
          glob: "test/**/*_test.rb",
          suffix: "_test.rb",
          roots: ["test"],
          superclass: "Constable::ColdCase::Minitest"
        }
      }.freeze

      # A single file the importer proposes to rewrite. Carries both sides so the caller
      # can always say precisely what changed -- we never overwrite blind.
      class Change
        attr_reader :path, :relative_path, :class_name, :before, :after

        def initialize(path:, relative_path:, class_name:, before:, after:)
          @path = path
          @relative_path = relative_path
          @class_name = class_name
          @before = before
          @after = after
        end

        def action = :superclass_swap

        # The rewrite only ever prepends a header and appends `end`, so the diff is exact
        # without needing a real diff algorithm.
        def diff
          added_head = @after.split(@before, 2).first.to_s
          out = "--- a/#{@relative_path}\n+++ b/#{@relative_path}\n"
          added_head.each_line { |line| out << "+#{line.chomp}\n" }
          out << "  #{@before.lines.size} unchanged line#{"s" unless @before.lines.size == 1} (byte for byte)\n"
          out << "+end\n"
          out
        end

        def to_h
          { action: action, path: @relative_path, class_name: @class_name,
            bytes_before: @before.bytesize, bytes_after: @after.bytesize }
        end
      end

      # What an import run did, or would do. Everything the CLI needs to print a report.
      class Result
        attr_reader :from, :strategy, :root, :config_path, :globs_added, :existing_globs,
                    :changes, :covered, :skipped, :errors

        def initialize(from:, strategy:, root:, config_path:, dry_run:)
          @from = from
          @strategy = strategy
          @root = root
          @config_path = config_path
          @dry_run = dry_run
          @globs_added = []
          @existing_globs = []
          @changes = []
          @covered = []
          @skipped = []
          @errors = []
          @comments_preserved = true
        end

        attr_accessor :comments_preserved

        def dry_run?            = @dry_run
        def comments_preserved? = @comments_preserved
        def config_changed?     = !@globs_added.empty?
        def files_changed       = @changes.map(&:relative_path)
        def any_changes?        = config_changed? || !@changes.empty?
        def imported_count      = @covered.size + @changes.size

        # Whichever routes were actually used, named honestly.
        def routes
          [(:config_path_match if config_changed?), (:superclass_swap unless @changes.empty?)].compact
        end

        def to_h
          {
            from: @from, strategy: @strategy, dry_run: @dry_run, routes: routes,
            config_path: @config_path, globs_added: @globs_added,
            comments_preserved: @comments_preserved,
            covered: @covered, changes: @changes.map(&:to_h),
            skipped: @skipped, errors: @errors
          }
        end

        # Written for somebody who has just typed `constable import` and does not yet know
        # what a cold case is. "reopen" is the word this code uses internally and it means
        # nothing to a reader; "import" itself suggests files were copied somewhere, which
        # is the opposite of what happened. So: say where the files are, say what changed,
        # and say what to do next.
        def summary
          verb = dry_run? ? "Would adopt" : "Adopted"
          noun = imported_count == 1 ? "file" : "files"
          lines = ["#{verb} #{imported_count} #{@from} #{noun} as cold cases."]

          unless @globs_added.empty?
            lines << ""
            lines << "  Your #{@from} files stay exactly where they are and are not changed."
            lines << "  #{dry_run? ? "One line would be added to" : "One line was added to"} " \
                     "#{@config_path}:"
            lines << ""
            @globs_added.each { |glob| lines << "    cold_cases:\n      - #{glob}" }
            lines << ""
            lines << "  Constable runs them from there, through real #{engine_label}, and folds"
            lines << "  the results into its own reporting, flake history and CI gate."
            unless comments_preserved?
              lines << "  note: config.yml was rewritten from parsed YAML; comments were not preserved"
            end
          end
          unless @changes.empty?
            lines << "  superclass swap: #{@changes.size} file(s) wrapped"
            @changes.each { |c| lines << "    - #{c.relative_path} -> class #{c.class_name} < #{superclass_name}" }
          end
          unless @skipped.empty?
            lines << "  skipped #{@skipped.size} file(s) already reopened:"
            @skipped.each { |s| lines << "    - #{s[:path]} (#{s[:reason]})" }
          end
          @errors.each { |e| lines << "  error: #{e[:path]} -- #{e[:message]}" }

          unless dry_run? || imported_count.zero?
            lines << ""
            lines << "  Next:  constable test --full        run everything, cold and native"
            lines << "         constable test --unsafe      run only these"
            lines << "         constable modernize PATH     see what one file would look like"
            lines << "                                      as a native case (writes nothing)"
          end

          lines.join("\n")
        end

        def engine_label = @from.to_s == "rspec" ? "RSpec" : "Minitest"

        def superclass_name = ENGINES.fetch(@from)[:superclass]

        def covered_by(glob)
          @covered.select { |path| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
        end
      end

      attr_reader :from, :config, :root, :strategy

      def initialize(from:, config: Constable.config, root: nil, paths: nil, strategy: :auto, dry_run: false)
        @from = from.to_s.downcase.to_sym
        unless ENGINES.key?(@from)
          raise ArgumentError,
                "unknown import source #{from.inspect} (expected :rspec or :minitest)"
        end

        @strategy = (strategy || :auto).to_sym
        unless STRATEGIES.include?(@strategy)
          raise ArgumentError,
                "unknown strategy #{strategy.inspect} (expected #{STRATEGIES.join(", ")})"
        end

        @config = config
        @root = (root || config&.root || Constable.root).to_s
        @paths = paths
        @dry_run = dry_run
      end

      def engine = ENGINES.fetch(@from)
      def dry_run? = @dry_run

      def call
        result = Result.new(from: @from, strategy: @strategy, root: @root,
                            config_path: Config::CONFIG_PATH, dry_run: @dry_run)
        candidates = discover(result)
        return result if candidates.empty?

        globs, leftovers = partition(candidates)
        apply_config_globs(globs, result)
        apply_superclass_swaps(leftovers, result)
        result
      end

      # Every file the engine owns that isn't already running as a cold case.
      def discover(result = nil)
        files = expand_paths.select { |path| File.file?(path) }
        files.sort.filter_map do |path|
          relative = relativize(path)
          if already_reopened?(path)
            result&.skipped&.push(path: relative, reason: "already a #{engine[:superclass]} subclass")
            next
          end
          if @config.respond_to?(:cold_case?) && @config.cold_case?(relative)
            result&.skipped&.push(path: relative, reason: "already matched by a cold_cases glob")
            next
          end
          relative
        end
      end

      # Derives a valid, collision-free constant from a file path.
      # spec/controllers/users_controller_spec.rb -> LegacyUsersControllerSpec
      #
      # `taken` is both the names already handed out in this run and anything the caller
      # knows is spoken for; on a clash we widen with a parent directory segment rather
      # than appending a number, because "LegacyModelsUserSpec" says something and
      # "LegacyUserSpec2" says nothing.
      def self.class_name_for(relative_path, taken: [], prefix: "Legacy")
        segments = relative_path.to_s.sub(/\.rb\z/, "").split("/")
        segments.shift if %w[spec test].include?(segments.first) && segments.size > 1
        base = camelize(segments.pop.to_s)
        name = "#{prefix}#{base}"

        while taken.include?(name)
          parent = segments.pop
          break if parent.nil?

          name = "#{prefix}#{camelize(parent)}#{name.delete_prefix(prefix)}"
        end

        suffix = 2
        candidate = name
        while taken.include?(candidate)
          candidate = "#{name}#{suffix}"
          suffix += 1
        end
        candidate
      end

      def self.camelize(string)
        parts = string.to_s.gsub(/[^A-Za-z0-9_]/, "_").split("_").reject(&:empty?)
        camel = parts.map { |part| part.match?(/\A[A-Z]/) ? part : part.capitalize }.join
        camel = "X#{camel}" unless camel.match?(/\A[A-Z]/)
        camel
      end

      # Wraps a file's contents. The body is emitted byte for byte -- not reindented, not
      # re-encoded, not touched. That is the entire safety argument for this mode.
      def wrap(source, class_name)
        body = source.end_with?("\n") || source.empty? ? source : "#{source}\n"
        "#{banner(class_name)}#{body}end\n"
      end

      def banner(class_name)
        <<~HEADER
          # Reopened by `constable import --from=#{@from}`. Everything between this line and the
          # final `end` is the original file, byte for byte -- no rewriting was done, so this file
          # still passes or fails exactly as it did before. Run `constable modernize` on it when
          # you want the native DSL; until then it runs through the real #{@from} engine.
          class #{class_name} < #{engine[:superclass]}
        HEADER
      end

      private

      def expand_paths
        return Dir.glob(File.join(@root, engine[:glob])) if @paths.nil? || Array(@paths).empty?

        Array(@paths).flat_map do |entry|
          absolute = File.absolute_path?(entry.to_s) ? entry.to_s : File.join(@root, entry.to_s)
          if File.directory?(absolute)
            Dir.glob(File.join(absolute, "**", "*#{engine[:suffix]}"))
          elsif absolute.include?("*")
            Dir.glob(absolute)
          else
            [absolute]
          end
        end.uniq.sort
      end

      def relativize(path) = path.to_s.delete_prefix("#{@root}/")

      # A file that already declares a ColdCase superclass has been imported before.
      def already_reopened?(path)
        head = File.open(path, "r") { |io| io.read(4096).to_s }
        head.include?("Constable::ColdCase")
      rescue StandardError
        false
      end

      # Decides which files a glob can cleanly cover and which need the per-file wrap.
      def partition(candidates)
        return [[], candidates] if @strategy == :superclass

        set = candidates.to_set
        globs = []
        remaining = candidates.dup

        clean_globs(candidates, set).each do |glob|
          matched = remaining.select { |path| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
          next if matched.empty?

          globs << glob
          remaining -= matched
        end

        # --strategy=config means "change no source files at all": anything a directory
        # glob couldn't cleanly cover gets listed by its exact path instead.
        if @strategy == :config
          globs.concat(remaining)
          remaining = []
        end

        [globs, remaining]
      end

      # A glob is "clean" when every file on disk it matches is one we're importing.
      # Broadest first, so `spec/**/*_spec.rb` beats a pile of per-directory globs.
      def clean_globs(candidates, set)
        directories = candidates.map { |path| File.dirname(path) }.flat_map { |dir| ancestors(dir) }.uniq
        directories
          .map { |dir| dir == "." ? "*#{engine[:suffix]}" : "#{dir}/**/*#{engine[:suffix]}" }
          .uniq
          .select { |glob| clean?(glob, set) }
          .sort_by { |glob| [-candidates.count { |p| File.fnmatch?(glob, p, File::FNM_PATHNAME | File::FNM_EXTGLOB) }, glob] }
      end

      def ancestors(dir)
        parts = dir.split("/")
        parts.each_index.map { |i| parts[0..i].join("/") }.reverse
      end

      def clean?(glob, set)
        on_disk = Dir.glob(File.join(@root, glob)).map { |path| relativize(path) }
        !on_disk.empty? && on_disk.all? { |path| set.include?(path) }
      end

      def apply_config_globs(globs, result)
        return if globs.empty?

        path = File.join(@root, Config::CONFIG_PATH)
        existing = existing_cold_cases(path)
        result.existing_globs.concat(existing)
        fresh = globs.reject { |glob| existing.include?(glob) }
        result.globs_added.concat(fresh)
        result.covered.concat(covered_files(globs))

        return if fresh.empty? || dry_run?

        FileUtils.mkdir_p(File.dirname(path))
        updated, preserved = merged_config_yaml(path, fresh)
        result.comments_preserved = preserved
        File.write(path, updated)
      end

      def covered_files(globs)
        globs.flat_map { |glob| Dir.glob(File.join(@root, glob)).map { |path| relativize(path) } }.uniq.sort
      end

      def existing_cold_cases(path)
        return [] unless File.exist?(path)

        raw = YAML.safe_load_file(path, permitted_classes: [], aliases: true) || {}
        Array(raw["cold_cases"]).map(&:to_s)
      rescue StandardError
        []
      end

      # Editing YAML as text rather than round-tripping through the parser, because a
      # config file is a document a human wrote and their comments are part of it.
      # If the text edit can't be verified afterwards we fall back to a full dump, which
      # keeps every setting but loses the comments -- and says so in the result.
      def merged_config_yaml(path, globs)
        original = File.exist?(path) ? File.read(path) : nil
        edited = original.nil? ? fresh_config_yaml(globs) : insert_globs(original, globs)

        parsed = begin
          edited && (YAML.safe_load(edited, permitted_classes: [], aliases: true) || {})
        rescue StandardError
          nil
        end

        if edited && parsed.is_a?(Hash) && globs.all? { |glob| Array(parsed["cold_cases"]).include?(glob) }
          [edited, true]
        else
          [rewritten_config_yaml(original, globs), false]
        end
      end

      def fresh_config_yaml(globs)
        <<~YAML
          # Constable settings. See docs/SPEC.md for the full reference.
          cold_cases:                     # run verbatim through their original engine
          #{globs.map { |glob| "  - #{quote(glob)}" }.join("\n")}
        YAML
      end

      # Last resort: reparse and re-dump. Loses comments, never loses settings.
      def rewritten_config_yaml(original, globs)
        raw = if original
                begin
                  YAML.safe_load(original, permitted_classes: [], aliases: true) || {}
                rescue StandardError
                  {}
                end
              else
                {}
              end
        raw["cold_cases"] = (Array(raw["cold_cases"]).map(&:to_s) + globs).uniq
        YAML.dump(raw)
      end

      def insert_globs(original, globs)
        lines = original.lines
        key_index = lines.index { |line| line.match?(/\Acold_cases\s*:/) }

        return append_block(lines, globs) if key_index.nil?

        key_line = lines[key_index]
        inline = key_line.split(":", 2)[1].to_s.sub(/#.*\z/, "").strip

        # `cold_cases: []` and `cold_cases:` both become a block; anything else inline
        # (a populated flow sequence, an anchor) is too exotic to edit safely as text --
        # nil tells the caller to fall back to a full re-dump.
        return nil if !inline.empty? && inline != "[]"

        lines[key_index] = key_line.sub(/:\s*\[\]/, ":") if inline == "[]"

        insert_at = key_index
        cursor = key_index + 1
        while cursor < lines.length
          line = lines[cursor]
          break if line.match?(/\A\S/) && !line.start_with?("#")

          insert_at = cursor if line.match?(/\A\s+-\s/)
          cursor += 1
        end

        indent = lines[insert_at].match?(/\A(\s+)-\s/) ? lines[insert_at][/\A\s+/] : "  "
        lines[insert_at] = "#{lines[insert_at].chomp}\n" unless lines[insert_at].end_with?("\n")
        lines.insert(insert_at + 1, *globs.map { |glob| "#{indent}- #{quote(glob)}\n" })
        lines.join
      end

      def append_block(lines, globs)
        body = lines.join
        body += "\n" unless body.empty? || body.end_with?("\n")
        body += "\n" unless body.empty? || body.end_with?("\n\n")
        body + "# Added by `constable import` -- these run verbatim as cold cases.\n" \
               "cold_cases:\n#{globs.map { |glob| "  - #{quote(glob)}\n" }.join}"
      end

      # A sentinel the caller turns into the dump fallback -- returning invalid YAML on
      # purpose is clearer than raising through the happy path.
      def rewritten_via_dump_marker = " unparseable"

      def quote(glob) = glob.match?(%r{\A[A-Za-z0-9_.\-/*\[\]{}]+\z}) ? glob : glob.inspect

      def apply_superclass_swaps(files, result)
        taken = []
        files.each do |relative|
          absolute = File.join(@root, relative)
          begin
            before = File.read(absolute)
          rescue StandardError => e
            result.errors << { path: relative, message: e.message }
            next
          end

          class_name = self.class.class_name_for(relative, taken: taken)
          taken << class_name
          change = Change.new(path: absolute, relative_path: relative, class_name: class_name,
                              before: before, after: wrap(before, class_name))
          result.changes << change
          File.write(absolute, change.after) unless dry_run?
        end
      end
    end
  end
end
