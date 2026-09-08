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

    # Child side, immediately after the fork and before any test runs. Gives this process
    # a database of its own, named `<database>_<index>`.
    #
    # `mode` is the `worker_databases` setting:
    #
    #   :schema  rebuild it from schema every run, which is what Rails does. Correct by
    #            construction -- no drift is possible -- and the right default.
    #   :reuse   connect to it when it is already there, build it from schema when it is
    #            not. Skips reloading a large schema on every run, and is the only thing
    #            that works when the schema cannot rebuild the database by itself.
    def after_fork!(index, mode: :schema)
      return false unless shardable?
      return reuse!(index) if mode.to_sym == :reuse

      ::ActiveRecord::TestDatabases.create_and_load_schema(index, env_name: env_name)
      true
    rescue StandardError => e
      # A worker that cannot build its own database must never fall back to sharing the
      # parent's -- that is the corruption this module exists to prevent. The runner turns
      # this into a serial run rather than letting it kill the process.
      raise Constable::Error, "worker #{index} could not create its own test database: " \
                              "#{e.class}: #{e.message}"
    end

    # `constable prepare`. Builds worker `index`'s databases from the parent process --
    # the same work :reuse would do lazily inside a fork, done once, deliberately, where
    # the output is visible and a failure is not four stack traces at once.
    def prepare!(index)
      raise Constable::Error, "this app has no ActiveRecord databases to prepare" unless shardable?

      # Renaming is destructive, and here it happens in the parent rather than in a fork
      # that is about to die. Without restoring the names afterwards this command would
      # leave the process -- and, worse, anything else in it -- pointed at
      # `<database>_<index>` instead of the real test database.
      original = database_names
      begin
        reuse!(index)
      ensure
        restore_database_names(original)
        ::ActiveRecord::Base.establish_connection
      end
    rescue Constable::Error
      raise
    rescue StandardError => e
      raise Constable::Error, "could not prepare worker #{index}: #{e.class}: #{e.message}"
    end

    def database_names
      ::ActiveRecord::Base.configurations
                          .configs_for(env_name: env_name, include_hidden: true)
                          .map(&:database)
    end

    def restore_database_names(names)
      ::ActiveRecord::Base.configurations
                          .configs_for(env_name: env_name, include_hidden: true)
                          .zip(names).each { |config, name| config._database = name if name }
    end

    # The :reuse half. Points every database this environment declares at its `_<index>`
    # sibling, and only builds the ones that are not there yet.
    #
    # "There" means present *and* populated: an empty database is not a prepared one, and
    # connecting to it would hand the worker a suite with no tables. Deciding that per
    # database rather than per worker matters for a multi-database app -- Caseflow has a
    # primary and an ETL database -- where one may be prepared and the other not.
    #
    # Keeping these current is the user's job once they opt in, which is the trade the
    # setting exists to let them make.
    def reuse!(index)
      built = []

      each_worker_config(index) do |db_config|
        next if populated?(db_config)

        ::ActiveRecord::Tasks::DatabaseTasks.reconstruct_from_schema(db_config, nil)
        built << db_config.database
      end

      built
    ensure
      # Rails does this after its own schema load: the pool has to be re-established
      # against the renamed configuration before any test asks for a connection.
      ::ActiveRecord::Base.establish_connection
    end

    # Every database config for this environment, renamed to its per-worker sibling.
    # `_database=` is exactly how Rails' own TestDatabases does the renaming, and this
    # runs in a forked child, so the mutation dies with the worker.
    def each_worker_config(index)
      configs = ::ActiveRecord::Base.configurations.configs_for(env_name: env_name,
                                                                include_hidden: true)
      configs.each do |db_config|
        db_config._database = "#{db_config.database}_#{index}"
        next unless db_config.database_tasks?

        yield db_config
      end
    end

    # Present and holding tables. A database that exists but is empty is not prepared, and
    # silently running a suite against no tables is the worst of the available outcomes.
    def populated?(db_config)
      ::ActiveRecord::Base.establish_connection(db_config)
      ::ActiveRecord::Base.connection.tables.any?
    rescue StandardError
      false
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
