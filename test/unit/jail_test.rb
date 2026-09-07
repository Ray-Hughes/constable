# frozen_string_literal: true

require_relative "../helper"

module Constable
  class JailTest < TestCase
    # An in-memory stand-in for the docket half of Constable::Storage::Adapter.
    #
    # Deliberately duck-typed rather than a subclass: Jail is being written alongside the
    # real SQLite adapter, and a unit test for the state machine should not wait on -- or
    # boot -- a database. The semantics here mirror the shipped adapter exactly, including
    # the auto-release that happens inside #record_parole_pass and the merged
    # `released:` / `state: :released` shape it hands back once the row is gone.
    class FakeBlotter
      attr_reader :calls

      def initialize(parole_period: 10)
        @docket        = {}
        @history       = Hash.new { |hash, key| hash[key] = [] }
        @parole_period = parole_period
        @calls         = Hash.new(0)
      end

      def close = nil

      # --- flake history (only what Jail reads) ---------------------------------
      def push_history(identity, *statuses)
        statuses.each { |status| @history[identity] << status }
        self
      end

      def last_status(identity) = @history[identity].last

      # --- jail docket ----------------------------------------------------------
      def jail(identity, label:, file:, line:, reason:)
        @calls[:jail] += 1
        existing = @docket[identity]
        if existing
          existing.merge!(
            label: label, file: file, line: line, reason: reason, state: :jailed,
            parole_clean_runs: 0, paroled_at: nil, times_jailed: existing[:times_jailed].to_i + 1
          )
        else
          @docket[identity] = {
            identity: identity, label: label, file: file, line: line, reason: reason,
            jailed_at: "2026-09-06T00:00:00.000Z", state: :jailed, parole_clean_runs: 0,
            parole_violations: 0, times_jailed: 1
          }
        end
        jail_entry(identity)
      end

      def jailed  = @docket.values.select { |row| row[:state] == :jailed }.map(&:dup)
      def paroled = @docket.values.select { |row| row[:state] == :parole }.map(&:dup)

      def jail_entry(identity) = @docket[identity]&.dup

      def parole(identity)
        @calls[:parole] += 1
        return nil unless @docket[identity]

        @docket[identity].merge!(state: :parole, parole_clean_runs: 0,
                                 paroled_at: "2026-09-06T00:00:00.000Z")
        jail_entry(identity)
      end

      def release(identity)
        @calls[:release] += 1
        !@docket.delete(identity).nil?
      end

      def record_parole_pass(identity)
        @calls[:record_parole_pass] += 1
        entry = @docket[identity]
        return nil unless entry && entry[:state] == :parole

        clean = entry[:parole_clean_runs].to_i + 1
        if clean >= @parole_period
          @docket.delete(identity)
          return entry.merge(state: :released, parole_clean_runs: clean, released: true)
        end

        entry[:parole_clean_runs] = clean
        entry.merge(released: false)
      end

      def record_parole_violation(identity)
        @calls[:record_parole_violation] += 1
        entry = @docket[identity]
        return nil unless entry && entry[:state] == :parole

        entry.merge!(
          state: :jailed, parole_clean_runs: 0, paroled_at: nil,
          parole_violations: entry[:parole_violations].to_i + 1,
          times_jailed: entry[:times_jailed].to_i + 1
        )
        jail_entry(identity)
      end

      # Test-side inspection.
      def docket_size = @docket.size
      def state_of(identity) = @docket[identity]&.fetch(:state, nil)
    end

    # A blotter that counts but refuses to move a paroled test back to jail, standing in
    # for a third-party adapter that implements the interface only half way.
    class LazyBlotter < FakeBlotter
      def record_parole_violation(_identity)
        @calls[:record_parole_violation] += 1
        nil
      end
    end

    def setup
      super
      @period  = 10
      @config  = Config.new({ "parole_period" => @period }, root: tmp_root)
      @blotter = FakeBlotter.new(parole_period: @period)
      Constable.storage = @blotter
    end

    def jail(config: @config, storage: @blotter) = Jail.new(config: config, storage: storage)

    def result(status: :failed, identity: "aaaa000000000001", line: 12,
               file: "test/cases/users_case.rb", case_name: "UsersCase",
               description: "creates a user")
      Result.new(identity: identity, case_name: case_name, description: description,
                 file: file, line: line, status: status)
    end

    # --- route one: a flake-history flip ---------------------------------------

    def test_a_test_that_flips_result_with_no_code_change_is_jailed
      @blotter.push_history("aaaa000000000001", :passed, :passed)
      subject = jail

      decided = subject.adjudicate(result(status: :failed))

      assert_equal :jailed, decided.status
      assert_match(/flake history flip/, decided.jail_reason)
      refute_empty subject.entries
      assert subject.jailed?("aaaa000000000001")
    end

    def test_a_first_ever_failure_is_just_a_failure
      decided = jail.adjudicate(result(status: :failed))

      assert_equal :failed, decided.status
      assert_equal 0, @blotter.docket_size
    end

    def test_a_failure_following_a_failure_is_not_a_flip
      @blotter.push_history("aaaa000000000001", :passed, :failed)

      decided = jail.adjudicate(result(status: :failed))

      assert_equal :failed, decided.status
      assert_equal 0, @blotter.docket_size
    end

    def test_flake_flip_is_never_claimed_for_a_passing_result
      @blotter.push_history("aaaa000000000001", :passed)

      refute jail.flake_flip?(result(status: :passed))
    end

    # --- route two: a --jail-mode failure --------------------------------------

    def test_a_failure_during_a_jail_mode_run_is_jailed_instead_of_failing_the_build
      subject = jail

      decided = subject.adjudicate(result(status: :failed), jail_mode: true)

      assert_equal :jailed, decided.status
      assert_match(/--jail/, decided.jail_reason)
      assert_equal 1, decided.times_jailed

      entry = subject.entry("aaaa000000000001")

      assert_equal "test/cases/users_case.rb", entry.file
      assert_equal 12, entry.line
      assert_equal 'UsersCase "creates a user"', entry.label
      refute_nil entry.jailed_at
    end

    def test_jail_mode_does_not_need_a_flake_history_to_jail
      jail.adjudicate(result(status: :failed), jail_mode: true)

      assert_equal 1, @blotter.docket_size
    end

    def test_a_passing_test_is_never_jailed_even_in_jail_mode
      decided = jail.adjudicate(result(status: :passed), jail_mode: true)

      assert_equal :passed, decided.status
      assert_equal 0, @blotter.docket_size
    end

    # --- route three: a parole violation ---------------------------------------

    def test_a_parole_violation_lands_on_the_same_docket
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")

      decided = subject.adjudicate(result(status: :failed))

      assert_equal :parole_violation, decided.status
      assert subject.jailed?("aaaa000000000001")
      refute subject.paroled?("aaaa000000000001")
    end

    def test_all_three_routes_share_one_docket
      subject = jail
      @blotter.push_history("flake00000000001", :passed)

      subject.adjudicate(result(status: :failed, identity: "flake00000000001"))
      subject.adjudicate(result(status: :failed, identity: "jailmode00000001"), jail_mode: true)
      subject.adjudicate(result(status: :failed, identity: "parole0000000001"), jail_mode: true)
      subject.parole("parole0000000001")
      subject.adjudicate(result(status: :failed, identity: "parole0000000001"))

      assert_equal 3, subject.entries.size
      assert_equal 3, subject.jailed.size
      assert_empty subject.paroled
    end

    # --- skipping ---------------------------------------------------------------

    def test_a_jailed_test_skips_only_its_investigate_body
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      assert subject.skip_body?("aaaa000000000001")
    end

    def test_a_paroled_test_is_not_skipped
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")

      refute subject.skip_body?("aaaa000000000001")
      assert subject.supervised?("aaaa000000000001")
    end

    def test_an_unknown_test_is_not_skipped
      refute jail.skip_body?("nothing000000001")
    end

    def test_mark_jailed_fills_in_the_docket_details_without_a_new_offence
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      decided = subject.mark_jailed(result(status: :skipped))

      assert_equal :jailed, decided.status
      assert_match(/--jail/, decided.jail_reason)
      assert_equal 1, decided.times_jailed
      assert_equal 1, @blotter.calls[:jail], "mark_jailed must not write to the docket"
    end

    def test_a_test_already_on_the_docket_is_not_jailed_twice_by_one_run
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      decided = subject.adjudicate(result(status: :failed), jail_mode: true)

      assert_equal :jailed, decided.status
      assert_equal 1, subject.entry("aaaa000000000001").times_jailed
    end

    # --- parole: clean runs ------------------------------------------------------

    def test_parole_counts_clean_runs_and_auto_releases_at_exactly_the_period
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")

      (1...@period).each do |day|
        transition = subject.record_pass("aaaa000000000001")

        assert_predicate transition, :continuing?, "released early on day #{day}"
        assert_equal day, transition.parole_day
        assert subject.paroled?("aaaa000000000001")
      end

      final = subject.record_pass("aaaa000000000001")

      assert_predicate final, :released?
      assert_equal @period, final.parole_day
      assert_equal 0, @blotter.docket_size
      refute subject.supervised?("aaaa000000000001")
    end

    def test_auto_release_needs_no_human_step_at_a_shorter_period
      config  = Config.new({ "parole_period" => 3 }, root: tmp_root)
      blotter = FakeBlotter.new(parole_period: 3)
      subject = Jail.new(config: config, storage: blotter)
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")

      2.times { assert_predicate subject.record_pass("aaaa000000000001"), :continuing? }

      assert_predicate subject.record_pass("aaaa000000000001"), :released?
      assert_equal 0, blotter.docket_size
    end

    def test_a_paroled_test_that_passes_runs_normally_and_reports_its_day
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")
      subject.record_pass("aaaa000000000001")

      decided = subject.adjudicate(result(status: :passed))

      assert_equal :passed, decided.status
      assert_equal 2, decided.parole_day
    end

    def test_recording_a_pass_for_a_test_that_is_not_on_parole_does_nothing
      transition = jail.record_pass("nothing000000001")

      assert_predicate transition, :none?
      assert_equal 0, @blotter.calls[:record_parole_pass]
    end

    # --- parole: violations ------------------------------------------------------

    def test_a_single_failure_on_parole_is_an_immediate_violation
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")
      2.times { subject.record_pass("aaaa000000000001") }

      transition = subject.record_failure("aaaa000000000001")

      assert_predicate transition, :violation?
      assert_equal 3, transition.parole_day, "should report the run it went down on"
      assert_equal @period, transition.parole_period
      assert_equal :jailed, @blotter.state_of("aaaa000000000001")
    end

    def test_a_violation_increments_both_parole_violations_and_times_jailed
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")

      transition = subject.record_failure("aaaa000000000001")

      assert_equal 1, transition.parole_violations
      assert_equal 2, transition.times_jailed

      entry = subject.entry("aaaa000000000001")

      assert_equal 1, entry.parole_violations
      assert_equal 2, entry.times_jailed, "a repeat offender reports its 2nd time in jail"
    end

    def test_a_violation_produces_the_parole_violation_status_not_a_plain_jailing
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")
      2.times { subject.record_pass("aaaa000000000001") }

      decided = subject.adjudicate(result(status: :failed))

      assert_equal :parole_violation, decided.status
      assert_predicate decided, :parole_violation?
      assert_predicate decided, :jailed?
      assert_equal 3, decided.parole_day
      assert_equal 2, decided.times_jailed
      assert_match(/parole violation/, decided.jail_reason)
    end

    def test_a_violation_wipes_parole_progress
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")
      3.times { subject.record_pass("aaaa000000000001") }
      subject.record_failure("aaaa000000000001")

      assert_equal 0, subject.entry("aaaa000000000001").parole_day
    end

    def test_a_half_implemented_adapter_still_gets_the_test_back_behind_bars
      blotter = LazyBlotter.new(parole_period: @period)
      subject = Jail.new(config: @config, storage: blotter)
      subject.adjudicate(result(status: :failed), jail_mode: true)
      subject.parole("aaaa000000000001")

      transition = subject.record_failure("aaaa000000000001")

      assert_predicate transition, :violation?
      assert subject.jailed?("aaaa000000000001")
      assert_equal 2, transition.times_jailed
    end

    def test_recording_a_failure_for_a_test_that_is_not_on_parole_does_nothing
      transition = jail.record_failure("nothing000000001")

      assert_predicate transition, :none?
    end

    # --- jail run ---------------------------------------------------------------

    def test_jail_run_never_auto_releases_or_auto_paroles_on_a_pass
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)
      passing = result(status: :passed)

      candidates = subject.candidates_for_release([passing])

      assert_equal ["aaaa000000000001"], candidates.map(&:identity)
      assert subject.jailed?("aaaa000000000001"), "a single green run releases nothing"
      assert_equal 1, @blotter.docket_size
      assert_equal 0, @blotter.calls[:release]
      assert_equal 0, @blotter.calls[:parole]
    end

    def test_jail_run_report_splits_candidates_from_the_still_failing
      subject = jail
      subject.adjudicate(result(status: :failed, identity: "green00000000001"), jail_mode: true)
      subject.adjudicate(result(status: :failed, identity: "red0000000000001"), jail_mode: true)

      report = subject.jail_run_report([
                                         result(status: :passed, identity: "green00000000001"),
                                         result(status: :failed, identity: "red0000000000001")
                                       ])

      assert_equal ["green00000000001"], report[:candidates].map(&:identity)
      assert_equal ["red0000000000001"], report[:still_failing].map(&:identity)
      assert_equal 2, @blotter.docket_size
    end

    # --- human operations --------------------------------------------------------

    def test_parole_moves_a_jailed_test_and_resets_the_clean_run_count
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      entry = subject.parole("aaaa000000000001")

      assert_predicate entry, :paroled?
      assert_equal 0, entry.parole_day
      assert_equal [entry.identity], subject.paroled.map(&:identity)
      assert_empty subject.jailed
    end

    def test_paroling_a_test_that_is_not_on_the_docket_returns_nothing
      assert_nil jail.parole("nothing000000001")
    end

    def test_release_takes_a_test_off_the_docket_entirely
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      assert subject.release("aaaa000000000001")
      refute subject.supervised?("aaaa000000000001")
      refute subject.release("aaaa000000000001")
    end

    def test_entries_lists_the_whole_docket_jailed_and_paroled_alike
      subject = jail
      subject.adjudicate(result(status: :failed, identity: "locked0000000001"), jail_mode: true)
      subject.adjudicate(result(status: :failed, identity: "watched000000001"), jail_mode: true)
      subject.parole("watched000000001")

      assert_equal %w[locked0000000001 watched000000001], subject.entries.map(&:identity).sort
      assert_equal ["locked0000000001"], subject.jailed.map(&:identity)
      assert_equal ["watched000000001"], subject.paroled.map(&:identity)
    end

    def test_summary_counts_split_parole_violations_out_of_the_jailed_total
      subject = jail
      subject.adjudicate(result(status: :failed, identity: "locked0000000001"), jail_mode: true)
      subject.adjudicate(result(status: :failed, identity: "watched000000001"), jail_mode: true)
      subject.parole("watched000000001")

      results = [
        subject.adjudicate(result(status: :failed, identity: "locked0000000001")),
        subject.adjudicate(result(status: :failed, identity: "watched000000001"))
      ]
      counts = subject.summary_counts(results)

      assert_equal 1, counts[:jailed]
      assert_equal 1, counts[:parole_violations]
    end

    def test_a_repeat_offender_counts_its_stays
      subject = jail
      subject.jail(result(status: :failed), reason: :jail_mode)
      subject.jail(result(status: :failed), reason: :flake)

      assert_equal 2, subject.entry("aaaa000000000001").times_jailed
      assert_match(/flake history flip/, subject.entry("aaaa000000000001").reason)
    end

    def test_a_full_release_wipes_the_slate
      subject = jail
      subject.jail(result(status: :failed), reason: :jail_mode)
      subject.release("aaaa000000000001")
      subject.jail(result(status: :failed), reason: :jail_mode)

      assert_equal 1, subject.entry("aaaa000000000001").times_jailed
    end

    def test_parole_period_falls_back_to_ten_when_configured_to_zero
      subject = Jail.new(config: Config.new({ "parole_period" => 0 }, root: tmp_root), storage: @blotter)

      assert_equal 10, subject.parole_period
    end

    # --- PATH:LINE resolution -----------------------------------------------------

    def test_resolve_maps_a_path_and_line_to_a_content_hash
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      assert_equal "aaaa000000000001", subject.resolve("test/cases/users_case.rb:12")
    end

    def test_resolve_accepts_a_bare_path_when_only_one_test_in_it_is_on_the_docket
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      assert_equal "aaaa000000000001", subject.resolve("test/cases/users_case.rb")
    end

    def test_resolve_ignores_a_line_that_does_not_match
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      assert_nil subject.resolve("test/cases/users_case.rb:99")
    end

    def test_resolve_tolerates_an_absolute_path_and_a_leading_dot_slash
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      assert_equal "aaaa000000000001", subject.resolve("./test/cases/users_case.rb:12")
      assert_equal "aaaa000000000001", subject.resolve("#{Constable.root}/test/cases/users_case.rb:12")
    end

    def test_resolve_accepts_an_identity_directly
      subject = jail
      subject.adjudicate(result(status: :failed), jail_mode: true)

      assert_equal "aaaa000000000001", subject.resolve("aaaa000000000001")
    end

    def test_resolve_falls_back_to_the_loaded_investigations
      klass = build_case("UsersCase") { investigate("creates a user") { :ok } }
      investigation = klass.investigations.first

      assert_equal investigation.identity,
                   jail.resolve("#{investigation.relative_file}:#{investigation.line}")
    end

    def test_resolve_bang_explains_itself_when_nothing_matches
      error = assert_raises(Constable::Error) { jail.resolve!("no/such/case.rb:3") }

      assert_match(/PATH:LINE/, error.message)
    end

    def test_resolve_returns_nothing_for_an_empty_target
      assert_nil jail.resolve("")
      assert_nil jail.resolve(nil)
    end
  end
end
