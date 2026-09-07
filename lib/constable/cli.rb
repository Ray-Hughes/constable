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

      say_table("JAILED", jail.entries.reject { |e| e[:state].to_s == "parole" }) do |entry|
        ["#{entry[:file]}:#{entry[:line]}", entry[:label], entry[:reason], jailed_on(entry)]
      end

      say_table("ON PAROLE", jail.entries.select { |e| e[:state].to_s == "parole" }) do |entry|
        clean = "#{entry[:parole_clean_runs].to_i}/#{config.parole_period} clean"
        ["#{entry[:file]}:#{entry[:line]}", entry[:label], clean, jailed_on(entry)]
      end

      say_table("WARRANTS", warrants.entries) do |entry|
        ["#{entry[:file]}:#{entry[:line]}", entry[:label], "issued #{short_date(entry[:issued_at])}"]
      end

      exit(EXIT_CLEAN)
    end

    desc "status", "How the suite is doing over time"
    def status
      config = load_config
      storage = Constable.storage
      Reporter.new(io: $stdout, config: config, color: color?).status(
        runs: storage.runs(limit: 30),
        slowest: storage.slowest(limit: 10),
        coverage: (storage.coverage_trend(limit: 30) rescue []) # rubocop:disable Style/RescueModifier
      )
      exit(EXIT_CLEAN)
    end

    desc "beat", "Coverage: overall %, per-file breakdown and the unpatrolled list"
    option :html, type: :boolean, default: false, desc: "Write a browsable HTML report"
    def beat
      config = load_config
      report = Constable::Coverage.load_last(config: config)
      unless report
        say "No coverage recorded yet. Run: constable test --full --coverage"
        exit(EXIT_FAILED)
      end

      say report.to_s
      if options[:html] || config.coverage_html?
        path = report.write_html
        say "\nHTML report: #{path}"
      end
      exit(EXIT_CLEAN)
    end

    desc "import", "Adopt an existing suite as cold cases -- verbatim, nothing rewritten"
    option :from, type: :string, required: true, enum: %w[rspec minitest], desc: "Source framework"
    option :strategy, type: :string, default: "config", enum: %w[config superclass],
                      desc: "config: no file changes at all. superclass: one line per file"
    option :"dry-run", type: :boolean, default: false, desc: "Show what would change"
    def import
      config = load_config
      result = Importer.run(
        from: options[:from].to_sym,
        config: config,
        dry_run: options[:"dry-run"],
        strategy: options[:strategy].to_sym
      )
      say result.to_s
      exit(EXIT_CLEAN)
    end

    desc "modernize PATH", "Opt-in AST rewrite of one file into the native DSL"
    option :"dry-run", type: :boolean, default: false, desc: "Show the rewrite without writing it"
    def modernize(path)
      config = load_config
      outcome = Importer::Modernizer.new(path, config: config).call

      if options[:"dry-run"]
        say outcome[:source]
      else
        File.write(path, outcome[:source])
        say "Rewrote #{path}"
      end

      if outcome[:flags].any?
        say "\nFlagged for a human decision:"
        outcome[:flags].each { |flag| say "  #{flag}" }
        say "\nSee constable_modernize_report.md"
      end
      exit(EXIT_CLEAN)
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
          state = entry[:state].to_s == "parole" ? "on parole" : "jailed"
          say format("%-8s %s:%s", state, entry[:file], entry[:line])
          say "         #{entry[:label]}"
          say "         #{entry[:reason]}"
          say "         jailed #{entry[:jailed_at]}#{repeat_note(entry)}"
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
        targets = path ? [path] : jail.entries.map { |e| "#{e[:file]}:#{e[:line]}" }

        if targets.empty?
          say "The docket is empty."
          return
        end

        selection = Selection.new(targets, config: config, root: Constable.root, full: true)
        runner = Runner.new(
          selection: selection,
          config: config,
          storage: storage,
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
          count = entry[:times_jailed].to_i
          count > 1 ? " (this is its #{Reporter.ordinalize(count)} time in jail)" : ""
        end
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
          say format("%s:%s", entry[:file], entry[:line])
          say "  #{entry[:label]}"
          say "  issued #{entry[:issued_at]}, last seen #{entry[:last_seen_at]}"
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
          entries.each { |entry| say "  #{yield(entry).compact.join('  ')}" }
        end
        say ""
      end

      def jailed_on(entry)
        "jailed #{short_date(entry[:jailed_at])}"
      end

      def short_date(value)
        value.to_s[0, 10]
      end
    end
  end
end
