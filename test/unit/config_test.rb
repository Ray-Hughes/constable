# frozen_string_literal: true

require_relative "../helper"

module Constable
  # config.yml is hand-edited, so every one of these is a plausible Tuesday afternoon
  # rather than an exotic input. The rule throughout: a typo gets a sentence naming the
  # file and the problem, never a stack trace from inside Psych.
  class ConfigTest < TestCase
    def load(yaml)
      write_file(".constable/config.yml", yaml)
      Constable.reset!
      Constable.config
    end

    def test_a_missing_config_file_is_fine
      Constable.reset!

      assert_equal 10, Constable.config.parole_period
    end

    def test_an_empty_config_file_is_fine
      assert_equal 10, load("").parole_period
    end

    def test_a_config_of_only_comments_is_fine
      assert_equal 10, load("# nothing to see here\n").parole_period
    end

    def test_unknown_keys_are_ignored
      assert_equal 10, load("not_a_real_key: 3\n").parole_period
    end

    def test_malformed_yaml_names_the_file_and_the_line
      error = assert_raises(Constable::Error) { load("cold_cases: [\n") }

      assert_match(%r{\.constable/config\.yml is not valid YAML}, error.message)
      assert_match(/line \d/, error.message)
    end

    def test_yaml_that_is_not_a_mapping_says_so
      error = assert_raises(Constable::Error) { load("- a\n- b\n") }

      assert_match(/must be a mapping of settings/, error.message)
      assert_match(/parsed as array/, error.message)
    end

    def test_a_bare_string_config_says_so_too
      error = assert_raises(Constable::Error) { load("just a string\n") }

      assert_match(/parsed as string/, error.message)
    end

    # --- values that are the right shape but the wrong number -------------------------

    def test_workers_accepts_a_quoted_number
      assert_equal 4, load(%(parallel_workers: "4"\n)).parallel_workers
    end

    def test_workers_never_drops_below_one
      assert_equal 1, load("parallel_workers: 0\n").parallel_workers
      assert_equal 1, load("parallel_workers: -3\n").parallel_workers
    end

    def test_workers_falls_back_when_it_cannot_be_read
      assert_equal 1, load("parallel_workers: banana\n").parallel_workers
    end

    # A threshold above 100 is a build that can never go green; below 0, a gate that can
    # never fail. Both are typos rather than intentions.
    def test_coverage_threshold_is_clamped_to_a_percentage
      assert_equal 100, load("coverage_threshold: 400\n").coverage_threshold
      assert_equal 0, load("coverage_threshold: -20\n").coverage_threshold
    end

    def test_negative_warrant_retries_means_off
      assert_equal 0, load("warrant_retries: -1\n").warrant_retries
    end

    # parole_period 0 would mean "release on sight", which is not parole.
    def test_parole_period_falls_back_rather_than_releasing_on_sight
      assert_equal 10, load("parole_period: 0\n").parole_period
      assert_equal 10, load("parole_period: -5\n").parole_period
    end

    def test_an_unrecognised_output_mode_falls_back_to_concise
      assert_equal :concise, load("output: sideways\n").output_mode
      assert_equal :expanded, load("output: expanded\n").output_mode
    end

    def test_explicit_nulls_fall_back_to_defaults
      config = load("parallel_workers:\ncoverage_threshold:\n")

      assert_equal 90, config.coverage_threshold
    end

    def test_an_unrecognised_worker_database_mode_falls_back_to_schema
      assert_equal :schema, load("worker_databases: sideways\n").worker_databases
      assert_equal :reuse, load("worker_databases: reuse\n").worker_databases
    end

    # YAML 1.1 reads `off`, `no` and `false` as the boolean, so the obvious way to write
    # this setting arrives as `false` rather than the string. Reading that as :schema
    # would silently do the opposite of what the line says.
    def test_yaml_booleans_are_read_as_off
      assert_equal :off, load("worker_databases: off\n").worker_databases
      assert_equal :off, load("worker_databases: no\n").worker_databases
      assert_equal :off, load("worker_databases: false\n").worker_databases
      assert_equal :off, load(%(worker_databases: "off"\n)).worker_databases
    end

    # config.yml is ERB-processed, the way Rails treats database.yml, so one file can say
    # different things in CI and on a laptop without a second file to keep in sync.
    def test_erb_is_evaluated
      assert_equal 4, load(%(parallel_workers: <%= 2 + 2 %>\n)).parallel_workers
    end

    def test_erb_can_read_the_environment
      with_env("CONSTABLE_TEST_WORKERS" => "3") do
        yaml = %(parallel_workers: <%= ENV.fetch("CONSTABLE_TEST_WORKERS", 8) %>\n)

        assert_equal 3, load(yaml).parallel_workers
      end
    end
  end
end
