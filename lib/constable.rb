# frozen_string_literal: true

require "constable/version"
require "constable/worker_databases"

# Constable -- an opinionated, strict Rails testing framework.
#
# Published on RubyGems as "constable-rails"; everything inside is simply Constable.
#
# Five ideas hold the whole thing up:
#
#   1. Isolation is non-negotiable in native code. No class-level shared state, no
#      before(:all) equivalent. Every native test gets a clean transaction and a clean
#      object graph.
#   2. Nondeterminism is caught by the linter, not discovered in CI.
#   3. Adoption never requires a rewrite. A whole existing RSpec/Minitest file runs
#      untouched from day one.
#   4. Every escape hatch is visible. Nothing that bends the rules is ever silent.
#   5. Fast is the default, not an opt-in.
module Constable
  class Error < StandardError; end
  class ConfigurationError < Error; end

  # Raised by assertion primitives. Distinct from Error so a genuine bug in a test never
  # gets mistaken for an assertion failure.
  class AssertionFailed < Error
    attr_reader :context

    def initialize(message, context: nil)
      @context = context
      super(message)
    end
  end

  autoload :Backtrace,     "constable/result"
  autoload :CLI,           "constable/cli"
  autoload :Case,          "constable/case"
  autoload :ColdCase,      "constable/cold_case"
  autoload :Config,        "constable/config"
  autoload :Coverage,      "constable/coverage"
  autoload :DSL,           "constable/dsl"
  autoload :Diff,          "constable/diff"
  autoload :Failure,       "constable/result"
  autoload :Identity,      "constable/identity"
  autoload :Importer,      "constable/importer"
  autoload :Insights,      "constable/insights"
  autoload :PortPlan,      "constable/port_plan"
  autoload :Investigation, "constable/investigation"
  autoload :Isolation,     "constable/isolation"
  autoload :Jail,          "constable/jail"
  autoload :LogRouter,     "constable/log_router"
  autoload :Matchers,      "constable/matchers"
  autoload :OrderAudit,    "constable/order_audit"
  autoload :RailsSupport,  "constable/rails_support"
  autoload :Registry,      "constable/registry"
  autoload :Reporter,      "constable/reporter"
  autoload :Result,        "constable/result"
  autoload :Runner,        "constable/runner"
  autoload :Shard,         "constable/shard"
  autoload :Selection,     "constable/selection"
  autoload :Storage,       "constable/storage"
  autoload :Warrants,      "constable/warrants"

  class << self
    attr_writer :root, :config, :storage

    # The application root. Rails.root when Rails is booted, otherwise the nearest
    # directory that looks like a project (has .constable/, Gemfile, or .git).
    def root
      @root ||= detect_root
    end

    def config
      @config ||= Config.load(root: root)
    end

    # Code-level configuration -- matchers, tier base classes, one-time global setup.
    # Settings that are merely settings belong in .constable/config.yml instead.
    #
    #   Constable.configure do |c|
    #     c.parallel_workers = 4
    #     c.before_suite { Capybara.default_driver = :rack_test }
    #   end
    def configure
      yield configuration if block_given?
      configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # The contents of test/cold_cases.rb:
    #
    #     Constable.cold_cases do
    #       rspec    "spec/**/*_spec.rb"
    #       minitest "test/legacy/**/*_test.rb"
    #     end
    #
    # Deliberately not part of Constable.configure. Linking a legacy suite is not a
    # setting, it is the decision that determines what `constable test` runs at all, and
    # it earns a file of its own so it is visible in the test tree.
    def cold_cases(&) = configuration.cold_cases(&)

    def storage
      @storage ||= Storage::Adapter.build(config).tap(&:setup!)
    end

    def registry
      @registry ||= Registry.new
    end

    # Warnings are never silent and never fatal by default. They accumulate through a run
    # and always get their own section in the summary.
    def warn!(message, location: nil, kind: :unsafe, **extra)
      warnings << { message: message, location: location, kind: kind, **extra }
    end

    def warnings
      @warnings ||= []
    end

    def reset!
      @config = nil
      @storage = nil
      @registry = nil
      @configuration = nil
      @warnings = []
    end

    private

    def detect_root
      return Rails.root.to_s if defined?(Rails) && Rails.respond_to?(:root) && Rails.root

      dir = Dir.pwd
      until dir == "/"
        return dir if File.exist?(File.join(dir, ".constable")) ||
                      File.exist?(File.join(dir, "Gemfile")) ||
                      File.directory?(File.join(dir, ".git"))

        dir = File.dirname(dir)
      end
      Dir.pwd
    end
  end

  # Code-level configuration set from test/case_helper.rb.
  # The Ruby half of configuration, set from test/case_helper.rb.
  #
  # Anything that is *code* -- custom matchers, tier base classes, one-time global setup --
  # can only live here. Everything that is merely a *setting* can live in either place, and
  # this is the one that wins:
  #
  #   a CLI flag        for one run
  #   Constable.configure   in case_helper.rb, because it is code and ran deliberately
  #   .constable/config.yml the declared default for the project
  #   Constable's defaults
  #
  # Until 1.1.0 the four accessors here were read by nothing at all: `c.parallel_workers = 4`
  # was in the generated case_helper.rb, documented, and silently ignored.
  class Configuration
    # Every setting .constable/config.yml understands, settable in Ruby as well. A nil is
    # "not set here" rather than "set to nothing", so leaving one alone defers to the file.
    # Settings have exactly one home: .constable/config.yml.
    #
    # They used to have two. Fourteen of sixteen were settable both there and here, which
    # meant a precedence rule to learn, the same setting documented twice across two
    # generated files, and eighty-five lines of catalogue in the first file an adopter
    # opens.
    #
    # Nothing is lost in expressiveness: config.yml is run through ERB before it is
    # parsed, exactly as Rails does for database.yml, so a computed value still works --
    #
    #     parallel_workers: <%= ENV.fetch("CI_WORKERS", 4) %>
    #
    # What stays here is what a YAML file genuinely cannot hold: blocks of code.
    SETTINGS = [].freeze

    # `storage` is the one setting that cannot live here, and the reason is ordering, not
    # preference: the blotter handle is opened before test/case_helper.rb is loaded,
    # because `constable jail`, `warrants`, `watchlist` and `status` all read the docket
    # without booting the app at all. By the time this block runs, it is already open.
    #
    # Raising beats accepting the value and quietly using the old path -- silently
    # ignoring a setting somebody wrote is the failure mode this whole class was fixed for.
    # Named individually so assigning one can say where it goes, rather than failing with
    # NoMethodError -- which reads as "that setting does not exist".
    SETTINGS_ONLY_IN_YAML = %i[
      storage modernize cold_cases warrants warrant_retries auto_relink parole_period
      coverage coverage_threshold coverage_html fail_on_warnings parallel_workers
      worker_databases jail_flakes output tiers
    ].freeze

    # Which engine a cold file runs under, declared rather than guessed. Without this the
    # only signal is the filename suffix, which cannot answer for `test/legacy/foo.rb` and
    # has to raise instead.
    class ColdCaseLinks
      ENGINES = %i[rspec minitest].freeze

      def initialize
        @globs = ENGINES.to_h { |engine| [engine, []] }
        @except = []
      end

      ENGINES.each do |engine|
        define_method(engine) { |*globs| @globs[engine].concat(globs.flatten.map(&:to_s)) }
      end

      # Carved out of the globs above.
      #
      # `constable modernize --port` without `delete` leaves the original in place, so the
      # glob still matches it and the same tests run twice -- once as the new native case
      # and once as the spec it was built from. Deleting the original solves it too, and is
      # the default; this is for a port you want to check against its source first.
      def except(*paths) = @except.concat(paths.flatten.map(&:to_s))

      def globs      = @globs.reject { |_engine, list| list.empty? }.transform_values(&:uniq)
      def exclusions = @except.uniq
      def any?       = globs.any?
      def flat       = globs.values.flatten
    end

    attr_accessor :seed

    SETTINGS_ONLY_IN_YAML.each do |setting|
      define_method("#{setting}=") do |_value|
        raise ConfigurationError, Configuration.yaml_only_message(setting)
      end
    end

    # Two of these could never have worked here, for reasons worth keeping distinct from
    # the general rule.
    def self.yaml_only_message(setting)
      case setting
      when :storage then storage_message
      when :modernize then modernize_message
      when :cold_cases then cold_cases_message
      else
        "#{setting} is set in .constable/config.yml, not Constable.configure. Settings " \
        "have one home so there is no precedence rule to learn, and the file is run " \
        "through ERB, so a computed value still works. Constable.configure is for " \
        "code: before_suite, after_suite, matchers."
      end
    end

    # cold_cases is the one setting whose home is neither config.yml nor a setter. Linking
    # a legacy suite is the single most consequential thing an adopter does, and burying it
    # in a config key meant the first `constable test` ran a thousand specs nobody could
    # see a reason for. It gets a file, so the link is visible in the tree.
    def self.cold_cases_message
      "cold_cases is declared in test/cold_cases.rb, not Constable.configure:\n\n    " \
        "Constable.cold_cases do\n      " \
        "rspec \"spec/**/*_spec.rb\"\n    " \
        "end\n\n" \
        "`constable import --from=rspec` writes that file for you. It lives in the test " \
        "tree rather than in config.yml so that linking a legacy suite is visible, and " \
        "deleting the file really does unlink it."
    end

    def self.storage_message
      "storage must be set in .constable/config.yml, not Constable.configure. The " \
        "blotter is opened before case_helper.rb loads, so that `constable jail` and " \
        "`constable status` can read the docket without booting the app -- by the time " \
        "this block runs the connection is already open."
    end

    def self.modernize_message
      "modernize must be set in .constable/config.yml, not Constable.configure. " \
        "`constable modernize` does not boot the application -- it is an AST rewrite, " \
        "and not booting is what makes it fast -- so case_helper.rb never runs for it."
    end

    def initialize
      @before_suite_hooks = []
      @after_suite_hooks  = []
    end

    # `Constable.cold_cases { rspec "spec/**/*_spec.rb" }` -- see ColdCaseLinks.
    def cold_cases(&block)
      @cold_case_links ||= ColdCaseLinks.new
      @cold_case_links.instance_eval(&block) if block
      @cold_case_links
    end

    attr_reader :cold_case_links

    # Settings live in config.yml, with one exception: the cold-case links live in
    # test/cold_cases.rb, and this is how they reach the loader.
    def overrides
      links = @cold_case_links
      return {} if links.nil? || links.globs.empty?

      { cold_cases: links.flat, cold_case_engines: links.globs,
        cold_case_except: links.exclusions }
    end

    def before_suite(&block) = @before_suite_hooks << block
    def after_suite(&block)  = @after_suite_hooks << block

    def run_before_suite! = @before_suite_hooks.each(&:call)
    def run_after_suite!  = @after_suite_hooks.each(&:call)
  end
end

# Registers Constable as the app's generator test framework, so `rails generate model`
# writes a case instead of a Minitest file. Conditional on purpose: everything above this
# line must load in a process with no Rails at all, which is what the :unit tier is for.
require "constable/railtie" if defined?(Rails::Railtie)
