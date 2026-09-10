# frozen_string_literal: true

module Constable
  # Splitting one suite across several CI machines.
  #
  # Constable already balances work across forked workers on one machine. A CI matrix is
  # the other axis: N jobs, each on its own machine, each running a slice. That is what
  # Knapsack and friends exist for, and it needs three things from a splitter, only the
  # first of which is about speed:
  #
  #   1. **Even slices.** Splitting by file count puts the four slowest files on one
  #      machine and the build waits for it. Constable already records an average duration
  #      per test to balance its own workers, so it can split by measured time instead --
  #      no separate report file to generate, upload and keep current, which is the part of
  #      the Knapsack workflow that rots.
  #
  #   2. **Every test in exactly one slice.** A splitter that drops a file produces a green
  #      build that ran less than it claimed, and nothing downstream can tell. That is the
  #      failure this project exists to prevent, so the partition is a partition: the union
  #      of every shard is the input, and no item appears twice. Tested directly.
  #
  #   3. **The same answer on every machine.** Each job computes its own slice
  #      independently, with no coordination, so shard 3 of 8 must decide identically to
  #      shard 5 of 8 or the two will disagree about who runs what. Everything here is a
  #      pure function of (items, count) -- sorted deterministically, never shuffled, and
  #      the durations come from a blotter each machine reads rather than writes.
  class Shard
    class Invalid < Constable::Error
    end

    attr_reader :index, :total

    # "3/8" -- the third of eight, one-based, because CI matrices are one-based and an
    # off-by-one here silently runs the wrong slice rather than failing.
    def self.parse(spec)
      return nil if spec.nil? || spec.to_s.strip.empty?

      match = spec.to_s.strip.match(%r{\A(\d+)\s*/\s*(\d+)\z})
      raise Invalid, "--shard takes N/M, for example --shard 3/8 (got #{spec.inspect})" unless match

      index = match[1].to_i
      total = match[2].to_i
      raise Invalid, "--shard count must be at least 1 (got #{spec.inspect})" if total < 1
      raise Invalid, "--shard #{index} is outside 1..#{total}" if index < 1 || index > total

      new(index: index, total: total)
    end

    def initialize(index:, total:)
      @index = index
      @total = total
    end

    def whole? = total == 1

    def to_s = "#{index}/#{total}"

    # Longest-processing-time-first, the same heuristic the worker balancer uses: hand out
    # the most expensive item to whichever slice is currently smallest. It is not optimal
    # -- optimal partitioning is NP-hard -- but it is within a few percent in practice and
    # it is O(n log n) rather than clever.
    #
    # Ties are broken by label so two machines with identical duration data cannot order
    # them differently.
    def slice(items, weights: {})
      return items if whole?

      buckets = Array.new(total) { [] }
      loads = Array.new(total, 0.0)

      ordered = items.sort_by { |item| [-weights.fetch(item, 0.0), item.label.to_s] }
      ordered.each do |item|
        slot = loads.index(loads.min)
        buckets[slot] << item
        loads[slot] += weights.fetch(item, DEFAULT_WEIGHT)
      end

      buckets[index - 1]
    end

    # What an item with no recorded history is assumed to cost. Small and non-zero: zero
    # would let an unbounded number of unmeasured files pile onto one slice.
    DEFAULT_WEIGHT = 0.05
  end
end
