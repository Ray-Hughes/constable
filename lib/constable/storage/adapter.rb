# frozen_string_literal: true

module Constable
  module Storage
    # The pluggable storage interface -- "the blotter".
    #
    # All operational data (flake history, jail/parole state, warrants) lives in a store
    # Constable owns entirely. Never the app's real database, and never the app's
    # transactional test connection, for three reasons:
    #
    #   1. Native cases wrap each test in a rolled-back transaction. Writing through the
    #      app's connection would roll this data back along with everything else.
    #   2. :unit-tier runs skip booting the Rails/DB stack for speed. Requiring a live
    #      Postgres just to record "did this test pass" would undo that.
    #   3. The workload is a handful of tables and ~one row per test per run. It does not
    #      need a client-server database.
    #
    # Adapters must be safe to open from the parent process; workers never write. Results
    # travel back over a pipe and the parent is the only writer, which keeps every adapter
    # free of cross-process write contention.
    class Adapter
      class NotSupported < StandardError; end

      attr_reader :config

      def initialize(config)
        @config = config
      end

      def self.build(config)
        case config.storage_adapter.to_s
        when "sqlite", "sqlite3", nil, "" then SqliteAdapter.new(config)
        when "postgres", "postgresql"     then PostgresAdapter.new(config)
        when "mysql", "mysql2"            then MysqlAdapter.new(config)
        else
          raise ArgumentError, "unknown storage adapter #{config.storage_adapter.inspect} " \
                               "(expected one of: sqlite, postgres, mysql)"
        end
      end

      # --- lifecycle -------------------------------------------------------------
      def setup!    = raise(NotImplementedError, "#{self.class}#setup!")
      def close     = nil
      def reset!    = raise(NotImplementedError, "#{self.class}#reset!")

      # --- runs ------------------------------------------------------------------
      def start_run(seed:, mode:, full:) = raise(NotImplementedError)
      def finish_run(run_id, totals:)    = raise(NotImplementedError)
      def runs(limit: 30)                = raise(NotImplementedError)

      # --- flake history ---------------------------------------------------------
      # Every test's pass/fail result is recorded, native and cold alike.
      def record_result(run_id, result)          = raise(NotImplementedError)
      def history_for(identity, limit: 50)       = raise(NotImplementedError)
      def last_status(identity)                  = raise(NotImplementedError)
      def known_identities                       = raise(NotImplementedError)
      def relink(old_identity, new_identity)     = raise(NotImplementedError)

      # --- jail docket -----------------------------------------------------------
      def jail(identity, label:, file:, line:, reason:) = raise(NotImplementedError)
      def jailed                                          = raise(NotImplementedError)
      def jail_entry(identity)                            = raise(NotImplementedError)
      def jailed?(identity)                               = !jail_entry(identity).nil?
      def parole(identity)                                = raise(NotImplementedError)
      def release(identity)                               = raise(NotImplementedError)
      def record_parole_pass(identity)                    = raise(NotImplementedError)
      def record_parole_violation(identity)               = raise(NotImplementedError)
      def paroled                                         = raise(NotImplementedError)

      # --- warrants --------------------------------------------------------------
      def issue_warrant(identity, label:, file:, line:, reason: nil) = raise(NotImplementedError)
      def warrants                                                   = raise(NotImplementedError)
      def warrant_entry(identity)                                    = raise(NotImplementedError)
      def warranted?(identity)                                       = !warrant_entry(identity).nil?
      def clear_warrant(identity)                                    = raise(NotImplementedError)
      def touch_warrant(identity, cleared:)                          = raise(NotImplementedError)

      # --- durations (worker load balancing, slowest list) -----------------------
      def record_duration(identity, duration)  = raise(NotImplementedError)
      def duration_index                       = raise(NotImplementedError)
      def slowest(limit: 10)                   = raise(NotImplementedError)

      # --- coverage --------------------------------------------------------------
      def record_coverage(run_id, percent:, files:) = raise(NotImplementedError)
      def coverage_trend(limit: 30)                 = raise(NotImplementedError)
    end
  end
end
