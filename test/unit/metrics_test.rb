# frozen_string_literal: true

require_relative "../helper"

module Constable
  # The numbers behind `constable last`, `constable metrics` and `constable insights`.
  #
  # None of this data is collected specially -- it is the same rows the runner already
  # writes to balance workers and detect flakes, asked a different question. Which means
  # the thing worth testing is the asking: a lifetime figure that quietly drops untimed
  # runs, or a percentage measured against the wrong denominator, is worse than no number
  # at all because it looks authoritative.
  class MetricsTest < TestCase
    def setup
      super
      @storage = Constable.storage
    end

    attr_reader :storage

    def result(identity:, status: :passed, duration: 0.25, file: "spec/a_spec.rb")
      Result.new(
        identity: identity, case_name: "ACase", description: "does a thing",
        file: file, line: 12, kind: :cold, tier: :integration,
        status: status, duration: duration
      )
    end

    def finished_run(duration: 1.5, results: [])
      run_id = storage.start_run(seed: 1, mode: "full", full: true)
      results.each { |r| storage.record_result(run_id, r) }
      storage.finish_run(run_id, totals: {
                           total: results.size,
                           passed: results.count(&:passed?),
                           failed: results.count(&:failed?),
                           duration: duration
                         })
      run_id
    end

    # --- lifetime ----------------------------------------------------------------------

    def test_lifetime_totals_add_up_across_runs
      finished_run(duration: 2.0, results: [result(identity: "a")])
      finished_run(duration: 3.0, results: [result(identity: "a"), result(identity: "b")])

      totals = storage.lifetime

      assert_equal 2, totals[:runs].to_i
      assert_equal 3, totals[:tests].to_i
      assert_in_delta 5.0, totals[:seconds].to_f, 0.001
    end

    # Runs recorded before durations were persisted have none. Summing them as if they
    # were free would understate what the suite costs, so the count of timed runs comes
    # back too and the CLI says which it is talking about.
    def test_lifetime_reports_how_many_runs_were_actually_timed
      finished_run(duration: 2.0, results: [result(identity: "a")])
      finished_run(duration: nil, results: [result(identity: "b")])

      totals = storage.lifetime

      assert_equal 2, totals[:runs].to_i
      assert_equal 1, totals[:timed_runs].to_i
    end

    # --- flakes vs breakage ------------------------------------------------------------
    #
    # A test that has never passed is not flaky, it is broken, and the two want opposite
    # responses. Reporting them together is how a flake list becomes noise.

    def test_flakiest_finds_tests_that_both_pass_and_fail
      finished_run(results: [result(identity: "flip", status: :passed)])
      finished_run(results: [result(identity: "flip", status: :failed)])
      finished_run(results: [result(identity: "steady", status: :passed)])

      flaky = storage.flakiest(limit: 10)

      assert_equal(%w[flip], flaky.map { |f| f[:identity] })
      assert_equal 1, flaky.first[:failures].to_i
      assert_equal 2, flaky.first[:runs].to_i
    end

    def test_a_test_that_never_passes_is_not_counted_as_a_flake
      2.times { finished_run(results: [result(identity: "broken", status: :failed)]) }

      assert_empty storage.flakiest(limit: 10)
      assert_equal(%w[broken], storage.failure_leaders(limit: 10).map { |f| f[:identity] })
    end

    # `errored` is a failure that did not reach an assertion. Result#failed? counts it, so
    # anything counting failures in SQL has to as well -- it did not, and a suite whose
    # failures all errored looked spotless.
    def test_errored_counts_as_a_failure
      finished_run(results: [result(identity: "boom", status: :passed)])
      finished_run(results: [result(identity: "boom", status: :errored)])

      assert_equal(%w[boom], storage.flakiest(limit: 10).map { |f| f[:identity] })
    end

    # --- where the time goes -----------------------------------------------------------

    def test_slowest_files_groups_durations_by_file
      run_id = finished_run(results: [
                              result(identity: "a", duration: 1.0, file: "spec/slow_spec.rb"),
                              result(identity: "b", duration: 2.0, file: "spec/slow_spec.rb"),
                              result(identity: "c", duration: 0.5, file: "spec/quick_spec.rb")
                            ])

      files = storage.slowest_files(run_id, limit: 10)

      assert_equal "spec/slow_spec.rb", files.first[:file]
      assert_in_delta 3.0, files.first[:total].to_f, 0.001
      assert_equal 2, files.first[:tests].to_i
    end

    # Wall time is what you waited; the sum of durations is what the suite cost. With
    # workers the second is larger, and a file's share measured against the first can
    # exceed 100% -- which it did, reporting a file as "335% of the run".
    def test_total_test_seconds_is_the_sum_of_durations_not_the_clock
      run_id = finished_run(duration: 1.0, results: [
                              result(identity: "a", duration: 2.0),
                              result(identity: "b", duration: 2.0)
                            ])

      assert_in_delta 4.0, storage.total_test_seconds(run_id), 0.001
    end

    # --- insights ----------------------------------------------------------------------

    def insights_for(run_id)
      Insights.new(storage: storage, config: Constable.config,
                   run: storage.run(run_id)).call
    end

    def test_a_file_owning_most_of_the_run_is_reported
      run_id = finished_run(results: [
                              result(identity: "a", duration: 9.0, file: "spec/hog_spec.rb"),
                              result(identity: "b", duration: 0.1, file: "spec/small_spec.rb")
                            ])

      headline = insights_for(run_id).map { |f| f[:headline] }.join(" ")

      assert_match(%r{spec/hog_spec\.rb}, headline)
      assert_match(/9\d%|8\d%/, headline)
    end

    # Every suite has a slowest file. Naming it when it owns 11% of the time is noise, and
    # noise is how a report earns its way into the ignored pile.
    def test_an_unremarkable_slowest_file_is_not_reported
      run_id = finished_run(results: Array.new(20) do |i|
        result(identity: "t#{i}", duration: 0.1, file: "spec/f#{i}_spec.rb")
      end)

      refute(insights_for(run_id).any? { |f| f[:headline].include?("of the suite's time") })
    end

    def test_nothing_is_suggested_for_a_clean_suite
      run_id = finished_run(results: [result(identity: "a", duration: 0.1)])

      assert(insights_for(run_id).none? { |f| f[:headline].include?("flip") })
    end
  end
end
