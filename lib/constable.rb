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
      else
        "#{setting} is set in .constable/config.yml, not Constable.configure. Settings " \
        "have one home so there is no precedence rule to learn, and the file is run " \
        "through ERB, so a computed value still works. Constable.configure is for " \
        "code: before_suite, after_suite, matchers."
      end
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

    # Nothing to merge: settings live in the file. The loader still asks, and an empty
    # hash is the honest answer.
    def overrides = {}

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
