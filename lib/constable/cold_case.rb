# frozen_string_literal: true

module Constable
  # Cold cases -- Tier 1 of the unsafe escape hatch, and the whole adoption story.
  #
  # Philosophy point 3: adoption never requires a rewrite. A cold case is an existing
  # RSpec or Minitest file that keeps its original body *verbatim* and still reports
  # into Constable's summary, flake history and CI gate alongside native cases. Two
  # ways in, and both have to work:
  #
  #   1. One-line superclass swap -- the file's wrapper line changes, nothing else:
  #
  #        class LegacyUsersSpec < Constable::ColdCase::RSpec
  #          describe UsersController do
  #            it "creates a user" do ... end
  #          end
  #        end
  #
  #   2. Zero file changes -- a `cold_cases:` glob in .constable/config.yml matches the
  #      file and Constable wraps it without anyone touching it:
  #
  #        cold_cases:
  #          - spec/controllers/**/*_spec.rb
  #
  # Nothing here reimplements RSpec or Minitest. The *real* engine runs the file
  # in-process and we translate its own verdicts into Constable::Result objects. That
  # matters for trust: a cold case has to behave exactly as it did before adoption, or
  # "runs untouched from day one" is a lie.
  #
  # Cold cases are exempt from the native rules on purpose, and the exemptions are not
  # oversights:
  #
  #   * No shuffling. Native cases get a fresh random order every run because isolation
  #     is guaranteed for them. A legacy suite frequently is *not* isolated -- it may
  #     lean on before(:all), class-level state or declaration order -- so re-ordering it
  #     would manufacture failures that have nothing to do with the code under test.
  #     Cold cases keep whatever order their own engine chose.
  #   * No transactional wrapper, no state-leak check, no linter. Those enforce rules the
  #     file never agreed to.
  #
  # The price of the exemption is visibility (philosophy point 4). Every cold-case file
  # emits exactly one warning, every run, until someone modernizes it -- one per FILE,
  # not per test, because a hundred warnings for one legacy spec is noise, not news.
  module ColdCase
    ENGINES = %i[rspec minitest].freeze

    # What to require, and which gem the user is missing if it isn't there.
    ENGINE_REQUIRES = { rspec: "rspec/core", minitest: "minitest" }.freeze
    ENGINE_GEMS     = { rspec: "rspec-rails", minitest: "minitest" }.freeze
    ENGINE_LABELS   = { rspec: "RSpec", minitest: "Minitest" }.freeze

    # The optional Gemfile group `constable:install` writes. It is optional precisely
    # because these dependencies are temporary: delete the group once the last cold case
    # is gone and both gems drop out of the app.
    GEMFILE_GROUP = <<~RUBY
      group :cold_case do
        gem "rspec-rails"
        gem "minitest"
      end
    RUBY

    # Base classes a legacy Minitest file is likely to inherit from, used as a last-ditch
    # content sniff when neither the filename nor an explicit ColdCase superclass says.
    MINITEST_SUPERCLASSES = /<\s*(?:::)?(?:Minitest::|ActiveSupport::|ActionDispatch::|ActionController::)/

    # Raised when a cold case needs an engine the app no longer has installed.
    class EngineMissing < Constable::Error; end

    class << self
      # ---- public API the Runner calls -------------------------------------------------

      # Runs one cold-case file through its own engine and returns [Constable::Result].
      # Every result has kind: :cold, so downstream code can tell at a glance that this
      # test is not under native rules.
      def run_file(path, config: Constable.config, seed: nil)
        absolute = absolute_path(path, config: config)
        engine   = engine_for(absolute)

        unless engine
          raise Constable::Error,
                "#{relative_path(absolute, config: config)} is registered as a cold case but " \
                "Constable can't tell whether it is RSpec or Minitest. Name it *_spec.rb or " \
                "*_test.rb, or give it a Constable::ColdCase::RSpec / " \
                "Constable::ColdCase::Minitest superclass."
        end

        adapter_for(engine).run_file(absolute, config: config, seed: seed)
      end

      # Convenience for a whole batch. Files run one at a time and in the given order --
      # engine globals are process-wide, so there is no safe way to interleave them.
      def run_files(paths, config: Constable.config, seed: nil)
        Array(paths).flat_map { |path| run_file(path, config: config, seed: seed) }
      end

      # Every file the `cold_cases:` globs match -- the zero-file-change adoption path.
      # Absolute, de-duplicated, sorted so a run's file order is stable.
      def cold_case_files(config: Constable.config)
        root = config.root.to_s
        matched = config.cold_cases.flat_map do |glob|
          pattern = File.absolute_path?(glob.to_s) ? glob.to_s : File.join(root, glob.to_s)
          Dir.glob(pattern, File::FNM_EXTGLOB)
        end
        matched.select { |path| File.file?(path) }.uniq.sort
      end

      def declared_engine_for(path)
        links = Constable.configuration.cold_case_links
        return nil unless links&.any?

        relative = path.to_s.delete_prefix("#{Constable.root}/")
        links.globs.each do |engine, globs|
          matched = globs.any? do |glob|
            File.fnmatch?(glob, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
              File.fnmatch?(glob, path.to_s, File::FNM_PATHNAME | File::FNM_EXTGLOB)
          end
          return engine if matched
        end
        nil
      end

      # :rspec, :minitest, or nil when we genuinely cannot tell.
      #
      # An explicit Constable::ColdCase::* superclass is the strongest signal -- the user
      # said so in the file. After that, filename convention, then a content sniff, then
      # the directory the file lives in.
      def engine_for(path)
        path = path.to_s
        source = head_of(path)

        return :rspec    if source&.match?(/<\s*(?:::)?Constable::ColdCase::RSpec\b/)
        return :minitest if source&.match?(/<\s*(?:::)?Constable::ColdCase::Minitest\b/)

        return :rspec    if path.end_with?("_spec.rb")
        return :minitest if path.end_with?("_test.rb")

        # test/cold_cases.rb says which engine each glob belongs to. It sits *below* the
        # naming convention deliberately: a glob is broad and may cover both kinds, so
        # `rspec "legacy/*.rb"` must not claim legacy/thing_test.rb. What it answers is the
        # case nothing else can -- a file whose name follows neither convention.
        declared = declared_engine_for(path)
        return declared if declared

        if source
          return :rspec    if source.match?(/^\s*(?:RSpec\.)?(?:describe|feature|context)\b/)
          return :minitest if source.match?(MINITEST_SUPERCLASSES) || source.match?(/^\s*def\s+test_/)
        end

        segments = path.split(File::SEPARATOR)
        return :rspec    if segments.include?("spec")
        return :minitest if segments.include?("test")

        nil
      end

      # The adapter module that knows how to drive one engine. Accepts an engine symbol
      # or a path. Requiring is lazy: an app with only RSpec cold cases never loads
      # Minitest, and vice versa.
      def adapter_for(engine_or_path)
        engine = ENGINES.include?(engine_or_path) ? engine_or_path : engine_for(engine_or_path)
        raise Constable::Error, "unknown cold-case engine: #{engine_or_path.inspect}" unless engine

        load_adapter!(engine)
      end

      # Drops both engines back to a clean slate. The adapters already restore global
      # state around every file; this is the belt-and-braces version for a long-lived
      # process (our own test suite, an editor plugin) that wants nothing left behind.
      def reset_engines!
        ENGINES.each do |engine|
          adapter = adapter_module(engine)
          adapter.reset_engine! if adapter.respond_to?(:reset_engine!)
        end
      end

      # ---- lazy engine loading ---------------------------------------------------------

      # Requires an engine, or explains -- precisely, and with the fix -- why it can't.
      # Constable itself must keep loading without either gem installed; that is the
      # entire point of the optional :cold_case group.
      def require_engine!(engine, path: nil)
        require ENGINE_REQUIRES.fetch(engine)
        true
      rescue ::LoadError => e
        raise EngineMissing, missing_engine_message(engine, error: e, path: path)
      end

      def missing_engine_message(engine, error: nil, path: nil)
        label = ENGINE_LABELS.fetch(engine)
        where = path ? " in #{relative_path(path)}" : ""

        <<~MESSAGE.strip
          Cold cases#{where} need #{label}, but `require "#{ENGINE_REQUIRES.fetch(engine)}"` failed#{" (#{error.message})" if error}.

          #{label} (the `#{ENGINE_GEMS.fetch(engine)}` gem) is only needed while cold cases exist, so
          `rails generate constable:install` puts it in an optional Gemfile group.
          Add the group back and run `bundle install`:

          #{GEMFILE_GROUP.chomp.gsub(/^/, "  ")}

          Delete the group once the suite is fully modernized -- both dependencies drop out
          on their own, because nothing native depends on them.
        MESSAGE
      end

      # ---- shared helpers used by both adapters ----------------------------------------

      # Exactly ONE warning per cold-case file, never per test. The count is the engine's
      # own real example count, so the summary line reads the way SPEC.md shows it:
      #
      #   running as a cold case (Constable::ColdCase::RSpec) -- 12 tests not yet under native rules
      def warn_for_file(path, base_class_name, count, config: Constable.config)
        location = relative_path(path, config: config)
        return if warned?(location)

        Constable.warn!(
          "running as a cold case (#{base_class_name}) — " \
          "#{count} #{count == 1 ? "test" : "tests"} not yet under native rules",
          location: location,
          kind: :cold_case,
          # Carried so the reporter can total them when there are too many to list. A
          # suite mid-adoption has hundreds of these, and printing every one buries the
          # things that actually need a decision.
          tests: count
        )
      end

      def relative_path(path, config: nil)
        root = (config&.root || Constable.root).to_s
        path.to_s.delete_prefix("#{root}/")
      end

      def absolute_path(path, config: Constable.config)
        path = path.to_s
        File.absolute_path?(path) ? path : File.expand_path(path, config.root.to_s)
      end

      # Cold-case classes announce themselves while their file loads, so a Result can be
      # labelled `LegacyUsersSpec` rather than an anonymous example-group description.
      def note_cold_class(klass)
        @declared_classes&.push(klass)
        klass
      end

      def while_loading(path)
        previous_file    = @loading_file
        previous_classes = @declared_classes
        @loading_file    = path
        @declared_classes = []
        yield
      ensure
        @loading_file = previous_file
        @declared_classes = previous_classes
      end

      # The name of the ColdCase subclass declared by the file we just loaded, if any.
      # Anonymous classes are ignored -- they have nothing useful to display.
      def declared_class_name
        @declared_classes&.map { |k| k.name if k.respond_to?(:name) }&.compact&.first
      end

      attr_reader :loading_file

      private

      def warned?(location)
        Constable.warnings.any? { |w| w[:kind] == :cold_case && w[:location] == location }
      end

      def load_adapter!(engine)
        require_engine!(engine)
        require "constable/cold_case/#{engine}"
        adapter_module(engine)
      end

      def adapter_module(engine)
        name = engine == :rspec ? :RSpecAdapter : :MinitestAdapter
        const_defined?(name, false) ? const_get(name, false) : nil
      end

      # Reads just enough of a file to classify it. Cheap, and never blows up on a file
      # that has been deleted between globbing and running.
      def head_of(path, bytes: 8192)
        return nil unless File.file?(path)

        File.open(path, "rb") { |f| f.read(bytes) }&.force_encoding(Encoding::UTF_8)
      rescue SystemCallError, IOError
        nil
      end
    end

    # Constable::ColdCase::RSpec and ::Minitest are the user-facing base classes, and
    # referencing one is what triggers the lazy require of the engine behind it. Doing
    # it here rather than with `autoload` lets us turn a bare LoadError into the
    # actionable "add the :cold_case group back" message.
    def self.const_missing(name)
      case name
      when :RSpec, :Minitest
        engine = name == :RSpec ? :rspec : :minitest
        load_adapter!(engine)
        return const_get(name, false) if const_defined?(name, false)
      end
      super
    end
  end
end
