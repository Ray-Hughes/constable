# frozen_string_literal: true

require_relative "../helper"

module Constable
  # Settings have exactly one home: `.constable/config.yml`.
  #
  # They used to have two. Fourteen of sixteen were settable both there and in
  # `Constable.configure`, which bought a precedence rule to learn, the same setting
  # documented twice across two generated files, and eighty-five lines of catalogue in the
  # first file a new adopter opens.
  #
  # Nothing was lost by removing the second home. config.yml is run through ERB before it
  # is parsed, exactly as Rails does for database.yml, so the one thing Ruby could do that
  # YAML could not -- compute a value -- still works:
  #
  #     parallel_workers: <%= ENV.fetch("CI_WORKERS", 4) %>
  #
  # `Constable.configure` is now for code alone: before_suite, after_suite, matchers.
  class ConfigureOverridesTest < TestCase
    def teardown
      Constable.instance_variable_set(:@configuration, nil)
      super
    end

    # --- one home ----------------------------------------------------------------------

    # Named individually rather than caught by method_missing, so assigning one says where
    # it goes instead of failing with NoMethodError -- which reads as "no such setting".
    def test_every_setting_says_where_it_goes_when_set_in_ruby
      Config::DEFAULTS.each_key do |setting|
        error = assert_raises(ConfigurationError, "c.#{setting} = should explain itself") do
          Constable.configure { |c| c.public_send("#{setting}=", "anything") }
        end

        assert_match(/config\.yml/, error.message)
      end
    end

    def test_the_two_lists_stay_in_step
      assert_equal Config::DEFAULTS.keys.map(&:to_sym).sort,
                   (Configuration::SETTINGS + Configuration::SETTINGS_ONLY_IN_YAML).sort,
                   "every setting must be accounted for in exactly one place"
    end

    # Ordering, not preference: the blotter is opened before case_helper.rb loads so the
    # docket commands can work without booting the app.
    def test_storage_explains_its_own_reason
      error = assert_raises(ConfigurationError) do
        Constable.configure { |c| c.storage = { "path" => "somewhere.sqlite3" } }
      end

      assert_match(/before case_helper\.rb loads/, error.message)
    end

    # `constable modernize` never boots the app at all -- that is what makes it read four
    # hundred files in ten seconds.
    def test_modernize_explains_its_own_reason
      error = assert_raises(ConfigurationError) do
        Constable.configure { |c| c.modernize = { "base" => "UnitCase" } }
      end

      assert_match(/does not boot the application/, error.message)
    end

    def test_configure_still_takes_code
      ran = []
      Constable.configure do |c|
        c.before_suite { ran << :before }
        c.after_suite { ran << :after }
      end

      Constable.configuration.run_before_suite!
      Constable.configuration.run_after_suite!

      assert_equal %i[before after], ran
    end

    def test_nothing_is_merged_over_the_file_any_more
      Constable.configure { |c| c.before_suite { nil } }

      assert_empty Constable.configuration.overrides
    end

    # --- ERB, which is what replaces computing a value in Ruby ---------------------------

    def test_a_value_can_be_computed_in_the_file
      ENV["CONSTABLE_TEST_WORKERS"] = "7"
      write_config(%(parallel_workers: <%= ENV.fetch("CONSTABLE_TEST_WORKERS", 2) %>\n))

      assert_equal 7, Constable.config.parallel_workers
    ensure
      ENV.delete("CONSTABLE_TEST_WORKERS")
    end

    def test_a_file_with_no_erb_is_unaffected
      write_config("parallel_workers: 3\n")

      assert_equal 3, Constable.config.parallel_workers
    end

    def test_erb_that_raises_says_which_file_it_was_reading
      write_file(".constable/config.yml", "parallel_workers: <%= raise 'boom' %>\n")

      assert_raises(StandardError) { Constable.reset! && Constable.config.parallel_workers }
    end
  end
end
