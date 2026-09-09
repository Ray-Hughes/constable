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
    #
    # `clear_all_connections!` and not `disconnect!`. Closing the pools outright was tried
    # here, on the theory that returning a connection to the pool leaves the socket and the
    # driver's C-side state for `fork` to copy into every child. It changed nothing
    # measurable, and the crash it was meant to prevent turned out to predate it -- see
    # the note on native drivers in the README. Rails does the same thing before its own
    # fork, and matching it is the conservative choice.
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
      return connect_worker!(index) if mode.to_sym == :reuse

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

    # The one mistake `:reuse` invites, caught before the fork rather than after.
    #
    # `:reuse` keeps the per-worker databases between runs, which is the whole point --
    # and it means they do not follow migrations by themselves. Run a migration, run the
    # suite, and every worker is now testing yesterday's schema. That does not fail
    # cleanly: it fails as a missing column in whichever file happened to touch it, three
    # files away from anything you changed, differently on each run because the file went
    # to a different worker. Exactly the shape of bug that costs an afternoon.
    #
    # So compare what each worker database has migrated against what the real test
    # database has, and refuse rather than guess. Two integers per database, in the parent,
    # before anything forks.
    #
    # Returns the worker indexes that are out of date, empty when they are all current or
    # when the question cannot be answered (no schema_migrations table, an adapter that
    # will not connect) -- an unanswerable check must not block a run that would have
    # worked.
    def stale_workers(count)
      return [] unless shardable?

      expected = {}
      original = database_names
      begin
        each_source_config do |db_config|
          fingerprint = schema_fingerprint(db_config)
          expected[db_config.database.to_s] = fingerprint if fingerprint
        end
        return [] if expected.empty?

        stale = []
        (0...count).each do |index|
          names = database_names
          begin
            each_worker_config(index) do |db_config|
              source = db_config.database.to_s.sub(/_#{index}\z/, "")
              next unless expected.key?(source)

              actual = schema_fingerprint(db_config)
              stale << index if actual && actual != expected[source]
            end
          ensure
            restore_database_names(names)
          end
        end
        stale.uniq
      ensure
        # Names only. Nothing here ever repointed ActiveRecord::Base, so there is no
        # connection to put back -- which is the point.
        restore_database_names(original)
      end
    rescue StandardError
      []
    end

    # What a database has migrated: how many migrations it has run and the latest one.
    # Cheaper than diffing every version, and a worker that missed a migration differs in
    # both. nil when the question does not apply.
    def schema_fingerprint(db_config)
      with_probe_connection(db_config) do |connection|
        next nil unless connection.table_exists?("schema_migrations")

        connection.select_rows("SELECT COUNT(*), MAX(version) FROM schema_migrations").first
      end
    rescue StandardError
      nil
    end

    # Databases this environment declares that cannot be given to each worker, so every
    # worker shares the one copy.
    #
    # Constable skips them on purpose -- appending `_3` to an Oracle TNS service name names
    # nothing -- but "skipped" and "safe" are different claims, and only the first was ever
    # made. A legacy database that tests write to is shared mutable state across processes,
    # and the failures it produces do not look like a parallelism problem: they look like
    # records vanishing mid-test, in whichever spec happened to be running when another
    # worker's suite hook cleaned the database they were both using.
    #
    # Measured on a real suite: 53 `VacolsRecordNotFound` failures across a four-worker
    # run, every one of them passing serially, all from one shared Oracle database that
    # each worker deleted from at startup.
    def unshardable_databases
      return [] unless active_record?

      ::ActiveRecord::Base.configurations
                          .configs_for(env_name: env_name, include_hidden: true)
                          .filter_map { |db_config| share_reason(db_config) }
    rescue StandardError
      []
    end

    # Why a database stays shared, in the words of the setting that caused it. Both reasons
    # matter and only one of them is about the adapter: `database_tasks: false` is how an
    # app says "Rails does not manage this one", which is the usual way a legacy database is
    # declared -- and it is exactly the database most likely to be shared, written to by
    # tests, and cleaned by a suite hook in every worker at once.
    #
    # The config's *name* rather than its database, because a TNS descriptor is four lines
    # of connection string and "vacols" is what anyone reading the warning calls it.
    def share_reason(db_config)
      name = db_config.respond_to?(:name) ? db_config.name : db_config.database
      return "#{name} (database_tasks: false)" unless db_config.database_tasks?
      return nil if shardable_adapter?(db_config)

      "#{name} (#{db_config.adapter})"
    end

    # The same configs `each_worker_config` renames, left under their real names.
    def each_source_config
      ::ActiveRecord::Base.configurations
                          .configs_for(env_name: env_name, include_hidden: true)
                          .each do |db_config|
        next unless db_config.database_tasks?
        next unless shardable_adapter?(db_config)

        yield db_config
      end
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

    # Postgres can copy a whole database in one statement:
    #
    #   CREATE DATABASE "caseflow_test_3" TEMPLATE "caseflow_test"
    #
    # That matters because it needs no schema.rb at all. An app whose schema cannot
    # rebuild the database by itself -- custom types, functions, triggers -- can still get
    # per-worker databases this way, cloned from the test database it already has. It is
    # also far faster than replaying a large schema once per worker.
    #
    # Returns true when it cloned, false when this is not Postgres or the source is not
    # there, so the caller can fall back to loading the schema.
    def clone_database(db_config, index)
      return false unless postgres?(db_config)

      source = db_config.database.to_s.sub(/_#{index}\z/, "")
      target = db_config.database.to_s
      return false if source.empty? || source == target

      maintenance_connection(db_config) do |connection|
        return false unless database_exists?(connection, source)

        # A template cannot be copied while anything is connected to it.
        disconnect_everyone_from!(connection, source)
        connection.execute(%(DROP DATABASE IF EXISTS "#{target}"))
        connection.execute(%(CREATE DATABASE "#{target}" TEMPLATE "#{source}"))
      end

      true
    rescue StandardError
      # Cloning is the fast path, never the only one. Anything unexpected -- a permission,
      # a Postgres version, a connection that will not drop -- falls back to the schema.
      false
    end

    def postgres?(db_config)
      db_config.respond_to?(:adapter) && db_config.adapter.to_s.include?("postgre")
    end

    # Postgres will not let you create a database while connected to the one you are
    # copying, so the statements run against the cluster's own maintenance database.
    def maintenance_connection(db_config)
      previous = ::ActiveRecord::Base.connection_db_config
      ::ActiveRecord::Base.establish_connection(db_config.configuration_hash.merge(database: "postgres"))
      yield ::ActiveRecord::Base.connection
    ensure
      ::ActiveRecord::Base.establish_connection(previous)
    end

    def database_exists?(connection, name)
      # Plain Ruby, not #present?: this runs inside a forked worker in somebody else's app,
      # and quietly depending on ActiveSupport being loaded is how a fast path silently
      # turns itself off.
      value = connection.select_value("SELECT 1 FROM pg_database WHERE datname = #{connection.quote(name)}")
      !value.nil?
    rescue StandardError
      false
    end

    def disconnect_everyone_from!(connection, name)
      connection.execute(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
        "WHERE datname = #{connection.quote(name)} AND pid <> pg_backend_pid()"
      )
    rescue StandardError
      nil
    end

    # The :reuse half, inside a worker: connect to `<database>_<index>` and nothing else.
    #
    # Building is deliberately not done here. Twelve workers forked at once would each try
    # to build the same missing databases simultaneously, and on Postgres the clone has to
    # disconnect everything attached to the template first -- which is the shared test
    # database every other worker is also cloning from. They terminate each other's
    # connections and die, silently, mid-run. Observed exactly that: nineteen files
    # scheduled, zero results, workers gone without a word.
    #
    # So preparation happens once, in the parent, through `constable prepare`. A worker
    # that finds nothing to connect to says so, and the runner falls back to serial.
    def connect_worker!(index)
      missing = []

      each_worker_config(index) do |db_config|
        missing << db_config.database unless populated?(db_config)
      end

      unless missing.empty?
        raise Constable::Error,
              "worker #{index} has no database to use (#{missing.join(", ")}). " \
              "`worker_databases: reuse` expects them to exist already -- run " \
              "`constable prepare` once, then run the suite."
      end

      ::ActiveRecord::Base.establish_connection
      []
    end

    # The building half, run from the parent by `constable prepare`. Points every database
    # this environment declares at its `_<index>` sibling, and builds the ones that are
    # not there yet.
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

        # Clone first: it needs no schema.rb, which is the only thing that works for an
        # app whose schema cannot rebuild the database, and it is faster besides.
        next built << "#{db_config.database} (cloned)" if clone_database(db_config, index)

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
    # Adapters where "give each worker its own copy" is a thing that can be done at all.
    #
    # An app can hold connections Constable has no business renaming. Caseflow talks to a
    # legacy Oracle system (VACOLS) alongside its own Postgres databases; appending `_3` to
    # an Oracle TNS service name produces `ORA-12162: TNS:net service name is incorrectly
    # specified`, and since that surfaces inside a `before(:suite)` hook, RSpec swallowed
    # it and the worker ran nothing at all.
    #
    # An external system like that is shared by every worker on purpose: it is not
    # per-worker test data, and there is no per-worker copy of it to make.
    SHARDABLE_ADAPTERS = %w[postgresql postgis mysql2 trilogy sqlite3].freeze

    def shardable_adapter?(db_config)
      return false unless db_config.respond_to?(:adapter)

      SHARDABLE_ADAPTERS.include?(db_config.adapter.to_s)
    end

    def each_worker_config(index)
      configs = ::ActiveRecord::Base.configurations.configs_for(env_name: env_name,
                                                                include_hidden: true)
      configs.each do |db_config|
        next unless db_config.database_tasks?
        next unless shardable_adapter?(db_config)

        db_config._database = "#{db_config.database}_#{index}"
        yield db_config
      end
    end

    # Present and holding tables. A database that exists but is empty is not prepared, and
    # silently running a suite against no tables is the worst of the available outcomes.
    def populated?(db_config)
      with_probe_connection(db_config) { |connection| connection.tables.any? }
    rescue StandardError
      false
    end

    # A connection class of its own, so looking at a database never disturbs the app's.
    #
    # Asking "is this worker database prepared, and has it run our migrations?" needs a
    # connection, and the obvious way to get one is to point ActiveRecord::Base at it and
    # then point it back. That works, right up until the app has a native driver attached.
    #
    # Measured on a real app with a legacy Oracle database: repointing Base in the parent
    # before forking killed the whole run with SIGABRT, no output on either stream, the
    # crash report landing inside libclntsh -- Oracle's client catching a SIGSEGV in its
    # own handler and calling abort. Nothing about it says "your test runner opened a
    # connection it did not need".
    #
    # A named subclass gets its own `connection_specification_name`, so its pool is its
    # own: establishing and removing it leaves ActiveRecord::Base, and every other class
    # with a connection, untouched. Anonymous would not do -- a class with no name falls
    # back to its superclass's specification name, which is Base again.
    def probe_class
      base = ::ActiveRecord::Base
      return @probe_class if defined?(@probe_class) && @probe_base.equal?(base)

      klass = Class.new(base)
      klass.abstract_class = true if klass.respond_to?(:abstract_class=)
      # Naming it is not decoration: an unnamed class falls back to its superclass's
      # connection specification name, which would put us right back on Base's pool.
      remove_const(:ProbeConnection) if const_defined?(:ProbeConnection, false)
      const_set(:ProbeConnection, klass)
      @probe_base = base
      @probe_class = klass
    end

    def with_probe_connection(db_config)
      probe_class.establish_connection(db_config)
      yield probe_class.connection
    ensure
      begin
        probe_class.remove_connection
      rescue StandardError
        nil
      end
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
