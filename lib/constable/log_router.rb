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

        unless rails_loaded?
          reason = "Rails is not loaded — nothing to route, stdout is already results only"
          return @current = Routing.new(routed: false, path: target, verbose: verbose, reason: reason)
        end

        file   = open_log(target)
        logger = build_logger(verbose ? Tee.new(file, io) : file)

        remember_previous!
        apply(logger)

        @current = Routing.new(routed: true, path: target, verbose: verbose, reason: nil)
      end

      # Puts back whatever the app had before route!. Only useful in-process (our own
      # suite, or a REPL); a real run never wants its logs back on stdout.
      def restore!
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

      def open_log(path)
        FileUtils.mkdir_p(File.dirname(path))
        close_file
        @file = File.open(path, "a")
        @file.sync = true
        @file
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
