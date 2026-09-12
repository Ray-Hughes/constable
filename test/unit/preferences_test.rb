# frozen_string_literal: true

require_relative "../helper"

module Constable
  # .constable/config.yml is a team agreement; preferences.yml is not. The whole value of
  # the split is the line between them holding, so that is what these are about.
  class PreferencesTest < TestCase
    def write_preferences(yaml)
      write_file(Config::PREFERENCES_PATH, yaml)
      Constable.reset!
      Constable.config
    end

    def test_a_preference_layers_over_the_project_config
      write_config("output: concise\n")
      config = write_preferences("output: expanded\n")

      assert_equal :expanded, config.output_mode
    end

    def test_the_project_config_still_answers_what_the_preference_does_not
      write_config("output: concise\nparole_period: 4\n")
      config = write_preferences("heartbeat: 30\n")

      assert_equal 30, config.heartbeat
      assert_equal 4, config.parole_period
      assert_equal :concise, config.output_mode
    end

    def test_no_preferences_file_is_fine
      write_config("output: expanded\n")
      Constable.reset!

      assert_equal :expanded, Constable.config.output_mode
    end

    # The line that makes the split safe. A suite that is green on one machine and red on
    # another, with the difference in a gitignored file nobody else can see, is worse than
    # no preferences at all.
    def test_a_setting_that_changes_what_passes_is_refused
      error = assert_raises(Constable::ConfigurationError) do
        write_preferences("coverage_threshold: 10\n")
      end

      assert_match(/coverage_threshold/, error.message)
      assert_match(/not a preference/, error.message)
      assert_match(%r{\.constable/config\.yml}, error.message)
    end

    def test_the_refusal_names_every_offender
      error = assert_raises(Constable::ConfigurationError) do
        write_preferences("jail_flakes: true\nwarrants: true\n")
      end

      assert_match(/jail_flakes, warrants/, error.message)
      assert_match(/are not preferences/, error.message)
    end

    def test_every_preference_key_is_actually_readable
      Config::PREFERENCE_KEYS.each do |key|
        assert_respond_to Constable.config, key, "#{key} is offered as a preference but cannot be read"
      end
    end

    def test_colour_is_undecided_unless_asked_for
      write_config("")
      Constable.reset!

      assert_nil Constable.config.color
    end

    def test_colour_can_be_forced_off
      assert_equal false, write_preferences("color: false\n").color
    end
  end
end
