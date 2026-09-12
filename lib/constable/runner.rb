# frozen_string_literal: true

require "securerandom"
require "timeout"

module Constable
  # Executes a selection and turns it into results.
  #
  # Ordering is random every run, because a suite that only passes in one order is a suite
  # that will fail the first time anything is added to it. The seed is always printed and
  # always replayable. Cold cases are exempt -- they keep whatever order their own engine
  # chose, since reordering someone's untouched legacy file is exactly the kind of surprise
  # the cold-case story exists to avoid.
  class Runner
    # Thresholds for "this run is broken, not these tests" -- see #systemic_failure.
    SYSTEMIC_MINIMUM   = 5    # below this it is cheaper to believe the tests
    SYSTEMIC_SHARE     = 0.25 # of the whole run
    SYSTEMIC_AGREEMENT = 0.8  # of the failures, failing identically

    # `failed` rather than `count` or `tally`, both of which override an Enumerable method.
    Systemic = Struct.new(:exception_class, :failed, :total, keyword_init: true)

    # One unit of work. Native items are a single investigation; cold items are a whole
    # file, because their engine owns the granularity inside it.
    # What an engine writes when our interrupt reaches it before we do.
    TIMEOUT_MESSAGE = /Timeout::(?:Error|ExitException)|execution expired/

    class Item
      attr_reader :investigation, :path, :kind

      def initialize(investigation: nil, path: nil, kind: :native)
        @investigation = investigation
        @path = path
        @kind = kind
      end

      def native? = @kind == :native
      def cold?   = @kind == :cold
      def identity = native? ? @investigation.identity : Identity.for_cold_case(@path, "file")
      def label = native? ? @investigation.display_label : @path.to_s
    end

    attr_reader :config, :selection, :reporter, :storage, :seed, :results, :coverage_report

    def initialize(selection:, config: Constable.config, reporter: nil, storage: nil,
                   seed: nil, jail_mode: false, jail_run: false, warrants: nil, coverage: nil,
                   workers: nil, verbose: false, shard: nil, shard_by_time: false,
                   timeout: nil, io: $stdout)
      @selection  = selection
      @config     = config
      @storage    = storage || Constable.storage
      @seed       = (seed || ENV["CONSTABLE_SEED"] || SecureRandom.random_number(10_000)).to_i
      @jail_mode  = jail_mode
      @jail_run   = jail_run
      @warrants_requested = warrants.nil? ? config.warrants? : warrants
      @coverage_requested = coverage.nil? ? config.coverage? : coverage
      @workers    = workers
      @verbose    = verbose
      @shard      = shard
      @shard_by_time = shard_by_time
      @timeout    = (timeout || config.timeout).to_i
      @io         = io
      @reporter   = reporter || Reporter.new(io: io, config: config)
      @results    = []
      @worker_coverage = {}
      @warnings_before = Constable.warnings.size
    end

    def jail_mode?  = @jail_mode

    # `constable jail run` exists precisely to run the bodies the docket normally skips.
    def jail_run?   = @jail_run
    def coverage?   = @coverage_requested

    # Boots the app the way a run does -- test/case_helper.rb, which requires
    # config/environment -- without selecting or running anything.
    #
    # `constable prepare` needs this: it asks ActiveRecord what databases exist, and
    # before the helper has run there is no ActiveRecord to ask. It reported "this app has
    # no test databases to prepare" on an app with three of them.
    def self.boot!
      helper = %w[test/case_helper.rb spec/case_helper.rb]
               .map { |p| File.join(Constable.root, p) }
               .find { |p| File.exist?(p) }
      require helper if helper
      helper
    end

    # Loads every case file and hands back the identities the suite actually defines,
    # without running anything. `constable prune` needs this: which tests still exist is
    # only knowable once the whole suite has been loaded.
    def self.identities(config: Constable.config)
      selection = Selection.new([], config: config, root: Constable.root, full: true)
      runner = new(selection: selection, config: config,
                   reporter: Reporter.new(io: StringIO.new, config: config, color: false),
                   storage: Constable.storage, workers: 1)
      runner.send(:load_suite!)
      Constable.registry.disambiguate_identities!
      Constable.registry.investigations.map(&:identity)
    end

    # => Integer exit status (0 clean, 1 failures)
    def call
      # Before anything is loaded: Coverage only counts files required after it starts, so
      # starting it any later measures an empty application and reports a confident 100%.
      # force:, because #coverage? has already folded --coverage together with the config
      # setting, and asking the config again would throw the flag away.
      Constable::Coverage.start!(config: @config, force: true) if coverage?

      load_suite!
      # Before anything is keyed on an identity -- selection, the docket, flake history --
      # settle any two tests that happen to share a body.
      Constable.registry.disambiguate_identities!
      items = shard_of(build_items)
      refuse_empty_selection!(items)
      ordered = order(items)

      run_id = @storage.start_run(seed: @seed, mode: mode_label, full: @selection.full?)
      Constable.configuration.run_before_suite!

      started = monotonic
      # A cold-case file is one work item but an unknown number of tests until its own
      # engine has run it, so claim a total only when every item is a native investigation.
      warn_about_tight_timeout!(ordered)
      announced = ordered.all?(&:native?) ? ordered.size : nil
      @reporter.start(total: announced, seed: @seed, forecast: forecast_for(ordered))

      # The "alone" half of the order audit has to happen before the suite has touched
      # anything, so it runs here rather than alongside the results it will be compared to.
      order_audit.record_isolated!(ordered.select(&:native?).map(&:investigation))

      # Warm everything that reads the blotter while we are still single-process.
      docket_snapshot
      duration_index
      known_before

      raw = order_audit.audit(execute(ordered)) + load_error_results

      @results = adjudicate(raw)
      duration = monotonic - started

      # Cold-case engines hold a live session -- for RSpec that is a configuration
      # carrying `after(:suite)` hooks that have not fired yet. Tear it down before our
      # own after_suite so the engine's cleanup runs inside the suite, not after it.
      ColdCase.reset_engines!
      Constable.configuration.run_after_suite!
      @coverage_report = build_coverage_report if coverage?

      persist(run_id, @results, @coverage_report, duration: duration)
      suggestions = rename_suggestions(@results)

      @reporter.finish(
        results: @results,
        duration: duration,
        seed: @seed,
        coverage: @coverage_report,
        suggestions: suggestions,
        history: failure_history(@results)
      )

      exit_status(@results, @coverage_report)
    end

    private

    def mode_label
      return "jail_run" if jail_run?
      return "jail" if jail_mode?
      return @selection.only.to_s if @selection.only

      @selection.full? ? "full" : "diff"
    end

    # test/case_helper.rb is the app's own entry point -- it boots Rails, defines the tier
    # base classes and loads support files. Everything else depends on it having run.
    def load_suite!
      add_suite_dirs_to_load_path!

      helper = %w[test/case_helper.rb spec/case_helper.rb].map { |p| File.join(Constable.root, p) }
                                                          .find { |p| File.exist?(p) }
      require helper if helper

      # Between requiring the helper and asking the selection anything.
      #
      # Ordering is the whole point. case_helper.rb is where Constable.configure runs, so
      # its settings do not exist until the line above. But Selection memoizes its targets
      # the first time it is asked for them, and `cold_cases` is one of the settings people
      # will most want to set in Ruby -- ask first and the override arrives too late to
      # matter, silently. Requiring the helper needs no selection, so this fits between.
      @config.apply_overrides!(Constable.configuration.overrides)

      @selection.native_targets.each { |target| load_case_file(target.path) }
      helper
    end

    # Case files open with `require "case_helper"`, the way an RSpec file opens with
    # `require "rails_helper"`. That only resolves if the suite directory is on the load
    # path, and nothing else puts it there.
    def add_suite_dirs_to_load_path!
      %w[test spec].each do |dir|
        path = File.join(Constable.root, dir)
        $LOAD_PATH.unshift(path) if File.directory?(path) && !$LOAD_PATH.include?(path)
      end
    end

    def load_case_file(path)
      require path
    rescue StandardError, ScriptError => e
      load_errors << [path, e]
    end

    def load_errors
      @load_errors ||= []
    end

    # A case file that will not load is a failure, not a silence. Reporting it as a result
    # puts it in the FAILURES section with its own error, instead of letting a whole file
    # of tests quietly vanish from the run.
    def load_error_results
      load_errors.map do |path, error|
        relative = path.to_s.delete_prefix("#{Constable.root}/")
        result = Result.new(
          identity: Identity.for_source("load-error:#{relative}"),
          case_name: relative,
          description: "could not be loaded",
          file: relative,
          line: 1,
          kind: :native,
          status: :errored,
          failure: Failure.from_exception(error, context: "This file never ran. Nothing in it was tested.")
        )
        result.seed = @seed
        result
      end
    end

    # A run that was *asked* for something specific and found nothing is a usage error, not
    # a pass. `constable test test/cases/typo_case.rb` used to print "0 passed, 0 failed"
    # and exit 0, so a mistyped path in a CI script produced a green build that ran no
    # tests at all. A full run with an empty suite is a different thing and stays quiet.
    def refuse_empty_selection!(items)
      return unless items.empty?
      return unless @selection.explicit?
      # A file that raised while loading registers no investigations, so the selection
      # comes back empty and this guard would report "no tests matched" -- burying the
      # actual error, which is already captured and about to be reported as a failure.
      # "Your path is wrong" is the wrong thing to say about a file that is right there
      # and broken.
      return if load_errors.any?

      raise Constable::Error, @selection.empty_selection_message
    end

    def build_items
      native = native_items
      cold = @selection.cold_targets_selected.map { |t| Item.new(path: t.path, kind: :cold) }
      native + cold
    end

    def native_items
      @selection.native_targets.flat_map do |target|
        investigations = Constable.registry.investigations_in(target.path)
        investigations = narrow_to_line(investigations, target.line) if target.line
        investigations.map { |inv| Item.new(investigation: inv) }
      end
    end

    # PATH:LINE means "the investigation at that line" -- but developers point at any line
    # inside the block, so pick the investigation whose declaration is nearest above it.
    #
    # Bounded by the end of the file. Unbounded, `:999` on a twenty-line file quietly ran
    # the last investigation in it: not the test the user asked for, not an error, and
    # green either way. A line past the end is a typo, and no answer beats a wrong one.
    def narrow_to_line(investigations, line)
      exact = investigations.select { |inv| inv.line == line }
      return exact if exact.any?
      return [] unless line_within_file?(investigations.first, line)

      nearest = investigations.select { |inv| inv.line <= line }.max_by(&:line)
      nearest ? [nearest] : []
    end

    def line_within_file?(investigation, line)
      path = investigation&.file
      return false if path.nil?

      path = File.join(@config.root, path) unless File.exist?(path)
      return false unless File.exist?(path)

      line <= File.foreach(path).count
    end

    def order(items)
      native, cold = items.partition(&:native?)
      [*native.shuffle(random: Random.new(@seed)), *cold]
    end

    def execute(items)
      return [] if items.empty?

      items = group_by_case(items)
      count = worker_count(items)
      if count > 1 && forkable? && parallel_safe?(count)
        run_parallel(items, count)
      else
        run_serial(items)
      end
    end

    # Here rather than only in #balance, because #balance is the parallel path and a serial
    # run never reaches it. That was the whole bug: the grouping landed, the tests passed,
    # and the suite it was written for runs serially -- so the repetition it was meant to
    # fix was still there on screen, unchanged.
    #
    # Stable within a group and across groups, so `--seed` still replays an order.
    def group_by_case(items)
      items.group_by { |item| scheduling_group(item) }.values.flatten(1)
    end

    # Forking is only safe once each worker has a database of its own. Without that,
    # every worker opens the same one: on SQLite the run dissolves into "database is
    # locked", and on a client/server database the tests quietly see each other's rows,
    # which is worse. An app with no ActiveRecord has nothing to shard and is always safe.
    #
    # When we cannot shard, we run serially and say why. Slow is a trade-off; wrong is not.
    def parallel_safe?(count)
      # An explicit opt-out. No attempt, and no warning about one -- the user has already
      # told us they know.
      return false if @config.worker_databases == :off
      return true unless WorkerDatabases.active_record?

      unless WorkerDatabases.shardable?
        Constable.warn!(
          "parallel workers need one database per worker, and this app's ActiveRecord " \
          "cannot provide them (active_record/test_databases did not load). Running " \
          "serially instead -- pass --workers N once that is available.",
          kind: :parallel
        )
        return false
      end

      warn_about_shared_databases!
      worker_databases_current?(count)
    end

    # A database Constable could not shard is shared by every worker, and that is worth
    # saying out loud before the run rather than leaving it to be deduced from the wreckage.
    #
    # The failures it causes do not look like a parallelism problem. They look like records
    # disappearing mid-test: worker 2's `before(:suite)` cleans the shared legacy database
    # while worker 1 is halfway through a test that just created rows in it. Measured on a
    # real suite -- 53 `VacolsRecordNotFound` failures across four workers, every one of
    # them passing serially.
    def warn_about_shared_databases!
      shared = WorkerDatabases.unshardable_databases
      return if shared.empty?

      Constable.warn!(
        "#{shared.join(", ")} cannot be given to each worker, so all of them share it. " \
        "Tests that write to it will interfere with each other, and the failures will not " \
        "look like a parallelism problem -- they look like rows vanishing mid-test. Run " \
        "specs that touch it serially (`--workers 1`), or `worker_databases: off`.",
        kind: :parallel
      )
    end

    # `:reuse` keeps the per-worker databases between runs, so they do not follow
    # migrations by themselves. A run against stale copies does not fail cleanly -- it
    # fails as a missing column in whichever file happened to touch it, on a different
    # worker each run.
    #
    # Serial is the right fallback rather than a refusal, because the database a serial
    # run uses is the real test database, and that one *is* current. So the suite still
    # runs, correctly, and says exactly what to do to get its speed back.
    def worker_databases_current?(count)
      return true unless @config.worker_databases.to_s == "reuse"

      stale = WorkerDatabases.stale_workers(count)
      return true if stale.empty?

      Constable.warn!(
        "worker database#{"s" if stale.length > 1} #{stale.join(", ")} " \
        "#{stale.length > 1 ? "have" : "has"} not run the migrations the test database " \
        "has. `worker_databases: reuse` keeps these between runs, which means they do " \
        "not follow a migration on their own. Running serially instead -- " \
        "`constable prepare` rebuilds them.",
        kind: :parallel
      )
      false
    end

    def worker_count(items)
      requested = @workers || @config.parallel_workers
      requested.to_i.clamp(1, items.size)
    end

    def forkable?
      Process.respond_to?(:fork) && !@verbose
    end

    def run_serial(items)
      items.flat_map do |item|
        run_item(item).each { |result| @reporter.record(result) }
      end
    ensure
      close_shared_scope!
    end

    # Workers never write to the blotter -- they ship results back over a pipe and the
    # parent is the sole writer. That keeps every storage adapter free of cross-process
    # write contention without any locking of its own.
    def run_parallel(items, count)
      buckets = balance(items, count)
      readers = []
      pids = []

      # Everything that reads the blotter has already been warmed, so the handle can go.
      # A child inheriting a writable SQLite connection is a corruption risk, and the
      # driver rightly complains about it.
      @storage.close

      # Same reasoning for the app's own connections: a child that inherits a live
      # handle can corrupt it. Rails does exactly this before its own fork.
      WorkerDatabases.before_fork!
      # A forked child inherits the parent's memory but not its threads -- including a
      # mutex that a now-absent thread was holding, which is a deadlock the child can never
      # resolve. The spinner is a thread holding a mutex around every write, so it stops
      # before the fork and the parent restarts it once the workers are away.
      @reporter.stop_activity!

      buckets.each_with_index do |bucket, worker_index|
        reader, writer = IO.pipe
        # Marshal payloads are binary. Left in text mode, the first byte that isn't valid
        # UTF-8 takes the worker down with an encoding error.
        reader.binmode
        writer.binmode
        pid = fork do
          reader.close

          # Tell the app which worker it is.
          #
          # Anything a suite keeps on disk per process needs this: a browser cache, a
          # download directory, a screenshot path, a scratch file. Without it every worker
          # computes the same path and they race -- and the way that surfaces is not a
          # tidy error. Observed on a real suite: eight workers running
          # `Dir.mkdir(dir) unless File.directory?(dir)` in a spec/support file, the losers
          # raising Errno::EEXIST *while loading rails_helper*, so those workers ran their
          # files with no database cleaning at all.
          #
          # Deliberately its own name rather than TEST_ENV_NUMBER or parallel_tests'
          # TEST_SUBCATEGORY: those are already wired into some apps' database.yml, and
          # setting one here would rename databases behind WorkerDatabases' back.
          ENV["CONSTABLE_WORKER"]  = worker_index.to_s
          ENV["CONSTABLE_WORKERS"] = buckets.length.to_s

          # Before a single test runs: build this worker's own database and point the
          # process at it. Never falls back to the shared one -- that is the bug this
          # exists to prevent -- but the failure is reported home rather than raised.
          # A raise here dumps a full stack trace per worker and leaves the parent
          # reporting a run that never happened.
          begin
            WorkerDatabases.after_fork!(worker_index, mode: @config.worker_databases)
          rescue Constable::Error => e
            write_message(writer, :worker_error, e.message)
            writer.close
            exit!(0)
          end

          # Anything at all, not just Constable::Error. An uncaught exception in a forked
          # child kills it silently: the parent sees a closed pipe, no results and no
          # reason, and a run that scheduled nineteen files reports zero tests and exits
          # 0. A worker that dies has to say so.
          begin
            # The position report after each item is what lets the parent finish the work
            # if this worker dies partway. Results for an item are all written once the
            # item is done, so "position n reported" means items 0...n are home and
            # nothing from item n was ever sent -- the boundary is exact, and re-running
            # from it cannot duplicate a result.
            bucket.each_with_index do |item, position|
              run_item(item).each { |result| write_message(writer, :result, result.to_h) }
              write_message(writer, :progress, position + 1)
            end
            close_shared_scope!
          rescue Exception => e # rubocop:disable Lint/RescueException
            write_message(writer, :worker_error, "#{e.class}: #{e.message}")
            writer.close
            exit!(0)
          end

          # A worker owns its own cold-case session, and it dies here. Fire the engine's
          # after(:suite) hooks in the process that ran the before(:suite) half, before
          # coverage is read -- the parent has no hooks to run on its behalf.
          ColdCase.reset_engines!

          # Ruby's Coverage counts lines in the process that executed them, so a worker's
          # hits would die with it. They ride home on the same pipe as the results.
          write_message(writer, :coverage, Constable::Coverage.peek_raw) if coverage?

          writer.close
          exit!(0)
        end
        writer.close
        readers << reader
        pids << pid
      end

      collected = drain(readers)
      record_worker_exits(pids)

      # No worker could build itself a database, so no test ran. Not every app can be
      # sharded: an app whose schema.rb cannot rebuild the database on its own -- Postgres
      # custom types, functions and triggers are the usual reason, and are exactly why
      # such apps use structure.sql -- will fail here every time. Rails' own `parallelize`
      # fails the same way; the difference is that this is not the user's fault and they
      # should not have to read four stack traces to find that out.
      #
      # Nothing has run yet, so falling back to a serial run costs a restart, not
      # correctness.
      #
      # The condition is deliberately "nothing came back", not "a worker said why". A
      # child can die without managing to report -- and then a run that scheduled
      # nineteen files says "0 tests, 0 failed" and exits 0, which is the worst thing a
      # test runner can do. If work was scheduled and no result arrived, something is
      # wrong whether or not anyone explained it.
      return run_serially_after_worker_failure(items) if collected.empty? && !items.empty?

      # A warning raised inside a worker only ever reached that worker's memory, so the
      # results carry them home. Nothing that bends the rules is allowed to go missing
      # just because it happened in a subprocess.
      collected.each { |result| Constable.warnings.concat(Array(result.warnings)) }
      collected + finish_abandoned_work(buckets)
    end

    # One worker dying used to cost its whole remaining bucket, silently.
    #
    # `worker_errors` was only ever read on the path where *nothing* came back, so a
    # worker that died beside living ones was collected and never mentioned. The parent
    # reported the results it happened to receive, called them the whole suite, and
    # exited 0. Observed: a 192-test suite reporting "99 passed, 0 failed" -- green, with
    # 93 tests that never ran.
    #
    # Now the parent knows what it scheduled and how far each worker actually got, so it
    # can just run the rest itself. Serial, in this process, which is the one place that
    # cannot also die without anyone noticing.
    def finish_abandoned_work(buckets)
      abandoned = buckets.each_with_index.flat_map do |bucket, index|
        done = worker_progress[index]
        done < bucket.size ? bucket[done..] : []
      end
      return [] if abandoned.empty?

      Constable.warn!(
        "#{abandoned.size} test#{"s" unless abandoned.size == 1} did not come back from " \
        "a parallel worker, so #{abandoned.size == 1 ? "it was" : "they were"} run here " \
        "instead -- everything ran, nothing was skipped. A worker died partway through " \
        "its share#{worker_death_reason}.",
        kind: :parallel
      )
      run_serial(abandoned)
    end

    def worker_death_reason
      return "" if worker_errors.empty?

      ": #{worker_errors.first}"
    end

    def worker_progress = (@worker_progress ||= Hash.new(0))

    # How often each failing test has failed before.
    #
    # "This has failed four of the last twelve runs" is a different fact from "this
    # failed", and it is the one that decides what to do: a first failure is news about
    # the change you just made, a recurring one is news about the test. The blotter has
    # been recording it since the beginning; the summary never asked.
    #
    # Only for tests that failed in this run -- there is no reason to query history for
    # the several thousand that passed.
    def failure_history(results)
      failing = results.select(&:failed?)
      return {} if failing.empty?

      failing.to_h do |result|
        rows = Array(@storage.history_for(result.identity, limit: 25))
        failures = rows.count { |row| %w[failed errored].include?(row[:status].to_s) }
        [result.identity, { runs: rows.size, failures: failures }]
      end
    rescue StandardError
      {}
    end

    def worker_errors = (@worker_errors ||= [])

    # A worker can die below Ruby: a segfault, an OOM kill, a signal. No `rescue` reaches
    # that, so the only evidence is the exit status, and without it the run can only say
    # "the workers exited without reporting anything" -- true, and useless.
    #
    # Forking a process that already holds database connections is where this comes from.
    # An app with a native driver -- Oracle's OCI, for instance -- can have a child die
    # the moment it touches an inherited handle.
    def record_worker_exits(pids)
      pids.each do |pid|
        _, status = Process.waitpid2(pid)
        next if status.nil? || status.success?

        worker_errors << if status.signaled?
                           "a worker was killed by SIG#{Signal.signame(status.termsig)} " \
                             "-- forking an app that already holds native database " \
                             "connections can do this"
                         else
                           "a worker exited with status #{status.exitstatus}"
                         end
      rescue StandardError
        nil
      end
    end

    def run_serially_after_worker_failure(items)
      reason = worker_errors.first.to_s
      reason = "the workers exited without reporting anything" if reason.empty?

      Constable.warn!(
        "the parallel workers produced no results, so the suite ran serially instead -- " \
        "everything ran, nothing was skipped. Two things cause this: the app's schema " \
        "cannot rebuild a database by itself (Postgres custom types; try " \
        "`worker_databases: reuse` with `constable prepare`), or forking is unsafe in " \
        "this app, which happens when a native driver's connections are inherited by a " \
        "child. `worker_databases: off` stops the attempt. The workers said: #{reason}",
        kind: :parallel
      )

      # The blotter handle was closed before forking, and the pool was cleared. Both come
      # back on their next use, so there is nothing to reopen by hand.
      results = run_serial(items)

      # Belt and braces. If the serial fallback also produces nothing for work that was
      # scheduled, the run is broken in a way no summary can honestly describe, and
      # reporting a clean zero would be a lie.
      if results.empty? && !items.empty?
        raise Constable::Error,
              "#{items.size} test file(s) were scheduled and none of them ran. " \
              "The first worker said: #{reason}"
      end

      results
    end

    # Every message on the pipe is tagged, because results are not the only thing a worker
    # has to send home.
    def write_message(writer, kind, body)
      payload = Marshal.dump([kind, body])
      writer.write([payload.bytesize].pack("N"))
      writer.write(payload)
      writer.flush
    end

    # Reads from every worker as results arrive, so the glyph stream stays live rather than
    # arriving in one lump when the slowest worker finishes.
    def drain(readers)
      collected = []
      buffers = Hash.new { |h, k| h[k] = String.new(encoding: Encoding::BINARY) }
      open_readers = readers.dup

      until open_readers.empty?
        ready, = IO.select(open_readers, nil, nil, 1)
        next unless ready

        ready.each do |reader|
          chunk = begin
            reader.read_nonblock(65_536)
          rescue IOError # EOFError is one of these -- the worker finished and closed its end.
            nil
          rescue IO::WaitReadable
            next
          end

          if chunk.nil?
            open_readers.delete(reader)
            reader.close unless reader.closed?
            next
          end

          buffers[reader] << chunk
          extract(buffers[reader]).each do |kind, body|
            case kind
            when :result
              result = Result.from_h(body)
              collected << result
              @reporter.record(result)
            when :coverage
              @worker_coverage = Constable::Coverage.merge_raw(@worker_coverage, body)
            when :progress
              index = readers.index(reader)
              worker_progress[index] = body.to_i if index
            when :worker_error
              # A worker that could not start. Collected rather than raised, so the parent
              # decides what to do once it knows whether any worker got going at all.
              worker_errors << body
            end
          end
        end
      end

      collected
    end

    def extract(buffer)
      out = []
      loop do
        break if buffer.bytesize < 4

        size = buffer.byteslice(0, 4).unpack1("N")
        break if buffer.bytesize < 4 + size

        payload = buffer.byteslice(4, size)
        rest = buffer.byteslice(4 + size, buffer.bytesize - 4 - size)
        buffer.replace(rest || String.new(encoding: Encoding::BINARY))
        out << Marshal.load(payload) # rubocop:disable Security/MarshalLoad -- our own pipe
      end
      out
    end

    # One slice of the suite, for one machine in a CI matrix.
    #
    # Applied before anything else looks at the item list, so the docket, the reporter and
    # the exit status all describe this machine's share honestly rather than the whole
    # suite's. Weighted by the same measured durations the worker balancer uses, so slices
    # are even in time rather than in file count.
    def shard_of(items)
      return items if @shard.nil? || @shard.whole?

      @shard.slice(items, weights: shard_weights(items))
    end

    # Deliberately empty unless asked for, and this is the interesting part.
    #
    # Weighting the split by recorded durations makes slices even in time rather than in
    # file count, which is the whole appeal. But each machine computes its own slice with
    # no coordination, so every machine must derive the *same* partition -- and durations
    # come from the blotter, which each run writes back to.
    #
    # Measured: running shards 1, 2 and 3 in sequence locally, each run updated the
    # durations the next one read, so each repartitioned. One file ran in two shards and
    # another ran in none. Eighteen tests were missing from the union and thirty-three were
    # duplicated -- a green build that ran less than it claimed, which is the exact failure
    # this project exists to prevent.
    #
    # So the default partition depends on nothing but the item set: sorted by label,
    # handed out round-robin, provably every item exactly once whatever any blotter says.
    # `--shard-by-time` opts into duration weighting, and is safe only when every machine
    # reads identical duration data -- a blotter restored from one shared cache, and never
    # one written back to mid-matrix.
    def shard_weights(items)
      return {} unless @shard_by_time

      items.to_h { |item| [item, weight_of(item, duration_index)] }
    end

    # Longest-processing-time-first: the slowest tests are handed out before the quick ones,
    # so no worker is left holding a three-second test after everyone else has finished.
    def balance(items, count)
      index = duration_index
      buckets = Array.new(count) { [] }
      loads = Array.new(count, 0.0)

      # A case is one unit of work, not a bag of independent tests.
      #
      # These used to be balanced test by test, which sorted every investigation in the run
      # by duration and so scattered one case's tests across the whole schedule. Two costs.
      # The output went flat and repetitive -- the live stream groups by case, so a case
      # whose tests arrive in four separate bursts gets four separate lines, and reading it
      # is impossible. And a witness_all fixture could not work at all, since its
      # transaction spans the case and half the tests would land in another process.
      #
      # Balancing is coarser now, bounded by the largest case rather than the largest test.
      # On a real suite that is a rounding error, and legible output every run is not.
      grouped = items.group_by { |item| scheduling_group(item) }.values

      grouped.sort_by { |group| -group.sum { |item| weight_of(item, index) } }.each do |group|
        slot = loads.index(loads.min)
        buckets[slot].concat(group)
        loads[slot] += group.sum { |item| weight_of(item, index, default: 0.05) }
      end
      buckets.reject(&:empty?)
    end

    # What has to stay together.
    #
    # Not the item's own case class: `docket` builds an anonymous subclass per group, so a
    # case with four dockets is four classes that all report under one name. Grouping by the
    # class gave each docket its own line and the repetition this was meant to fix survived
    # -- visibly, on a real suite, with PowerOfAttorneyMapperCase appearing four times in one
    # screenful.
    #
    # So group by what the reader sees, which is the nearest named non-docket ancestor. That
    # is the same answer `constable_display_name` gives, and it has to be, or the scheduler
    # and the stream disagree about what a case is.
    def scheduling_group(item)
      return item.path unless item.native?

      klass = item.investigation&.case_class
      return klass unless klass.respond_to?(:constable_display_name)

      klass.constable_display_name
    end

    # What one item is expected to cost.
    #
    # A native item is one investigation and its identity is in the duration index. A cold
    # item is a whole *file* of examples, and its identity is
    # `Identity.for_cold_case(path, "file")` -- a key nothing ever records, because
    # durations are stored per example, keyed by the example's description. So every cold
    # item weighed 0.0 and the sort was a no-op.
    #
    # That made longest-processing-time-first do nothing at all on a suite that is entirely
    # cold cases, which is the common case for an app that has just adopted Constable: the
    # files went out in whatever order they were discovered, and one worker could take the
    # slowest four while another took four quick ones.
    #
    # The per-file totals were already being computed for `constable modernize --plan`; this
    # just asks for them here too.
    def weight_of(item, index, default: 0.0)
      return index.fetch(item.identity, default) if item.native?

      file_durations.dig(relative_to_root(item.path), :seconds) || default
    end

    def relative_to_root(path)
      path.to_s.delete_prefix("#{Constable.root}/")
    end

    # Read once, in the parent, before any fork -- same as the duration index.
    # A timeout below what this suite has actually taken will fail working files.
    #
    # A blunt floor was the other option and it is worse: `--timeout 60` to find which of a
    # thousand files is hanging is exactly the right thing to do, and a floor high enough to
    # protect a slow suite would silently ignore it. So the data answers instead -- the
    # blotter knows how long each file took, and says so when the limit is under that.
    def warn_about_tight_timeout!(_items)
      return if @timeout.zero?

      slowest = file_durations.values.map { |row| row[:seconds].to_f }.max.to_i
      return if slowest.zero? || slowest < @timeout

      Constable.warn!(
        "--timeout #{@timeout}s is under the #{slowest}s this suite's slowest file has taken. " \
        "Files over the limit will be failed as hung when they are only slow. Raise it, or " \
        "narrow the run to the files you are chasing."
      )
    end

    # What this run is about to cost, from what the blotter has seen before.
    #
    # A suite that takes 45 minutes should say so at the start rather than leaving you to
    # find out. Returns nil rather than a guess when there is nothing recorded -- a made-up
    # estimate on a first run is worse than no estimate, because it will be believed once
    # and then never again.
    def forecast_for(items)
      index = duration_index
      files = file_durations
      return nil if index.empty? && files.empty?

      seconds = 0.0
      tests = 0
      known = 0

      items.each do |item|
        if item.native?
          recorded = index[item.identity]
          if recorded
            seconds += recorded
            known += 1
          end
          tests += 1
        else
          relative = item.path.to_s.delete_prefix("#{Constable.root}/")
          recorded = files[relative]
          next unless recorded

          seconds += recorded[:seconds] || recorded["seconds"] || 0
          tests += (recorded[:tests] || recorded["tests"] || 0).to_i
          known += 1
        end
      end

      return nil if known.zero?

      # Test bodies are not the run. Booting, loading files, suite hooks and cleaning
      # between examples are all wall-clock time nobody's duration records -- measured on a
      # real suite as 2m 25s of bodies inside an 11m run. The same per-test overhead the
      # port planner uses, which got within 1m 30s of an 11m 11s run.
      overhead = begin
        @storage.overhead_per_test
      rescue StandardError
        nil
      end
      seconds += overhead[:seconds] * tests if overhead && tests.positive?

      # Scale by coverage. An estimate built from a third of the files, presented as if it
      # covered all of them, is worse than none: it will be believed once.
      scale = items.size.to_f / known
      { seconds: seconds * scale, tests: (tests * scale).round, known: known, total: items.size,
        partial: known < items.size }
    end

    def file_durations
      @file_durations ||= begin
        @storage.average_seconds_by_file
      rescue StandardError
        {}
      end
    end

    def duration_index
      @duration_index ||= begin
        @storage.duration_index
      rescue StandardError
        {}
      end
    end

    # --- running one item ------------------------------------------------------

    # A test that never finishes takes the whole run with it, and the symptom is not a
    # failure -- it is a terminal that sits there. Caseflow's suite hangs on a browser-driven
    # feature spec after an hour of wall clock and ten minutes of CPU: nothing to read,
    # nothing recorded, no way to know which file did it.
    #
    # So a hung item is a failed item. Timeout.timeout raises into the blocked thread, which
    # interrupts a socket read, a select, or a condition-variable wait -- the three shapes
    # this takes in practice. It is a blunt instrument and can leave state behind, which is
    # why it is off unless asked for; against a run that never ends, a named failure and a
    # finished suite is the better trade.
    def run_item(item)
      explain_timeouts(Timeout.timeout(@timeout) { run_item!(item) }, item)
    rescue Timeout::Error
      [timed_out(item)]
    end

    # Usually the engine catches the interrupt before we do -- RSpec and Minitest both treat
    # it as the example failing, which is better than our own result because it lands on the
    # exact test rather than the file. What they write is "Timeout::ExitException: execution
    # expired", which says nothing about the limit, why it exists, or what to do next.
    def explain_timeouts(results, item)
      results.each do |result|
        next unless result.failure&.message&.match?(TIMEOUT_MESSAGE)

        result.failure = Failure.new(
          message: timeout_explanation(item),
          context: result.failure.context,
          backtrace: result.failure.backtrace
        )
      end
    end

    def timeout_explanation(item)
      relative = item_file(item)
      "Timed out. No result after #{@timeout}s, so --timeout stopped it -- without that " \
        "limit this run would not have ended on its own.\n\n" \
        "If the file is genuinely this slow, raise the limit. If it is hung, run it alone " \
        "to see where it stops:\n  constable test #{relative}"
    end

    def run_item!(item)
      enter_shared_scope(item)
      item.cold? ? run_cold(item) : [run_native(item)]
    end

    # A witness_all fixture lives in a transaction spanning its whole case, so the case's
    # investigations have to run together and on one worker. They are scheduled adjacently
    # for exactly that reason (see #balance); this closes the previous case's scope when the
    # run moves on, and #close_shared_scope! catches the last one.
    def enter_shared_scope(item)
      klass = item.native? ? item.investigation&.case_class : nil
      return if klass == @shared_scope_owner

      close_shared_scope!
      @shared_scope_owner = klass
      return unless klass.respond_to?(:shared_fixtures?) && klass.shared_fixtures?

      klass.constable_open_shared_scope!
    end

    def close_shared_scope!
      owner = @shared_scope_owner
      @shared_scope_owner = nil
      return unless owner.respond_to?(:constable_close_shared_scope!)

      owner.constable_close_shared_scope!
    rescue StandardError => e
      Constable.warn!("could not roll back shared fixtures for #{owner}: #{e.message}")
    end

    # Only a cold item carries a path; a native one knows its file through its investigation.
    def item_file(item)
      path = item.cold? ? item.path : item.investigation&.file
      path.to_s.delete_prefix("#{Constable.root}/")
    end

    def timed_out(item)
      relative = item_file(item)
      Result.new(
        identity: item.cold? ? Identity.for_cold_case(item.path, "timeout") : item.investigation.identity,
        case_name: File.basename(item_file(item).to_s),
        description: "timed out after #{@timeout}s",
        file: relative,
        line: item.cold? ? 0 : item.investigation.line.to_i,
        kind: item.kind,
        status: :errored,
        failure: Failure.new(
          message: "No result after #{@timeout}s. The run would not have ended on its own.\n\n" \
                   "Raise the limit for a genuinely slow file, or run it alone to see where " \
                   "it stops:\n  constable test #{relative}",
          backtrace: []
        )
      ).tap { |result| result.seed = @seed }
    end

    def run_cold(item)
      warnings_before = Constable.warnings.size
      # The seed goes in, not just onto the results: Minitest randomizes its own method
      # order, so passing it is what makes `constable test PATH --seed N` actually replay.
      results = ColdCase.run_file(item.path, config: @config, seed: @seed)
      raised = Constable.warnings[warnings_before..] || []

      results.each { |r| r.seed = @seed }

      # A cold case warns once per file, not once per test, so the warning rides home on
      # the first result rather than being repeated on all of them.
      results.first&.warnings&.concat(raised)
      results
    rescue StandardError => e
      [Result.new(
        identity: Identity.for_cold_case(item.path, "load"),
        case_name: File.basename(item.path),
        description: "failed to load",
        file: item.path.to_s.delete_prefix("#{Constable.root}/"),
        line: 0,
        kind: :cold,
        status: :errored,
        failure: Failure.from_exception(e)
      ).tap { |r| r.seed = @seed }]
    end

    def run_native(item)
      investigation = item.investigation
      jail_entry = docket_snapshot[investigation.identity]

      return run_jailed_setup(investigation, jail_entry) if jail_entry&.jailed? && !jail_run?

      result = execute_investigation(investigation)
      result.seed = @seed
      result
    end

    # A jailed test still runs its briefing and witnesses -- only the investigate body is
    # skipped -- so setup rot surfaces on the next ordinary run rather than lying in wait
    # until someone gets around to `constable jail run`.
    def run_jailed_setup(investigation, entry)
      started = monotonic
      failure = nil

      instance = Case.constable_instance_for(investigation)
      begin
        # Setup without a body, but with its teardown -- skipping the body is the point of
        # the jail; skipping the cleanup would just leave the request session, the browser
        # or whatever else a teardown releases open for whatever runs next.
        Isolation.with_rollback(investigation.tier) do
          raised = nil
          begin
            instance.run_setup(investigation)
          rescue StandardError => e
            raised = e
          end
          # On its own line, not behind an ||=: teardown has to run whether or not setup
          # got that far, and the first failure is still the one worth reporting.
          teardown_failure = instance.run_teardown
          raised ||= teardown_failure
          raise raised if raised
        end
      rescue StandardError => e
        failure = Failure.from_exception(e, context: "setup for a jailed test still runs, and it failed")
      ensure
        teardown(instance)
      end

      result = Result.from_investigation(
        investigation,
        status: :jailed,
        duration: monotonic - started,
        failure: failure
      )
      result.jail_reason  = entry.reason
      result.times_jailed = entry.times_jailed
      result.seed = @seed
      result
    end

    def execute_investigation(investigation)
      started = monotonic
      before = leak_check? ? Isolation.snapshot : nil
      warnings_before = Constable.warnings.size
      failure = nil
      status = :passed

      instance = Case.constable_instance_for(investigation)

      begin
        # run_investigation is the whole lifecycle: before_setup, briefings, body,
        # teardowns, after_teardown. The teardown half runs inside the rollback whether or
        # not the body raised, and a teardown that raises never masks the body's failure.
        Isolation.with_rollback(investigation.tier) { instance.run_investigation(investigation) }
      rescue AssertionFailed => e
        status = :failed
        failure = Failure.from_exception(e, context: e.context)
      rescue StandardError => e
        status = :errored
        failure = Failure.from_exception(e)
      ensure
        # Time stays frozen and the network stays blocked only for the life of one
        # investigation. Whatever the outcome, the next one starts from clean ground.
        teardown(instance)
      end

      duration = monotonic - started
      raised = Constable.warnings[warnings_before..] || []

      if before
        leaks = Isolation.diff(before, Isolation.snapshot)
        if leaks.any?
          Constable.warn!(
            "state leaked out of this investigation: #{leaks.join("; ")}",
            location: investigation.location,
            kind: :leak
          )
        end
      end

      Result.from_investigation(
        investigation,
        status: status,
        duration: duration,
        failure: failure,
        warnings: Constable.warnings[warnings_before..] || raised
      )
    end

    # The leak check walks every user class's class variables, which is worth it per test
    # but not worth it per test in a hot parallel loop on a huge suite.
    def leak_check?
      return @leak_check if defined?(@leak_check)

      @leak_check = ENV["CONSTABLE_LEAK_CHECK"] != "0"
    end

    # --- adjudication ----------------------------------------------------------

    # Turns raw pass/fail into the verdict the build acts on: warrants decide whether a
    # failure is even real, then jail decides whether it blocks.
    def adjudicate(raw)
      @systemic = systemic_failure(raw)
      announce_systemic_failure(@systemic) if @systemic

      raw.map do |result|
        decided = warrants.adjudicate(
          result,
          requested: @warrants_requested,
          subject: investigation_for(result.identity)
        ) { |subject, _attempt| rerun_in_isolation(subject) }

        next decided if jail_run?

        jail.adjudicate(decided, jail_mode: jail_mode?, systemic: systemic?(decided))
      end
    end

    # A run is "systemically broken" when a large share of it failed the same way: the
    # database was down, a worker could not start, a shared fixture never loaded. Thirty
    # tests did not each independently go bad in the same second.
    #
    # This matters because flake history reads "passed last run, failed this run" as
    # evidence about a *test*, and jails it. One bad afternoon on CI could therefore
    # quarantine a third of a healthy suite, and the docket -- which is supposed to be a
    # record of tests worth distrusting -- fills up with tests that were never at fault.
    def systemic_failure(results)
      failures = results.select(&:failed?)
      return nil if failures.size < SYSTEMIC_MINIMUM
      return nil if failures.size < results.size * SYSTEMIC_SHARE

      grouped = failures.group_by { |result| result.failure&.exception_class.to_s }
      grouped.delete("")
      return nil if grouped.empty?

      exception_class, sharing = grouped.max_by { |_klass, group| group.size }
      return nil if sharing.size < failures.size * SYSTEMIC_AGREEMENT

      Systemic.new(exception_class: exception_class, failed: sharing.size, total: results.size)
    end

    # Only the failures that look like the outage are exempt. A genuine failure that
    # happened to land in the same run is still a genuine failure.
    def systemic?(result)
      return false unless @systemic
      return false unless result.failed?

      result.failure&.exception_class.to_s == @systemic.exception_class
    end

    def announce_systemic_failure(systemic)
      Constable.warn!(
        "#{systemic.failed} of #{systemic.total} tests failed with the same error " \
        "(#{systemic.exception_class}). That reads as one broken run rather than " \
        "#{systemic.failed} newly flaky tests, so flake history and the jail docket were " \
        "left alone. Fix the cause and run again.",
        kind: :systemic
      )
    end

    def investigation_for(identity)
      @investigation_index ||= Constable.registry.investigations.to_h { |inv| [inv.identity, inv] }
      @investigation_index[identity]
    end

    # One test, run again from scratch, so a warrant's retries measure the test rather than
    # whatever the rest of the suite left lying around.
    def rerun_in_isolation(subject)
      investigation = subject.is_a?(Investigation) ? subject : investigation_for(subject.to_s)
      return nil unless investigation

      execute_investigation(investigation)
    end

    def jail
      @jail ||= Jail.new(config: @config, storage: @storage)
    end

    # The docket, read once in the parent and inherited by every worker through fork.
    # A worker that queried it directly would be reaching into a database handle it does
    # not own -- SQLite is explicit that a connection must not cross a fork -- and the
    # answer cannot change mid-run anyway.
    def docket_snapshot
      @docket_snapshot ||= jail.entries.to_h { |entry| [entry.identity, entry] }
    rescue StandardError
      {}
    end

    def warrants
      @warrants ||= Warrants.new(config: @config, storage: @storage)
    end

    def order_audit
      @order_audit ||= OrderAudit.new(config: @config, storage: @storage)
    end

    # --- persistence and reporting --------------------------------------------

    def persist(run_id, results, coverage_report, duration: nil)
      results.each do |result|
        # The blotter is the evidence file. A result produced by an outage is not
        # evidence about the test, so it is not filed -- otherwise the next run reads
        # "failed, then passed" and draws a conclusion from a power cut.
        next if systemic?(result)

        @storage.record_result(run_id, result)
        @storage.record_duration(result.identity, result.duration)
      end

      Constable::Coverage.record!(coverage_report, run_id, storage: @storage) if coverage_report

      @storage.finish_run(run_id, totals: totals(results, duration))
    rescue StandardError => e
      Constable.warn!("could not write to the blotter: #{e.message}", kind: :storage)
    end

    # What the blotter keeps about a run as a whole.
    #
    # `duration` and `skipped` were missing here for a long time, so both columns existed
    # in the schema and were never written -- which meant the store could say how many
    # tests a suite had run but not how long any of it took. `constable metrics` is what
    # made that visible: a lifetime runtime of zero.
    def totals(results, duration = nil)
      {
        total: results.size,
        passed: results.count(&:passed?),
        failed: results.count(&:failed?),
        jailed: results.count(&:jailed?),
        skipped: results.count(&:skipped?),
        warranted: results.count(&:warranted?),
        duration: duration
      }
    end

    # The blotter's identities as they stood before this run wrote anything. Taken up
    # front, because rename detection compares "what we used to know" against "what we
    # just saw", and persisting first would make every test look familiar.
    def known_before
      @known_before ||= Array(@storage.known_identities).map(&:to_s)
    rescue StandardError
      []
    end

    # A test whose body changed gets a new identity, so an old one vanishing the same run
    # a similar new one appears is usually a rename plus a tweak, not two separate edits.
    # Confirming the relink also carries any jail or warrant entry across, which is what
    # stops a fixed-but-still-jailed test from haunting the docket forever.
    def rename_suggestions(results)
      return [] unless @selection.full?

      seen     = results.map(&:identity)
      vanished = known_before - seen
      fresh    = results.reject { |r| known_before.include?(r.identity) }
      return [] if vanished.empty? || fresh.empty?

      labels = vanished.to_h { |identity| [identity, label_for(identity)] }

      fresh.filter_map do |result|
        match = vanished.max_by { |old| similarity(labels[old], result.description) }
        next if match.nil?

        score = similarity(labels[match], result.description)
        next if score < 0.5

        suggestion = {
          relinked: false, score: score,
          old_identity: match, new_identity: result.identity,
          old_label: labels[match], new_label: result.display_label
        }

        if @config.auto_relink? && score >= 0.85
          @storage.relink(match, result.identity)
          suggestion[:relinked] = true
        end

        suggestion
      end
    rescue StandardError
      []
    end

    # The blotter keeps a display label alongside each identity purely so a vanished test
    # can still be named in a suggestion.
    def label_for(identity)
      row = @storage.history_for(identity, limit: 1).first
      return identity unless row

      [row[:case_name], row[:description]].compact.join(" ").strip
    rescue StandardError
      identity
    end

    # Cheap token overlap -- enough to spot "creates a user" vs "creates a user with valid
    # params" without pulling in a Levenshtein dependency for a hint that a human confirms.
    def similarity(left, right)
      a = left.to_s.downcase.scan(/\w+/)
      b = right.to_s.downcase.scan(/\w+/)
      return 0.0 if a.empty? || b.empty?

      (a & b).size.to_f / [a.size, b.size].max
    end

    def exit_status(results, coverage_report)
      return 1 if results.any?(&:failed?)
      return 1 if @config.fail_on_warnings? && new_warnings.any?
      return 1 if coverage_report && !coverage_report.meets_threshold?(@config)

      0
    end

    def new_warnings
      Constable.warnings[@warnings_before..] || []
    end

    # Combines what this process saw with everything the workers sent back. Cold cases
    # count here too -- Coverage works at the process level, so it never knew which engine
    # ran the code.
    def build_coverage_report
      merged = Constable::Coverage.merge_raw(Constable::Coverage.peek_raw, @worker_coverage)
      report = Constable::Coverage.build_report(
        merged,
        config: @config,
        root: Constable.root,
        # Cold cases contribute their numbers but are never held to the diff gate, so a
        # run carrying nothing else must not be gated at all.
        gate: !@selection.cold_only?
      )
      Constable::Coverage.abort!
      report
    end

    # The last thing to happen to an instance, after its own teardowns and after the
    # transaction is gone: the runtime DSL's global state -- a frozen clock, a barred
    # network, a half-open unsafe block -- belongs to the process, not to the test, so it
    # is released once everything that might still depend on it has finished.
    def teardown(instance)
      instance._constable_dsl_teardown if instance.respond_to?(:_constable_dsl_teardown)
    rescue StandardError => e
      Constable.warn!("teardown after an investigation raised: #{e.message}", kind: :teardown)
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
