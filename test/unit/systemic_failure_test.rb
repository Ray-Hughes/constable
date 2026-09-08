# frozen_string_literal: true

require_relative "../helper"

module Constable
  # A run where a third of the suite fails with the identical error is one broken
  # machine, not thirty newly flaky tests.
  #
  # This matters because flake history reads "passed last run, failed this run" as
  # evidence about a *test* and jails it. Observed in a real app: parallel workers all
  # opened the same SQLite file, 130 tests failed with `database is locked`, and the next
  # run had 29 healthy tests on the docket marked "passed, then failed with no code
  # change". The docket is meant to hold tests worth distrusting, not afternoons.
  class SystemicFailureTest < TestCase
    def build_result(description:, status: :passed, exception_class: nil)
      result = Result.new(
        identity: Identity.digest(description), case_name: "SuiteCase",
        description: description, file: "test/cases/suite_case.rb", line: 1, status: status
      )
      result.failure = Failure.new(message: "boom", exception_class: exception_class) if exception_class
      result
    end

    def runner
      selection = Selection.new([], config: Constable.config, root: tmp_root, full: true)
      Runner.new(selection: selection, config: Constable.config,
                 reporter: Reporter.new(io: StringIO.new, config: Constable.config, color: false),
                 storage: Constable.storage, workers: 1)
    end

    # `outage` failures share one class; `real` failures are ordinary and distinct.
    def suite(passing: 0, outage: 0, real: 0, outage_class: "ActiveRecord::StatementTimeout")
      results = []
      passing.times { |i| results << build_result(description: "passes #{i}") }
      outage.times do |i|
        results << build_result(description: "outage #{i}", status: :failed,
                                exception_class: outage_class)
      end
      real.times do |i|
        results << build_result(description: "real #{i}", status: :failed,
                                exception_class: "RealFailure#{i}")
      end
      results
    end

    def detect(results) = runner.send(:systemic_failure, results)

    # --- detection ------------------------------------------------------------------

    def test_a_wall_of_identical_failures_is_recognised
      systemic = detect(suite(passing: 60, outage: 130))

      refute_nil systemic
      assert_equal "ActiveRecord::StatementTimeout", systemic.exception_class
      assert_equal 130, systemic.failed
    end

    # The common case, and the one that must never be touched: a normal red run.
    def test_one_ordinary_failure_is_not_systemic
      assert_nil detect(suite(passing: 100, real: 1))
    end

    # Small suites are noisy. Below the floor it is cheaper to believe the tests.
    def test_a_tiny_suite_is_never_systemic
      assert_nil detect(suite(passing: 1, outage: 4))
    end

    # A handful of identical failures in a large suite is a shared bug in the code under
    # test, which is exactly the thing the suite is for. Not an outage.
    def test_a_small_share_of_identical_failures_is_not_systemic
      assert_nil detect(suite(passing: 200, outage: 10))
    end

    # Failures that disagree about *how* they failed are real failures.
    def test_many_failures_with_different_errors_are_not_systemic
      assert_nil detect(suite(passing: 10, real: 40))
    end

    # A genuine failure landing in the same run as an outage must not rescue the outage
    # from detection, nor be exempted by it.
    def test_a_dominant_error_still_counts_with_a_little_noise
      systemic = detect(suite(passing: 20, outage: 60, real: 5))

      refute_nil systemic
      assert_equal "ActiveRecord::StatementTimeout", systemic.exception_class
    end

    def test_failures_without_an_exception_class_are_ignored
      assert_nil detect(suite(passing: 10, outage: 30, outage_class: nil))
    end

    def test_an_all_passing_run_is_not_systemic
      assert_nil detect(suite(passing: 50))
    end

    def test_an_empty_run_is_not_systemic
      assert_nil detect([])
    end

    # --- what it changes --------------------------------------------------------------

    # The point of the whole exercise: healthy tests stay off the docket.
    def test_a_systemic_run_does_not_jail_a_test_that_passed_last_time
      results = suite(passing: 20, outage: 60)
      victim  = results.last
      run_id = Constable.storage.start_run(seed: 1, mode: "test", full: true)
      Constable.storage.record_result(run_id, build_result(description: victim.description))

      run = runner
      run.send(:adjudicate, results)

      jail = Jail.new(config: Constable.config, storage: Constable.storage)
      assert_nil jail.entry(victim.identity),
                 "an outage must not put a healthy test on the docket"
    end

    # It stops the docket filling up; it does not paper over the failure.
    def test_a_systemic_run_still_fails
      results = suite(passing: 20, outage: 60)

      decided = runner.send(:adjudicate, results)

      assert_equal 60, decided.count(&:failed?)
    end

    def test_a_systemic_run_says_so_out_loud
      runner.send(:adjudicate, suite(passing: 20, outage: 60))

      warning = Constable.warnings.find { |w| w[:kind] == :systemic }
      refute_nil warning, "a run this broken must not be summarised silently"
      assert_match(/one broken run/, warning[:message])
      assert_match(/ActiveRecord::StatementTimeout/, warning[:message])
    end
  end
end
