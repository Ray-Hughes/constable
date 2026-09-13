# frozen_string_literal: true

require "fileutils"
require "logger"

module Constable
  # stdout is results only.
  #
  # A test run's stdout belongs to the reporter -- glyphs while it runs, the summary when
  # it finishes. Rails.logger, ActiveRecord's SQL logging and request/response logging all
  # go to log/test.log and nowhere else, so a failure never has to be dug out of a wall of
  # scrolled-past SQL. `constable test --verbose` is the escape hatch: the same lines still
  # land in the file, and are additionally teed to stdout for active debugging.
  #
  #   Constable::LogRouter.route!(verbose: options[:verbose])
  #
  # Rails is never required at load time -- a :unit-tier run boots without an app at all --
  # so without Rails this is a no-op that says why.
  module LogRouter
    DEFAULT_PATH = "log/test.log"

    # What route! did, for a caller that wants to say so (or a test that wants to check).
    Routing = Struct.new(:routed, :path, :verbose, :reason, keyword_init: true) do
      def routed?  = !!routed
      def verbose? = !!verbose

      def to_s
        return reason.to_s unless routed?

        verbose? ? "logs → #{path} (teed to stdout)" : "logs → #{path}"
      end
    end

    # Writes to the log file and, in verbose mode, to stdout as well. Teeing at the IO
    # keeps this independent of which logger-broadcast API a given Rails version ships.
    class Tee
      attr_reader :targets

      def initialize(*targets)
        @targets = targets.compact
      end

      def write(*args)
        @targets.sum { |target| target.write(*args).to_i }
      end

      def <<(text)
        @targets.each { |target| target << text }
        self
      end

      def print(*args) = @targets.each { |target| target.print(*args) }
      def puts(*args)  = @targets.each { |target| target.puts(*args) }
      def flush        = @targets.each { |target| target.flush if target.respond_to?(:flush) }
      def sync         = true
      def tty?         = false

      # Something that has been handed $stdout may ask it for a file descriptor. Answer
      # with the first target that has one rather than raising NoMethodError from inside
      # somebody else's gem.
      def fileno
        @targets.each { |t| return t.fileno if t.respond_to?(:fileno) }
        nil
      end

      def sync=(value)
        @targets.each { |target| target.sync = value if target.respond_to?(:sync=) }
      end

      # Never closes stdout/stderr out from under the process.
      def close
        @targets.each do |target|
          next if target.equal?($stdout) || target.equal?($stderr)

          target.close if target.respond_to?(:close) && !target.closed?
        end
      end
    end

    # Everything in a Rails app that is allowed to talk. Each entry is resolved lazily and
    # skipped when its constant isn't loaded, so a unit-tier app with no ActionMailer, or a
    # Rails version that dropped a component, routes the rest without complaint.
    LOGGER_TARGETS = [
      ["Rails",                       :logger=, :logger],
      ["ActiveRecord::Base",          :logger=, :logger],
      ["ActionController::Base",      :logger=, :logger],
      ["ActionView::Base",            :logger=, :logger],
      ["ActionMailer::Base",          :logger=, :logger],
      ["ActiveJob::Base",             :logger=, :logger],
      ["ActiveStorage",               :logger=, :logger],
      ["ActiveSupport::LogSubscriber", :logger=, :logger]
    ].freeze

    class << self
      # Routes every Rails-side logger at log/test.log. Returns a Routing describing what
      # happened; `verbose: true` additionally tees the same lines to `io`.
      def route!(verbose: false, path: nil, io: $stdout, root: nil)
        target = path ? File.expand_path(path.to_s, root || Constable.root) : default_path(root)

        # Taking the console does not depend on Rails, and the ordering matters: route! runs
        # before the app boots, so anything that waited for Rails would miss every warning
        # emitted *by* booting it -- which is most of them. A suite with no Rails at all
        # still wants its stdout kept for results.
        file = open_log(target)
        capture_console!(file, verbose ? io : nil)

        unless rails_loaded?
          reason = "Rails is not loaded — no loggers to route, but stdout is held for results"
          return @current = Routing.new(routed: false, path: target, verbose: verbose, reason: reason)
        end

        logger = build_logger(verbose ? Tee.new(file, io) : file)

        remember_previous!
        apply(logger)

        @current = Routing.new(routed: true, path: target, verbose: verbose, reason: nil)
      end

      # The terminal, as it was before route! took it. The reporter writes here; everything
      # else writes to the log.
      def console = @console_out || $stdout

      # The same, for the stream errors belong on. Convention puts them on stderr, and a
      # run has pointed the real one at the log.
      def console_err = @console_err || $stderr

      # Rails loggers are not the only thing that writes to a terminal. A gem warning --
      # Faraday's "install the faraday-retry gem", say -- goes straight to $stderr, once
      # per file that triggers it, and lands in the middle of the live stream:
      #
      #   Address    ✓✓✓✓✓✓✓✓✓✓✓To use retry middleware with Faraday v2.0+...
      #
      # stdout is supposed to be results only. So the app's stdout and stderr are pointed
      # at log/test.log for the duration of the run, and the reporter keeps the real
      # terminal it captured beforehand. `--verbose` tees both back, which is the whole
      # point of that flag.
      def capture_console!(file, tee_to)
        # Reassigning the $stdout *object* is not enough. A gem that writes through the
        # STDERR constant, a C extension, or anything that already holds file descriptor 2
        # goes straight past it -- and in a terminal both streams land in the same place,
        # so "it was only on stderr" is no comfort at all when it lands mid-glyph.
        #
        # So the descriptors themselves are pointed at the log, and the reporter is handed
        # a dup of the real terminal taken beforehand. #reopen changes where fd 1 and 2
        # write for the whole process, which is the only thing that catches every writer.
        @console_out = $stdout.dup
        @console_err = $stderr.dup
        @reopened    = false

        # --verbose means "show me everything", so nothing is redirected; the object swap
        # is enough to tee. The same fallback covers anything that is not a real IO on
        # both sides -- a StringIO standing in for the terminal in a test, most obviously,
        # where IO#reopen has nothing to reopen onto.
        if tee_to || !redirectable?(file)
          @swapped_out = $stdout
          @swapped_err = $stderr
          replacement  = tee_to ? Tee.new(file, tee_to) : file
          $stdout = replacement
          $stderr = replacement
          return
        end

        $stdout.reopen(file)
        $stderr.reopen(file)
        $stdout.sync = true
        $stderr.sync = true
        @reopened = true

        # Whatever happens next -- a clean exit, a raise, an interrupt -- the descriptors
        # go back. Without this an uncaught exception prints its backtrace into
        # log/test.log and the terminal shows nothing at all, which is a far worse bug
        # than the one being fixed.
        install_exit_guard!
      end

      def install_exit_guard!
        return if @exit_guard_installed

        @exit_guard_installed = true
        at_exit { restore_console! }
      end

      # Every party has to be a real IO: the log we are redirecting to, and the two streams
      # we are redirecting away from and will later have to put back.
      def redirectable?(file)
        [file, $stdout, $stderr].all? { |io| io.is_a?(::IO) && io.respond_to?(:fileno) }
      rescue StandardError
        false
      end

      def restore_console!
        if @reopened
          $stdout.reopen(@console_out)
          $stderr.reopen(@console_err)
        elsif @swapped_out
          $stdout = @swapped_out
          $stderr = @swapped_err
        end

        [@console_out, @console_err].each { |io| io&.close unless io&.closed? } if @reopened
        @console_out = nil
        @console_err = nil
        @swapped_out = nil
        @swapped_err = nil
        @reopened = false
      end

      # Puts back whatever the app had before route!. Only useful in-process (our own
      # suite, or a REPL); a real run never wants its logs back on stdout.
      def restore!
        restore_console!
        (@previous || {}).each do |constant_name, (setter, logger)|
          constant = resolve(constant_name)
          constant&.public_send(setter, logger)
        end
        close_file
        @previous = nil
        @current  = nil
        true
      end

      attr_reader :current

      def routed? = !!@current&.routed?

      def default_path(root = nil)
        File.expand_path(DEFAULT_PATH, root || Constable.root)
      end

      private

      def rails_loaded?
        defined?(Rails) && Rails.respond_to?(:logger)
      end

      # A log file it cannot open must not end the run.
      #
      # CI found this: the workspace is prepared as root and the suite runs as another user,
      # so `log/test.log` was unwritable and the whole run died at startup on an EACCES --
      # before a single test, with a stack trace instead of a reason. Routing logs away from
      # stdout is a convenience; the tests are the point.
      #
      # It falls back to devnull, so log output is discarded rather than dumped into the
      # results, and says once what happened.
      def open_log(path)
        close_file
        FileUtils.mkdir_p(File.dirname(path))
        @file = File.open(path, "a")
        @file.sync = true
        @file
      rescue SystemCallError, IOError => e
        Constable.warn!(
          "could not write to #{path} (#{e.class}), so log output is being discarded for " \
          "this run. Nothing else is affected."
        )
        @file = File.open(File::NULL, "a")
      end

      def close_file
        @file.close if @file && !@file.closed?
        @file = nil
      rescue IOError
        @file = nil
      end

      # A plain message-only format: test.log is read by a human chasing one request, not
      # parsed by a log shipper. Tagged logging is preserved where Rails offers it, since
      # Rails' own middleware calls `logger.tagged`.
      def build_logger(device)
        logger = ::Logger.new(device)
        logger.level = ::Logger::DEBUG
        logger.formatter = ->(_severity, _time, _progname, message) { "#{message}\n" }

        if defined?(ActiveSupport::TaggedLogging)
          ActiveSupport::TaggedLogging.new(logger)
        else
          logger
        end
      end

      def apply(logger)
        each_target do |constant, setter, _getter|
          constant.public_send(setter, logger)
        end

        # SQL comment logging chases backtraces on every query -- expensive, and pointless
        # when nobody is reading the file live.
        active_record = resolve("ActiveRecord::Base")
        active_record.verbose_query_logs = false if active_record.respond_to?(:verbose_query_logs=)
      end

      def remember_previous!
        @previous = {}
        each_target do |constant, setter, getter|
          @previous[constant.to_s] = [setter, (constant.public_send(getter) if constant.respond_to?(getter))]
        end
      end

      def each_target
        LOGGER_TARGETS.each do |constant_name, setter, getter|
          constant = resolve(constant_name)
          next unless constant.respond_to?(setter)

          yield constant, setter, getter
        end
      end

      def resolve(constant_name)
        Object.const_get(constant_name)
      rescue NameError
        nil
      end
    end
  end
end
