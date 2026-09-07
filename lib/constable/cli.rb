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
    rescue Thor::Error => e
      warn e.message
      exit(EXIT_USAGE)
    rescue Interrupt
      warn "\ninterrupted"
      exit(EXIT_FAILED)
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

      say result.summary
      say "\nNothing was rewritten -- cold cases run through their own engine, unchanged." if result.any_changes?
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
        warn "modernize needs at least one path"
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

      desc "release PATH:LINE", "Fully release a test, no supervision"
      def release(locator)
        act(locator) { |jail, identity| jail.release(identity) }
        say "Released."
      end

      no_commands do
        def act(locator)
          jail = Jail.new(config: Constable.config, storage: Constable.storage)
          identity = jail.identity_for(locator)
          unless identity
            warn "Nothing on the docket at #{locator}"
            exit(EXIT_USAGE)
          end
          yield jail, identity
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
        identity = warrants.identity_for(locator)
        unless identity
          warn "No warrant at #{locator}"
          exit(EXIT_USAGE)
        end
        warrants.clear(identity)
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

    desc "jail SUBCOMMAND", "The jail docket"
    subcommand "jail", JailCommand

    desc "warrants SUBCOMMAND", "Outstanding warrants"
    subcommand "warrants", WarrantsCommand

    desc "history SUBCOMMAND", "Flake history"
    subcommand "history", HistoryCommand

    no_commands do
      def load_config
        Constable.config
      end

      def color?
        return false if options[:"no-color"]
        return false unless $stdout.tty?
        return false unless ENV["NO_COLOR"].to_s.empty?

        true
      end

      def reporter(config)
        Reporter.new(io: $stdout, config: config, color: color?)
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
