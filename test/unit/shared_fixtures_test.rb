# frozen_string_literal: true

require_relative "../helper"

module Constable
  # witness_all is the one place Constable builds a fixture once for many tests, and the
  # whole question is whether the isolation holds. These are about that, not about speed.
  class SharedFixturesTest < TestCase
    def setup
      super
      skip "test-prof not available" unless SharedFixtures.available?
    end

    def test_the_block_runs_once_for_the_whole_case
      calls = []
      klass = build_case do
        witness_all(:thing) { calls << :built }
        investigate("a") { thing }
        investigate("b") { thing }
        investigate("c") { thing }
      end

      run_case(klass)

      assert_equal 1, calls.size, "witness_all built its fixture #{calls.size} times"
    end

    # A plain witness is per test. That distinction is the reason both exist.
    def test_a_plain_witness_still_runs_once_per_test
      calls = []
      klass = build_case do
        witness(:thing) { calls << :built }
        investigate("a") { thing }
        investigate("b") { thing }
      end

      run_case(klass)

      assert_equal 2, calls.size
    end

    def test_every_investigation_sees_the_same_value
      seen = []
      klass = build_case do
        witness_all(:token) { Object.new }
        investigate("a") { seen << token.object_id }
        investigate("b") { seen << token.object_id }
      end

      run_case(klass)

      assert_equal 1, seen.uniq.size
    end

    def test_a_case_without_shared_fixtures_opens_no_scope
      klass = build_case { investigate("a") { attest(1).to eq(1) } }

      refute_predicate klass, :shared_fixtures?
    end

    def test_shared_fixtures_are_inherited
      parent = build_case("ParentSharedCase") { witness_all(:thing) { :from_parent } }
      child = Class.new(parent)

      assert_predicate child, :shared_fixtures?
      assert_includes child.shared_fixtures.keys, :thing
    end

    # The saving is the INSERT; the SELECT that makes it safe is the price. A caller who
    # has measured that their fixture is never mutated can decline it.
    def test_reload_can_be_declined
      klass = build_case do
        witness_all(:thing, reload: false) { Object.new }
        investigate("a") { thing }
      end

      refute klass.shared_fixtures[:thing][:reload]
    end

    def test_reload_is_on_by_default
      klass = build_case do
        witness_all(:thing) { Object.new }
        investigate("a") { thing }
      end

      assert klass.shared_fixtures[:thing][:reload]
    end

    # Anything that is not a persisted record has nothing to re-read, and must come back
    # untouched rather than raising.
    def test_rereading_a_plain_object_returns_it
      klass = build_case { witness_all(:thing) { Object.new } }
      value = Object.new

      assert_same value, klass.constable_reread(value)
    end

    def test_witness_all_requires_a_block
      assert_raises(ArgumentError) { build_case { witness_all(:thing) } }
    end

    private

    def build_case(name = "SharedSubjectCase", &block)
      klass = Class.new(Constable::Case)
      Object.const_set(name, klass) unless Object.const_defined?(name)
      klass.class_eval(&block) if block
      klass
    end

    def run_case(klass)
      klass.constable_open_shared_scope!
      klass.investigations.each do |investigation|
        instance = Case.constable_instance_for(investigation)
        instance.instance_eval(&investigation.block)
      end
    ensure
      klass.constable_close_shared_scope!
    end
  end
end
