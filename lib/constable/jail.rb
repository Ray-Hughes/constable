# frozen_string_literal: true

module Constable
  # The docket.
  #
  # Jail answers exactly one question: *does this test block the build?* (Whether the
  # failure was even real is a different question, and warrants answer that one.)
  #
  # A test lands on the docket three ways, and all three land in the same place:
  #
  #   1. A flake-history flip -- it passed, then failed, with no code change. Identity is
  #      a content hash of the investigate body, so an unchanged hash that flips result
  #      *is* a flake by definition. Nothing else needs to be inferred.
  #   2. A failure during a `--jail` run. The on-ramp for a big red legacy suite: run
  #      once in jail mode for a clean baseline, then work the docket down.
  #   3. A parole violation -- a test that was trusted again and immediately let us down.
  #
  # Jailing is not hiding. It swaps "blocks the build" for "tracked and skipped", and a
  # jailed test is always its own summary category -- never folded into passed. Only the
  # `investigate` body is skipped; `briefing` and `witness` still run, so setup rot
  # surfaces on the next ordinary run instead of ambushing whoever finally works the
  # docket. That decision is exposed here as #skip_body?; the Runner does the skipping.
  #
  # The state machine is small: jailed <-> parole -> released.
  #
  # Storage owns the persistence and the counters (see Constable::Storage); this class
  # owns the policy and hands the Runner and the reporter decided Results.
  class Jail
    # Why a test is on the docket. Stored as free text so the blotter stays readable to a
    # human running `constable jail`, keyed by symbol so callers don't retype prose.
    REASONS = {
      flake:            "flake history flip -- passed, then failed with no code change",
      jail_mode:        "failed during a --jail run",
      parole_violation: "parole violation -- failed while out on parole",
      manual:           "jailed by hand"
    }.freeze

    # One row of the docket, normalized.
    #
    # Adapters hand back symbol-keyed hashes, but this wrapper is deliberately tolerant of
    # string keys and of a couple of column aliases: the blotter is the kind of thing
    # people point third-party adapters at, and a docket entry is not worth a NoMethodError
    # over a spelling.
    class Entry
      attr_reader :identity, :label, :file, :line, :reason, :state, :times_jailed,
                  :parole_violations, :parole_day, :jailed_at, :paroled_at, :updated_at, :row

      def self.wrap(row)
        return nil if row.nil?
        return row if row.is_a?(Entry)
        return nil unless row.respond_to?(:to_h)

        hash = row.to_h
        hash.empty? ? nil : new(hash)
      end

      def initialize(row)
        @row               = row.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
        @identity          = @row[:identity].to_s
        @label             = @row[:label]
        @file              = @row[:file].to_s
        @line              = @row[:line]&.to_i
        @reason            = @row[:reason]
        @state             = normalize_state(@row[:state] || @row[:status])
        @times_jailed      = (@row[:times_jailed] || 1).to_i
        @parole_violations = (@row[:parole_violations] || 0).to_i
        @parole_day        = (@row[:parole_clean_runs] || @row[:parole_day] || 0).to_i
        @jailed_at         = @row[:jailed_at]
        @paroled_at        = @row[:paroled_at]
        @updated_at        = @row[:updated_at]
      end

      def jailed?   = @state == :jailed
      def paroled?  = @state == :parole
      # An auto-release hands back the entry as it was at the moment the row went away --
      # the only chance the caller gets to report it.
      def released? = @state == :released || @row[:released] == true

      def location = "#{@file}:#{@line}"
      def to_h     = @row.dup

      private

      def normalize_state(value)
        case value.to_s
        when "parole", "paroled" then :parole
        when "released"          then :released
        else :jailed
        end
      end
    end

    # What one turn of the parole state machine did. The reporter reads this to say
    # "Failed on day 3 of a 10-run parole" and "this is its 2nd time in jail" without
    # doing arithmetic of its own.
    class Transition
      OUTCOMES = %i[none parole_continues released parole_violation].freeze

      attr_reader :outcome, :entry, :parole_day, :parole_period, :times_jailed, :parole_violations

      def initialize(outcome:, entry: nil, parole_day: 0, parole_period: 0,
                     times_jailed: nil, parole_violations: nil)
        @outcome           = outcome
        @entry             = entry
        @parole_day        = parole_day.to_i
        @parole_period     = parole_period.to_i
        @times_jailed      = (times_jailed || entry&.times_jailed).to_i
        @parole_violations = (parole_violations || entry&.parole_violations).to_i
      end

      def none?       = @outcome == :none
      def continuing? = @outcome == :parole_continues
      def released?   = @outcome == :released
      def violation?  = @outcome == :parole_violation
    end

    attr_reader :config, :storage

    def initialize(config: Constable.config, storage: Constable.storage)
      @config  = config
      @storage = storage
    end

    # Consecutive clean runs that earn an automatic release. Floors at 1 -- a period of
    # zero would mean "release on sight", which is not parole.
    def parole_period
      period = @config.respond_to?(:parole_period) ? @config.parole_period.to_i : 0
      period.positive? ? period : 10
    end

    # --- queries ---------------------------------------------------------------

    # The whole docket, jailed and paroled alike, newest first. Assembled from both
    # storage lists and deduplicated, so an adapter that returns everything from #jailed
    # is as correct here as one that filters by state.
    def entries
      rows = Array(@storage.jailed) + Array(@storage.paroled)
      rows.filter_map { |row| Entry.wrap(row) }.uniq(&:identity)
    end

    def entry(identity) = Entry.wrap(@storage.jail_entry(identity.to_s))

    def jailed  = entries.select(&:jailed?)
    def paroled = entries.select(&:paroled?)

    # Deliberately not Storage#jailed?, which is "on the docket at all" -- a paroled test
    # is on the docket and is emphatically not in jail.
    def jailed?(identity)  = entry(identity)&.jailed? || false
    def paroled?(identity) = entry(identity)&.paroled? || false

    def supervised?(identity) = !entry(identity).nil?

    # The Runner's question. True means: build the instance, run every briefing and
    # witness, then stop short of the investigate body. Setup rot surfaces immediately;
    # the failing assertion stays locked up.
    def skip_body?(identity) = jailed?(identity)

    # A test passed, then failed, and its content hash never moved. That is a flake, and
    # it is the one route into jail that needs no flag and no human.
    #
    # Ask this *before* recording the current result to flake history, or the "previous"
    # status will be the one being adjudicated.
    def flake_flip?(result)
      return false unless result.failed?

      @storage.last_status(result.identity).to_s == "passed"
    end

    # --- routes in -------------------------------------------------------------

    # Books a finished Result onto the docket and hands it back decided, so the Runner can
    # keep treating results as its only currency.
    def jail(result, reason: :manual)
      text  = reason_text(reason)
      entry = jail_identity(result.identity, label: result.display_label,
                                             file: result.file, line: result.line, reason: text)
      result.status       = :jailed
      result.jail_reason  = text
      result.times_jailed = entry&.times_jailed
      result
    end

    # Route 1. Recorded with its own reason so `constable jail` reads as an explanation
    # rather than a list.
    def jail_for_flake(result) = jail(result, reason: :flake)

    # Route 2. Jail mode: a failure is tracked and skipped instead of red.
    def jail_failure(result) = jail(result, reason: :jail_mode)

    # The primitive under all of the above, for the CLI and for anything holding an
    # identity rather than a Result.
    def jail_identity(identity, label:, file:, line:, reason: :manual)
      Entry.wrap(@storage.jail(identity.to_s, label: label, file: file, line: line,
                                              reason: reason_text(reason))) || entry(identity)
    end

    # --- the parole state machine ----------------------------------------------

    # A clean run for a test on parole. `parole_period` of these in a row and it walks --
    # automatically, with no human step, because that is what the period is for.
    def record_pass(identity)
      before = entry(identity)
      return Transition.new(outcome: :none, entry: before, parole_period: parole_period) unless before&.paroled?

      after = Entry.wrap(@storage.record_parole_pass(identity.to_s))
      day   = after&.parole_day&.positive? ? after.parole_day : before.parole_day + 1

      if after&.released?
        transition(:released, after, day)
      elsif day >= parole_period
        # Belt and braces: an adapter that only counts still gets the release it earned.
        @storage.release(identity.to_s)
        transition(:released, after || before, day)
      else
        transition(:parole_continues, after || before, day)
      end
    end

    # A paroled test failed. Once is enough -- parole exists precisely because the test
    # had not earned trust yet, so there is no leniency and no second look.
    def record_failure(identity)
      before = entry(identity)
      return Transition.new(outcome: :none, entry: before, parole_period: parole_period) unless before&.paroled?

      day   = before.parole_day + 1 # the run it went down on, not the runs it survived
      after = Entry.wrap(@storage.record_parole_violation(identity.to_s))
      after = force_back_to_jail(before) if after.nil? || after.paroled?

      Transition.new(
        outcome: :parole_violation, entry: after, parole_day: day, parole_period: parole_period,
        times_jailed: after&.times_jailed || (before.times_jailed + 1),
        parole_violations: after&.parole_violations || (before.parole_violations + 1)
      )
    end

    # --- human operations ------------------------------------------------------

    # `constable jail parole PATH:LINE`. Jail -> parole; the clean-run count starts over.
    def parole(identity) = Entry.wrap(@storage.parole(identity.to_s))

    # `constable jail release PATH:LINE`. Off the docket entirely, no supervision.
    def release(identity) = @storage.release(identity.to_s) ? true : false

    # `jail run` never auto-releases and never auto-paroles. One green run proves nothing;
    # it only earns a mention. A human reads this list and decides.
    #
    # Pass the raw Results from the jail run -- do *not* route those through #adjudicate,
    # which would book them straight back onto the docket they came from.
    def candidates_for_release(results)
      Array(results).select { |result| passing?(result) }
                    .filter_map { |result| entry(result.identity) }
    end

    # The whole picture after a `jail run`, for the CLI to print.
    def jail_run_report(results)
      results = Array(results)
      {
        candidates:    candidates_for_release(results),
        still_failing: results.reject { |r| passing?(r) }.filter_map { |r| entry(r.identity) }
      }
    end

    # --- the Runner's single entry point ---------------------------------------

    # One call per finished result. Returns the same Result, decided.
    #
    # Call it *before* writing the result to flake history (the flip check reads the
    # previous status) and *after* Warrants has had its say (a warranted result is not a
    # failure, so it never reaches the docket).
    def adjudicate(result, jail_mode: false)
      return result if result.nil?

      docket = entry(result.identity)

      return record_result(result) if docket&.paroled?
      return mark_jailed(result)   if docket&.jailed?
      return result unless result.failed?

      if jail_mode
        jail_failure(result)
      elsif flake_flip?(result)
        jail_for_flake(result)
      else
        result
      end
    end

    # Drives the parole machine from a Result and stamps the outcome onto it. A parole
    # violation gets its own status -- it is more urgent news than a plain new failure,
    # because somebody deliberately trusted this test again.
    def record_result(result)
      return result unless paroled?(result.identity)

      if result.failed?
        transition = record_failure(result.identity)
        result.status       = :parole_violation
        result.jail_reason  = REASONS[:parole_violation]
        result.parole_day   = transition.parole_day
        result.times_jailed = transition.times_jailed
      elsif result.passed?
        result.parole_day = record_pass(result.identity).parole_day
      end

      result
    end

    # For a test the Runner skipped because it is on the docket: fills in the reason and
    # the repeat-offender count without touching storage. Nothing here is a new offence.
    def mark_jailed(result)
      docket = entry(result.identity)
      result.status       = :jailed
      result.jail_reason  = docket&.reason
      result.times_jailed = docket&.times_jailed
      result
    end

    # Headline counts for the summary line: "2 jailed (1 parole violation)".
    def summary_counts(results)
      results = Array(results)
      {
        jailed:            results.count { |r| r.status == :jailed },
        parole_violations: results.count { |r| r.status == :parole_violation },
        on_parole:         paroled.size
      }
    end

    # --- PATH:LINE resolution ---------------------------------------------------

    # The CLI speaks in file:line; the blotter is keyed by content hash. The docket stores
    # both, so it is the first place to look; loaded investigations are the fallback for a
    # test that is not on the docket yet.
    #
    # Returns an identity String, or nil when nothing matches.
    def resolve(target)
      text = target.to_s.strip
      return nil if text.empty?
      return text if identity_like?(text) && entry(text)

      file, line = self.class.split_target(text)
      return nil if file.empty?

      matches = entries.select { |e| self.class.same_path?(e.file, file) }
      matches = matches.select { |e| e.line == line } if line
      return matches.first.identity if matches.any?

      self.class.registry_identity(file, line)
    end

    def resolve!(target)
      resolve(target) || raise(Constable::Error, "no test found for #{target.inspect} " \
                                                 "(expected PATH:LINE, e.g. test/cases/users_case.rb:12)")
    end

    # "test/cases/users_case.rb:12" -> ["test/cases/users_case.rb", 12]
    def self.split_target(target)
      text  = target.to_s.strip
      match = text.match(/\A(?<file>.+):(?<line>\d+)\z/)
      match ? [match[:file], match[:line].to_i] : [text, nil]
    end

    def self.normalize_path(path)
      path.to_s.strip.delete_prefix("#{Constable.root}/").delete_prefix("./")
    end

    def self.same_path?(left, right) = normalize_path(left) == normalize_path(right)

    # Falls back to whatever the Registry has loaded, so `constable jail parole` works on
    # a test that has never been on the docket.
    def self.registry_identity(file, line)
      investigations = Constable.registry.investigations
      matches = investigations.select { |inv| same_path?(inv.relative_file, file) }
      matches = matches.select { |inv| inv.line.to_i == line } if line
      matches.first&.identity
    rescue StandardError
      nil
    end

    private

    def transition(outcome, entry, day)
      Transition.new(outcome: outcome, entry: entry, parole_day: day, parole_period: parole_period)
    end

    def force_back_to_jail(before)
      jail_identity(before.identity, label: before.label, file: before.file,
                                     line: before.line, reason: :parole_violation)
    end

    def reason_text(reason)
      REASONS.fetch(reason) { reason.to_s.empty? ? REASONS[:manual] : reason.to_s }
    end

    def passing?(result)
      result.respond_to?(:passed?) ? result.passed? : result.to_s == "passed"
    end

    def identity_like?(text) = text.match?(/\A[0-9a-f]{8,64}\z/)
  end
end
