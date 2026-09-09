# frozen_string_literal: true

require_relative "../helper"

module Constable
  # Parallel workers sharing one database is the bug this module exists to prevent, and
  # it is not a subtle one: on SQLite a suite that passes 188/0 serially collapses into
  # 130 "database is locked" failures the moment workers are switched on.
  #
  # ActiveRecord is not a dependency of this gem, so these tests define the smallest
  # shape that behaves like it and assert on what Constable *does* with it.
  class WorkerDatabasesTest < TestCase
    def teardown
      teardown_fake_active_record
      super
    end

    # Builds just enough ::ActiveRecord for WorkerDatabases to have an opinion.
    # The smallest thing that behaves like ActiveRecord for this module's purposes.
    # `populated:` decides whether the per-worker databases already hold tables, which is
    # the question :reuse mode turns on.
    def stub_active_record(with_test_databases: true, populated: false, databases: %w[primary])
      calls = { cleared: 0, schema: [], reconstructed: [], renamed: [] }

      Object.const_set(:ActiveRecord, Module.new) unless defined?(::ActiveRecord)
      handler = Object.new
      handler.define_singleton_method(:clear_all_connections!) { calls[:cleared] += 1 }

      configs = databases.map { |name| FakeDbConfig.new(name, calls) }
      connection = Object.new
      connection.define_singleton_method(:tables) { populated ? %w[users] : [] }

      base = Class.new
      base.define_singleton_method(:connection_handler) { handler }
      base.define_singleton_method(:connection) { connection }
      base.define_singleton_method(:establish_connection) { |*| true }
      base.define_singleton_method(:configurations) do
        Object.new.tap do |c|
          c.define_singleton_method(:configs_for) { |**| configs }
        end
      end
      ::ActiveRecord.const_set(:Base, base)

      tasks = Module.new
      tasks.define_singleton_method(:reconstruct_from_schema) do |db_config, _|
        calls[:reconstructed] << db_config.database
      end
      ::ActiveRecord.const_set(:Tasks, Module.new) unless ::ActiveRecord.const_defined?(:Tasks, false)
      ::ActiveRecord::Tasks.const_set(:DatabaseTasks, tasks)

      if with_test_databases
        test_databases = Module.new
        test_databases.define_singleton_method(:create_and_load_schema) do |index, env_name:|
          calls[:schema] << [index, env_name]
        end
        ::ActiveRecord.const_set(:TestDatabases, test_databases)
      end

      calls
    end

    # Stands in for an ActiveRecord::DatabaseConfigurations::HashConfig. Records the
    # rename, which is the part :reuse mode has to get right for a multi-database app.
    class FakeDbConfig
      attr_reader :database

      def initialize(database, calls)
        @database = database
        @calls = calls
      end

      def _database=(name)
        @database = name
        @calls[:renamed] << name
      end

      def database_tasks? = true
    end

    def teardown_fake_active_record
      return unless defined?(::ActiveRecord)

      ::ActiveRecord.send(:remove_const, :Base) if ::ActiveRecord.const_defined?(:Base, false)
      ::ActiveRecord.send(:remove_const, :TestDatabases) if ::ActiveRecord.const_defined?(:TestDatabases, false)
      ::ActiveRecord.send(:remove_const, :Tasks) if ::ActiveRecord.const_defined?(:Tasks, false)
      Object.send(:remove_const, :ActiveRecord) if ::ActiveRecord.constants.empty?
    end

    # --- detection ------------------------------------------------------------------

    # The :unit tier exists so Constable runs in a process with no Rails at all. Nothing
    # here may raise in that process.
    def test_an_app_without_active_record_reports_no_databases_to_shard
      refute_predicate WorkerDatabases, :active_record?
      refute_predicate WorkerDatabases, :shardable?
    end

    def test_before_fork_is_a_no_op_without_active_record
      refute WorkerDatabases.before_fork!
    end

    def test_after_fork_is_a_no_op_without_active_record
      refute WorkerDatabases.after_fork!(0)
    end

    def test_active_record_is_detected_when_present
      stub_active_record

      assert_predicate WorkerDatabases, :active_record?
      assert_predicate WorkerDatabases, :shardable?
    end

    # ActiveRecord present but the parallel machinery missing: we know the databases are
    # shared and we know we cannot fix it, which is precisely when the runner must not fork.
    def test_active_record_without_the_parallel_machinery_is_not_shardable
      stub_active_record(with_test_databases: false)
      # A real activerecord is in this repo's bundle, so `require` would happily define
      # the machinery the scenario is meant to be missing. Stub the loader out instead.
      without_test_databases_loader do
        assert_predicate WorkerDatabases, :active_record?
        refute_predicate WorkerDatabases, :shardable?
      end
    end

    def without_test_databases_loader
      original = WorkerDatabases.method(:load_test_databases!)
      WorkerDatabases.define_singleton_method(:load_test_databases!) { nil }
      yield
    ensure
      WorkerDatabases.define_singleton_method(:load_test_databases!, original)
    end

    # --- the fork lifecycle ----------------------------------------------------------

    def test_before_fork_clears_inherited_connections
      calls = stub_active_record

      assert WorkerDatabases.before_fork!
      assert_equal 1, calls[:cleared]
    end

    def test_after_fork_builds_a_database_for_that_worker
      calls = stub_active_record

      assert WorkerDatabases.after_fork!(3)
      assert_equal 1, calls[:schema].size
      assert_equal 3, calls[:schema].first.first
    end

    def test_each_worker_asks_for_its_own_index
      calls = stub_active_record

      3.times { |i| WorkerDatabases.after_fork!(i) }

      assert_equal [0, 1, 2], calls[:schema].map(&:first)
    end

    def test_after_fork_passes_the_environment_through
      calls = stub_active_record

      WorkerDatabases.after_fork!(0)

      assert_equal "test", calls[:schema].first.last
    end

    # A worker that cannot build its own database must fail loudly. Carrying on would
    # mean silently sharing the parent's, which is the exact bug being fixed.
    def test_a_worker_that_cannot_build_its_database_raises
      stub_active_record
      ::ActiveRecord::TestDatabases.define_singleton_method(:create_and_load_schema) do |_i, env_name:|
        raise "no such schema for #{env_name}"
      end

      error = assert_raises(Constable::Error) { WorkerDatabases.after_fork!(1) }
      assert_match(/worker 1 could not create its own test database/, error.message)
    end

    # Clearing connections is best-effort: a handler that objects should not take the
    # whole run down before it has started.
    def test_before_fork_survives_a_handler_that_raises
      stub_active_record
      handler = ::ActiveRecord::Base.connection_handler
      handler.define_singleton_method(:clear_all_connections!) { raise "already closed" }

      refute WorkerDatabases.before_fork!
    end

    # --- when the app cannot be sharded at all ----------------------------------------
    #
    # Not every app can. One whose schema.rb cannot rebuild the database on its own --
    # Postgres custom types, functions and triggers are the usual reason, and are exactly
    # why such apps keep a structure.sql -- fails here every time. Rails' own
    # `parallelize` fails the same way. The difference has to be that Constable says so
    # in a sentence and runs the suite anyway, rather than printing one stack trace per
    # worker and reporting a run that never happened.

    def run_suite(workers:)
      write_config("storage:\n  adapter: sqlite\n  path: .constable/constable.sqlite3\n")
      write_file("test/cases/models/probe_case.rb", <<~CASE)
        class ProbeCase < Constable::Case
          investigate("first") { assert(true) }
          investigate("second") { assert(true) }
        end
      CASE

      selection = Selection.new([], config: Constable.config, root: tmp_root, full: true)
      runner = Runner.new(selection: selection, config: Constable.config,
                          reporter: Reporter.new(io: StringIO.new, config: Constable.config,
                                                 color: false),
                          storage: Constable.storage, workers: workers)
      [runner.call, runner]
    ensure
      Object.send(:remove_const, :ProbeCase) if Object.const_defined?(:ProbeCase)
    end

    def with_unshardable_app
      stub_active_record
      ::ActiveRecord::TestDatabases.define_singleton_method(:create_and_load_schema) do |_i, env_name:|
        raise ActiveRecordStub, "PG::UndefinedObject: type \"assign_record\" does not exist (#{env_name})"
      end
      yield
    end

    class ActiveRecordStub < StandardError
    end

    def test_the_suite_still_runs_when_no_worker_can_build_a_database
      skip "fork is unavailable" unless Process.respond_to?(:fork)

      status, runner = with_unshardable_app { run_suite(workers: 2) }

      assert_equal 0, status, "the suite should have run and passed, serially"
      assert_equal 2, runner.results.size, "every test should still have run"
      assert(runner.results.all?(&:passed?))
    end

    def test_it_says_why_it_fell_back
      skip "fork is unavailable" unless Process.respond_to?(:fork)

      with_unshardable_app { run_suite(workers: 2) }

      warning = Constable.warnings.find { |w| w[:kind] == :parallel }
      refute_nil warning, "a silent fallback is the failure mode this exists to prevent"
      assert_match(/ran serially/, warning[:message])
      assert_match(/worker_databases: reuse/, warning[:message], "it should offer the way that works")
      assert_match(/worker_databases: off/, warning[:message], "and the way to stop trying")
      assert_match(/assign_record/, warning[:message], "and pass the real error through")
    end

    # --- worker_databases modes --------------------------------------------------------

    def test_reuse_builds_a_database_that_is_not_there_yet
      calls = stub_active_record(populated: false)

      WorkerDatabases.after_fork!(0, mode: :reuse)

      assert_equal 1, calls[:reconstructed].size, "a missing database still has to be built"
    end

    # The point of the mode: a prepared database is not rebuilt, so a large schema is not
    # reloaded on every run -- and an app whose schema cannot load standalone still works.
    def test_reuse_leaves_a_prepared_database_alone
      calls = stub_active_record(populated: true)

      WorkerDatabases.after_fork!(0, mode: :reuse)

      assert_empty calls[:reconstructed]
    end

    # A database that exists but is empty is not prepared. Running a suite against no
    # tables is the worst of the available outcomes.
    def test_reuse_rebuilds_an_empty_database
      calls = stub_active_record(populated: false)

      WorkerDatabases.after_fork!(0, mode: :reuse)

      refute_empty calls[:reconstructed]
    end

    def test_reuse_renames_every_database_to_its_worker_sibling
      calls = stub_active_record(populated: true, databases: %w[primary etl])

      WorkerDatabases.after_fork!(3, mode: :reuse)

      assert_equal %w[primary_3 etl_3], calls[:renamed]
    end

    def test_schema_mode_is_still_the_default
      calls = stub_active_record

      WorkerDatabases.after_fork!(1)

      assert_equal [[1, "test"]], calls[:schema]
      assert_empty calls[:reconstructed]
    end

    # --- constable prepare -------------------------------------------------------------

    def test_prepare_builds_the_databases
      calls = stub_active_record(populated: false)

      WorkerDatabases.prepare!(0)

      refute_empty calls[:reconstructed]
    end

    # prepare! renames in the parent, not in a fork that is about to die. Leaving the
    # names renamed would point the console -- and anything else in the process -- at
    # `<database>_0` instead of the real test database.
    def test_prepare_puts_the_database_names_back
      stub_active_record(populated: true, databases: %w[primary etl])

      WorkerDatabases.prepare!(2)

      assert_equal %w[primary etl], WorkerDatabases.database_names
    end

    def test_prepare_puts_the_names_back_even_when_it_fails
      stub_active_record(populated: false, databases: %w[primary])
      ::ActiveRecord::Tasks::DatabaseTasks.define_singleton_method(:reconstruct_from_schema) do |*|
        raise "no such schema"
      end

      assert_raises(Constable::Error) { WorkerDatabases.prepare!(0) }
      assert_equal %w[primary], WorkerDatabases.database_names
    end

    def test_prepare_refuses_an_app_with_no_databases
      error = assert_raises(Constable::Error) { WorkerDatabases.prepare!(0) }

      assert_match(/no ActiveRecord databases to prepare/, error.message)
    end

    # --- cloning -----------------------------------------------------------------------
    #
    # Postgres copies a whole database in one statement, which needs no schema.rb at all.
    # That is the only thing that works for an app whose schema cannot rebuild the
    # database by itself -- and it is what unblocks parallelism for one, since without it
    # such an app runs serially forever.

    def stub_postgres(source_exists: true)
      calls = { executed: [] }
      configs = [PostgresDbConfig.new("caseflow_test", calls)]
      connection = Object.new
      connection.define_singleton_method(:execute) { |sql| calls[:executed] << sql.to_s }
      connection.define_singleton_method(:quote) { |v| "'#{v}'" }
      connection.define_singleton_method(:select_value) { |_| source_exists ? 1 : nil }
      connection.define_singleton_method(:tables) { [] }

      Object.const_set(:ActiveRecord, Module.new) unless defined?(::ActiveRecord)
      base = Class.new
      base.define_singleton_method(:connection) { connection }
      base.define_singleton_method(:connection_db_config) { configs.first }
      base.define_singleton_method(:establish_connection) { |*| true }
      base.define_singleton_method(:configurations) do
        Object.new.tap { |c| c.define_singleton_method(:configs_for) { |**| configs } }
      end
      handler = Object.new
      handler.define_singleton_method(:clear_all_connections!) { nil }
      base.define_singleton_method(:connection_handler) { handler }
      ::ActiveRecord.const_set(:Base, base)

      tasks = Module.new
      tasks.define_singleton_method(:reconstruct_from_schema) { |c, _| calls[:executed] << "schema:#{c.database}" }
      ::ActiveRecord.const_set(:Tasks, Module.new) unless ::ActiveRecord.const_defined?(:Tasks, false)
      ::ActiveRecord::Tasks.const_set(:DatabaseTasks, tasks)
      ::ActiveRecord.const_set(:TestDatabases, Module.new)

      calls
    end

    class PostgresDbConfig
      attr_reader :database

      def initialize(database, calls)
        @database = database
        @calls = calls
      end

      def _database=(name)
        @database = name
      end

      def database_tasks? = true
      def adapter = "postgresql"
      def configuration_hash = { adapter: "postgresql", database: @database }
    end

    def test_a_worker_database_is_cloned_rather_than_rebuilt_from_schema
      calls = stub_postgres

      WorkerDatabases.after_fork!(3, mode: :reuse)

      assert(calls[:executed].any? do |sql|
        sql.include?(%(CREATE DATABASE "caseflow_test_3" TEMPLATE "caseflow_test"))
      end,
             "expected a template clone, got #{calls[:executed].inspect}")
      refute(calls[:executed].any? { |sql| sql.start_with?("schema:") }, "schema.rb should not be needed")
    end

    def test_the_template_is_disconnected_before_it_is_copied
      calls = stub_postgres

      WorkerDatabases.after_fork!(1, mode: :reuse)

      assert(calls[:executed].any? { |sql| sql.include?("pg_terminate_backend") },
             "Postgres will not copy a database anything is connected to")
    end

    def test_a_stale_worker_database_is_dropped_first
      calls = stub_postgres

      WorkerDatabases.after_fork!(2, mode: :reuse)

      assert(calls[:executed].any? { |sql| sql.include?(%(DROP DATABASE IF EXISTS "caseflow_test_2")) })
    end

    # No source to copy: fall back to the schema rather than inventing an empty database.
    def test_it_falls_back_to_the_schema_when_there_is_nothing_to_clone
      calls = stub_postgres(source_exists: false)

      WorkerDatabases.after_fork!(0, mode: :reuse)

      assert(calls[:executed].any? { |sql| sql.start_with?("schema:") })
    end
  end
end
