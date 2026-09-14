# frozen_string_literal: true

require "helper"

module Constable
  # A cold case runs against a session RSpec::Configuration that Constable swaps in. Anything
  # installed on the configuration that existed at boot -- shoulda-matchers' integration,
  # `config.include SomeHelper`, Capybara's drivers -- is installed on an object the session
  # never uses, so the cold case runs without it and dies on a method that is plainly set up.
  #
  # These cover the two ways that configuration gets into the session: a host registering it
  # explicitly, and `load_support` handing over the files it declined to load itself.
  class ColdCaseBootstrapTest < TestCase
    HELPER_MODULE = <<~RUBY
      module BootstrapHelper
        def bootstrapped_value = 42
      end

      RSpec.configure do |config|
        config.include BootstrapHelper
      end
    RUBY

    NEEDS_HELPER = <<~SPEC
      describe "a legacy spec" do
        it "calls a helper the host included via RSpec.configure" do
          expect(bootstrapped_value).to eq(42)
        end
      end
    SPEC

    def setup
      super
      ColdCase.reset_engines!
      ColdCase.reset_bootstrap!
    end

    def teardown
      ColdCase.reset_bootstrap!
      ColdCase.reset_engines!
      super
    end

    def test_bootstrap_block_configures_the_session_the_cold_case_runs_in
      ran = 0
      ColdCase.bootstrap do
        ran += 1
        ::RSpec.configure { |config| config.include(Module.new { def bootstrapped_value = 42 }) }
      end

      path = write_file("spec/needs_helper_spec.rb", NEEDS_HELPER)
      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal [:passed], results.map(&:status),
                   "the bootstrap block's config.include never reached the session configuration"
      assert_equal 1, ran
    end

    # Once per session, not once per file -- a bootstrap that re-ran would re-register every
    # hook it installs, and a `before(:suite)` would fire twice.
    def test_bootstrap_runs_once_across_files
      ran = 0
      ColdCase.bootstrap { ran += 1 }

      trivial = 'describe("x") { it("passes") { expect(1).to eq(1) } }'
      first  = write_file("spec/first_spec.rb", trivial)
      second = write_file("spec/second_spec.rb", trivial)
      ColdCase.run_files([first, second], config: Constable.config)

      assert_equal 1, ran
    end

    # The file is still not loaded into native cases -- Constable owns the transaction and
    # isolation itself -- but it is no longer thrown away, because cold cases need it.
    def test_load_support_hands_rspec_configuring_files_to_the_cold_case_session
      write_file("spec/support/bootstrap_helper.rb", HELPER_MODULE)

      skipped = Constable.load_support("spec/support/**/*.rb")

      assert_equal ["spec/support/bootstrap_helper.rb"], skipped.map(&:first)
      assert_includes ColdCase.bootstrap_entries.join, "bootstrap_helper.rb"

      path = write_file("spec/needs_helper_spec.rb", NEEDS_HELPER)
      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal [:passed], results.map(&:status),
                   "a skipped support file's RSpec.configure never reached the cold-case session"
    end

    def test_bootstrap_failure_names_the_file
      ColdCase.bootstrap { raise ArgumentError, "no such thing" }
      path = write_file("spec/needs_helper_spec.rb", NEEDS_HELPER)

      error = assert_raises(Constable::Error) { ColdCase.run_file(path, config: Constable.config) }

      assert_match(/bootstrap block could not be loaded/, error.message)
      assert_match(/no such thing/, error.message)
    end
  end
end
