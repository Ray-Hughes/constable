# frozen_string_literal: true

require "fileutils"
require "constable/storage"

module Constable
  module Storage
    # The default blotter: a single self-contained file at .constable/constable.sqlite3.
    #
    # SQLite is the right shape for this workload and the spec says why: a handful of
    # tables, roughly one row per test per run, a dozen-ish workers. It also keeps the
    # promise that a :unit-tier run boots without a database server -- requiring a live
    # Postgres just to record "did this test pass" would undo the speed it is there for.
    #
    # WAL mode plus a busy_timeout is belt and braces rather than necessity: only the
    # parent process writes (workers ship results back over a pipe), but a reader that
    # wanders in -- an editor plugin, a second terminal running `constable jail` -- should
    # never see "database is locked" while a run is writing.
    class SqliteAdapter < RelationalAdapter
      # How long a statement waits on a lock before giving up. Generous, because the only
      # thing it ever waits on is a concurrent *reader* finishing.
      BUSY_TIMEOUT_MS = 5_000

      def path = config.storage_path

      # Drops the handle as well as closing it, so a later query reconnects instead of
      # reaching for a closed database. The Runner closes before forking workers, because
      # SQLite is explicit that a connection must not be carried across a fork.
      def close
        @connection.close if @connection && !@connection.closed?
        @connection = nil
        super
      end

      private

      def connect!
        require_driver!
        FileUtils.mkdir_p(File.dirname(path))
        @connection = SQLite3::Database.new(path)
        @connection.results_as_hash = true
        @connection.busy_timeout = BUSY_TIMEOUT_MS
        # Readers never block the writer and the writer never blocks readers.
        @connection.execute("PRAGMA journal_mode = WAL")
        # WAL + NORMAL is durable across process crashes, which is the only failure that
        # matters here; a machine losing power mid-run costs us one run's bookkeeping.
        @connection.execute("PRAGMA synchronous = NORMAL")
        @connection
      end

      def require_driver!
        require "sqlite3"
      rescue LoadError => e
        raise Constable::ConfigurationError,
              "the sqlite3 gem is required for Constable's default storage adapter " \
              "(add `gem \"sqlite3\"` to your Gemfile and run `bundle install`) -- #{e.message}"
      end

      def execute_raw(sql)
        connection.execute(sql)
        nil
      end

      def query(sql, binds = [])
        connection.execute(sql, binds)
      end

      def execute(sql, binds = [])
        connection.execute(sql, binds)
        nil
      end

      def insert(sql, binds, _table)
        connection.execute(sql, binds)
        connection.last_insert_row_id
      end

      def connection
        connect! if @connection.nil? || @connection.closed?
        @connection
      end
    end
  end
end
