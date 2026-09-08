# frozen_string_literal: true

module Constable
  # Warrants -- automatic flaky detection.
  #
  # Jail asks "does this block the build?". A warrant asks the question underneath it:
  # *is this failure even real?* The two are deliberately separate mechanisms, and a test
  # can be subject to both.
  #
  # Opt in with `warrants: true` in config, or `constable test --warrants` for one run.
  # Once a warrant exists it stands on its own: a warranted test gets the full retry
  # treatment on **every** future run whether or not the flag is passed, because the
  # blotter entry carries the rule, not the command line.
  #
  # Issuing one:
  #
  #   A test fails its normal attempt while warrants are active. Constable reruns that one
  #   test, in isolation, `warrant_retries` more times (default 5).
  #     * fails every retry  -> a genuine failure. No warrant. Handled like any other
  #       failure, jail included if `--jail` is also on.
  #     * passes at least once -> flaky, not broken. A warrant goes on the blotter, the
  #       result stops blocking the build, and it gets its own section in the summary.
  #
  # Living under one:
  #
  #     * all retries pass -> warrant cleared, entry removed, reported as cleared.
  #     * any retry fails  -> warrant stands, "still under warrant", still non-blocking.
  #
  # The blotter is the only record. Nothing here ever writes to a source file, and there
  # is deliberately no companion command that annotates specs -- same reasoning as jail:
  # one source of truth, nothing to drift out of sync. `constable warrants release
  # PATH:LINE` is the manual clear.
  class Warrants
    # What a run's adjudication concluded about one test.
    #
    #   :issued   a fresh warrant -- failed, then passed under retry
    #   :genuine  no warrant -- failed every retry, this is a real failure
    #   :upheld   standing warrant, still flaky
    #   :cleared  standing warrant, clean sweep -- lifted
    #   :none     the machinery did not apply
    VERDICTS = %i[none issued genuine upheld cleared].freeze

    # One row of the warrants table, normalized. Tolerant of string keys for the same
    # reason Jail::Entry is: the storage layer is pluggable.
    class Entry
      attr_reader :identity, :label, :file, :line, :reason, :issued_at, :last_seen_at,
                  :times_seen, :clean_runs, :failed_runs, :row

      def self.wrap(row)
        return nil if row.nil?
        return row if row.is_a?(Entry)
        return nil unless row.respond_to?(:to_h)

        hash = row.to_h
        hash.empty? ? nil : new(hash)
      end

      def initialize(row)
        @row          = row.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
        @identity     = @row[:identity].to_s
        @label        = @row[:label]
        @file         = @row[:file].to_s
        @line         = @row[:line]&.to_i
        @reason       = @row[:reason]
        @issued_at    = @row[:issued_at]
        @last_seen_at = @row[:last_seen_at]
        @times_seen   = (@row[:times_seen] || 0).to_i
        @clean_runs   = (@row[:clean_runs] || 0).to_i
        @failed_runs  = (@row[:failed_runs] || 0).to_i
      end

      # A cleared entry is handed back by storage as it was at the moment the row went
      # away -- the only chance the reporter gets to name its final counters.
      def cleared? = @row[:cleared] == true || @row[:state].to_s == "cleared"

      def location = "#{@file}:#{@line}"
      def to_h     = @row.dup
    end

    attr_reader :config, :storage, :issued, :cleared, :upheld, :genuine, :verdicts

    def initialize(config: Constable.config, storage: Constable.storage)
      @config   = config
      @storage  = storage
      @issued   = []
      @cleared  = []
      @upheld   = []
      @genuine  = []
      @verdicts = {}
    end

    # How many isolated reruns one adjudication costs. Zero disables the mechanism
    # outright -- there is nothing to learn from retrying a test no times.
    def warrant_retries
      retries = @config.respond_to?(:warrant_retries) ? @config.warrant_retries.to_i : 0
      retries.negative? ? 0 : retries
    end

    # The flag, not the blotter.
    def enabled? = @config.respond_to?(:warrants?) ? @config.warrants? : false

    def active?(requested: false) = requested || enabled?

    # The blotter, not the flag. A standing warrant outranks the flag in both directions:
    # it applies without `--warrants`, and no flag is needed to clear it.
    def standing?(identity) = !entry(identity).nil?
    alias warranted? standing?

    # "Is this identity subject to the warrant machinery this run?" -- either because
    # somebody asked for warrants, or because this test already has one.
    def applies_to?(identity, requested: false)
      return false if warrant_retries.zero?

      standing?(identity) || active?(requested: requested)
    end

    # "Should I actually spend retries on this result?" A standing warrant is retried
    # however the normal attempt went; an ordinary test only earns retries by failing.
    def retry?(result, requested: false)
      return false if warrant_retries.zero?
      return false if result.nil? || result.jailed? || result.skipped?
      return true  if standing?(result.identity)

      active?(requested: requested) && result.failed?
    end

    # --- queries ---------------------------------------------------------------

    def entries            = Array(@storage.warrants).filter_map { |row| Entry.wrap(row) }
    def entry(identity)    = Entry.wrap(@storage.warrant_entry(identity.to_s))
    def any?               = !entries.empty?

    # A warranted result never fails the build. That is the whole point of establishing
    # that the failure was not real.
    def blocks_build?(result) = result.failed?

    # --- adjudication ----------------------------------------------------------

    # The Runner's single entry point. Hands back the same Result, decided.
    #
    #   warrants.adjudicate(result, requested: cli_flag, subject: investigation) do |subject, attempt|
    #     runner.run_one_in_isolation(subject)   # => a Constable::Result
    #   end
    #
    # The block reruns exactly one test in isolation and returns its outcome -- a Result,
    # a status Symbol, or a boolean. It is called `warrant_retries` times, always the full
    # count: a partial sample is a worse answer than a slower one, and the retry statuses
    # end up on `Result#retries` for the reporter.
    #
    # Order matters at the call site: adjudicate first, then hand the result to Jail. A
    # warranted result is not a failure, so it must never reach the docket; a genuine one
    # should, jail mode included.
    def adjudicate(result, requested: false, subject: nil, &rerun)
      decide(result, requested: requested, subject: subject, &rerun)
      persist(result)
      result
    end

    # The half that runs tests and decides, with no writes -- safe inside a fork worker,
    # where the architecture's "only the parent writes" rule applies. The parent calls
    # #persist on the Result that comes back over the pipe.
    def decide(result, requested: false, subject: nil, &rerun)
      return result unless retry?(result, requested: requested)
      raise ArgumentError, "Warrants#decide needs a block that reruns one test in isolation" unless rerun

      statuses = run_retries(result, subject, rerun)
      result.retries = statuses
      result.status  = decided_status(result, statuses)
      result
    end

    # The half that writes. Derives the verdict from the blotter plus the retry statuses
    # already on the Result, so it works equally on a locally decided result and on one
    # that arrived from a worker as a hash.
    def persist(result, verdict = verdict_for(result))
      @verdicts[result.identity] = verdict unless verdict == :none

      case verdict
      when :issued
        @storage.issue_warrant(result.identity, label: result.display_label, file: result.file,
                                                line: result.line, reason: issue_reason(result))
        @issued << result
      when :upheld
        @storage.touch_warrant(result.identity, cleared: false)
        @upheld << result
      when :cleared
        # touch_warrant(cleared: true) lifts the warrant and hands back the final row.
        # clear_warrant stays the manual path; calling both would just be noise.
        @storage.touch_warrant(result.identity, cleared: true)
        @cleared << result
      when :genuine
        @genuine << result
      end

      verdict
    end

    # Fully derivable from (does a warrant stand?, how did the retries go?), which is why
    # a worker never has to ship a verdict back alongside the result.
    def verdict_for(result)
      statuses = Array(result&.retries).map { |status| normalize_status(status) }
      return :none if statuses.empty?

      if standing?(result.identity)
        statuses.all?(:passed) ? :cleared : :upheld
      else
        statuses.any?(:passed) ? :issued : :genuine
      end
    end

    # --- human operations ------------------------------------------------------

    # `constable warrants release PATH:LINE`.
    def release(identity) = @storage.clear_warrant(identity.to_s) ? true : false

    # Counts for the summary line and its own section.
    def summary_counts
      { issued: @issued.size, cleared: @cleared.size, upheld: @upheld.size, standing: entries.size }
    end

    # --- PATH:LINE resolution ---------------------------------------------------

    # The CLI speaks in file:line, the blotter is keyed by content hash. Warrant rows
    # carry both; loaded investigations are the fallback.
    # Every docket row a target could mean.
    #
    # The interesting case is a bare path. "test/cases/users_case.rb" with three tests
    # on the docket is a question, not an instruction: picking one silently acts on a
    # test the user never named -- and not even the first one, since the order is
    # whatever storage returns. Callers ask for the candidates and refuse to guess.
    def candidates(target)
      text = target.to_s.strip
      return [] if text.empty?

      if text.match?(/\A[0-9a-f]{8,64}\z/) && (row = entry(text))
        return [row]
      end

      file, line = Jail.split_target(text)
      return [] if file.empty?

      matches = entries.select { |e| Jail.same_path?(e.file, file) }
      matches = matches.select { |e| e.line == line } if line
      matches
    end

    def resolve(target)
      matches = candidates(target)
      return matches.first.identity if matches.size == 1
      return nil unless matches.empty?

      file, line = Jail.split_target(target.to_s.strip)
      return nil if file.empty?

      Jail.registry_identity(file, line)
    end

    def resolve!(target)
      resolve(target) || raise(Constable::Error, "no test found for #{target.inspect} " \
                                                 "(expected PATH:LINE, e.g. test/cases/users_case.rb:12)")
    end

    private

    def run_retries(result, subject, rerun)
      Array.new(warrant_retries) do |index|
        normalize_status(call_rerun(rerun, subject || result, index + 1))
      end
    end

    # Blocks are lenient about extra arguments; lambdas are not, and somebody will pass one.
    def call_rerun(rerun, subject, attempt)
      return rerun.call(subject, attempt) unless rerun.lambda?

      case rerun.arity
      when 0 then rerun.call
      when 1 then rerun.call(subject)
      else rerun.call(subject, attempt)
      end
    end

    def decided_status(result, statuses)
      if standing?(result.identity)
        # A standing warrant is judged on the retries alone -- a clean sweep lifts it,
        # anything else keeps it standing and non-blocking.
        statuses.all?(:passed) ? :passed : :warranted
      elsif statuses.any?(:passed)
        :warranted
      else
        result.status # a genuine failure keeps whatever kind of failure it was
      end
    end

    def normalize_status(value)
      return value.passed? ? :passed : :failed if value.respond_to?(:passed?)
      return :passed if value == true
      return :failed if value == false || value.nil?

      value.to_s == "passed" ? :passed : :failed
    end

    def issue_reason(result)
      statuses = Array(result.retries).map { |status| normalize_status(status) }
      passes   = statuses.count(:passed)
      "failed its normal attempt, then passed #{passes} of #{statuses.size} isolated retries"
    end
  end
end
