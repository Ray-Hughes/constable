# frozen_string_literal: true

module Constable
  # `constable test --watch`: save a file, and the tests that cover it run.
  #
  # Polling rather than filesystem events, so there is no extra gem and it behaves the
  # same on macOS, Linux and inside a container with a mounted volume -- where event APIs
  # are least reliable. Once a second over a few thousand Ruby files is a few milliseconds.
  #
  # Each run is a fresh `constable test` process. Loading the app once and re-running in
  # it would be faster, but a test environment does not reload code (cache_classes), so a
  # long-lived process runs whatever the files said when it started -- and a watcher that
  # quietly tests stale code is worse than one that takes a few seconds to boot.
  class Watcher
    DIRS = %w[app lib config test spec].freeze
    INTERVAL = 1.0
    # A save is often several writes in a burst (formatters, editors writing a temp file
    # then renaming). Waiting this long for quiet runs the burst once.
    SETTLE = 0.3

    def initialize(selection:, root: Constable.root, io: $stdout, interval: INTERVAL,
                   runner: nil, sleeper: ->(seconds) { sleep(seconds) })
      @selection = selection
      @root      = root.to_s
      @io        = io
      @interval  = interval
      @runner    = runner || ->(files) { system(*command(files)) }
      @sleeper   = sleeper
      @forwarded = []
      @snapshot  = scan
    end

    # Options to pass through to each run -- a seed, an --only, a tier. Never --watch.
    attr_writer :forwarded

    def run(initial: [])
      @io.puts "Watching #{DIRS.select { |d| File.directory?(File.join(@root, d)) }.join(", ")} " \
               "for changes. Ctrl-C to stop."
      run_tests(initial) if initial.any?
      loop { tick }
    rescue Interrupt
      @io.puts "\nStopped watching."
    end

    # One pass: anything saved since the last look runs its tests. Returns the case files
    # it ran, for the tests of this class.
    def tick
      @sleeper.call(@interval)
      changed = changes
      return [] if changed.empty?

      @sleeper.call(SETTLE)
      changed |= changes
      cases = @selection.covering(changed)
      if cases.empty?
        @io.puts "\n#{describe(changed)} changed -- no tests cover it."
        return []
      end

      @io.puts "\n#{describe(changed)} changed -- running #{cases.size} #{cases.size == 1 ? "file" : "files"}."
      run_tests(cases)
      cases
    end

    # Files added, removed or modified since the last call. Deleted files are left out:
    # there is nothing to run for them, and their tests will say so when they next run.
    def changes
      now = scan
      changed = now.reject { |path, mtime| @snapshot[path] == mtime }.keys
      @snapshot = now
      changed.sort
    end

    def command(files)
      [Gem.ruby, "-S", "constable", "test", *files, *@forwarded]
    end

    private

    def run_tests(files)
      @runner.call(files.map { |f| f.delete_prefix("#{@root}/") })
    end

    def scan
      DIRS.each_with_object({}) do |dir, out|
        Dir.glob(File.join(@root, dir, "**", "*.rb")).each do |path|
          out[path] = File.mtime(path)
        rescue SystemCallError
          next
        end
      end
    end

    def describe(files)
      names = files.map { |f| f.delete_prefix("#{@root}/") }
      names.size > 3 ? "#{names.first(3).join(", ")} and #{names.size - 3} more" : names.join(", ")
    end
  end
end
