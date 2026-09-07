# frozen_string_literal: true

require_relative "../helper"

module Constable
  # The blotter, exercised end to end against the real SQLite adapter -- the default, and
  # the one every other component talks to. The Postgres and MySQL adapters share their
  # entire SQL implementation with it (Storage::RelationalAdapter), so the coverage here
  # covers them too; what is genuinely theirs -- driver loading, connection options,
  # dialect quirks -- is tested separately below, and anything needing a live server is
  # skip-guarded.
  class StorageTest < TestCase
    def setup
      super
      @storage = Constable.storage
    end

    attr_reader :storage

    # --- adapter selection -----------------------------------------------------

    def test_builds_the_sqlite_adapter_by_default
      assert_instance_of Storage::SqliteAdapter, Storage::Adapter.build(Constable.config)
    end

    def test_builds_each_named_adapter
      assert_instance_of Storage::SqliteAdapter, build_with("sqlite")
      assert_instance_of Storage::SqliteAdapter, build_with("sqlite3")
      assert_instance_of Storage::PostgresAdapter, build_with("postgres")
      assert_instance_of Storage::PostgresAdapter, build_with("postgresql")
      assert_instance_of Storage::MysqlAdapter, build_with("mysql")
      assert_instance_of Storage::MysqlAdapter, build_with("mysql2")
    end

    def test_rejects_an_unknown_adapter_by_name
      error = assert_raises(ArgumentError) { build_with("oracle") }
      assert_match(/unknown storage adapter/, error.message)
      assert_match(/sqlite, postgres, mysql/, error.message)
    end

    # --- sqlite specifics ------------------------------------------------------

    def test_uses_the_configured_sqlite_path
      assert_equal File.join(tmp_root, ".constable/constable.sqlite3"), storage.path
      assert_path_exists storage.path
    end

    def test_creates_its_parent_directory
      write_config(<<~YAML)
        storage:
          adapter: sqlite
          path: tmp/deep/nested/blotter.sqlite3
      YAML

      refute File.directory?(File.join(tmp_root, "tmp/deep/nested"))
      adapter = Constable.storage

      assert_path_exists File.join(tmp_root, "tmp/deep/nested/blotter.sqlite3")
      assert_equal File.join(tmp_root, "tmp/deep/nested/blotter.sqlite3"), adapter.path
    end

    def test_runs_in_wal_mode_with_a_busy_timeout
      journal = storage.send(:connection).execute("PRAGMA journal_mode").first

      assert_equal "wal", journal["journal_mode"].to_s.downcase
      refute_equal 0, storage.send(:connection).execute("PRAGMA busy_timeout").first["timeout"].to_i
    end

    # --- schema ----------------------------------------------------------------

    def test_setup_stamps_a_schema_version
      assert_equal Storage::RelationalAdapter::SCHEMA_VERSION, storage.schema_version
    end

    def test_setup_is_idempotent
      storage.start_run(seed: 1, mode: :test, full: true)
      3.times { storage.setup! }

      assert_equal 1, storage.runs.size
      assert_equal Storage::RelationalAdapter::SCHEMA_VERSION, storage.schema_version
    end

    def test_creates_every_table_the_spec_names
      names = storage.send(:query, "SELECT name FROM sqlite_master WHERE type = 'table'").map { |r| r["name"] }

      %w[flake_history jail_docket warrants runs durations coverage_snapshots schema_meta].each do |table|
        assert_includes names, table
      end
    end

    def test_reset_empties_the_blotter_and_rebuilds_it
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_result(run_id, result(identity: "aaa"))
      storage.jail("aaa", label: "L", file: "f.rb", line: 1, reason: "flip")

      storage.reset!

      assert_empty storage.runs
      assert_empty storage.jailed
      assert_empty storage.known_identities
      assert_equal Storage::RelationalAdapter::SCHEMA_VERSION, storage.schema_version
    end

    # --- runs ------------------------------------------------------------------

    def test_start_run_returns_an_id_and_records_the_run
      run_id = storage.start_run(seed: 8841, mode: :jail, full: false)

      assert_kind_of Integer, run_id
      entry = storage.runs.first

      assert_equal run_id, entry[:id]
      assert_equal 8841, entry[:seed]
      assert_equal :jail, entry[:mode]
      assert_equal false, entry[:full]
      refute_nil entry[:started_at]
      assert_nil entry[:finished_at]
    end

    def test_finish_run_stores_totals_in_columns_and_as_json
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      finished = storage.finish_run(run_id, totals: {
                                      total: 482, passed: 478, failed: 2, jailed: 2,
                                      skipped: 0, warranted: 1, parole_violations: 1,
                                      duration: 12.4, warnings: 3
                                    })

      assert_equal 482, finished[:total]
      assert_equal 478, finished[:passed]
      assert_equal 1, finished[:parole_violations]
      assert_in_delta 12.4, finished[:duration]
      refute_nil finished[:finished_at]
      # Anything the reporter counted that has no column of its own survives as JSON.
      assert_equal 3, finished[:totals][:warnings]
    end

    def test_runs_are_newest_first_and_limited
      ids = 5.times.map { |i| storage.start_run(seed: i, mode: :test, full: true) }

      assert_equal(ids.reverse, storage.runs.map { |r| r[:id] })
      assert_equal(ids.last(2).reverse, storage.runs(limit: 2).map { |r| r[:id] })
    end

    # --- flake history ---------------------------------------------------------

    def test_records_every_result_native_and_cold_alike
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_result(run_id, result(identity: "native1"))
      storage.record_result(run_id, result(identity: "cold1", kind: :cold, status: :failed))

      assert_equal %w[cold1 native1], storage.known_identities
      assert_equal :native, storage.history_for("native1").first[:kind]
      assert_equal :cold, storage.history_for("cold1").first[:kind]
    end

    def test_recorded_rows_carry_the_display_fields_and_the_failure_message
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      failed = result(identity: "abc", status: :failed)
      failed.failure = Failure.new(message: "Expected :created, got :unprocessable_entity")
      storage.record_result(run_id, failed)

      row = storage.history_for("abc").first

      assert_equal run_id, row[:run_id]
      assert_equal "SessionsCase", row[:case_name]
      assert_equal "expires after inactivity", row[:description]
      assert_equal %(SessionsCase "expires after inactivity"), row[:label]
      assert_equal "test/cases/sessions_case.rb", row[:file]
      assert_equal 12, row[:line]
      assert_equal :integration, row[:tier]
      assert_equal :failed, row[:status]
      assert_in_delta 0.25, row[:duration]
      assert_equal "Expected :created, got :unprocessable_entity", row[:failure_message]
      refute_nil row[:recorded_at]
    end

    def test_accepts_the_hash_a_worker_ships_over_the_pipe
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_result(run_id, result(identity: "abc", status: :failed).to_h)

      assert_equal :failed, storage.last_status("abc")
    end

    def test_history_is_newest_first_across_runs
      3.times do |i|
        run_id = storage.start_run(seed: i, mode: :test, full: true)
        storage.record_result(run_id, result(identity: "abc", status: i.even? ? :passed : :failed))
      end

      assert_equal(%i[passed failed passed], storage.history_for("abc").map { |r| r[:status] })
      assert_equal 2, storage.history_for("abc", limit: 2).size
    end

    def test_last_status_answers_the_flake_flip_question
      assert_nil storage.last_status("never-seen")

      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_result(run_id, result(identity: "abc", status: :passed))

      assert_equal :passed, storage.last_status("abc")

      storage.record_result(run_id, result(identity: "abc", status: :failed))

      assert_equal :failed, storage.last_status("abc")
    end

    def test_known_identities_spans_every_table
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_result(run_id, result(identity: "from-history"))
      storage.jail("from-jail", label: "L", file: "f.rb", line: 1, reason: "flip")
      storage.issue_warrant("from-warrant", label: "L", file: "f.rb", line: 1)
      storage.record_duration("from-durations", 0.1)

      assert_equal %w[from-durations from-history from-jail from-warrant], storage.known_identities
    end

    # --- jail state machine ----------------------------------------------------

    def test_jailing_a_test_records_the_whole_docket_entry
      entry = storage.jail("abc", label: %(SessionsCase "expires"), file: "test/x.rb", line: 12,
                                  reason: "failed during a --jail run")

      assert_equal "abc", entry[:identity]
      assert_equal %(SessionsCase "expires"), entry[:label]
      assert_equal "test/x.rb", entry[:file]
      assert_equal 12, entry[:line]
      assert_equal "failed during a --jail run", entry[:reason]
      assert_equal :jailed, entry[:state]
      assert_equal 0, entry[:parole_clean_runs]
      assert_equal 0, entry[:parole_violations]
      assert_equal 1, entry[:times_jailed]
      refute_nil entry[:jailed_at]
      assert storage.jailed?("abc")
      assert_equal(["abc"], storage.jailed.map { |e| e[:identity] })
    end

    def test_jailed_predicate_is_false_for_an_unknown_test
      refute storage.jailed?("nope")
      assert_nil storage.jail_entry("nope")
      assert_empty storage.jailed
    end

    def test_re_jailing_counts_times_jailed_and_wipes_parole_progress
      storage.jail("abc", label: "L", file: "f.rb", line: 1, reason: "first")
      storage.parole("abc")
      storage.record_parole_pass("abc")

      entry = storage.jail("abc", label: "L", file: "f.rb", line: 1, reason: "second")

      assert_equal 2, entry[:times_jailed]
      assert_equal :jailed, entry[:state]
      assert_equal 0, entry[:parole_clean_runs]
      assert_nil entry[:paroled_at]
      assert_equal "second", entry[:reason]
    end

    def test_parole_moves_a_jailed_test_under_supervision
      storage.jail("abc", label: "L", file: "f.rb", line: 1, reason: "flip")
      entry = storage.parole("abc")

      assert_equal :parole, entry[:state]
      assert_equal 0, entry[:parole_clean_runs]
      refute_nil entry[:paroled_at]
      assert_empty storage.jailed
      assert_equal(["abc"], storage.paroled.map { |e| e[:identity] })
      # A paroled test is still on the docket -- it just runs again.
      assert storage.jailed?("abc")
    end

    def test_parole_on_a_test_that_was_never_jailed_is_a_no_op
      assert_nil storage.parole("abc")
      assert_empty storage.paroled
    end

    def test_clean_runs_accumulate_then_auto_release_at_the_parole_period
      write_config("parole_period: 3\n")
      adapter = Constable.storage
      adapter.jail("abc", label: "L", file: "f.rb", line: 1, reason: "flip")
      adapter.parole("abc")

      first = adapter.record_parole_pass("abc")

      assert_equal 1, first[:parole_clean_runs]
      assert_equal false, first[:released]

      second = adapter.record_parole_pass("abc")

      assert_equal 2, second[:parole_clean_runs]
      assert_equal false, second[:released]

      third = adapter.record_parole_pass("abc")

      assert_equal 3, third[:parole_clean_runs]
      assert_equal true, third[:released]
      assert_equal :released, third[:state]
      # Auto-released means off the docket entirely, no human step.
      assert_nil adapter.jail_entry("abc")
      assert_empty adapter.paroled
    end

    def test_clean_runs_are_ignored_for_a_test_that_is_not_on_parole
      storage.jail("abc", label: "L", file: "f.rb", line: 1, reason: "flip")

      assert_nil storage.record_parole_pass("abc")
      assert_nil storage.record_parole_pass("never-jailed")
      assert_equal 0, storage.jail_entry("abc")[:parole_clean_runs]
    end

    def test_a_parole_violation_goes_straight_back_to_jail_and_counts
      storage.jail("abc", label: "L", file: "f.rb", line: 1, reason: "flip")
      storage.parole("abc")
      storage.record_parole_pass("abc")

      entry = storage.record_parole_violation("abc")

      assert_equal :jailed, entry[:state]
      assert_equal 1, entry[:parole_violations]
      assert_equal 2, entry[:times_jailed]
      assert_equal 0, entry[:parole_clean_runs]
      assert_nil entry[:paroled_at]
      # The original reason survives; the caller decides whether to overwrite it.
      assert_equal "flip", entry[:reason]
    end

    def test_repeat_parole_violations_keep_counting
      storage.jail("abc", label: "L", file: "f.rb", line: 1, reason: "flip")
      2.times do
        storage.parole("abc")
        storage.record_parole_violation("abc")
      end

      entry = storage.jail_entry("abc")

      assert_equal 2, entry[:parole_violations]
      assert_equal 3, entry[:times_jailed]
    end

    def test_a_violation_only_applies_to_a_test_on_parole
      storage.jail("abc", label: "L", file: "f.rb", line: 1, reason: "flip")

      assert_nil storage.record_parole_violation("abc")
      assert_nil storage.record_parole_violation("unknown")
      assert_equal 0, storage.jail_entry("abc")[:parole_violations]
    end

    def test_release_takes_a_test_off_the_docket
      storage.jail("abc", label: "L", file: "f.rb", line: 1, reason: "flip")

      assert storage.release("abc")
      refute storage.jailed?("abc")
      assert_empty storage.jailed
      refute storage.release("abc")
    end

    # --- warrants --------------------------------------------------------------

    def test_issuing_a_warrant_records_the_standing_rule
      entry = storage.issue_warrant("abc", label: %(SessionsCase "expires"), file: "test/x.rb",
                                           line: 12, reason: "passed 2 of 5 retries")

      assert_equal "abc", entry[:identity]
      assert_equal %(SessionsCase "expires"), entry[:label]
      assert_equal "test/x.rb", entry[:file]
      assert_equal 12, entry[:line]
      assert_equal "passed 2 of 5 retries", entry[:reason]
      assert_equal 1, entry[:times_seen]
      assert_equal 1, entry[:failed_runs]
      assert_equal 0, entry[:clean_runs]
      refute_nil entry[:issued_at]
      assert storage.warranted?("abc")
      assert_equal(["abc"], storage.warrants.map { |w| w[:identity] })
    end

    def test_reissuing_keeps_the_original_issue_date
      first = storage.issue_warrant("abc", label: "L", file: "f.rb", line: 1, reason: "flaky")
      second = storage.issue_warrant("abc", label: "L2", file: "f2.rb", line: 2)

      assert_equal first[:issued_at], second[:issued_at]
      assert_equal 2, second[:times_seen]
      assert_equal 2, second[:failed_runs]
      assert_equal "L2", second[:label]
      # No new reason given, so the original stands.
      assert_equal "flaky", second[:reason]
    end

    def test_touching_a_warrant_that_did_not_clear_leaves_it_standing
      storage.issue_warrant("abc", label: "L", file: "f.rb", line: 1)
      entry = storage.touch_warrant("abc", cleared: false)

      assert_equal false, entry[:cleared]
      assert_equal :standing, entry[:state]
      assert_equal 2, entry[:times_seen]
      assert_equal 2, entry[:failed_runs]
      assert storage.warranted?("abc")
    end

    def test_touching_a_warrant_that_cleared_removes_it
      storage.issue_warrant("abc", label: "L", file: "f.rb", line: 1)
      entry = storage.touch_warrant("abc", cleared: true)

      assert_equal true, entry[:cleared]
      assert_equal :cleared, entry[:state]
      assert_equal 1, entry[:clean_runs]
      refute storage.warranted?("abc")
      assert_empty storage.warrants
    end

    def test_touching_an_absent_warrant_is_nil
      assert_nil storage.touch_warrant("abc", cleared: true)
      assert_nil storage.warrant_entry("abc")
      refute storage.warranted?("abc")
    end

    def test_clear_warrant_is_the_manual_release
      storage.issue_warrant("abc", label: "L", file: "f.rb", line: 1)

      assert storage.clear_warrant("abc")
      refute storage.warranted?("abc")
      refute storage.clear_warrant("abc")
    end

    # --- durations -------------------------------------------------------------

    def test_the_first_duration_becomes_the_average
      entry = storage.record_duration("abc", 3.2)

      assert_in_delta 3.2, entry[:average]
      assert_in_delta 3.2, entry[:last_duration]
      assert_in_delta 3.2, entry[:max_duration]
      assert_equal 1, entry[:samples]
    end

    def test_the_average_rolls_and_tracks_the_maximum
      storage.record_duration("abc", 1.0)
      storage.record_duration("abc", 2.0)
      entry = storage.record_duration("abc", 3.0)

      assert_in_delta 2.0, entry[:average]
      assert_in_delta 3.0, entry[:last_duration]
      assert_in_delta 3.0, entry[:max_duration]
      assert_equal 3, entry[:samples]

      slower = storage.record_duration("abc", 1.0)

      assert_in_delta 1.75, slower[:average]
      assert_in_delta 3.0, slower[:max_duration]
    end

    def test_the_average_stops_widening_past_the_rolling_window
      window = Storage::RelationalAdapter::ROLLING_WINDOW
      (window * 2).times { storage.record_duration("abc", 1.0) }

      assert_in_delta 1.0, storage.duration_index["abc"]

      # A test that genuinely got slower must move the average, not be drowned by history.
      5.times { storage.record_duration("abc", 10.0) }

      assert_operator storage.duration_index["abc"], :>, 2.0
    end

    def test_duration_index_maps_identity_to_average_seconds
      storage.record_duration("abc", 1.0)
      storage.record_duration("def", 2.0)

      index = storage.duration_index

      assert_equal %w[abc def], index.keys.sort
      assert_in_delta 2.0, index["def"]
    end

    def test_duration_index_is_empty_before_anything_is_recorded
      assert_empty storage.duration_index
      assert_empty storage.slowest
    end

    def test_slowest_is_worst_first_and_carries_display_fields
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_result(run_id, result(identity: "slow", case_name: "SlowCase", description: "crawls"))
      storage.record_duration("slow", 3.2)
      storage.record_duration("quick", 0.1)
      storage.record_duration("middling", 1.1)

      slowest = storage.slowest

      assert_equal(%w[slow middling quick], slowest.map { |s| s[:identity] })
      assert_equal %(SlowCase "crawls"), slowest.first[:label]
      assert_equal "test/cases/sessions_case.rb", slowest.first[:file]
      assert_equal 12, slowest.first[:line]
      assert_in_delta 3.2, slowest.first[:average]
      # No result recorded for it, so there is nothing to label it with -- but it still lists.
      assert_nil slowest.last[:label]
      assert_equal 2, storage.slowest(limit: 2).size
    end

    # --- relink ----------------------------------------------------------------

    def test_relink_moves_history_to_the_new_identity
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      2.times { storage.record_result(run_id, result(identity: "old")) }

      summary = storage.relink("old", "new")

      assert_equal 2, summary[:moved_results]
      assert_empty storage.history_for("old")
      assert_equal 2, storage.history_for("new").size
      assert_equal :passed, storage.last_status("new")
      assert_equal ["new"], storage.known_identities
    end

    def test_relink_moves_the_jail_entry_warrant_and_durations
      storage.jail("old", label: "L", file: "f.rb", line: 1, reason: "flip")
      storage.issue_warrant("old", label: "L", file: "f.rb", line: 1)
      storage.record_duration("old", 2.0)

      summary = storage.relink("old", "new")

      assert_equal %i[moved moved moved], [summary[:jail], summary[:warrant], summary[:durations]]
      assert storage.jailed?("new")
      refute storage.jailed?("old")
      assert storage.warranted?("new")
      assert_in_delta 2.0, storage.duration_index["new"]
      assert_nil storage.duration_index["old"]
      assert_equal 1, storage.jail_entry("new")[:times_jailed]
    end

    def test_relink_merges_rather_than_clobbering_live_state
      storage.jail("old", label: "old label", file: "f.rb", line: 1, reason: "old reason")
      storage.jail("new", label: "new label", file: "f.rb", line: 9, reason: "new reason")

      summary = storage.relink("old", "new")

      assert_equal :merged, summary[:jail]
      assert_nil storage.jail_entry("old")
      assert_equal "new reason", storage.jail_entry("new")[:reason]
    end

    def test_relink_reports_what_it_did_not_find
      summary = storage.relink("old", "new")

      assert_equal({ moved_results: 0, jail: :none, warrant: :none, durations: :none }, summary)
    end

    def test_relink_to_the_same_identity_is_a_no_op
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_result(run_id, result(identity: "same"))

      assert_equal 0, storage.relink("same", "same")[:moved_results]
      assert_equal 1, storage.history_for("same").size
    end

    # --- coverage --------------------------------------------------------------

    def test_records_a_coverage_snapshot_with_its_unpatrolled_count
      run_id = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_coverage(run_id, percent: 92.0,
                                      files: { "app/models/user.rb" => 100.0,
                                               "app/models/order.rb" => 61.5,
                                               "app/jobs/sweep_job.rb" => 0.0 })

      snapshot = storage.coverage_trend.first

      assert_equal run_id, snapshot[:run_id]
      assert_in_delta 92.0, snapshot[:percent]
      assert_equal 3, snapshot[:file_count]
      assert_equal 1, snapshot[:unpatrolled]
      # File paths stay Strings -- symbolizing a path would be nonsense.
      assert_in_delta 61.5, snapshot[:files]["app/models/order.rb"]
      refute_nil snapshot[:recorded_at]
    end

    def test_coverage_trend_is_newest_first_and_limited
      percents = [80.0, 85.0, 90.0]
      percents.each do |percent|
        run_id = storage.start_run(seed: 1, mode: :test, full: true)
        storage.record_coverage(run_id, percent: percent, files: {})
      end

      assert_equal(percents.reverse, storage.coverage_trend.map { |s| s[:percent] })
      assert_equal([90.0], storage.coverage_trend(limit: 1).map { |s| s[:percent] })
    end

    def test_coverage_trend_is_empty_without_snapshots
      assert_empty storage.coverage_trend
    end

    # --- a whole run, the way the runner will drive it --------------------------

    def test_a_full_lifecycle_across_several_runs
      identity = "0123456789abcdef"

      run_one = storage.start_run(seed: 1, mode: :test, full: true)
      storage.record_result(run_one, result(identity: identity, status: :passed, duration: 1.0))
      storage.record_duration(identity, 1.0)
      storage.finish_run(run_one, totals: { total: 1, passed: 1 })

      # Run two flips with no code change -- the flake detector jails it.
      run_two = storage.start_run(seed: 2, mode: :test, full: true)

      assert_equal :passed, storage.last_status(identity)
      storage.record_result(run_two, result(identity: identity, status: :failed, duration: 1.4))
      storage.record_duration(identity, 1.4)
      storage.jail(identity, label: "L", file: "f.rb", line: 1, reason: "flake history flip")
      storage.finish_run(run_two, totals: { total: 1, failed: 1, jailed: 1 })

      # Run three: jailed, so the body is skipped but the result is still recorded.
      run_three = storage.start_run(seed: 3, mode: :test, full: true)
      storage.record_result(run_three, result(identity: identity, status: :jailed, duration: 0.0))
      storage.finish_run(run_three, totals: { total: 1, jailed: 1 })

      # A human paroles it; it runs clean and is released.
      storage.parole(identity)
      Constable.config.instance_variable_get(:@raw)["parole_period"] = 2
      2.times do |i|
        run_id = storage.start_run(seed: 4 + i, mode: :test, full: true)
        storage.record_result(run_id, result(identity: identity, status: :passed, duration: 0.9))
        storage.record_parole_pass(identity)
        storage.finish_run(run_id, totals: { total: 1, passed: 1 })
      end

      assert_nil storage.jail_entry(identity)
      assert_equal 5, storage.runs.size
      assert_equal 5, storage.history_for(identity).size
      assert_equal(%i[passed passed jailed failed passed], storage.history_for(identity).map { |r| r[:status] })
      assert_equal [identity], storage.known_identities
    end

    # --- postgres --------------------------------------------------------------

    def test_postgres_adapter_demands_a_url
      adapter = build_with("postgres")
      error = assert_raises(ConfigurationError) { adapter.setup! }

      assert_match(/storage.url is not set/, error.message)
      assert_match(/separate from your app's/, error.message)
    end

    def test_postgres_rewrites_placeholders_positionally
      adapter = build_with("postgres")

      assert_equal "SELECT * FROM runs WHERE id = $1", adapter.send(:to_pg, "SELECT * FROM runs WHERE id = ?")
      assert_equal "INSERT INTO t (a, b) VALUES ($1, $2)", adapter.send(:to_pg, "INSERT INTO t (a, b) VALUES (?, ?)")
    end

    def test_postgres_uses_its_own_dialect_types
      types = build_with("postgres").send(:types)

      assert_equal "BIGSERIAL PRIMARY KEY", types[:pk]
      assert_equal "DOUBLE PRECISION", types[:float]
    end

    def test_postgres_ddl_is_valid_for_every_table
      adapter = build_with("postgres")
      ddl = adapter.send(:ddl_statements)

      assert_equal Storage::RelationalAdapter::TABLES.size, ddl.size
      assert(ddl.all? { |sql| sql.include?("CREATE TABLE IF NOT EXISTS") })
      assert(ddl.none? { |sql| sql.include?("AUTOINCREMENT") })
      # "full" is reserved in Postgres, which is why the column is full_run.
      assert(ddl.none? { |sql| sql.match?(/^\s+full\s/) })
    end

    def test_postgres_round_trip_when_a_server_is_available
      url = ENV.fetch("CONSTABLE_POSTGRES_URL", nil)
      skip "set CONSTABLE_POSTGRES_URL to exercise the postgres adapter against a live server" unless url

      write_config(<<~YAML)
        storage:
          adapter: postgres
          url: #{url}
      YAML

      adapter = Constable.storage
      adapter.reset!
      run_id = adapter.start_run(seed: 7, mode: :test, full: true)
      adapter.record_result(run_id, result(identity: "pg1", status: :failed))
      adapter.jail("pg1", label: "L", file: "f.rb", line: 1, reason: "flip")
      adapter.record_duration("pg1", 2.5)

      assert_equal :failed, adapter.last_status("pg1")
      assert_equal 7, adapter.runs.first[:seed]
      assert_equal true, adapter.runs.first[:full]
      assert_equal :jailed, adapter.jail_entry("pg1")[:state]
      assert_in_delta 2.5, adapter.duration_index["pg1"]
      assert_equal 1, adapter.relink("pg1", "pg2")[:moved_results]
    ensure
      adapter&.close
    end

    # --- mysql -----------------------------------------------------------------

    def test_mysql_adapter_demands_a_url
      adapter = build_with("mysql")
      error = assert_raises(ConfigurationError) { adapter.setup! }

      assert_match(/storage.url is not set/, error.message)
    end

    def test_mysql_names_the_gem_to_install_when_the_driver_is_missing
      skip "mysql2 is installed here, so the missing-driver path cannot be exercised" if driver_available?("mysql2")

      adapter = build_with("mysql", url: "mysql2://root@127.0.0.1/constable_metadata")
      error = assert_raises(ConfigurationError) { adapter.setup! }

      assert_match(/mysql2 gem is required/, error.message)
      assert_match(/bundle install/, error.message)
      assert_match(/storage.adapter back to "sqlite"/, error.message)
    end

    def test_mysql_parses_its_connection_url
      adapter = build_with("mysql", url: "mysql2://blotter:s3cret@db.internal:3307/constable_metadata")
      options = adapter.send(:connection_options, adapter.config.storage_url)

      assert_equal "db.internal", options[:host]
      assert_equal 3307, options[:port]
      assert_equal "blotter", options[:username]
      assert_equal "s3cret", options[:password]
      assert_equal "constable_metadata", options[:database]
    end

    def test_mysql_uses_its_own_dialect_types_and_index_syntax
      adapter = build_with("mysql")
      types = adapter.send(:types)

      assert_equal "BIGINT AUTO_INCREMENT PRIMARY KEY", types[:pk]
      assert_equal "DOUBLE", types[:float]
      # MySQL has no CREATE INDEX IF NOT EXISTS, so idempotency is a rescue instead.
      assert(adapter.send(:ddl_statements).none? { |sql| sql.include?("AUTOINCREMENT") })
    end

    def test_mysql_round_trip_when_a_server_is_available
      url = ENV.fetch("CONSTABLE_MYSQL_URL", nil)
      skip "set CONSTABLE_MYSQL_URL to exercise the mysql adapter against a live server" unless url

      write_config(<<~YAML)
        storage:
          adapter: mysql
          url: #{url}
      YAML

      adapter = Constable.storage
      adapter.reset!
      run_id = adapter.start_run(seed: 7, mode: :test, full: true)
      adapter.record_result(run_id, result(identity: "my1", status: :failed))
      adapter.record_duration("my1", 2.5)

      assert_equal :failed, adapter.last_status("my1")
      assert_equal 7, adapter.runs.first[:seed]
      assert_in_delta 2.5, adapter.duration_index["my1"]
    ensure
      adapter&.close
    end

    private

    def build_with(adapter_name, url: nil)
      raw = { "storage" => { "adapter" => adapter_name, "url" => url } }
      Storage::Adapter.build(Config.new(raw, root: tmp_root))
    end

    def driver_available?(gem_name)
      require gem_name
      true
    rescue LoadError
      false
    end

    def result(identity:, case_name: "SessionsCase", description: "expires after inactivity",
               status: :passed, kind: :native, duration: 0.25)
      Result.new(
        identity: identity, case_name: case_name, description: description,
        file: "test/cases/sessions_case.rb", line: 12, kind: kind, tier: :integration,
        status: status, duration: duration
      )
    end
  end
end

module Constable
  # `constable status` answers "how much of this suite is still opted out of native
  # rules, and is that number moving" -- which needs the split counted per run.
  class StorageKindTotalsTest < Constable::TestCase
    def setup
      super
      write_config("storage:\n  adapter: sqlite\n  path: .constable/constable.sqlite3\n")
      @storage = Constable.storage
    end

    def record(run_id, identity, kind)
      @storage.record_result(run_id, Result.new(
                                       identity: identity, case_name: "C", description: identity,
                                       file: "test/cases/#{identity}.rb", line: 1, kind: kind
                                     ))
    end

    def test_counts_native_and_cold_separately_per_run
      run_id = @storage.start_run(seed: 1, mode: "full", full: true)
      record(run_id, "a", :native)
      record(run_id, "b", :native)
      record(run_id, "c", :cold)

      totals = @storage.kind_totals(limit: 5)

      assert_equal 1, totals.size
      assert_equal 2, totals.first[:native]
      assert_equal 1, totals.first[:cold]
    end

    def test_returns_newest_run_first
      first = @storage.start_run(seed: 1, mode: "full", full: true)
      record(first, "a", :cold)
      second = @storage.start_run(seed: 2, mode: "full", full: true)
      record(second, "b", :native)

      totals = @storage.kind_totals(limit: 5)

      assert_equal second, totals.first[:run_id]
      assert_equal 1, totals.first[:native]
      assert_equal 0, totals.first[:cold]
    end

    def test_a_kind_with_no_rows_counts_zero_rather_than_going_missing
      run_id = @storage.start_run(seed: 1, mode: "full", full: true)
      record(run_id, "a", :native)

      assert_equal 0, @storage.kind_totals(limit: 5).first[:cold]
    end

    def test_no_runs_means_no_rows
      assert_empty @storage.kind_totals(limit: 5)
    end
  end
end
