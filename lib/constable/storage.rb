# frozen_string_literal: true

require "json"
require "constable/storage/adapter"

module Constable
  # The blotter -- everything Constable remembers between runs.
  #
  # This file is the entry point for the storage layer: it pulls in the abstract
  # +Adapter+ interface, declares the three shipped adapters so +Adapter.build+ can
  # resolve them, and defines the SQL implementation all three share.
  #
  # == Why one shared implementation
  #
  # SQLite, Postgres and MySQL differ in about six places -- how you open a connection,
  # how a placeholder is spelled, what an auto-incrementing primary key is called, and
  # how you read back an inserted id. Everything else (the schema, the queries, the jail
  # state machine, the rolling duration average) is identical. +RelationalAdapter+ holds
  # the identical part; each concrete adapter supplies the six differences. There is no
  # third-party SQL abstraction in play here on purpose -- Constable must boot for a
  # :unit-tier run without a Rails app present, so it carries no ActiveRecord dependency.
  #
  # == Conventions every caller can rely on
  #
  # * *Read methods return plain Ruby hashes with SYMBOL keys.* No adapter ever hands back
  #   a database-specific row object or a string-keyed hash. Other components (jail,
  #   warrants, the reporter, the CLI) consume these directly.
  # * *Enumerable reads are newest-first.* +runs+, +history_for+, +jailed+, +paroled+,
  #   +warrants+ and +coverage_trend+ all return most-recent-first. A consumer plotting a
  #   trend line reverses; a consumer asking "what happened last?" reads element zero.
  # * *Enum-ish values come back as Symbols* -- +:passed+, +:native+, +:unit+, +:jailed+,
  #   +:parole+ -- matching +Constable::Result::STATUSES+ and friends. Free text stays a
  #   String, and +nil+ stays +nil+ (never coerced into +:""+).
  # * *Timestamps are ISO-8601 UTC Strings* ("2026-09-06T12:00:00.000Z"), stored in text
  #   columns. Portable across all three engines, sortable as text, no timezone surprises,
  #   and no driver-specific Time coercion to get wrong.
  # * A read for something that does not exist returns +nil+ (single) or +[]+ (list).
  #
  # == Concurrency
  #
  # *Only the parent process writes to storage.* Workers ship their results back over a
  # pipe as +Result#to_h+ and the parent persists them, so no adapter needs cross-process
  # write locking and no upsert here needs to be atomic against a competing writer --
  # which is why the read-then-insert-or-update helpers below are written as two plain
  # statements rather than as three dialects' worth of ON CONFLICT syntax. SQLite still
  # runs in WAL mode with a busy_timeout anyway: a stray reader (an editor plugin, a
  # second terminal running `constable jail`) costs nothing to tolerate.
  module Storage
    autoload :SqliteAdapter,   "constable/storage/sqlite_adapter"
    autoload :PostgresAdapter, "constable/storage/postgres_adapter"
    autoload :MysqlAdapter,    "constable/storage/mysql_adapter"

    # The SQL half of every shipped adapter.
    #
    # Subclasses must implement: +connect!+, +execute_raw+, +query+, +execute+, +insert+,
    # +close+, and may override +types+ and +create_index+ for dialect quirks.
    class RelationalAdapter < Adapter
      # Bumped whenever the schema below changes. Stored in the schema_meta table so a
      # future release can migrate an existing blotter instead of asking for a wipe.
      SCHEMA_VERSION = 1

      # How many samples the duration average remembers. Past this, each new sample is
      # weighted 1/N against the running mean, so the index tracks a test that got slower
      # (or faster) instead of being anchored by a year of old timings.
      ROLLING_WINDOW = 20

      TABLES = %w[
        schema_meta runs flake_history jail_docket warrants durations coverage_snapshots
      ].freeze

      # Tables with a generated primary key, so an adapter knows when an insert has an id
      # worth reading back. The rest are keyed by identity, which the caller already has.
      AUTO_ID_TABLES = %w[runs flake_history coverage_snapshots].freeze

      # Column-name -> Ruby type. Drivers disagree about what they hand back (pg returns
      # every value as a String; sqlite3 and mysql2 return typed values), so every row
      # passes through here and comes out the same shape regardless of engine.
      INTEGER_COLUMNS = %w[
        id run_id line samples times_seen clean_runs failed_runs parole_clean_runs
        parole_violations times_jailed total passed failed jailed skipped errored
        warranted file_count unpatrolled
      ].freeze

      FLOAT_COLUMNS = %w[duration average last_duration max_duration percent].freeze
      BOOLEAN_COLUMNS = %w[full_run].freeze
      SYMBOL_COLUMNS = %w[status kind tier mode state].freeze
      # totals is Constable's own counter hash, so its keys become Symbols. files is keyed
      # by *file path*, which must stay a String.
      SYMBOL_KEYED_JSON_COLUMNS = %w[totals].freeze
      STRING_KEYED_JSON_COLUMNS = %w[files].freeze

      # Columns whose stored name is not the name callers should see. The run row is
      # opened with `full:`, so it reads back as `:full`; "full" is a reserved word in
      # Postgres, hence the full_run column underneath.
      COLUMN_ALIASES = { "full_run" => :full }.freeze

      def initialize(config)
        super
        @setup = false
      end

      # --- lifecycle -------------------------------------------------------------

      # Idempotent. Creating the schema is CREATE TABLE IF NOT EXISTS all the way down,
      # so calling this on every boot costs one round trip and never destroys anything.
      def setup!
        connect! unless @connection
        ddl_statements.each { |sql| execute_raw(sql) }
        index_statements.each { |(name, table, columns)| create_index(name, table, columns) }
        stamp_schema_version!
        @setup = true
        self
      end

      def close
        @connection = nil
        @setup = false
        nil
      end

      # Drops everything and rebuilds. Used by `constable history reset` and by our own
      # suite; never called during a test run.
      def reset!
        connect! unless @connection
        TABLES.reverse_each { |table| execute_raw("DROP TABLE IF EXISTS #{table}") }
        @setup = false
        setup!
      end

      # The schema version currently stamped on this blotter, as an Integer.
      def schema_version
        row = query("SELECT value FROM schema_meta WHERE name = ?", ["schema_version"]).first
        row && row["value"].to_i
      end

      # --- runs ------------------------------------------------------------------

      # Opens a run row and returns its id. Every flake_history and coverage row written
      # afterwards points back at it.
      def start_run(seed:, mode:, full:)
        insert_row("runs", {
                     "seed" => seed&.to_s,
                     "mode" => (mode || :test).to_s,
                     "full_run" => full ? 1 : 0,
                     "started_at" => now
                   })
      end

      # +totals+ is whatever the reporter counted. Recognised keys land in their own
      # columns so `constable status` can query them; the whole hash is also kept as JSON
      # so a future counter needs no migration to be readable.
      def finish_run(run_id, totals:)
        totals = symbolize(totals || {})
        update_row("runs", { "id" => run_id }, {
                     "finished_at" => now,
                     "duration" => totals[:duration]&.to_f,
                     "total" => totals[:total]&.to_i,
                     "passed" => totals[:passed]&.to_i,
                     "failed" => totals[:failed]&.to_i,
                     "jailed" => totals[:jailed]&.to_i,
                     "skipped" => totals[:skipped]&.to_i,
                     "warranted" => totals[:warranted]&.to_i,
                     "parole_violations" => totals[:parole_violations]&.to_i,
                     "totals" => JSON.generate(totals)
                   })
        run(run_id)
      end

      def run(run_id)
        row(query("SELECT * FROM runs WHERE id = ?", [run_id]).first)
      end

      # Most recent first.
      def runs(limit: 30)
        rows(query("SELECT * FROM runs ORDER BY id DESC LIMIT ?", [limit.to_i]))
      end

      # --- flake history ---------------------------------------------------------

      # Every result, native and cold alike, one row per test per run. This is the raw
      # material for flake detection (a status flip with no identity change) and for the
      # native-vs-cold trend in `constable status`.
      #
      # Accepts a Constable::Result or the Hash a worker shipped over the pipe.
      def record_result(run_id, result)
        attrs = result_attributes(result)
        insert_row("flake_history", {
                     "run_id" => run_id,
                     "identity" => attrs[:identity],
                     "label" => attrs[:label],
                     "case_name" => attrs[:case_name],
                     "description" => attrs[:description],
                     "file" => attrs[:file],
                     "line" => attrs[:line],
                     "kind" => attrs[:kind],
                     "tier" => attrs[:tier],
                     "status" => attrs[:status],
                     "duration" => attrs[:duration],
                     "failure_message" => attrs[:failure_message],
                     "recorded_at" => now
                   })
      end

      # Most recent first.
      def history_for(identity, limit: 50)
        rows(query(
               "SELECT * FROM flake_history WHERE identity = ? ORDER BY id DESC LIMIT ?",
               [identity.to_s, limit.to_i]
             ))
      end

      # The most recently recorded status for a test, as a Symbol, or nil if never seen.
      # The flake detector compares this against the status about to be recorded.
      def last_status(identity)
        row = query(
          "SELECT status FROM flake_history WHERE identity = ? ORDER BY id DESC LIMIT 1",
          [identity.to_s]
        ).first
        row && to_symbol(row["status"])
      end

      # Every identity the blotter has ever heard of, sorted. Rename detection diffs this
      # against the identities in the current run to spot a test that vanished.
      def known_identities
        query(<<~SQL).map { |r| r["identity"] }.compact.sort
          SELECT identity FROM flake_history
          UNION SELECT identity FROM jail_docket
          UNION SELECT identity FROM warrants
          UNION SELECT identity FROM durations
        SQL
      end

      # Moves a test's whole history from one content hash to another -- what
      # `constable history relink OLD NEW` does after a rename that also touched the body.
      #
      # Flake history rows always move. The jail entry, warrant and duration index move
      # too, unless the new identity already has one of its own, in which case the old
      # row is dropped rather than clobbering live state (:merged below).
      #
      # Returns a summary: { moved_results: Integer, jail: Symbol, warrant: Symbol,
      # durations: Symbol } where each Symbol is :moved, :merged or :none.
      def relink(old_identity, new_identity)
        old_identity = old_identity.to_s
        new_identity = new_identity.to_s
        return { moved_results: 0, jail: :none, warrant: :none, durations: :none } if old_identity == new_identity

        moved = count("SELECT COUNT(*) AS c FROM flake_history WHERE identity = ?", [old_identity])
        execute("UPDATE flake_history SET identity = ? WHERE identity = ?", [new_identity, old_identity])

        {
          moved_results: moved,
          jail: move_keyed_row("jail_docket", old_identity, new_identity),
          warrant: move_keyed_row("warrants", old_identity, new_identity),
          durations: move_keyed_row("durations", old_identity, new_identity)
        }
      end

      # --- jail docket -----------------------------------------------------------

      # Jails a test, or re-jails one already on the docket. A repeat offender keeps its
      # history: times_jailed goes up, parole_violations is untouched, and any parole
      # progress is wiped -- coming back to jail means starting the clean-run count over.
      def jail(identity, label:, file:, line:, reason:)
        identity = identity.to_s
        existing = jail_entry(identity)
        if existing
          update_row("jail_docket", { "identity" => identity }, {
                       "label" => label, "file" => file, "line" => line, "reason" => reason,
                       "jailed_at" => now, "state" => "jailed", "parole_clean_runs" => 0,
                       "paroled_at" => nil, "times_jailed" => existing[:times_jailed].to_i + 1,
                       "updated_at" => now
                     })
        else
          insert_row("jail_docket", {
                       "identity" => identity, "label" => label, "file" => file, "line" => line,
                       "reason" => reason, "jailed_at" => now, "state" => "jailed",
                       "parole_clean_runs" => 0, "parole_violations" => 0, "times_jailed" => 1,
                       "updated_at" => now
                     })
        end
        jail_entry(identity)
      end

      # Currently locked up (skipped in normal runs). Most recently jailed first.
      def jailed
        rows(query("SELECT * FROM jail_docket WHERE state = ? ORDER BY jailed_at DESC, identity ASC", ["jailed"]))
      end

      # Out on parole -- runs normally, but watched. Most recently paroled first.
      def paroled
        rows(query("SELECT * FROM jail_docket WHERE state = ? ORDER BY paroled_at DESC, identity ASC", ["parole"]))
      end

      def jail_entry(identity)
        row(query("SELECT * FROM jail_docket WHERE identity = ?", [identity.to_s]).first)
      end

      # Jail -> parole. The clean-run count starts at zero; parole_violations and
      # times_jailed carry over, because parole is supervision, not a fresh start.
      # Returns the updated entry, or nil if the test is not on the docket.
      def parole(identity)
        identity = identity.to_s
        return nil unless jail_entry(identity)

        update_row("jail_docket", { "identity" => identity }, {
                     "state" => "parole", "parole_clean_runs" => 0, "paroled_at" => now, "updated_at" => now
                   })
        jail_entry(identity)
      end

      # Off the docket entirely -- no supervision, no history kept here (flake history is
      # untouched). Returns true if there was something to release.
      def release(identity)
        identity = identity.to_s
        return false unless jail_entry(identity)

        execute("DELETE FROM jail_docket WHERE identity = ?", [identity])
        true
      end

      # One clean run for a test on parole. On reaching config.parole_period consecutive
      # clean runs the test auto-releases -- no human step, per the spec.
      #
      # Returns the updated entry. An auto-release returns the entry it had at the moment
      # of release with state: :released (the row is gone by then, so this is the only
      # chance the caller gets to report it). Returns nil if the test is not on parole.
      def record_parole_pass(identity)
        identity = identity.to_s
        entry = jail_entry(identity)
        return nil unless entry && entry[:state] == :parole

        clean = entry[:parole_clean_runs].to_i + 1
        period = parole_period

        if clean >= period
          execute("DELETE FROM jail_docket WHERE identity = ?", [identity])
          return entry.merge(state: :released, parole_clean_runs: clean, released: true)
        end

        update_row("jail_docket", { "identity" => identity },
                   { "parole_clean_runs" => clean, "updated_at" => now })
        jail_entry(identity).merge(released: false)
      end

      # A paroled test failed. No leniency: straight back to jail, both counters up, the
      # clean-run progress discarded. The original jail reason is preserved -- the caller
      # decides whether to overwrite it with a fresh one via #jail.
      # Returns the updated entry, or nil if the test is not on parole.
      def record_parole_violation(identity)
        identity = identity.to_s
        entry = jail_entry(identity)
        return nil unless entry && entry[:state] == :parole

        update_row("jail_docket", { "identity" => identity }, {
                     "state" => "jailed",
                     "parole_clean_runs" => 0,
                     "parole_violations" => entry[:parole_violations].to_i + 1,
                     "times_jailed" => entry[:times_jailed].to_i + 1,
                     "jailed_at" => now,
                     "paroled_at" => nil,
                     "updated_at" => now
                   })
        jail_entry(identity)
      end

      # --- warrants --------------------------------------------------------------

      # Writes a warrant to the blotter -- never to source. Re-issuing an existing warrant
      # refreshes its label/location and bumps failed_runs rather than resetting issued_at,
      # so "how long has this been flaky" survives.
      def issue_warrant(identity, label:, file:, line:, reason: nil)
        identity = identity.to_s
        existing = warrant_entry(identity)
        if existing
          update_row("warrants", { "identity" => identity }, {
                       "label" => label, "file" => file, "line" => line,
                       "reason" => reason || existing[:reason],
                       "last_seen_at" => now,
                       "times_seen" => existing[:times_seen].to_i + 1,
                       "failed_runs" => existing[:failed_runs].to_i + 1
                     })
        else
          insert_row("warrants", {
                       "identity" => identity, "label" => label, "file" => file, "line" => line,
                       "reason" => reason, "issued_at" => now, "last_seen_at" => now,
                       "times_seen" => 1, "clean_runs" => 0, "failed_runs" => 1
                     })
        end
        warrant_entry(identity)
      end

      # Most recently issued first.
      def warrants
        rows(query("SELECT * FROM warrants ORDER BY issued_at DESC, identity ASC"))
      end

      def warrant_entry(identity)
        row(query("SELECT * FROM warrants WHERE identity = ?", [identity.to_s]).first)
      end

      # Manual clear -- `constable warrants release PATH:LINE`. Returns true if there was
      # a warrant to clear.
      def clear_warrant(identity)
        identity = identity.to_s
        return false unless warrant_entry(identity)

        execute("DELETE FROM warrants WHERE identity = ?", [identity])
        true
      end

      # Records this run's verdict on a standing warrant.
      #
      #   cleared: true  -> every retry passed. The warrant is lifted and the row removed.
      #   cleared: false -> at least one retry failed. Still under warrant, non-blocking.
      #
      # Returns the entry either way -- the cleared one carries state: :cleared and its
      # final counters, since the row no longer exists for the reporter to look up.
      # Returns nil when there is no warrant on this identity.
      def touch_warrant(identity, cleared:)
        identity = identity.to_s
        entry = warrant_entry(identity)
        return nil unless entry

        if cleared
          execute("DELETE FROM warrants WHERE identity = ?", [identity])
          return entry.merge(
            state: :cleared, cleared: true, last_seen_at: now,
            times_seen: entry[:times_seen].to_i + 1, clean_runs: entry[:clean_runs].to_i + 1
          )
        end

        update_row("warrants", { "identity" => identity }, {
                     "last_seen_at" => now,
                     "times_seen" => entry[:times_seen].to_i + 1,
                     "failed_runs" => entry[:failed_runs].to_i + 1
                   })
        warrant_entry(identity).merge(state: :standing, cleared: false)
      end

      # --- durations -------------------------------------------------------------

      # Feeds two things: the parallel workers' load balancer (longest test first) and the
      # SLOWEST section of the summary.
      #
      # The average is rolling, not lifetime: past ROLLING_WINDOW samples each new timing
      # is weighted 1/ROLLING_WINDOW, so a test that got slower shows up as slower within
      # a handful of runs instead of being dragged back by ancient data.
      def record_duration(identity, duration)
        identity = identity.to_s
        duration = duration.to_f
        existing = row(query("SELECT * FROM durations WHERE identity = ?", [identity]).first)

        if existing
          weight = [existing[:samples].to_i, ROLLING_WINDOW].min
          average = ((existing[:average].to_f * weight) + duration) / (weight + 1)
          update_row("durations", { "identity" => identity }, {
                       "average" => average,
                       "last_duration" => duration,
                       "max_duration" => [existing[:max_duration].to_f, duration].max,
                       "samples" => existing[:samples].to_i + 1,
                       "updated_at" => now
                     })
        else
          insert_row("durations", {
                       "identity" => identity, "average" => duration, "last_duration" => duration,
                       "max_duration" => duration, "samples" => 1, "updated_at" => now
                     })
        end
        row(query("SELECT * FROM durations WHERE identity = ?", [identity]).first)
      end

      # { identity(String) => average_seconds(Float) }. The one read method that is not
      # symbol-keyed, because its keys are content hashes rather than field names.
      def duration_index
        query("SELECT identity, average FROM durations").to_h { |r| [r["identity"], r["average"].to_f] }
      end

      # Slowest tests by rolling average, worst first. Display fields come from the most
      # recent flake_history row for the identity -- record_duration is given only a
      # timing, so the label lives where the results live.
      def slowest(limit: 10)
        rows(query(<<~SQL, [limit.to_i]))
          SELECT d.identity, d.average, d.last_duration, d.max_duration, d.samples, d.updated_at,
                 (SELECT h.label FROM flake_history h WHERE h.identity = d.identity ORDER BY h.id DESC LIMIT 1) AS label,
                 (SELECT h.file  FROM flake_history h WHERE h.identity = d.identity ORDER BY h.id DESC LIMIT 1) AS file,
                 (SELECT h.line  FROM flake_history h WHERE h.identity = d.identity ORDER BY h.id DESC LIMIT 1) AS line
          FROM durations d
          ORDER BY d.average DESC, d.identity ASC
          LIMIT ?
        SQL
      end

      # --- coverage --------------------------------------------------------------

      # One snapshot per covered run. +files+ is a { path => percent } Hash (an Array of
      # paths is accepted too, and treated as unpatrolled); it round-trips as JSON so the
      # beat report can rebuild a per-file breakdown from history.
      def record_coverage(run_id, percent:, files:)
        files ||= {}
        insert_row("coverage_snapshots", {
                     "run_id" => run_id,
                     "percent" => percent.to_f,
                     "file_count" => file_count_for(files),
                     "unpatrolled" => unpatrolled_for(files),
                     "files" => JSON.generate(files),
                     "recorded_at" => now
                   })
      end

      # Most recent first. Reverse it to plot a line.
      def coverage_trend(limit: 30)
        rows(query("SELECT * FROM coverage_snapshots ORDER BY id DESC LIMIT ?", [limit.to_i]))
      end

      private

      # --- schema ----------------------------------------------------------------

      # Type names per dialect. Values are never interpolated into SQL anywhere in this
      # file -- these are column *types*, fixed strings from the map below.
      def types
        {
          pk: "INTEGER PRIMARY KEY AUTOINCREMENT",
          ident: "VARCHAR(64)",
          text: "TEXT",
          int: "INTEGER",
          float: "REAL",
          time: "VARCHAR(32)"
        }
      end

      def type(name) = types.fetch(name)

      def ddl_statements
        [
          <<~SQL,
            CREATE TABLE IF NOT EXISTS schema_meta (
              name  #{type(:ident)} PRIMARY KEY,
              value #{type(:text)} NOT NULL
            )
          SQL
          <<~SQL,
            CREATE TABLE IF NOT EXISTS runs (
              id                #{type(:pk)},
              seed              #{type(:ident)},
              mode              #{type(:ident)},
              full_run          #{type(:int)} NOT NULL DEFAULT 0,
              started_at        #{type(:time)} NOT NULL,
              finished_at       #{type(:time)},
              duration          #{type(:float)},
              total             #{type(:int)},
              passed            #{type(:int)},
              failed            #{type(:int)},
              jailed            #{type(:int)},
              skipped           #{type(:int)},
              warranted         #{type(:int)},
              parole_violations #{type(:int)},
              totals            #{type(:text)}
            )
          SQL
          <<~SQL,
            CREATE TABLE IF NOT EXISTS flake_history (
              id              #{type(:pk)},
              run_id          #{type(:int)},
              identity        #{type(:ident)} NOT NULL,
              label           #{type(:text)},
              case_name       #{type(:text)},
              description     #{type(:text)},
              file            #{type(:text)},
              line            #{type(:int)},
              kind            #{type(:ident)},
              tier            #{type(:ident)},
              status          #{type(:ident)} NOT NULL,
              duration        #{type(:float)},
              failure_message #{type(:text)},
              recorded_at     #{type(:time)} NOT NULL
            )
          SQL
          <<~SQL,
            CREATE TABLE IF NOT EXISTS jail_docket (
              identity          #{type(:ident)} PRIMARY KEY,
              label             #{type(:text)},
              file              #{type(:text)},
              line              #{type(:int)},
              reason            #{type(:text)},
              jailed_at         #{type(:time)} NOT NULL,
              state             #{type(:ident)} NOT NULL DEFAULT 'jailed',
              parole_clean_runs #{type(:int)} NOT NULL DEFAULT 0,
              parole_violations #{type(:int)} NOT NULL DEFAULT 0,
              times_jailed      #{type(:int)} NOT NULL DEFAULT 1,
              paroled_at        #{type(:time)},
              updated_at        #{type(:time)} NOT NULL
            )
          SQL
          <<~SQL,
            CREATE TABLE IF NOT EXISTS warrants (
              identity     #{type(:ident)} PRIMARY KEY,
              label        #{type(:text)},
              file         #{type(:text)},
              line         #{type(:int)},
              reason       #{type(:text)},
              issued_at    #{type(:time)} NOT NULL,
              last_seen_at #{type(:time)},
              times_seen   #{type(:int)} NOT NULL DEFAULT 0,
              clean_runs   #{type(:int)} NOT NULL DEFAULT 0,
              failed_runs  #{type(:int)} NOT NULL DEFAULT 0
            )
          SQL
          <<~SQL,
            CREATE TABLE IF NOT EXISTS durations (
              identity      #{type(:ident)} PRIMARY KEY,
              average       #{type(:float)} NOT NULL DEFAULT 0,
              last_duration #{type(:float)},
              max_duration  #{type(:float)},
              samples       #{type(:int)} NOT NULL DEFAULT 0,
              updated_at    #{type(:time)} NOT NULL
            )
          SQL
          <<~SQL
            CREATE TABLE IF NOT EXISTS coverage_snapshots (
              id          #{type(:pk)},
              run_id      #{type(:int)},
              percent     #{type(:float)},
              file_count  #{type(:int)},
              unpatrolled #{type(:int)},
              files       #{type(:text)},
              recorded_at #{type(:time)} NOT NULL
            )
          SQL
        ]
      end

      # [index name, table, columns]. Only VARCHAR/INTEGER columns are indexed -- MySQL
      # refuses to index a TEXT column without a prefix length.
      def index_statements
        [
          ["idx_flake_identity", "flake_history", %w[identity id]],
          ["idx_flake_run", "flake_history", %w[run_id]],
          ["idx_flake_status", "flake_history", %w[status]],
          ["idx_jail_state", "jail_docket", %w[state]],
          ["idx_coverage_run", "coverage_snapshots", %w[run_id]]
        ]
      end

      def create_index(name, table, columns)
        execute_raw("CREATE INDEX IF NOT EXISTS #{name} ON #{table} (#{columns.join(", ")})")
      end

      def stamp_schema_version!
        existing = query("SELECT value FROM schema_meta WHERE name = ?", ["schema_version"]).first
        if existing
          # Nothing to migrate yet -- version 1 is the first schema. A future release adds
          # its migrations here, keyed off existing["value"].to_i.
          nil
        else
          execute("INSERT INTO schema_meta (name, value) VALUES (?, ?)",
                  ["schema_version", SCHEMA_VERSION.to_s])
        end
      end

      # --- row plumbing ----------------------------------------------------------

      def insert_row(table, attrs)
        attrs = attrs.compact
        columns = attrs.keys
        sql = "INSERT INTO #{table} (#{columns.join(", ")}) VALUES (#{placeholders(columns.size)})"
        insert(sql, attrs.values, table)
      end

      def update_row(table, where, attrs)
        return if attrs.empty?

        assignments = attrs.keys.map { |c| "#{c} = ?" }.join(", ")
        conditions  = where.keys.map { |c| "#{c} = ?" }.join(" AND ")
        execute("UPDATE #{table} SET #{assignments} WHERE #{conditions}", attrs.values + where.values)
      end

      def placeholders(count) = Array.new(count, "?").join(", ")

      def count(sql, binds = [])
        result = query(sql, binds).first
        return 0 unless result

        (result["c"] || result.values.first).to_i
      end

      # Moves a single primary-keyed row from one identity to another. :moved when the row
      # relocated, :merged when the target already had one (the old row is dropped rather
      # than overwriting live state), :none when there was nothing to move.
      def move_keyed_row(table, old_identity, new_identity)
        old_exists = count("SELECT COUNT(*) AS c FROM #{table} WHERE identity = ?", [old_identity]).positive?
        return :none unless old_exists

        new_exists = count("SELECT COUNT(*) AS c FROM #{table} WHERE identity = ?", [new_identity]).positive?
        if new_exists
          execute("DELETE FROM #{table} WHERE identity = ?", [old_identity])
          :merged
        else
          execute("UPDATE #{table} SET identity = ? WHERE identity = ?", [new_identity, old_identity])
          :moved
        end
      end

      # --- value coercion --------------------------------------------------------

      # The single place a driver row becomes a Constable hash: symbol keys, Integers and
      # Floats where the column says so, Symbols for enum-ish columns, parsed JSON for the
      # blob columns, nil left as nil.
      def row(raw)
        return nil if raw.nil?

        raw.each_with_object({}) do |(column, value), out|
          column = column.to_s
          out[COLUMN_ALIASES.fetch(column, column.to_sym)] = coerce(column, value)
        end
      end

      def rows(raws) = Array(raws).map { |r| row(r) }

      def coerce(column, value)
        return nil if value.nil?

        case column
        when *INTEGER_COLUMNS then value.to_i
        when *FLOAT_COLUMNS   then value.to_f
        when *BOOLEAN_COLUMNS then truthy_column(value)
        when *SYMBOL_COLUMNS  then to_symbol(value)
        when *SYMBOL_KEYED_JSON_COLUMNS then parse_json(value, symbolize: true)
        when *STRING_KEYED_JSON_COLUMNS then parse_json(value, symbolize: false)
        when "seed" then numeric_seed(value)
        else value.is_a?(String) ? value : value.to_s
        end
      end

      # A seed is an Integer in practice (`--seed 8841`) but is stored as text so an
      # unusual one is never truncated. Hand back the Integer when it round-trips.
      def numeric_seed(value)
        string = value.to_s
        string.match?(/\A-?\d+\z/) ? string.to_i : string
      end

      def truthy_column(value)
        return value if [true, false].include?(value)
        return false if value.to_s.empty?

        !%w[0 f false].include?(value.to_s.downcase)
      end

      def to_symbol(value)
        string = value.to_s
        string.empty? ? nil : string.to_sym
      end

      def parse_json(value, symbolize:)
        return value unless value.is_a?(String)

        JSON.parse(value, symbolize_names: symbolize)
      rescue JSON::ParserError
        value
      end

      def symbolize(hash)
        return {} unless hash.respond_to?(:each_pair)

        hash.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
      end

      # Accepts a Constable::Result or the Hash a worker shipped over the pipe, and
      # flattens it into the columns flake_history stores.
      def result_attributes(result)
        hash = result.is_a?(Hash) ? symbolize(result) : symbolize(result.to_h)
        failure = hash[:failure]
        failure = symbolize(failure) if failure.is_a?(Hash)
        case_name = hash[:case_name].to_s
        description = hash[:description].to_s

        {
          identity: hash[:identity].to_s,
          label: hash[:label] || %(#{case_name} "#{description}"),
          case_name: case_name,
          description: description,
          file: hash[:file],
          line: hash[:line],
          kind: (hash[:kind] || :native).to_s,
          tier: hash[:tier]&.to_s,
          status: (hash[:status] || :passed).to_s,
          duration: hash[:duration].to_f,
          failure_message: failure.is_a?(Hash) ? failure[:message] : failure&.message
        }
      end

      def file_count_for(files)
        files.respond_to?(:size) ? files.size : 0
      end

      # "Unpatrolled" is a file with zero executed lines -- usually a file the suite never
      # touched at all, which is worth naming separately from a thinly covered one.
      def unpatrolled_for(files)
        case files
        when Hash  then files.count { |_, percent| percent.to_f.zero? }
        when Array then files.size
        else 0
        end
      end

      def parole_period
        period = config.respond_to?(:parole_period) ? config.parole_period.to_i : 0
        period.positive? ? period : 10
      end

      def now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")

      # --- driver hooks ----------------------------------------------------------

      def connect! = raise(NotImplementedError, "#{self.class}#connect!")
      def execute_raw(_sql) = raise(NotImplementedError, "#{self.class}#execute_raw")
      def query(_sql, _binds = []) = raise(NotImplementedError, "#{self.class}#query")
      def execute(_sql, _binds = []) = raise(NotImplementedError, "#{self.class}#execute")
      def insert(_sql, _binds, _table) = raise(NotImplementedError, "#{self.class}#insert")
    end
  end
end
