# frozen_string_literal: true

require "constable/storage"

module Constable
  module Storage
    # Optional blotter for teams that genuinely need one queryable store shared across
    # many CI machines -- a cross-repo flaky-test dashboard, which is a different problem
    # from local bookkeeping. For everything else the default SQLite adapter is faster,
    # simpler and dependency-free.
    #
    # == A separate connection, always
    #
    # This adapter opens its *own* connection from +storage.url+ and never touches
    # ActiveRecord, the app's connection pool, or the app's database. That is not a style
    # preference, it is the whole reason the blotter exists as a separate store:
    #
    #   1. Native cases wrap each test in a transaction that is rolled back afterwards.
    #      Writing flake history through the app's connection would enlist it in that
    #      transaction and roll the history back along with the test's fixtures -- the
    #      blotter would come out of every run empty.
    #   2. :unit-tier runs skip booting the Rails/DB stack entirely. There may not *be* an
    #      app connection to borrow.
    #   3. Even pointed at the same server, this must be a separate database (or at least
    #      a separate connection) so that dropping and reloading the test schema never
    #      takes the flake history with it.
    #
    # The +pg+ gem is not a dependency of constable-rails; it is required lazily, right
    # where it is needed, so nobody pays for a driver they did not ask for.
    class PostgresAdapter < RelationalAdapter
      def close
        @connection&.close
        super
      rescue StandardError
        super
      end

      private

      def connect!
        # Config first, driver second: a missing url is a typo in config.yml and worth
        # saying so before we go looking for a gem.
        url = config.storage_url
        if url.nil? || url.to_s.empty?
          raise Constable::ConfigurationError,
                "storage.adapter is \"postgres\" but storage.url is not set in .constable/config.yml " \
                "(expected something like postgres://user:pass@host/constable_metadata -- and it must " \
                "point at a database separate from your app's, never the app's test database)"
        end

        require_driver!

        # Deliberately PG::Connection.new and not ActiveRecord: this connection must be
        # outside the app's rolled-back test transaction. See the class comment.
        @connection = PG::Connection.new(url.to_s)
        # "relation already exists, skipping" on every idempotent setup! would otherwise
        # land on stderr. stdout and stderr belong to the run's results.
        @connection.exec("SET client_min_messages TO warning")
        @connection
      end

      def require_driver!
        require "pg"
      rescue LoadError => e
        raise Constable::ConfigurationError,
              "the pg gem is required for Constable's postgres storage adapter " \
              "(add `gem \"pg\"` to your Gemfile and run `bundle install`, or set " \
              "storage.adapter back to \"sqlite\" in .constable/config.yml) -- #{e.message}"
      end

      def types
        super.merge(
          pk: "BIGSERIAL PRIMARY KEY",
          int: "BIGINT",
          float: "DOUBLE PRECISION"
        )
      end

      def execute_raw(sql)
        connection.exec(sql)
        nil
      end

      def query(sql, binds = [])
        connection.exec_params(to_pg(sql), binds.map { |b| cast_bind(b) }).to_a
      end

      def execute(sql, binds = [])
        connection.exec_params(to_pg(sql), binds.map { |b| cast_bind(b) })
        nil
      end

      # Postgres has no "last insert id" on the connection, so the id comes back from the
      # statement itself -- but only the tables that actually have a generated id.
      def insert(sql, binds, table)
        sql = to_pg(sql)
        sql = "#{sql} RETURNING id" if AUTO_ID_TABLES.include?(table)
        result = connection.exec_params(sql, binds.map { |b| cast_bind(b) })
        AUTO_ID_TABLES.include?(table) ? result.first&.fetch("id", nil)&.to_i : nil
      end

      # Postgres numbers its placeholders. The SQL in RelationalAdapter is written with
      # "?" (no literal question marks appear in it), so a positional rewrite is exact.
      def to_pg(sql)
        index = 0
        sql.gsub("?") { "$#{index += 1}" }
      end

      # exec_params sends every bind as text; booleans need spelling out, everything else
      # is fine as its default to_s. Values are still bound, never interpolated.
      def cast_bind(value)
        case value
        when true then 1
        when false then 0
        else value
        end
      end

      def connection
        connect! unless @connection
        @connection
      end
    end
  end
end
