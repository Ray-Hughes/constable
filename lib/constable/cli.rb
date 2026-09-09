# frozen_string_literal: true

require "thor"

module Constable
  # The command line. Every command answers one question and prints the answer -- stdout is
  # reserved for results, so anything a Rails app would normally shout into the terminal
  # goes to log/test.log instead.
  class CLI < Thor
    EXIT_CLEAN = 0
    EXIT_FAILED = 1
    EXIT_USAGE = 2

    def self.exit_on_failure? = true

    # Thor's own exit status handling doesn't distinguish "tests failed" from "command was
    # wrong", and CI needs to. Commands return a status; this turns it into one.
    def self.dispatch!(argv)
      start(argv)
    # Thor::Error is a malformed command; Constable::Error is a wrong path, an unknown
    # tier, an unreadable config. Both are the user's mistake rather than a crash, and
    # both deserve one sentence and a usage status instead of a backtrace.
    rescue Thor::Error, Constable::Error => e
      complain(e.message)
      exit(EXIT_USAGE)
    rescue Interrupt
      complain("\ninterrupted")
      exit(EXIT_FAILED)
    end

    # Anything the user has to see, written where they will see it.
    #
    # Not Kernel#warn. A run points stdout and stderr at log/test.log, so an error has to
    # go to the console the reporter kept -- and `warn` would not reach it even without
    # that: Rails apps routinely override Warning.warn to funnel Ruby warnings into
    # Rails.logger, and a real one did. The message arrived in log/test.log tagged
    # "[RUBY WARNING]" while the terminal showed nothing at all.
    def self.complain(message)
      LogRouter.restore!
      io = LogRouter.console_err
      io.puts(message)
      io.flush if io.respond_to?(:flush)
    rescue StandardError
      $stderr.puts(message) # rubocop:disable Style/StderrPuts
    end

    class_option :"no-color", type: :boolean, default: false, desc: "Disable ANSI color"

    desc "test [PATH[:LINE]]", "Run the suite -- native and cold cases side by side"
    long_desc <<~DESC
      With no arguments, runs only the cases touched by your current git diff. CI should
      always pass --full. PATH runs one file; PATH:LINE runs the single investigation at
      that line.
    DESC
    option :full,     type: :boolean, default: false, desc: "Run the whole suite (always use this in CI)"
    option :unsafe,   type: :boolean, default: false, desc: "Run cold cases only"
    option :jail,     type: :boolean, default: false, desc: "Jail failures instead of failing the build"
    option :warrants, type: :boolean, desc: "Turn the flaky detector on for this run"
    option :coverage, type: :boolean, desc: "Record coverage for this run"
    option :seed,     type: :numeric, desc: "Replay a previous run's order"
    option :workers,  type: :numeric, desc: "Parallel workers (default: config, or auto)"
    option :verbose,  type: :boolean, default: false, desc: "Stream log/test.log to stdout"
    option :tier,     type: :string,  desc: "Run one tier only: unit, integration or system"
    option :output,   type: :string,  desc: "Live stream detail: concise (default) or expanded"
    option :expanded, type: :boolean, default: false, desc: "Shorthand for --output=expanded"
    option :concise,  type: :boolean, default: false, desc: "Shorthand for --output=concise"
    def test(*paths)
      config = load_config
      LogRouter.route!(verbose: options[:verbose])

      selection = Selection.new(
        paths,
        config: config,
        root: Constable.root,
        full: options[:full],
        unsafe_only: options[:unsafe],
        tier: options[:tier]
      )

      runner = Runner.new(
        selection: selection,
        config: config,
        reporter: reporter(config),
        storage: Constable.storage,
        seed: options[:seed],
        jail_mode: options[:jail],
        warrants: options[:warrants],
        coverage: options[:coverage],
        workers: options[:workers],
        verbose: options[:verbose]
      )

      exit(runner.call)
    end

    desc "watchlist", "Everything under supervision right now: jailed, paroled and warranted"
    def watchlist
      config = load_config
      storage = Constable.storage
      jail = Jail.new(config: config, storage: storage)
      warrants = Warrants.new(config: config, storage: storage)

      say_table("JAILED", jail.jailed) do |entry|
        [entry.location, entry.label, entry.reason, jailed_on(entry)]
      end

      say_table("ON PAROLE", jail.paroled) do |entry|
        ["#{entry.parole_day}/#{config.parole_period} clean"].then do |clean|
          [entry.location, entry.label, clean.first, jailed_on(entry)]
        end
      end

      say_table("WARRANTS", warrants.entries) do |entry|
        [entry.location, entry.label, "issued #{short_date(entry.issued_at)}"]
      end

      exit(EXIT_CLEAN)
    end

    desc "status", "How the suite is doing over time"
    long_desc <<~DESC
      The trend view: how much of the suite is still running as cold cases, how the last
      runs went, and which tests have been the slowest historically. For what is flagged
      right now -- jailed, paroled, warranted -- use `constable watchlist` instead.
    DESC
    def status
      storage = Constable.storage
      runs = storage.runs(limit: 20)

      if runs.empty?
        say "No runs recorded yet. Run: constable test --full"
        exit(EXIT_CLEAN)
      end

      print_adoption(storage, runs)
      print_recent_runs(runs)
      print_historical_slowest(storage)
      exit(EXIT_CLEAN)
    end

    desc "beat", "Coverage: overall %, per-file breakdown and the unpatrolled list"
    option :html, type: :boolean, default: false, desc: "Write a browsable HTML report"
    def beat
      config = load_config
      LogRouter.route!(verbose: false)

      # The beat is walked, not remembered: a stored snapshot carries percentages but not
      # the per-line detail the breakdown and the HTML report are made of. So this runs
      # the full suite with coverage on and reports on what it finds.
      selection = Selection.new([], config: config, root: Constable.root, full: true)
      runner = Runner.new(
        selection: selection, config: config, reporter: reporter(config),
        storage: Constable.storage, coverage: true
      )
      runner.call
      report = runner.coverage_report

      unless report
        say "No coverage was recorded. Is there anything to run?"
        exit(EXIT_FAILED)
      end

      say ""
      say report.beat_report

      if options[:html] || config.coverage_html?
        path = Constable::Coverage.write_html(report)
        say "\nHTML report: #{path}"
      end
      exit(EXIT_CLEAN)
    end

    desc "import", "Adopt an existing suite as cold cases -- verbatim, nothing rewritten"
    option :from, type: :string, required: true, enum: %w[rspec minitest], desc: "Source framework"
    option :strategy, type: :string, default: "auto", enum: %w[auto config superclass],
                      desc: "auto: widest clean glob, else a superclass swap. " \
                            "config: no file changes at all. superclass: one line per file"
    option :"dry-run", type: :boolean, default: false, desc: "Show what would change"
    def import
      result = Importer.run(
        from: options[:from].to_sym,
        config: load_config,
        dry_run: options[:"dry-run"],
        strategy: options[:strategy].to_sym
      )

      # The summary says this in full now, in the reader's own terms.
      say result.summary
      exit(EXIT_CLEAN)
    end

    desc "modernize PATH [PATH...]", "Opt-in AST rewrite into the native DSL"
    long_desc <<~DESC
      Reports by default and writes nothing. --alongside writes a new *_case.rb next to the
      original; --in-place overwrites it. Anything the rewrite cannot decide safely is
      flagged for a human rather than guessed at, and never converted.
    DESC
    option :alongside, type: :boolean, default: false, desc: "Write PATH_case.rb beside the original"
    option :"in-place", type: :boolean, default: false, desc: "Overwrite the file"
    option :"show-source", type: :boolean, default: false, desc: "Print the rewritten source"
    def modernize(*paths)
      if paths.empty?
        CLI.complain("modernize needs at least one path")
        exit(EXIT_USAGE)
      end

      mode = if options[:"in-place"] then :in_place
             elsif options[:alongside] then :alongside
             else :none
             end

      run = Importer.modernize(paths, config: load_config, write: mode)

      run.results.each do |result|
        if result.error
          say "#{result.relative_path}: #{result.error}"
          next
        end

        counts = result.counts
        say "#{result.relative_path} — #{describe_counts(counts)}"
        say(result.source) if options[:"show-source"]

        result.flags.each { |flag| say "    flagged #{flag[:location]}  #{flag[:reason]}" }
      end

      say "\nWrote #{run.written.size} file(s)." if run.written.any?
      say "Report: #{run.report_path}" if run.report_path
      say "\nNothing was written. Re-run with --alongside or --in-place." if mode == :none
      exit(run.ok? ? EXIT_CLEAN : EXIT_FAILED)
    end

    desc "version", "Print the version"
    def version
      say "constable #{Constable::VERSION} (gem: constable-rails)"
      exit(EXIT_CLEAN)
    end
    map %w[-v --version] => :version

    # --- subcommands -----------------------------------------------------------

    # The jail docket. Jailing isn't hiding -- it swaps "blocks the build" for "tracked and
    # skipped", and nothing leaves the docket without someone deciding it should.
    class JailCommand < Thor
      def self.exit_on_failure? = true

      default_task :list

      desc "list", "Every jailed test: reason, file:line, date jailed"
      def list
        config = Constable.config
        jail = Jail.new(config: config, storage: Constable.storage)
        entries = jail.entries

        if entries.empty?
          say "The docket is empty."
          return
        end

        entries.each do |entry|
          state = entry.paroled? ? "on parole" : "jailed"
          say format("%-9s %s", state, entry.location)
          say "          #{entry.label}"
          say "          #{entry.reason}"
          say "          jailed #{short_date(entry.jailed_at)}#{repeat_note(entry)}"
          say ""
        end
      end

      # Thor reserves `run` as a method name, so the command is named for the user and the
      # method is named for Ruby.
      map "run" => :rerun

      desc "run [PATH:LINE]", "Re-run jailed tests -- sequentially, for clean attribution"
      option :full, type: :boolean, default: false,
                    desc: "Re-run the whole docket in one parallel batch (faster, coarser)"
      def rerun(path = nil)
        config = Constable.config
        storage = Constable.storage
        jail = Jail.new(config: config, storage: storage)
        targets = path ? [path] : jail.entries.map(&:location)

        if targets.empty?
          say "The docket is empty."
          return
        end

        selection = Selection.new(targets, config: config, root: Constable.root, full: true)
        runner = Runner.new(
          selection: selection,
          config: config,
          storage: storage,
          jail_run: true,
          # Sequential by default: one test at a time gives clean attribution for a
          # docket nobody trusts yet. --full trades that for speed.
          workers: options[:full] ? nil : 1
        )
        status = runner.call

        # A pass here is a candidate, never a release. One green run doesn't prove anything.
        passed = runner.results.select(&:passed?)
        if passed.any?
          say "\nCandidates for parole (a pass here is not a release):"
          passed.each { |r| say "  constable jail parole #{r.location}    # #{r.display_label}" }
        end
        exit(status)
      end

      desc "parole PATH:LINE", "Move a jailed test to parole -- runs again, but watched"
      def parole(locator)
        act(locator) { |jail, identity| jail.parole(identity) }
        say "Paroled. It runs normally now; one failure sends it straight back."
      end

      desc "release [PATH:LINE]", "Fully release a test, no supervision"
      long_desc <<~DESC
        Takes one test off the docket. `--all` empties it.

        Emptying is the right move after a docket that filled up on its own -- before
        1.4.0 a pass/fail flip jailed a test automatically, and a suite with
        order-dependent tests could put dozens on it that nobody chose. Releasing is safe:
        anything genuinely broken fails again on the next run, in the open.
      DESC
      option :all, type: :boolean, default: false, desc: "Release every test on the docket"
      def release(locator = nil)
        return release_all if options[:all]

        if locator.nil?
          CLI.complain("release needs a PATH:LINE, or --all to empty the docket")
          exit(EXIT_USAGE)
        end

        act(locator) { |jail, identity| jail.release(identity) }
        say "Released."
      end

      no_commands do
        # Emptying the docket in one go. Right after a docket that filled up on its own --
        # before 1.4.0 a pass/fail flip jailed a test automatically, and a suite with
        # order-dependent tests could put dozens on it that nobody chose. Releasing is
        # safe: anything genuinely broken fails again on the next run, in the open.
        def release_all
          jail = Jail.new(config: Constable.config, storage: Constable.storage)
          entries = jail.entries

          if entries.empty?
            say "The docket is already empty."
            return 0
          end

          entries.each { |entry| jail.release(entry.identity) }
          say "Released #{entries.size} #{entries.size == 1 ? "test" : "tests"}. The docket is empty."
          say "Anything genuinely broken will fail on the next run, where you can see it."
          0
        end

        def act(locator)
          jail = Jail.new(config: Constable.config, storage: Constable.storage)
          refuse_ambiguous(locator, jail.candidates(locator), "on the docket")

          identity = jail.resolve(locator)
          unless identity
            CLI.complain("Nothing on the docket at #{locator}")
            exit(EXIT_USAGE)
          end
          yield jail, identity
        end

        # A bare path naming several tests is a question. Answer it with the list rather
        # than acting on whichever row the database happened to return first.
        def refuse_ambiguous(locator, candidates, noun)
          return if candidates.size <= 1

          CLI.complain("#{locator} matches #{candidates.size} tests #{noun}. Name one:")
          candidates.sort_by { |entry| entry.line.to_i }.each do |entry|
            CLI.complain("  #{entry.location}  #{entry.label}")
          end
          exit(EXIT_USAGE)
        end

        def repeat_note(entry)
          count = entry.times_jailed
          count > 1 ? " (this is its #{Reporter.ordinalize(count)} time in jail)" : ""
        end

        def short_date(value) = value.to_s[0, 10]
      end
    end

    # Warrants answer a different question from jail: not "does this block the build" but
    # "is this failure even real."
    class WarrantsCommand < Thor
      def self.exit_on_failure? = true

      default_task :list

      desc "list", "Every test currently under a warrant"
      def list
        warrants = Warrants.new(config: Constable.config, storage: Constable.storage)
        entries = warrants.entries

        if entries.empty?
          say "No warrants outstanding."
          return
        end

        entries.each do |entry|
          say entry.location
          say "  #{entry.label}"
          say "  issued #{entry.issued_at.to_s[0, 10]}, last seen #{entry.last_seen_at.to_s[0, 10]}"
          say ""
        end
      end

      desc "release PATH:LINE", "Clear a warrant by hand"
      def release(locator)
        warrants = Warrants.new(config: Constable.config, storage: Constable.storage)
        JailCommand.new.send(:refuse_ambiguous, locator, warrants.candidates(locator), "under warrant")

        identity = warrants.resolve(locator)
        unless identity
          CLI.complain("No warrant at #{locator}")
          exit(EXIT_USAGE)
        end
        warrants.release(identity)
        say "Warrant cleared."
      end
    end

    # Flake history is keyed by a content hash of the investigate block, so renames carry
    # over on their own. This is for the case where a rename shipped with a real edit.
    class HistoryCommand < Thor
      def self.exit_on_failure? = true

      default_task :show

      desc "show", "Recent runs"
      def show
        storage = Constable.storage
        storage.runs(limit: 20).each do |run|
          say format("%s  seed %-6s %s  %d passed, %d failed",
                     run[:started_at], run[:seed], run[:mode], run[:passed].to_i, run[:failed].to_i)
        end
      end

      desc "relink OLD_HASH NEW_HASH", "Carry a test's history across a real body change"
      def relink(old_hash, new_hash)
        Constable.storage.relink(old_hash, new_hash)
        say "Relinked #{old_hash} -> #{new_hash}. History carried over."
      end
    end

    desc "prepare", "Build the per-worker test databases parallel runs need"
    long_desc <<~DESC
      For `worker_databases: reuse`. Creates `<database>_0` .. `<database>_<N-1>` and
      loads the schema into each, once, so later runs can connect straight to them.

      Only useful for an app that has opted into reuse -- the default `schema` mode
      rebuilds them on every run and needs no preparation. It is the answer for an app
      whose schema cannot rebuild the database by itself: prepare these once, by whatever
      means already works for you, and Constable will use them from then on.
    DESC
    option :workers, type: :numeric, desc: "How many to prepare (default: the configured worker count)"
    def prepare
      config = load_config
      # The app has to be up before we can ask ActiveRecord anything about it.
      Runner.boot!
      config.apply_overrides!(Constable.configuration.overrides)

      unless WorkerDatabases.shardable?
        CLI.complain("This app has no ActiveRecord test databases to prepare.")
        exit(EXIT_USAGE)
      end

      count = (options[:workers] || config.parallel_workers).to_i.clamp(1, 64)
      say "Preparing #{count} worker #{count == 1 ? "database" : "databases"}..."

      count.times do |index|
        built = WorkerDatabases.prepare!(index)
        say "  worker #{index}: #{built.empty? ? "already prepared" : "built #{built.join(", ")}"}"
      end

      say "\nDone. Set `worker_databases: reuse` so runs connect to these instead of " \
          "rebuilding them."
      0
    rescue Constable::Error => e
      CLI.complain(e.message)
      exit(EXIT_FAILED)
    end

    desc "prune", "Forget docket rows and warrants for tests that no longer exist"
    long_desc <<~DESC
      A test's key is a content hash of its body, so editing a jailed test gives it a new
      identity and leaves the old row behind -- pointing at a file:line that may now hold
      something else. That is identity working as designed; this is the broom.

      Loads the whole suite first, because which tests still exist is only knowable once
      every case file has been read. Cold cases are never pruned while their file exists:
      their tests cannot be enumerated without running their own engine, so silence about
      them means nothing.
    DESC
    option :dry_run, type: :boolean, default: false, desc: "List what would go, change nothing"
    def prune
      config = load_config
      known  = Runner.identities(config: config)
      cold   = ->(path) { config.cold_case?(path) }

      jail     = Jail.new(config: config, storage: Constable.storage)
      warrants = Warrants.new(config: config, storage: Constable.storage)

      stale_rows     = jail.stale_entries(known, cold_case: cold)
      stale_warrants = warrants.stale_entries(known, cold_case: cold)

      if stale_rows.empty? && stale_warrants.empty?
        say "Nothing to prune -- every row on the docket still names a test that exists."
        return 0
      end

      report_prunable("docket", stale_rows)
      report_prunable("warrants", stale_warrants)

      if options[:dry_run]
        say "Dry run: nothing was changed."
        return 0
      end

      stale_rows.each { |entry| jail.forget(entry.identity) }
      stale_warrants.each { |entry| warrants.release(entry.identity) }
      say "Pruned #{stale_rows.size + stale_warrants.size} row(s). Flake history is left alone."
      0
    end

    desc "jail SUBCOMMAND", "The jail docket"
    subcommand "jail", JailCommand

    desc "warrants SUBCOMMAND", "Outstanding warrants"
    subcommand "warrants", WarrantsCommand

    desc "history SUBCOMMAND", "Flake history"
    subcommand "history", HistoryCommand

    no_commands do
      def report_prunable(heading, entries)
        return if entries.empty?

        say "#{heading} (#{entries.size}):"
        entries.sort_by { |entry| [entry.file.to_s, entry.line.to_i] }.each do |entry|
          say "  #{entry.location}  #{entry.label}"
        end
        say ""
      end

      def load_config
        Constable.config
      end

      def color?
        return false if options[:"no-color"]
        # The console, not $stdout -- which by now is log/test.log, and a file is never a
        # tty. Asking the wrong one silently turns colour off for everybody.
        return false unless LogRouter.console.tty?
        return false unless ENV["NO_COLOR"].to_s.empty?

        true
      end

      # LogRouter.console, not $stdout: by this point route! has pointed $stdout at
      # log/test.log so a stray gem warning cannot land in the middle of the live stream.
      # The reporter is the one thing that still writes to the terminal.
      def reporter(config)
        Reporter.new(io: LogRouter.console, config: config, color: color?, mode: output_mode)
      end

      # nil means "the config file decides". The explicit --output wins over the two
      # shorthands, and --concise wins over --expanded if somebody passes both -- the
      # quieter of two contradictory instructions is the safer one to obey.
      def output_mode
        return options[:output] if options[:output]
        return :concise if options[:concise]
        return :expanded if options[:expanded]

        nil
      end

      def say_table(heading, entries)
        say heading
        say "─" * heading.length
        if entries.empty?
          say "  (none)"
        else
          entries.each { |entry| say "  #{yield(entry).compact.join("  ")}" }
        end
        say ""
      end

      def jailed_on(entry)
        "jailed #{short_date(entry.jailed_at)}"
      end

      def short_date(value)
        value.to_s[0, 10]
      end

      # The adoption number: what share of the suite is still opted out of native rules.
      # It only means anything as a direction of travel, so it is shown against the run
      # the blotter remembers furthest back.
      def print_adoption(storage, runs)
        totals = storage.kind_totals(limit: runs.size)
        return if totals.empty?

        latest = totals.first
        total = latest[:native] + latest[:cold]
        return if total.zero?

        native_pct = (latest[:native] * 100.0 / total).round
        say_table("ADOPTION", [latest]) do |entry|
          ["#{native_pct}% native", "#{entry[:native]} native", "#{entry[:cold]} cold"]
        end

        oldest = totals.last
        oldest_total = oldest[:native] + oldest[:cold]
        return if oldest_total.zero? || totals.size < 2

        was = (oldest[:native] * 100.0 / oldest_total).round
        say "  #{was}% native #{totals.size} runs ago -> #{native_pct}% now"
        say ""
      end

      def print_recent_runs(runs)
        say_table("RECENT RUNS", runs.first(10)) do |run|
          [
            short_date(run[:started_at]),
            format("%-5s", run[:mode]),
            "#{run[:passed].to_i} passed",
            "#{run[:failed].to_i} failed",
            ("#{run[:jailed].to_i} jailed" if run[:jailed].to_i.positive?)
          ]
        end
      end

      def print_historical_slowest(storage)
        slowest = storage.slowest(limit: 10)
        say_table("SLOWEST, HISTORICALLY", slowest) do |entry|
          [format("%6.2fs", entry[:average].to_f), entry[:label] || entry[:identity]]
        end
      end

      def describe_counts(counts)
        parts = counts.filter_map { |kind, count| "#{count} #{kind}" if count.to_i.positive? }
        parts.empty? ? "nothing to convert" : parts.join(", ")
      end
    end
  end
end
