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
    option :only,     type: :string, enum: %w[native cold rspec minitest],
                      desc: "Narrow by what runs the test: native, cold, rspec or minitest"
    option :jail,     type: :boolean, default: false, desc: "Jail failures instead of failing the build"
    option :warrants, type: :boolean, desc: "Turn the flaky detector on for this run"
    option :coverage, type: :boolean, desc: "Record coverage for this run"
    option :seed,     type: :numeric, desc: "Replay a previous run's order"
    option :timeout,  type: :numeric,
                      desc: "Fail a file that produces no result in N seconds instead of hanging"
    option :workers,  type: :numeric, desc: "Parallel workers (default: config, or auto)"
    option :show,     type: :string,  desc: "Expand collapsed sections: --show warnings"
    option :shard,    type: :string,  desc: "Run one slice of the suite: --shard 3/8 (for a CI matrix)"
    option :"shard-by-time", type: :boolean, default: false,
                             desc: "Weight --shard by duration (needs identical blotter data everywhere)"
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
        only: options[:only],
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
        verbose: options[:verbose],
        shard: shard_from(options[:shard]),
        shard_by_time: options[:"shard-by-time"],
        timeout: options[:timeout]
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

    desc "last", "Everything about the most recent run"
    long_desc <<~DESC
      The post-mortem: when it ran, how it was invoked, what failed, where the time went.

      `constable status` is the trend and `constable metrics` is the lifetime view; this is
      the single run you just did, in enough detail to act on without re-running it.
    DESC
    option :limit, type: :numeric, default: 5, desc: "How many slow tests and failures to list"
    def last
      storage = Constable.storage
      run = storage.runs(limit: 1).first

      if run.nil?
        say "No runs recorded yet. Run: constable test --full"
        exit(EXIT_CLEAN)
      end

      limit = options[:limit].to_i.clamp(1, 50)
      results = storage.results_for_run(run[:id])

      print_run_header(run)
      print_run_failures(results, limit)
      print_run_slowest(results, limit)
      print_run_files(storage, run, limit)
      exit(EXIT_CLEAN)
    end

    desc "metrics", "Lifetime KPIs for the suite"
    long_desc <<~DESC
      What the blotter knows after months of runs: how many there have been, how many tests
      they executed, how much wall-clock time the suite has cost, and which tests have been
      worth the least of it.

      Nothing here is collected specially. Every number is read back out of the same rows
      the runner already writes, which means a suite that has been running for a while
      already has these answers -- nothing had asked for them until now.
    DESC
    option :limit, type: :numeric, default: 10, desc: "Rows per section"
    def metrics
      storage = Constable.storage
      totals = storage.lifetime

      if totals[:runs].to_i.zero?
        say "No runs recorded yet. Run: constable test --full"
        exit(EXIT_CLEAN)
      end

      limit = options[:limit].to_i.clamp(1, 50)
      print_lifetime(totals)
      print_flakiest(storage, limit)
      print_failure_leaders(storage, limit)
      exit(EXIT_CLEAN)
    end

    desc "insights", "What to fix first, and why"
    long_desc <<~DESC
      The prescriptive view. Every line is tied to something measured -- a recorded
      duration, a counted status flip, a parsed construct -- and nothing is printed on a
      hunch. A report that guesses gets ignored, and then so does the one that does not.
    DESC
    def insights
      storage = Constable.storage
      run = storage.runs(limit: 1).first

      if run.nil?
        say "No runs recorded yet. Run: constable test --full"
        exit(EXIT_CLEAN)
      end

      findings = Insights.new(storage: storage, config: load_config, run: run).call

      if findings.empty?
        say "Nothing to suggest -- no flakes, no runaway files, nothing jailed."
        exit(EXIT_CLEAN)
      end

      say "INSIGHTS"
      say "─" * 8
      say ""
      findings.each do |finding|
        say "  #{finding[:headline]}"
        finding[:detail].to_s.split("\n").each { |line| say "    #{line}" }
        say ""
      end
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
    option :cold, type: :boolean, default: false,
                  desc: "Move it verbatim as a cold case instead of converting"
    option :limit, type: :numeric,
                   desc: "How many files to LIST in the output. Does not change what is ported"
    option :batch, type: :numeric,
                   desc: "Port only the first N files. With --delete, run again for the next N"
    option :plan, type: :boolean, default: false,
                  desc: "Show what a --port would do -- destinations, forms, blockers, runtime -- and write nothing"
    option :delete, type: :boolean,
                    desc: "With --port: remove the original after it has been written"
    option :base, type: :string,
                  desc: "Superclass for converted cases (e.g. UnitCase). Default: Constable::Case"
    option :port, type: :boolean,
                  desc: "Write into test/cases/, mirroring the spec path"
    option :"show-source", type: :boolean, default: false, desc: "Print the rewritten source"
    def modernize(*paths)
      if paths.empty?
        CLI.complain("modernize needs at least one path")
        exit(EXIT_USAGE)
      end

      config = load_config
      # A flag beats the file. The file says what this project does by default; the flag
      # says what this invocation does instead.
      # `options.key?` is the test, not truthiness: `--no-port` must be able to switch off
      # what the config turned on. Thor only includes these keys when they were actually
      # given, because neither declares a default -- one that did would make absence
      # indistinguishable from an explicit false, and the config could never win.
      port = options.key?("port") ? options[:port] : config.modernize_port?
      delete = options.key?("delete") ? options[:delete] : config.modernize_delete?
      base = options[:base] || config.modernize_base
      batch = options[:batch] || config.modernize_batch

      # --port --cold is a real combination, not a conflict: it means "move this file into
      # the native tree even though it cannot be converted", which is how a port finishes
      # the last mile instead of stalling on the files that need a human.
      mode = if port && options[:cold] then :port_cold
             elsif port then :port
             elsif options[:"in-place"] then :in_place
             elsif options[:cold] then :cold
             elsif options[:alongside] then :alongside
             else :none
             end

      # Only a port moves a file, so only a port can finish the move. Deleting a spec
      # after an --alongside or a dry run would remove a test nothing had copied.
      if delete && !%i[port port_cold].include?(mode)
        CLI.complain("--delete only makes sense with --port; nothing else moves the file.")
        exit(EXIT_USAGE)
      end

      # A plan never writes, whatever else was asked for. Someone who types `--plan --port
      # --delete` wants to see the deletions, not perform them.
      mode = :none if options[:plan]

      run = Importer.modernize(paths, config: config, write: mode, base: base,
                                      delete_original: delete && !options[:plan],
                                      batch: batch)

      if options[:plan]
        print_port_plan(run, delete: delete, base: base)
        exit(run.ok? ? EXIT_CLEAN : EXIT_FAILED)
      end

      print_modernize_results(run)
      if mode == :none
        say "\nNothing was written. Re-run with --port (into test/cases/), --alongside or " \
            "--in-place."
      end
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
        Reporter.new(io: LogRouter.console, config: config, color: color?, mode: output_mode,
                     show: options[:show])
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

      # Colour, for the reports that are read rather than parsed.
      #
      # Padding happens before painting, always: an ANSI escape is zero columns wide but
      # several characters long, so `format("%-40s", painted)` pads to the wrong width and
      # every column after it staggers.
      def ansi_codes
        { bold: 1, dim: 2, red: 31, green: 32, yellow: 33, cyan: 36 }
      end

      def paint(text, *styles)
        codes = styles.flatten.filter_map { |style| ansi_codes[style] }
        return text.to_s if codes.empty? || !color?

        "\e[#{codes.join(";")}m#{text}\e[0m"
      end

      # The directory every path in a set shares, so it can be said once in a heading
      # instead of repeated on sixty-five rows that then wrap.
      def common_directory(paths)
        return nil if paths.size < 2

        parts = paths.map { |path| File.dirname(path).split("/") }
        shared = parts.reduce { |a, b| a.take_while.with_index { |seg, i| seg == b[i] } }
        return nil if shared.nil? || shared.empty?

        shared.join("/")
      end

      # Asking for more rows than exist is the same as asking for all of them, so the
      # ceiling is the collection itself and `--limit <size>` always means everything.
      def listing_limit(requested, available)
        requested.to_i.clamp(1, [available, 1].max)
      end

      def shard_from(spec)
        Shard.parse(spec)
      rescue Constable::Error => e
        CLI.complain(e.message)
        exit(EXIT_USAGE)
      end

      # --- modernize output ----------------------------------------------------------
      #
      # One line per file, and the per-flag detail behind a flag.
      #
      # It used to print every flagged construct inline, which on a real directory was
      # thousands of lines with the same `let!` sentence repeated three hundred times --
      # long enough that the summary scrolled away and nobody could see what had actually
      # moved. The detail is not lost: it is in the report file, grouped and explained
      # once, which is a better place to read two hundred occurrences of anything.

      def print_modernize_results(run)
        processed, failed = run.results.partition(&:ok?)

        print_modernize_files(processed)
        print_modernize_failures(failed)
        print_modernize_blockers(processed)
        print_modernize_summary(run, processed, failed)
      end

      def print_modernize_files(results)
        return if results.empty?

        # Clamped to what exists, not to an arbitrary ceiling: the hint below prints the
        # exact number that shows everything, and a ceiling would make that number a lie
        # on any directory larger than it. One real suite has 1,277 spec files.
        rows = results.first(listing_limit(options[:limit] || 40, results.size))
        say_table("FILES", rows) do |result|
          [modernize_glyph(result), modernize_name(result), modernize_outcome(result)]
        end
        return unless results.size > rows.size

        say "  #{paint("... and #{results.size - rows.size} more processed but not listed " \
                       "(--limit #{results.size} to list them all)", :dim)}"
        say ""
      end

      # Converted cleanly, moved verbatim, or reported only.
      def modernize_glyph(result)
        return paint("·", :dim) unless result.written_to
        return paint("○", :yellow) if result.written_as == :cold

        paint("✓", :green)
      end

      def modernize_name(result)
        format("%-52s", truncate_label(result.relative_path, 52))
      end

      def modernize_outcome(result)
        counts = result.counts
        return "#{counts[:converted]} converted, #{counts[:flagged]} blocked" unless result.written_to

        form = result.written_as == :cold ? "verbatim" : "converted"
        blocked = counts[:flagged].positive? ? " (#{counts[:flagged]} blockers)" : ""
        moved = result.removed_original ? ", original removed" : ""
        "#{form}#{blocked}#{moved}"
      end

      def print_modernize_failures(failed)
        return if failed.empty?

        say_table("NOT CONVERTED (#{failed.size})", failed) do |result|
          [result.relative_path, result.error.to_s]
        end
      end

      # The same table the report leads with. Two hundred occurrences of one construct is
      # the useful fact; two hundred lines saying so is not.
      def print_modernize_blockers(results)
        counts = results.flat_map { |r| Array(r.flags) }
                        .group_by { |f| f[:kind] }
                        .transform_values(&:size)
                        .sort_by { |_, n| -n }
        return if counts.empty?

        total = counts.sum { |_, n| n }
        say_table("WHAT IS BLOCKING CONVERSION", counts.first(8)) do |kind, count|
          share = (count * 100.0 / total).round
          [paint(format("%5d", count), :bold),
           paint(format("%3d%%", share), :dim),
           paint(kind.to_s, share >= 25 ? :yellow : :cyan)]
        end
      end

      def print_modernize_summary(run, processed, failed)
        converted = processed.count { |r| r.written_as == :native }
        verbatim = processed.count { |r| r.written_as == :cold }
        removed = processed.count(&:removed_original)

        say "SUMMARY"
        say "─" * 7
        if run.written.any?
          say "  #{run.written.size} file(s) written -- #{converted} converted, #{verbatim} verbatim"
          say "  #{removed} original(s) removed" if removed.positive?
        else
          say "  nothing written (add --port, --alongside or --in-place)"
        end
        say "  #{failed.size} file(s) could not be processed" if failed.any?
        if Array(run.carried).any?
          say "  #{Array(run.carried).size} support file(s) copied alongside " \
              "(required by relative path)"
        end
        if Array(run.excluded).any?
          say "  #{Array(run.excluded).size} original(s) excluded in the cold_cases block " \
              "so they don't run twice (the port kept them; --delete removes them instead)"
        end
        if run.remaining.to_i.positive?
          say "  #{paint("#{run.remaining} file(s) left in this directory -- run the same command " \
                         "again for the next batch", :cyan)}"
        end
        say "  full detail, with guidance per construct: #{run.report_path}" if run.report_path
        say ""
      end

      # --- port plan ---------------------------------------------------------------

      def print_port_plan(run, delete:, base:)
        plan = PortPlan.new(run.results, storage: Constable.storage, root: Constable.root,
                                         delete: delete, base: base)

        print_plan_headline(plan)
        print_plan_files(plan)
        print_plan_blockers(plan)
        print_plan_runtime(plan)
        print_plan_footer(plan)
      end

      def print_plan_headline(plan)
        say_table("PORT PLAN", [plan]) do |p|
          [paint("#{p.entries.size} files", :bold),
           paint("#{p.native} convert", :green),
           paint("#{p.cold} move verbatim", :yellow),
           paint("base #{p.base || "Constable::Case"}", :dim)]
        end
      end

      def print_plan_files(plan)
        # A port is usually a whole directory, so the default shows enough of it to check
        # the destinations look right without printing four hundred lines.
        limit = listing_limit(options[:limit] || 25, plan.entries.size)
        rows = plan.entries.first(limit)

        # Every row carried its full source and destination, both of which usually share a
        # directory with every other row -- so two long prefixes were repeated sixty-five
        # times and the lines wrapped. Said once here instead.
        from = common_directory(rows.map(&:source))
        into = common_directory(rows.map(&:destination))

        say "WHAT MOVES WHERE"
        say "─" * 16
        say "  #{paint("#{from} → #{into}", :dim)}" if from && into
        say ""
        rows.each { |entry| say "  #{plan_row(entry, from, into)}" }
        say ""
        return unless plan.entries.size > limit

        # The number that shows everything is already known here, so print it rather than
        # an N the reader has to work out.
        hint = "... and #{plan.entries.size - limit} more in this plan but not listed " \
               "(--limit #{plan.entries.size} to list them all)"
        say "  #{paint(hint, :dim)}"
        say ""
      end

      def plan_row(entry, from, into)
        form = entry.form == :cold ? "verbatim " : "converted"
        source = from ? entry.source.delete_prefix("#{from}/") : entry.source
        dest = into ? entry.destination.delete_prefix("#{into}/") : entry.destination
        blocked = entry.flags.positive? ? paint(" (#{entry.flags})", :dim) : ""

        "#{paint(form, entry.form == :cold ? :yellow : :green)}  " \
          "#{format("%-52s", truncate_label(source, 52))}#{paint("→ ", :dim)}#{paint(dest, :dim)}#{blocked}"
      end

      def print_plan_blockers(plan)
        return if plan.blockers.empty?

        total = plan.blockers.sum { |_, n| n }
        say_table("WHY THE VERBATIM ONES CANNOT CONVERT", plan.blockers.first(6)) do |kind, n|
          share = (n * 100.0 / total).round
          [paint(format("%5d", n), :bold),
           paint(format("%3d%%", share), :dim),
           paint(kind.to_s, share >= 25 ? :yellow : :cyan)]
        end
      end

      # The estimate is of the tests, not of the port, and it only exists for files this
      # blotter has actually seen run. Saying "unknown" for the rest is the honest answer;
      # extrapolating from the measured ones would invent a number and present it in the
      # same typeface as a measured one.
      def print_plan_runtime(plan)
        if plan.measured.empty?
          say "ESTIMATED RUNTIME"
          say "─" * 17
          say "  no recorded durations for these files yet -- run them once and ask again"
          say ""
          return
        end

        say_table("ESTIMATED RUNTIME", [plan]) do |p|
          if p.projected_seconds
            [paint(human_seconds(p.projected_seconds), :bold, :cyan),
             "across #{p.total_tests} tests",
             paint("measured from #{p.measured.size} of #{p.entries.size} files", :dim)]
          else
            [paint("#{human_seconds(p.total_seconds)} of test time", :bold, :cyan),
             "across #{p.total_tests} tests",
             paint("measured from #{p.measured.size} of #{p.entries.size} files", :dim)]
          end
        end

        if plan.projected_seconds
          say "  #{human_seconds(plan.total_seconds)} of that is the test bodies. The rest is boot, " \
              "file loading, suite"
          say "  hooks and cleaning between examples -- #{format("%.2fs", plan.overhead[:seconds])} " \
              "per test, measured from your largest"
          say "  recorded run (#{plan.overhead[:sample]} tests)."
        else
          say "  That is the sum of the test bodies only. Loading files, suite hooks and cleaning"
          say "  between examples are not in it, and on a real suite they were the larger half --"
          say "  run the suite once so the overhead can be measured rather than guessed."
        end
        say ""
        return if plan.unmeasured.empty?

        say "  #{plan.unmeasured.size} file(s) have never run here, so they are not in that total"
        say ""
      end

      def print_plan_footer(plan)
        say "Nothing was written."
        removals = plan.delete ? " and remove #{plan.entries.size} original(s)" : ""
        say "Re-run without --plan to write #{plan.entries.size} file(s)#{removals}."
      end

      # --- last / metrics --------------------------------------------------------

      def print_run_header(run)
        pieces = [
          "#{run[:passed].to_i} passed",
          "#{run[:failed].to_i} failed",
          ("#{run[:skipped].to_i} skipped" if run[:skipped].to_i.positive?),
          ("#{run[:jailed].to_i} jailed" if run[:jailed].to_i.positive?)
        ].compact

        say_table("LAST RUN", [run]) do |r|
          [short_date(r[:started_at]), format("%-5s", r[:mode]), "seed #{r[:seed]}",
           human_seconds(r[:duration]), pieces.join(", ")]
        end
      end

      def print_run_failures(results, limit)
        # Both, because Result#failed? counts both -- an errored test is a failed one
        # that did not get as far as an assertion.
        failures = results.select { |r| %w[failed errored].include?(r[:status].to_s) }
        return if failures.empty?

        say_table("FAILED (#{failures.size})", failures.first(limit)) do |r|
          [truncate_label(r[:label] || r[:description]), "#{r[:file]}:#{r[:line]}"]
        end
      end

      def print_run_slowest(results, limit)
        timed = results.select { |r| r[:duration] }
        return if timed.empty?

        say_table("SLOWEST TESTS", timed.first(limit)) do |r|
          [format("%8s", human_seconds(r[:duration])), truncate_label(r[:label] || r[:description])]
        end
      end

      # Per file rather than per test, because that is the unit someone actually opens.
      def print_run_files(storage, run, limit)
        files = storage.slowest_files(run[:id], limit: limit)
        return if files.empty?

        # Against the sum of test durations, not the clock: with workers the tests add up
        # to more than the run took, and a percentage of wall time can exceed 100%.
        total = storage.total_test_seconds(run[:id])
        say_table("SLOWEST FILES", files) do |f|
          share = total.positive? ? " (#{(f[:total].to_f * 100 / total).round}%)" : ""
          [format("%8s", human_seconds(f[:total])) + share,
           "#{f[:tests].to_i} tests", f[:file]]
        end
      end

      def print_lifetime(totals)
        runs = totals[:runs].to_i
        tests = totals[:tests].to_i
        passed = totals[:passed].to_i
        rate = tests.positive? ? "#{(passed * 100.0 / tests).round(1)}%" : "n/a"

        timed = totals[:timed_runs].to_i
        runtime = if timed.zero?
                    "runtime not recorded yet"
                  elsif timed < runs
                    "#{human_seconds(totals[:seconds])} of runtime (#{timed} of #{runs} runs timed)"
                  else
                    "#{human_seconds(totals[:seconds])} of runtime"
                  end

        say_table("LIFETIME", [totals]) do |_t|
          ["#{runs} #{pluralize_word(runs, "run")}", "#{tests} tests executed",
           "#{rate} passed", runtime]
        end
        say "  first run #{short_date(totals[:first_run])}, " \
            "most recent #{short_date(totals[:last_run])}"
        say ""
      end

      def print_flakiest(storage, limit)
        flaky = storage.flakiest(limit: limit)
        return if flaky.empty?

        say_table("FLAKIEST", flaky) do |f|
          ["#{f[:failures].to_i}/#{f[:runs].to_i} failed",
           truncate_label(f[:label]), "#{f[:file]}:#{f[:line]}"]
        end
      end

      def print_failure_leaders(storage, limit)
        leaders = storage.failure_leaders(limit: limit)
                         .select { |r| r[:failures].to_i == r[:runs].to_i }
        return if leaders.empty?

        say_table("NEVER PASSED", leaders) do |f|
          ["#{f[:runs].to_i} #{pluralize_word(f[:runs].to_i, "run")}",
           truncate_label(f[:label]), "#{f[:file]}:#{f[:line]}"]
        end
      end

      def pluralize_word(count, word) = count == 1 ? word : "#{word}s"

      def human_seconds(value)
        seconds = value.to_f
        return format("%.0fms", seconds * 1000) if seconds.positive? && seconds < 1
        return format("%.1fs", seconds) if seconds < 60

        format("%dm %02ds", seconds.to_i / 60, seconds.to_i % 60)
      end

      def truncate_label(label, width = 58)
        text = label.to_s
        text.length > width ? "#{text[0, width - 1]}…" : text
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
