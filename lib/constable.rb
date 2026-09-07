# frozen_string_literal: true

require "constable/version"

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
  autoload :Investigation, "constable/investigation"
  autoload :Isolation,     "constable/isolation"
  autoload :Jail,          "constable/jail"
  autoload :LogRouter,     "constable/log_router"
  autoload :Matchers,      "constable/matchers"
  autoload :OrderAudit,    "constable/order_audit"
  autoload :Registry,      "constable/registry"
  autoload :Reporter,      "constable/reporter"
  autoload :Result,        "constable/result"
  autoload :Runner,        "constable/runner"
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
    def warn!(message, location: nil, kind: :unsafe)
      warnings << { message: message, location: location, kind: kind }
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
  class Configuration
    attr_accessor :parallel_workers, :seed, :coverage, :warrants

    def initialize
      @before_suite_hooks = []
      @after_suite_hooks  = []
    end

    def before_suite(&block) = @before_suite_hooks << block
    def after_suite(&block)  = @after_suite_hooks << block

    def run_before_suite! = @before_suite_hooks.each(&:call)
    def run_after_suite!  = @after_suite_hooks.each(&:call)
  end
end
