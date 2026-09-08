# frozen_string_literal: true

module Constable
  # Per-worker databases for parallel runs.
  #
  # Forking N workers that all talk to one database is not a speed/safety trade, it is a
  # correctness bug. On SQLite it shows up immediately and honestly -- every worker
  # contends for the same file and the run dissolves into
  # `SQLite3::BusyException: database is locked` -- and on a client/server database it
  # shows up later and far worse, as tests seeing each other's rows.
  #
  # Rails already solved this for `rails test`: each worker gets its own database, named
  # by appending the worker index, rebuilt from schema. This is the same thing, driven by
  # Constable's runner rather than by ActiveSupport::Testing::Parallelization, because
  # Constable does its own forking.
  #
  # Everything here is defensive. Constable runs in apps with no ActiveRecord at all --
  # that is the whole point of the :unit tier -- so every entry point answers "no" rather
  # than raising when the pieces are missing, and the runner falls back to a serial run.
  module WorkerDatabases
    module_function

    # Is there an ActiveRecord in this process whose databases would be shared by forks?
    def active_record?
      defined?(::ActiveRecord::Base) ? true : false
    end

    # Can we actually give each worker its own database? Rails ships the machinery in
    # active_record/test_databases, which is only loaded when someone asks for parallel
    # tests -- so ask for it here rather than assuming.
    def shardable?
      return false unless active_record?

      load_test_databases!
      defined?(::ActiveRecord::TestDatabases) ? true : false
    end

    # Parent side, before the fork. A child inheriting a live connection is a corruption
    # risk in exactly the way an inherited SQLite handle is.
    def before_fork!
      return false unless active_record?

      ::ActiveRecord::Base.connection_handler.clear_all_connections!
      true
    rescue StandardError
      false
    end

    # Child side, immediately after the fork and before any test runs. Builds
    # `<database>_<index>` from schema and points this process at it.
    #
    # ENV["VERBOSE"] is silenced the way Rails silences it: schema loading is chatty, and
    # stdout belongs to the reporter.
    def after_fork!(index)
      return false unless shardable?

      ::ActiveRecord::TestDatabases.create_and_load_schema(index, env_name: env_name)
      true
    rescue StandardError => e
      # A worker that cannot build its own database would otherwise silently fall back to
      # sharing the parent's, which is the bug this module exists to prevent. Say so, and
      # let the failure be a real one.
      raise Constable::Error, "worker #{index} could not create its own test database: " \
                              "#{e.class}: #{e.message}"
    end

    def env_name
      if defined?(::ActiveRecord::ConnectionHandling::DEFAULT_ENV)
        ::ActiveRecord::ConnectionHandling::DEFAULT_ENV.call
      else
        ENV["RAILS_ENV"] || "test"
      end
    end

    def load_test_databases!
      return if defined?(::ActiveRecord::TestDatabases)

      require "active_record/test_databases"
    rescue LoadError, StandardError
      nil
    end
  end
end
