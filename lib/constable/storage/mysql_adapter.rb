# frozen_string_literal: true

require "uri"
require "constable/storage"

module Constable
  module Storage
    # Optional blotter, same trade-off as the Postgres adapter: worth it only when one
    # store has to be shared across many CI machines. Locally, SQLite wins on every axis.
    #
    # == A separate connection, always
    #
    # This adapter opens its *own* connection from +storage.url+ and never borrows
    # ActiveRecord's. The reasoning is the same as everywhere else in the storage layer:
    #
    #   1. Native cases run inside a transaction that is rolled back after every test.
    #      Writing the blotter through the app's connection would roll the blotter back
    #      too, and flake history would never survive a run.
    #   2. :unit-tier runs never boot the DB stack, so there may be no app connection at
    #      all to borrow.
    #   3. Reloading the app's test schema must never take the jail docket with it.
    #
    # The +mysql2+ gem is not a dependency of constable-rails; it is required lazily so
    # nobody installs a driver they do not use.
    class MysqlAdapter < RelationalAdapter
      # MySQL's "index already exists". CREATE INDEX has no IF NOT EXISTS in MySQL, so an
      # idempotent setup! means creating and forgiving the duplicate.
      DUPLICATE_INDEX = 1061

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
                "storage.adapter is \"mysql\" but storage.url is not set in .constable/config.yml " \
                "(expected something like mysql2://user:pass@host/constable_metadata -- and it must " \
                "point at a database separate from your app's, never the app's test database)"
        end

        require_driver!

        # Deliberately Mysql2::Client and not ActiveRecord: this connection lives outside
        # the app's rolled-back test transaction. See the class comment.
        @connection = Mysql2::Client.new(**connection_options(url.to_s))
      end

      def require_driver!
        require "mysql2"
      rescue LoadError => e
        raise Constable::ConfigurationError,
              "the mysql2 gem is required for Constable's mysql storage adapter " \
              "(add `gem \"mysql2\"` to your Gemfile and run `bundle install`, or set " \
              "storage.adapter back to \"sqlite\" in .constable/config.yml) -- #{e.message}"
      end

      def connection_options(url)
        uri = URI.parse(url)
        {
          host: uri.host || "127.0.0.1",
          port: uri.port || 3306,
          username: uri.user && URI.decode_www_form_component(uri.user),
          password: uri.password && URI.decode_www_form_component(uri.password),
          database: uri.path.to_s.delete_prefix("/"),
          cast_booleans: false,
          reconnect: true
        }.compact
      end

      def types
        super.merge(
          pk: "BIGINT AUTO_INCREMENT PRIMARY KEY",
          int: "BIGINT",
          float: "DOUBLE"
        )
      end

      def create_index(name, table, columns)
        execute_raw("CREATE INDEX #{name} ON #{table} (#{columns.join(", ")})")
      rescue StandardError => e
        # Mysql2::Error::ConnectionError et al. all respond to #error_number.
        raise unless e.respond_to?(:error_number) && e.error_number == DUPLICATE_INDEX
      end

      def execute_raw(sql)
        connection.query(sql)
        nil
      end

      def query(sql, binds = [])
        return connection.query(sql).to_a if binds.empty?

        connection.prepare(sql).execute(*binds).to_a
      end

      def execute(sql, binds = [])
        if binds.empty?
          connection.query(sql)
        else
          connection.prepare(sql).execute(*binds)
        end
        nil
      end

      def insert(sql, binds, _table)
        execute(sql, binds)
        connection.last_id
      end

      def connection
        connect! unless @connection
        @connection
      end
    end
  end
end
