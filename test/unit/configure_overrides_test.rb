# frozen_string_literal: true

require_relative "../helper"

module Constable
  # `Constable.configure` in test/case_helper.rb is the Ruby half of configuration. Until
  # 1.1.0 it exposed four accessors that nothing in the codebase ever read: the generated
  # case_helper.rb told you to write `c.parallel_workers = 4`, documented it, and silently
  # ignored it.
  #
  # Precedence, and the reason for it:
  #
  #   a CLI flag            one run, most specific
  #   Constable.configure   code you deliberately ran
  #   .constable/config.yml the project's declared default
  #   Constable's defaults
  class ConfigureOverridesTest < TestCase
    def teardown
      Constable.instance_variable_set(:@configuration, nil)
      super
    end

    def configured(&)
      Constable.configure(&)
      Constable.config.apply_overrides!(Constable.configuration.overrides)
      Constable.config
    end

    # The two halves must stay in step, so a setting cannot be added to one and forgotten
    # in the other. `storage` is the single documented exception.
    def test_every_config_key_is_settable_in_ruby_except_the_documented_one
      keys = Config::DEFAULTS.keys.map(&:to_sym).sort
      covered = (Configuration::SETTINGS + Configuration::SETTINGS_ONLY_IN_YAML).sort

      assert_equal keys, covered,
                   "config.yml and Constable.configure must understand the same settings"
    end

    # Ordering, not preference: the blotter is opened before case_helper.rb loads so the
    # docket commands can work without booting the app. Accepting the setting and quietly
    # using the old path is exactly the failure this release exists to stop.
    def test_setting_storage_in_ruby_says_why_it_cannot_work
      error = assert_raises(ConfigurationError) do
        Constable.configure { |c| c.storage = { "path" => "somewhere.sqlite3" } }
      end

      assert_match(%r{must be set in \.constable/config\.yml}, error.message)
      assert_match(/before case_helper\.rb loads/, error.message)
    end

    def test_a_ruby_setting_overrides_the_file
      write_config("parallel_workers: 2\n")

      assert_equal 7, configured { |c| c.parallel_workers = 7 }.parallel_workers
    end

    def test_a_setting_left_alone_defers_to_the_file
      write_config("parole_period: 4\n")

      assert_equal 4, configured { |c| c.parallel_workers = 7 }.parole_period
    end

    def test_settings_the_file_does_not_mention_still_work
      assert_equal 3, configured { |c| c.parole_period = 3 }.parole_period
    end

    def test_output_mode_is_settable_in_ruby
      assert_equal :expanded, configured { |c| c.output = :expanded }.output_mode
    end

    def test_booleans_survive_the_merge
      assert_predicate configured { |c| c.warrants = true }, :warrants?
      assert_predicate configured { |c| c.fail_on_warnings = true }, :fail_on_warnings?
    end

    # false is a value, not an absence -- the merge must not treat it as "unset".
    def test_false_is_an_override_not_an_absence
      write_config("warrants: true\n")

      refute_predicate configured { |c| c.warrants = false }, :warrants?
    end

    def test_nested_settings_merge_rather_than_replace_wholesale
      write_config("tiers:\n  unit: test/cases/models/**/*\n  system: test/cases/system/**/*\n")

      config = configured { |c| c.tiers = { "unit" => "test/cases/fast/**/*" } }

      assert_equal "test/cases/fast/**/*", config.tiers["unit"]
      assert_equal "test/cases/system/**/*", config.tiers["system"],
                   "the file's other tiers should survive"
    end

    def test_arrays_are_replaced_not_concatenated
      write_config("cold_cases:\n  - spec/legacy/**/*_spec.rb\n")

      config = configured { |c| c.cold_cases = ["spec/models/**/*_spec.rb"] }

      assert_equal ["spec/models/**/*_spec.rb"], config.cold_cases
    end

    # The values still go through the same clamping as the file's, so a typo in Ruby is no
    # more dangerous than a typo in YAML.
    def test_ruby_values_are_validated_like_file_values
      assert_equal 100, configured { |c| c.coverage_threshold = 400 }.coverage_threshold
      assert_equal 10, configured { |c| c.parole_period = 0 }.parole_period
      assert_equal :concise, configured { |c| c.output = :sideways }.output_mode
    end

    def test_configuring_nothing_changes_nothing
      write_config("parole_period: 6\n")

      assert_equal 6, configured { |_c| nil }.parole_period
    end

    # The computed case, which is the whole reason to want Ruby at all.
    def test_a_setting_can_be_computed
      config = configured { |c| c.parallel_workers = (2 * 2) }

      assert_equal 4, config.parallel_workers
    end
  end
end
