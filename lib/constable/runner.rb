# frozen_string_literal: true

require "securerandom"

module Constable
  # Executes a selection and turns it into results.
  #
  # Ordering is random every run, because a suite that only passes in one order is a suite
  # that will fail the first time anything is added to it. The seed is always printed and
  # always replayable. Cold cases are exempt -- they keep whatever order their own engine
  # chose, since reordering someone's untouched legacy file is exactly the kind of surprise
  # the cold-case story exists to avoid.
  class Runner
    # One unit of work. Native items are a single investigation; cold items are a whole
    # file, because their engine owns the granularity inside it.
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

    attr_reader :config, :selection, :reporter, :storage, :seed, :results

    def initialize(selection:, config: Constable.config, reporter: nil, storage: nil,
                   seed: nil, jail_mode: false, warrants: nil, coverage: nil,
                   workers: nil, verbose: false, io: $stdout)
      @selection  = selection
      @config     = config
      @storage    = storage || Constable.storage
      @seed       = (seed || ENV["CONSTABLE_SEED"] || SecureRandom.random_number(10_000)).to_i
      @jail_mode  = jail_mode
      @warrants_requested = warrants.nil? ? config.warrants? : warrants
      @coverage_requested = coverage.nil? ? config.coverage? : coverage
      @workers    = workers
      @verbose    = verbose
      @io         = io
      @reporter   = reporter || Reporter.new(io: io, config: config)
      @results    = []
      @warnings_before = Constable.warnings.size
    end

    def jail_mode?  = @jail_mode
    def coverage?   = @coverage_requested

    # => Integer exit status (0 clean, 1 failures)
    def call
      load_suite!
      items = build_items
      ordered = order(items)

      run_id = @storage.start_run(seed: @seed, mode: mode_label, full: @selection.full?)
      coverage_report = nil

      Constable::Coverage.start!(config: @config) if coverage?
      Constable.configuration.run_before_suite!

      started = monotonic
      @reporter.start(total: ordered.size, seed: @seed, reason: @selection.reason)

      # The "alone" half of the order audit has to happen before the suite has touched
      # anything, so it runs here rather than alongside the results it will be compared to.
      order_audit.record_isolated!(ordered.select(&:native?).map(&:investigation))

      raw = order_audit.audit(execute(ordered))

      @results = adjudicate(raw)
      duration = monotonic - started

      Constable.configuration.run_after_suite!
      coverage_report = Constable::Coverage.stop! if coverage?

      persist(run_id, @results, coverage_report)
      suggestions = rename_suggestions(@results)

      @reporter.finish(
        results: @results,
        duration: duration,
        seed: @seed,
        coverage: coverage_report,
        suggestions: suggestions
      )

      exit_status(@results, coverage_report)
    end

    private

    def mode_label
      return "jail" if jail_mode?
      return "unsafe" if @selection.unsafe_only?

      @selection.full? ? "full" : "diff"
    end

    # test/case_helper.rb is the app's own entry point -- it boots Rails, defines the tier
    # base classes and loads support files. Everything else depends on it having run.
    def load_suite!
      helper = %w[test/case_helper.rb spec/case_helper.rb].map { |p| File.join(Constable.root, p) }
                                                          .find { |p| File.exist?(p) }
      require helper if helper

      @selection.native_targets.each { |target| load_case_file(target.path) }
      helper
    end

    def load_case_file(path)
      require path
    rescue StandardError, ScriptError => e
      @load_errors ||= []
      @load_errors << [path, e]
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
    def narrow_to_line(investigations, line)
      exact = investigations.select { |inv| inv.line == line }
      return exact if exact.any?

      nearest = investigations.select { |inv| inv.line <= line }.max_by(&:line)
      nearest ? [nearest] : []
    end

    def order(items)
      native, cold = items.partition(&:native?)
      [*native.shuffle(random: Random.new(@seed)), *cold]
    end

    def execute(items)
      return [] if items.empty?

      count = worker_count(items)
      if count > 1 && forkable?
        run_parallel(items, count)
      else
        run_serial(items)
      end
    end

    def worker_count(items)
      requested = @workers || @config.parallel_workers
      [[requested.to_i, 1].max, items.size].min
    end

    def forkable?
      Process.respond_to?(:fork) && !@verbose
    end

    def run_serial(items)
      items.flat_map do |item|
        run_item(item).each { |result| @reporter.record(result) }
      end
    end

    # Workers never write to the blotter -- they ship results back over a pipe and the
    # parent is the sole writer. That keeps every storage adapter free of cross-process
    # write contention without any locking of its own.
    def run_parallel(items, count)
      buckets = balance(items, count)
      readers = []
      pids = []

      buckets.each do |bucket|
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          bucket.each do |item|
            run_item(item).each { |result| write_result(writer, result) }
          end
          writer.close
          exit!(0)
        end
        writer.close
        readers << reader
        pids << pid
      end

      collected = drain(readers)
      pids.each { |pid| Process.waitpid(pid) rescue nil } # rubocop:disable Style/RescueModifier
      collected
    end

    def write_result(writer, result)
      payload = Marshal.dump(result.to_h)
      writer.write([payload.bytesize].pack("N"))
      writer.write(payload)
      writer.flush
    end

    # Reads from every worker as results arrive, so the glyph stream stays live rather than
    # arriving in one lump when the slowest worker finishes.
    def drain(readers)
      collected = []
      buffers = Hash.new { |h, k| h[k] = +"" }
      open_readers = readers.dup

      until open_readers.empty?
        ready, = IO.select(open_readers, nil, nil, 1)
        next unless ready

        ready.each do |reader|
          chunk = begin
            reader.read_nonblock(65_536)
          rescue EOFError, IOError
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
          extract(buffers[reader]).each do |hash|
            result = Result.from_h(hash)
            collected << result
            @reporter.record(result)
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
        buffer.replace(buffer.byteslice(4 + size, buffer.bytesize - 4 - size) || +"")
        out << Marshal.load(payload) # rubocop:disable Security/MarshalLoad -- our own pipe
      end
      out
    end

    # Longest-processing-time-first: the slowest tests are handed out before the quick ones,
    # so no worker is left holding a three-second test after everyone else has finished.
    def balance(items, count)
      index = duration_index
      buckets = Array.new(count) { [] }
      loads = Array.new(count, 0.0)

      items.sort_by { |item| -index.fetch(item.identity, 0.0) }.each do |item|
        slot = loads.index(loads.min)
        buckets[slot] << item
        loads[slot] += index.fetch(item.identity, 0.05)
      end
      buckets.reject(&:empty?)
    end

    def duration_index
      @duration_index ||= begin
        @storage.duration_index
      rescue StandardError
        {}
      end
    end

    # --- running one item ------------------------------------------------------

    def run_item(item)
      item.cold? ? run_cold(item) : [run_native(item)]
    end

    def run_cold(item)
      ColdCase.run_file(item.path, config: @config).each { |r| r.seed = @seed }
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
      jail_entry = jail.entry(investigation.identity)

      if jail_entry && jail.skip_body?(investigation.identity)
        return run_jailed_setup(investigation, jail_entry)
      end

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

      begin
        Isolation.with_rollback(investigation.tier) do
          instance = Case.constable_instance_for(investigation)
          instance.run_setup(investigation)
        end
      rescue StandardError => e
        failure = Failure.from_exception(e, context: "setup for a jailed test still runs, and it failed")
      end

      result = Result.from_investigation(
        investigation,
        status: :jailed,
        duration: monotonic - started,
        failure: failure
      )
      result.jail_reason  = entry[:reason]
      result.times_jailed = entry[:times_jailed]
      result.seed = @seed
      result
    end

    def execute_investigation(investigation)
      started = monotonic
      before = leak_check? ? Isolation.snapshot : nil
      failure = nil
      status = :passed

      begin
        Isolation.with_rollback(investigation.tier) do
          Case.run(investigation)
        end
      rescue AssertionFailed => e
        status = :failed
        failure = Failure.from_exception(e, context: e.context)
      rescue StandardError => e
        status = :errored
        failure = Failure.from_exception(e)
      end

      duration = monotonic - started

      if before
        leaks = Isolation.diff(before, Isolation.snapshot)
        if leaks.any?
          Constable.warn!(
            "state leaked out of this investigation: #{leaks.join('; ')}",
            location: investigation.location,
            kind: :leak
          )
        end
      end

      Result.from_investigation(investigation, status: status, duration: duration, failure: failure)
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
      raw.map do |result|
        result = warrants.adjudicate(result) { |identity| rerun_in_isolation(identity) } if warrants.active?
        jail.adjudicate(result, jail_mode: jail_mode?)
      end
    end

    def rerun_in_isolation(identity)
      investigation = Constable.registry.investigations.find { |inv| inv.identity == identity }
      return nil unless investigation

      execute_investigation(investigation)
    end

    def jail
      @jail ||= Jail.new(config: @config, storage: @storage)
    end

    def warrants
      @warrants ||= Warrants.new(config: @config, storage: @storage, requested: @warrants_requested)
    end

    def order_audit
      @order_audit ||= OrderAudit.new(config: @config, storage: @storage)
    end

    # --- persistence and reporting --------------------------------------------

    def persist(run_id, results, coverage_report)
      results.each do |result|
        @storage.record_result(run_id, result)
        @storage.record_duration(result.identity, result.duration)
      end

      if coverage_report
        @storage.record_coverage(run_id, percent: coverage_report.percent, files: coverage_report.files)
      end

      @storage.finish_run(run_id, totals: totals(results))
    rescue StandardError => e
      Constable.warn!("could not write to the blotter: #{e.message}", kind: :storage)
    end

    def totals(results)
      {
        total: results.size,
        passed: results.count(&:passed?),
        failed: results.count(&:failed?),
        jailed: results.count(&:jailed?),
        warranted: results.count(&:warranted?)
      }
    end

    # A test whose body changed gets a new identity, so an old one vanishing the same run a
    # similar new one appears is usually a rename plus a tweak, not two separate edits.
    def rename_suggestions(results)
      return [] unless @selection.full?

      seen = results.map(&:identity)
      known = @storage.known_identities
      vanished = known.reject { |entry| seen.include?(entry[:identity]) }
      fresh = results.reject { |r| known.any? { |k| k[:identity] == r.identity } }
      return [] if vanished.empty? || fresh.empty?

      fresh.filter_map do |result|
        match = vanished.max_by { |old| similarity(old[:description].to_s, result.description.to_s) }
        score = similarity(match[:description].to_s, result.description.to_s)
        next if score < 0.5

        if @config.auto_relink? && score >= 0.85
          @storage.relink(match[:identity], result.identity)
          next { relinked: true, from: match, to: result, score: score }
        end

        { relinked: false, from: match, to: result, score: score }
      end
    rescue StandardError
      []
    end

    # Cheap token overlap -- enough to spot "creates a user" vs "creates a user with valid
    # params" without pulling in a Levenshtein dependency for a hint that a human confirms.
    def similarity(left, right)
      a = left.downcase.scan(/\w+/)
      b = right.downcase.scan(/\w+/)
      return 0.0 if a.empty? || b.empty?

      (a & b).size.to_f / [a.size, b.size].max
    end

    def exit_status(results, coverage_report)
      return 1 if results.any?(&:failed?)
      return 1 if @load_errors&.any?
      return 1 if @config.fail_on_warnings? && new_warnings.any?
      return 1 if coverage_report && !coverage_report.meets_threshold?(@config)

      0
    end

    def new_warnings
      Constable.warnings[@warnings_before..] || []
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
