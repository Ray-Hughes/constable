# frozen_string_literal: true

require_relative "../helper"

module Constable
  # Splitting one suite across CI machines.
  #
  # The speed property is the obvious one and the least important. The two that matter are
  # that every test lands in exactly one slice, and that each machine reaches the same
  # answer without talking to any other -- a splitter that drops a file produces a green
  # build that ran less than it claimed, and nothing downstream can tell.
  class ShardTest < TestCase
    Item = Struct.new(:label, keyword_init: true)

    def items(count)
      Array.new(count) { |i| Item.new(label: format("spec/file_%02d_spec.rb", i)) }
    end

    def weights_for(list, seconds)
      list.each_with_index.to_h { |item, i| [item, seconds[i] || 1.0] }
    end

    # --- parsing -----------------------------------------------------------------------

    def test_parses_one_based_shard_specs
      shard = Shard.parse("3/8")

      assert_equal 3, shard.index
      assert_equal 8, shard.total
    end

    def test_nil_and_blank_mean_no_sharding
      assert_nil Shard.parse(nil)
      assert_nil Shard.parse("")
    end

    # CI matrices are one-based. Accepting a zero silently runs the wrong slice.
    def test_rejects_an_out_of_range_or_malformed_shard
      assert_raises(Shard::Invalid) { Shard.parse("0/8") }
      assert_raises(Shard::Invalid) { Shard.parse("9/8") }
      assert_raises(Shard::Invalid) { Shard.parse("3 of 8") }
      assert_raises(Shard::Invalid) { Shard.parse("3/0") }
    end

    # --- the partition property --------------------------------------------------------

    def test_every_item_lands_in_exactly_one_shard
      list = items(37)
      weights = weights_for(list, Array.new(37) { |i| (i % 7) + 0.5 })

      slices = (1..5).map { |i| Shard.new(index: i, total: 5).slice(list, weights: weights) }

      assert_equal list.size, slices.sum(&:size), "a shard split must not lose or duplicate work"
      assert_equal list.map(&:label).sort, slices.flatten.map(&:label).sort
    end

    def test_more_shards_than_items_leaves_some_shards_empty_rather_than_dropping_work
      list = items(3)

      slices = (1..8).map { |i| Shard.new(index: i, total: 8).slice(list, weights: {}) }

      assert_equal 3, slices.sum(&:size)
      assert_equal 5, slices.count(&:empty?)
    end

    def test_a_single_shard_is_the_whole_suite
      list = items(10)

      assert_equal list, Shard.new(index: 1, total: 1).slice(list, weights: {})
    end

    # --- determinism -------------------------------------------------------------------
    #
    # Each CI job computes its own slice with no coordination, so the split has to be a
    # pure function of its inputs. If shard 3 and shard 5 disagree about who owns a file,
    # it either runs twice or not at all.

    def test_the_same_inputs_always_produce_the_same_slice
      list = items(20)
      weights = weights_for(list, Array.new(20) { |i| (i % 4) + 1.0 })

      first  = Shard.new(index: 2, total: 4).slice(list, weights: weights)
      second = Shard.new(index: 2, total: 4).slice(list.shuffle, weights: weights)

      assert_equal first.map(&:label), second.map(&:label),
                   "input order must not change which slice an item lands in"
    end

    def test_items_with_equal_weight_are_ordered_by_label_not_by_chance
      list = items(6)
      flat = list.to_h { |item| [item, 1.0] }

      a = Shard.new(index: 1, total: 3).slice(list, weights: flat)
      b = Shard.new(index: 1, total: 3).slice(list.reverse, weights: flat)

      assert_equal a.map(&:label), b.map(&:label)
    end

    # The property that made this feature dangerous before it was fixed.
    #
    # Each machine computes its own slice with no coordination, so every machine must
    # derive the same partition. Weighting by durations read from the blotter broke that:
    # each shard run wrote durations back, so the next shard read different weights and
    # repartitioned. Measured locally across three shards -- one file ran in two of them,
    # another ran in none, eighteen tests missing from the union and thirty-three
    # duplicated. A green build that ran less than it claimed.
    #
    # Weights are therefore opt-in, and the default partition depends on nothing but the
    # item set.
    def test_the_partition_survives_weights_changing_between_shards
      list = items(24)
      # Shard 1 sees one set of durations; by the time shard 2 runs, they have moved.
      early = weights_for(list, Array.new(24) { |i| (i % 5) + 1.0 })
      later = weights_for(list, Array.new(24) { |i| ((i * 3) % 7) + 0.5 })

      unweighted = (1..3).map { |i| Shard.new(index: i, total: 3).slice(list, weights: {}) }

      assert_equal list.map(&:label).sort, unweighted.flatten.map(&:label).sort,
                   "the default split must not depend on anything that can change"

      # And the documented hazard, demonstrated rather than described: with weights, two
      # machines reading different data disagree about who owns what.
      drifted = [Shard.new(index: 1, total: 3).slice(list, weights: early),
                 Shard.new(index: 2, total: 3).slice(list, weights: later),
                 Shard.new(index: 3, total: 3).slice(list, weights: later)]

      refute_equal list.map(&:label).sort, drifted.flatten.map(&:label).sort,
                   "if this ever passes, weighted sharding became safe and the docs should say so"
    end

    # --- balance -----------------------------------------------------------------------

    # Splitting by count puts the slow files wherever they happen to fall and the build
    # waits for the unluckiest machine. Splitting by measured time is the whole point.
    def test_slices_are_balanced_by_duration_not_by_count
      list = items(6)
      # One very slow file and five quick ones.
      weights = weights_for(list, [60.0, 1.0, 1.0, 1.0, 1.0, 1.0])

      slices = (1..2).map { |i| Shard.new(index: i, total: 2).slice(list, weights: weights) }
      totals = slices.map { |slice| slice.sum { |item| weights[item] } }

      # The slow one is alone; the five quick ones are together.
      assert_equal [1, 5], slices.map(&:size).sort
      assert_in_delta 60.0, totals.max, 0.01
    end

    def test_unmeasured_items_are_spread_rather_than_piled_onto_one_slice
      list = items(8)

      slices = (1..4).map { |i| Shard.new(index: i, total: 4).slice(list, weights: {}) }

      assert_equal [2, 2, 2, 2], slices.map(&:size)
    end
  end
end
