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
    def stub_active_record(with_test_databases: true)
      calls = { cleared: 0, schema: [] }

      Object.const_set(:ActiveRecord, Module.new) unless defined?(::ActiveRecord)
      handler = Object.new
      handler.define_singleton_method(:clear_all_connections!) { calls[:cleared] += 1 }

      base = Class.new
      base.define_singleton_method(:connection_handler) { handler }
      ::ActiveRecord.const_set(:Base, base)

      if with_test_databases
        databases = Module.new
        databases.define_singleton_method(:create_and_load_schema) do |index, env_name:|
          calls[:schema] << [index, env_name]
        end
        ::ActiveRecord.const_set(:TestDatabases, databases)
      end

      calls
    end

    def teardown_fake_active_record
      return unless defined?(::ActiveRecord)

      ::ActiveRecord.send(:remove_const, :Base) if ::ActiveRecord.const_defined?(:Base, false)
      ::ActiveRecord.send(:remove_const, :TestDatabases) if ::ActiveRecord.const_defined?(:TestDatabases, false)
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
  end
end
