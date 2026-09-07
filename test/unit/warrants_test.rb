# frozen_string_literal: true

require_relative "../helper"

module Constable
  class WarrantsTest < TestCase
    # An in-memory stand-in for the warrants half of Constable::Storage::Adapter.
    #
    # Duck-typed on purpose: this is a unit test of the retry policy, and it should not
    # need a database on disk to answer "is this failure even real". The semantics mirror
    # the shipped adapter, including touch_warrant(cleared: true) lifting the warrant and
    # handing back the final row.
    class FakeBlotter
      attr_reader :touches

      def initialize
        @warrants = {}
        @touches  = []
      end

      def close = nil

      def issue_warrant(identity, label:, file:, line:, reason: nil)
        existing = @warrants[identity]
        if existing
          existing.merge!(label: label, file: file, line: line, reason: reason || existing[:reason],
                          times_seen: existing[:times_seen] + 1, failed_runs: existing[:failed_runs] + 1)
        else
          @warrants[identity] = {
            identity: identity, label: label, file: file, line: line, reason: reason,
            issued_at: "2026-09-06T00:00:00.000Z", last_seen_at: "2026-09-06T00:00:00.000Z",
            times_seen: 1, clean_runs: 0, failed_runs: 1
          }
        end
        warrant_entry(identity)
      end

      def warrants = @warrants.values.map(&:dup)

      def warrant_entry(identity) = @warrants[identity]&.dup

      def clear_warrant(identity) = !@warrants.delete(identity).nil?

      def touch_warrant(identity, cleared:)
        entry = @warrants[identity]
        return nil unless entry

        @touches << [identity, cleared]
        if cleared
          @warrants.delete(identity)
          return entry.merge(state: :cleared, cleared: true, clean_runs: entry[:clean_runs] + 1,
                             times_seen: entry[:times_seen] + 1)
        end

        entry.merge!(times_seen: entry[:times_seen] + 1, failed_runs: entry[:failed_runs] + 1)
        entry.merge(state: :standing, cleared: false)
      end

      # Test-side inspection.
      def size = @warrants.size
    end

    IDENTITY = "bbbb000000000001"

    def setup
      super
      @blotter = FakeBlotter.new
      Constable.storage = @blotter
      @reruns = []
    end

    def config(warrants: false, retries: 5)
      Config.new({ "warrants" => warrants, "warrant_retries" => retries }, root: tmp_root)
    end

    def warrants(warrants: false, retries: 5, storage: @blotter)
      Warrants.new(config: config(warrants: warrants, retries: retries), storage: storage)
    end

    def result(status: :failed, identity: IDENTITY, line: 12,
               file: "test/cases/sessions_case.rb", case_name: "SessionsCase",
               description: "expires after inactivity")
      Result.new(identity: identity, case_name: case_name, description: description,
                 file: file, line: line, status: status)
    end

    # A rerun callable that plays back a scripted sequence of outcomes and records how
    # many times it was asked to run the test in isolation.
    def rerun(*outcomes)
      script = outcomes.dup
      proc do |subject, attempt|
        @reruns << [subject, attempt]
        script.shift
      end
    end

    def all_failing  = rerun(*Array.new(10, :failed))
    def all_passing  = rerun(*Array.new(10, :passed))

    def standing_warrant(identity = IDENTITY)
      @blotter.issue_warrant(identity, label: "SessionsCase \"expires after inactivity\"",
                                       file: "test/cases/sessions_case.rb", line: 12, reason: "flaky")
    end

    # --- issuing a warrant -------------------------------------------------------

    def test_a_warrant_is_issued_when_a_retry_passes
      subject = warrants(warrants: true)

      decided = subject.adjudicate(result, &rerun(:failed, :failed, :passed, :failed, :failed))

      assert_equal :warranted, decided.status
      assert_predicate decided, :warranted?
      assert subject.standing?(IDENTITY)
      assert_equal [IDENTITY], subject.issued.map(&:identity)
      assert_equal :issued, subject.verdicts[IDENTITY]
    end

    def test_an_issued_warrant_does_not_block_the_build
      subject = warrants(warrants: true)

      decided = subject.adjudicate(result, &rerun(:failed, :failed, :failed, :failed, :passed))

      refute subject.blocks_build?(decided)
      refute_predicate decided, :failed?
    end

    def test_an_issued_warrant_records_where_the_flake_lives
      subject = warrants(warrants: true)
      subject.adjudicate(result, &rerun(:passed, :failed, :failed, :failed, :failed))

      entry = subject.entry(IDENTITY)

      assert_equal "test/cases/sessions_case.rb", entry.file
      assert_equal 12, entry.line
      assert_equal 'SessionsCase "expires after inactivity"', entry.label
      assert_match(/passed 1 of 5 isolated retries/, entry.reason)
    end

    def test_no_warrant_is_issued_when_every_retry_fails
      subject = warrants(warrants: true)

      decided = subject.adjudicate(result, &all_failing)

      assert_equal :failed, decided.status
      refute subject.standing?(IDENTITY)
      assert_equal 0, @blotter.size
      assert_equal [IDENTITY], subject.genuine.map(&:identity)
      assert_equal :genuine, subject.verdicts[IDENTITY]
      assert subject.blocks_build?(decided), "a genuine failure still blocks the build"
    end

    def test_an_errored_result_that_fails_every_retry_keeps_its_own_kind_of_failure
      subject = warrants(warrants: true)

      decided = subject.adjudicate(result(status: :errored), &all_failing)

      assert_equal :errored, decided.status
    end

    def test_the_retry_statuses_are_kept_on_the_result
      subject = warrants(warrants: true, retries: 3)

      decided = subject.adjudicate(result, &rerun(:failed, :passed, :failed))

      assert_equal %i[failed passed failed], decided.retries
    end

    # --- retry counts -------------------------------------------------------------

    def test_the_number_of_reruns_honours_warrant_retries
      warrants(warrants: true, retries: 5).adjudicate(result, &all_failing)

      assert_equal 5, @reruns.size
      assert_equal [1, 2, 3, 4, 5], @reruns.map(&:last)
    end

    def test_a_configured_retry_count_is_used_verbatim
      warrants(warrants: true, retries: 2).adjudicate(result, &all_failing)

      assert_equal 2, @reruns.size
    end

    def test_the_full_retry_count_runs_even_after_an_early_pass
      warrants(warrants: true, retries: 5).adjudicate(result, &all_passing)

      assert_equal 5, @reruns.size
    end

    def test_zero_retries_turns_the_whole_mechanism_off
      subject = warrants(warrants: true, retries: 0)

      decided = subject.adjudicate(result, &all_passing)

      assert_empty @reruns
      assert_equal :failed, decided.status
      refute subject.applies_to?(IDENTITY, requested: true)
    end

    def test_the_block_may_return_results_booleans_or_symbols
      subject = warrants(warrants: true, retries: 3)
      passing = Result.new(identity: IDENTITY, case_name: "SessionsCase", description: "d",
                           file: "f", line: 1, status: :passed)

      decided = subject.adjudicate(result, &rerun(passing, false, "passed"))

      assert_equal %i[passed failed passed], decided.retries
    end

    def test_a_lambda_of_arity_one_is_called_correctly
      subject = warrants(warrants: true, retries: 2)
      seen = []
      callable = ->(subject_result) { seen << subject_result and :failed }

      subject.adjudicate(result, &callable)

      assert_equal 2, seen.size
    end

    def test_the_subject_handed_to_the_block_defaults_to_the_result
      warrants(warrants: true, retries: 1).adjudicate(result, &all_failing)

      assert_equal IDENTITY, @reruns.first.first.identity
    end

    def test_an_explicit_subject_is_handed_to_the_block_instead
      investigation = Object.new
      warrants(warrants: true, retries: 1).adjudicate(result, subject: investigation, &all_failing)

      assert_same investigation, @reruns.first.first
    end

    # --- when the machinery applies at all ------------------------------------------

    def test_warrants_are_opt_in_and_do_nothing_without_the_flag_or_a_standing_warrant
      subject = warrants(warrants: false)

      decided = subject.adjudicate(result, &all_passing)

      assert_empty @reruns
      assert_equal :failed, decided.status
      assert_equal 0, @blotter.size
      refute subject.applies_to?(IDENTITY)
    end

    def test_a_single_run_can_request_warrants_without_config
      subject = warrants(warrants: false)

      decided = subject.adjudicate(result, requested: true, &rerun(:passed, :failed, :failed, :failed, :failed))

      assert_equal :warranted, decided.status
      assert subject.applies_to?(IDENTITY, requested: true)
    end

    def test_an_active_run_does_not_retry_a_test_that_passed_normally
      subject = warrants(warrants: true)

      decided = subject.adjudicate(result(status: :passed), &all_failing)

      assert_empty @reruns
      assert_equal :passed, decided.status
    end

    def test_a_jailed_or_skipped_result_is_never_retried
      standing_warrant
      subject = warrants(warrants: true)

      subject.adjudicate(result(status: :jailed), &all_failing)
      subject.adjudicate(result(status: :skipped), &all_failing)

      assert_empty @reruns
    end

    # --- living under a warrant -------------------------------------------------------

    def test_a_standing_warrant_applies_on_every_future_run_regardless_of_the_flag
      standing_warrant
      subject = warrants(warrants: false)

      assert subject.applies_to?(IDENTITY)
      assert subject.standing?(IDENTITY)

      subject.adjudicate(result(status: :passed), &rerun(:passed, :failed, :passed, :passed, :passed))

      assert_equal 5, @reruns.size, "a warranted test is retried whether or not --warrants is passed"
    end

    def test_a_standing_warrant_is_retried_even_when_the_normal_attempt_passed
      standing_warrant
      subject = warrants(warrants: false)

      decided = subject.adjudicate(result(status: :passed), &rerun(:passed, :passed, :failed, :passed, :passed))

      assert_equal 5, @reruns.size
      assert_equal :warranted, decided.status
    end

    def test_a_warrant_is_cleared_when_every_retry_passes
      standing_warrant
      subject = warrants(warrants: false)

      decided = subject.adjudicate(result(status: :failed), &all_passing)

      assert_equal :passed, decided.status
      refute subject.standing?(IDENTITY)
      assert_equal 0, @blotter.size
      assert_equal [IDENTITY], subject.cleared.map(&:identity)
      assert_equal :cleared, subject.verdicts[IDENTITY]
      assert_equal [[IDENTITY, true]], @blotter.touches
    end

    def test_a_warrant_stands_when_at_least_one_retry_fails
      standing_warrant
      subject = warrants(warrants: false)

      decided = subject.adjudicate(result(status: :failed), &rerun(:passed, :passed, :passed, :passed, :failed))

      assert_equal :warranted, decided.status
      assert subject.standing?(IDENTITY)
      assert_equal [IDENTITY], subject.upheld.map(&:identity)
      assert_equal :upheld, subject.verdicts[IDENTITY]
      assert_equal [[IDENTITY, false]], @blotter.touches
      refute subject.blocks_build?(decided), "still under warrant is still non-blocking"
    end

    def test_an_upheld_warrant_keeps_the_date_it_was_first_issued
      standing_warrant
      issued_at = @blotter.warrant_entry(IDENTITY)[:issued_at]

      warrants(warrants: false).adjudicate(result, &rerun(:passed, :failed, :failed, :failed, :failed))

      assert_equal issued_at, @blotter.warrant_entry(IDENTITY)[:issued_at]
    end

    # --- the decide / persist split ------------------------------------------------

    def test_decide_runs_the_retries_without_writing_to_the_blotter
      subject = warrants(warrants: true)

      decided = subject.decide(result, &rerun(:failed, :passed, :failed, :failed, :failed))

      assert_equal :warranted, decided.status
      assert_equal 0, @blotter.size, "a worker decides; only the parent writes"
      assert_empty subject.issued
    end

    def test_persist_derives_the_verdict_from_a_result_that_came_back_from_a_worker
      decided = warrants(warrants: true).decide(result, &rerun(:failed, :passed, :failed, :failed, :failed))
      shipped = Result.from_h(decided.to_h)
      parent  = warrants(warrants: true)

      assert_equal :issued, parent.persist(shipped)
      assert parent.standing?(IDENTITY)
    end

    def test_persist_is_a_no_op_for_a_result_that_was_never_adjudicated
      subject = warrants(warrants: true)

      assert_equal :none, subject.persist(result)
      assert_equal 0, @blotter.size
      assert_empty subject.verdicts
    end

    def test_decide_without_a_block_says_so
      subject = warrants(warrants: true)

      assert_raises(ArgumentError) { subject.decide(result) }
    end

    # --- human operations -----------------------------------------------------------

    def test_release_clears_a_warrant_by_hand
      standing_warrant
      subject = warrants

      assert subject.release(IDENTITY)
      refute subject.standing?(IDENTITY)
      refute subject.release(IDENTITY)
    end

    def test_entries_lists_the_current_table
      standing_warrant
      standing_warrant("cccc000000000002")

      assert_equal %w[bbbb000000000001 cccc000000000002], warrants.entries.map(&:identity).sort
      assert_predicate warrants, :any?
    end

    def test_summary_counts_report_the_run
      standing_warrant("cccc000000000002")
      subject = warrants(warrants: true)
      subject.adjudicate(result, &rerun(:passed, :failed, :failed, :failed, :failed))
      subject.adjudicate(result(identity: "cccc000000000002"), &all_passing)

      counts = subject.summary_counts

      assert_equal 1, counts[:issued]
      assert_equal 1, counts[:cleared]
      assert_equal 0, counts[:upheld]
      assert_equal 1, counts[:standing]
    end

    def test_nothing_here_ever_touches_a_source_file
      source = write_file("test/cases/sessions_case.rb", "# original\n")
      before = File.read(source)
      subject = warrants(warrants: true)
      subject.adjudicate(result, &rerun(:passed, :failed, :failed, :failed, :failed))
      subject.release(IDENTITY)

      assert_equal before, File.read(source)
    end

    # --- PATH:LINE resolution ----------------------------------------------------------

    def test_resolve_maps_a_path_and_line_to_a_content_hash
      standing_warrant

      assert_equal IDENTITY, warrants.resolve("test/cases/sessions_case.rb:12")
      assert_equal IDENTITY, warrants.resolve("test/cases/sessions_case.rb")
      assert_equal IDENTITY, warrants.resolve(IDENTITY)
      assert_nil warrants.resolve("test/cases/sessions_case.rb:99")
    end

    def test_resolve_falls_back_to_the_loaded_investigations
      klass = build_case("SessionsCase") { investigate("expires after inactivity") { :ok } }
      investigation = klass.investigations.first

      assert_equal investigation.identity,
                   warrants.resolve("#{investigation.relative_file}:#{investigation.line}")
    end

    def test_resolve_bang_explains_itself_when_nothing_matches
      error = assert_raises(Constable::Error) { warrants.resolve!("no/such/case.rb:3") }

      assert_match(/PATH:LINE/, error.message)
    end
  end
end
