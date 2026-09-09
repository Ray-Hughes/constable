# frozen_string_literal: true

module Constable
  # What to fix first, and why.
  #
  # Every finding here is tied to something measured: a recorded duration, a counted status
  # flip, a row on the docket. Nothing is inferred from a hunch and nothing is printed
  # without a number behind it, because a report that cries wolf is one nobody reads twice
  # -- and this project's whole argument is that its output can be trusted.
  #
  # The data is not new. The runner has been writing per-test durations to balance workers
  # and per-result rows to detect flakes since the beginning; this asks those rows a
  # different question.
  class Insights
    # A file has to own at least this share of a run before it is worth naming. Below it,
    # "your slowest file" is noise -- every suite has one.
    FILE_SHARE = 0.10

    # A test that flips this often is not a test, it is a coin.
    FLAKE_RUNS = 3

    def initialize(storage:, config:, run:)
      @storage = storage
      @config = config
      @run = run
    end

    def call
      [
        slow_file_finding,
        flake_finding,
        broken_finding,
        jail_finding,
        cold_case_finding
      ].compact
    end

    private

    attr_reader :storage, :config, :run

    # One file owning a tenth of the run is worth saying out loud, because the fix is
    # usually local to that file and nobody looks for it otherwise.
    def slow_file_finding
      total = storage.total_test_seconds(run[:id])
      return nil unless total.positive?

      files = storage.slowest_files(run[:id], limit: 3)
      return nil if files.empty?

      worst = files.first
      share = worst[:total].to_f / total
      return nil if share < FILE_SHARE

      {
        headline: format("%s is %d%% of the suite's time (%s across %d tests)",
                         worst[:file], (share * 100).round, seconds(worst[:total]),
                         worst[:tests].to_i),
        detail: "Average #{seconds(worst[:average])} per test. The next two: " \
                "#{files.drop(1).map { |f| "#{f[:file]} (#{seconds(f[:total])})" }.join(", ")}.\n" \
                "A file this size is usually one expensive fixture or one `before` doing " \
                "real work for every example."
      }
    end

    # A flake is a test that has both passed and failed at the same identity. Constable
    # keys identity on the body of the test, so this cannot be a rename.
    def flake_finding
      flaky = storage.flakiest(limit: 5).select { |f| f[:runs].to_i >= FLAKE_RUNS }
      return nil if flaky.empty?

      worst = flaky.first
      {
        headline: "#{flaky.size} #{plural(flaky.size, "test")} " \
                  "#{flaky.size == 1 ? "flips" : "flip"} between pass and fail",
        detail: "Worst: #{label_for(worst)} -- #{worst[:failures]} failures in " \
                "#{worst[:runs]} runs.\n" \
                "`constable test #{location(worst)} --warrants` reruns it in isolation " \
                "before believing the result."
      }
    end

    # Never passing is not flaking. The two look alike in a summary and want opposite
    # responses: one is a broken test, the other is a broken guarantee.
    def broken_finding
      leaders = storage.failure_leaders(limit: 10)
      always = leaders.select { |row| row[:failures].to_i == row[:runs].to_i && row[:runs].to_i >= 2 }
      return nil if always.empty?

      {
        headline: "#{always.size} #{plural(always.size, "test")} #{always.size == 1 ? "has" : "have"} " \
                  "never passed",
        detail: "These are not flakes -- they have failed every run recorded. " \
                "First: #{label_for(always.first)} (#{always.first[:runs]} runs).\n" \
                "Fix or delete them; a permanently red test teaches everyone to ignore red."
      }
    end

    def jail_finding
      jailed = storage.jailed
      return nil if jailed.empty?

      {
        headline: "#{jailed.size} #{plural(jailed.size, "test")} on the docket",
        detail: "Jailed tests are skipped and tracked, not forgotten. " \
                "`constable jail run` reruns them; `constable jail list` says why each is there."
      }
    end

    # Adoption, phrased as the work remaining rather than as a score.
    def cold_case_finding
      totals = storage.kind_totals(limit: 1).first
      return nil if totals.nil?

      cold = totals[:cold].to_i
      total = cold + totals[:native].to_i
      return nil if cold.zero? || total.zero?

      {
        headline: "#{(cold * 100.0 / total).round}% of the suite still runs as cold cases " \
                  "(#{cold} of #{total})",
        detail: "Cold cases are exempt from Constable's rules, so none of the guarantees " \
                "apply to them yet.\n" \
                "`constable modernize PATH` reports what one file would become; nothing is " \
                "written unless you ask."
      }
    end

    def label_for(row)
      row[:label].to_s.empty? ? location(row) : row[:label]
    end

    def location(row)
      [row[:file], row[:line]].compact.join(":")
    end

    def seconds(value)
      value.to_f >= 60 ? format("%dm %ds", value.to_i / 60, value.to_i % 60) : format("%.1fs", value)
    end

    def plural(count, word) = count == 1 ? word : "#{word}s"
  end
end
