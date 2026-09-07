# frozen_string_literal: true

# Only ever reached through Constable::ColdCase, which requires the engine first and
# turns a missing gem into an actionable message. Never require this file directly.
require "minitest"

module Constable
  module ColdCase
    # The one-line superclass swap for a Minitest file:
    #
    #   class UsersControllerTest < Constable::ColdCase::Minitest   # was: < Minitest::Test
    #     def test_creates_a_user
    #       post users_path, params: valid_params
    #       assert_response :created
    #     end
    #   end
    #
    # There is no DSL forwarding to do here, and that is the point: this really is a
    # Minitest::Test subclass, so `def test_*`, `setup`, `teardown`, every assertion and
    # every plugin behave identically to the day before the line changed. Constable only
    # needs to know which classes belong to a cold-case file and to collect their results.
    #
    # It also covers the verbatim-wrapper form, where the original file (including its own
    # `class FooTest < ActiveSupport::TestCase`) is nested inside this class -- nested
    # classes register themselves with Minitest::Runnable exactly as they always did.
    class Minitest < ::Minitest::Test
      def self.cold_case_engine = :minitest

      def self.inherited(subclass)
        super
        ColdCase.note_cold_class(subclass)
      end
    end

    # Drives Minitest over one file and translates its verdicts into Constable Results.
    module MinitestAdapter
      # Minitest hands every outcome to a reporter. We plug in one that keeps the
      # Minitest::Result objects instead of printing them -- pass, fail, error and skip
      # all arrive through #record, in the engine's own order.
      class Collector < ::Minitest::AbstractReporter
        attr_reader :results

        def initialize
          super()
          @results = []
        end

        def record(result)
          @results << result
        end
      end

      class << self
        def engine = :minitest
        def base_class_name = "Constable::ColdCase::Minitest"

        def run_file(path, config: Constable.config, seed: nil)
          ColdCase.require_engine!(:minitest, path: path)
          disable_autorun!

          collector  = Collector.new
          load_error = nil
          # Minitest's runnable registry is a single process-wide array that every
          # Test subclass appends itself to at definition time. Snapshot it, let the file
          # add whatever it adds, run only the difference, then put the snapshot back --
          # otherwise a cold-case class would still be registered for the next file's run
          # (and for anything else in this process that later asks Minitest to run).
          registry = ::Minitest::Runnable.runnables
          snapshot = registry.dup

          ColdCase.while_loading(path) do
            load_error = capture_load(path)
            run_runnables(discover_runnables(registry, snapshot, path), collector) unless load_error

            ColdCase.warn_for_file(path, base_class_name, collector.results.size, config: config)
          end

          build_results(path, collector.results, config: config, seed: seed, load_error: load_error)
        ensure
          registry&.replace(snapshot) if snapshot
        end

        # Nothing to tear down: the registry is restored around every file and the
        # autorun hook is deliberately left claimed. @known_runnables is intentionally
        # kept -- it is a discovery index of classes we have already seen, not engine
        # state, and forgetting it can only make discovery worse, never make something
        # run that shouldn't (a class still has to own methods defined in the file).
        def reset_engine!
          nil
        end

        private

        # `require "minitest/autorun"` installs an at_exit hook that runs every registered
        # runnable and then calls `exit` with its own status. Inside a Constable run that
        # would re-run the whole cold-case docket at process exit and clobber Constable's
        # exit code. Minitest guards the hook with @@installed_at_exit, so claiming the
        # flag before we load anything makes a legacy file's `require "minitest/autorun"`
        # the no-op it needs to be. Deliberately not restored: a *later* cold-case file
        # requiring autorun would install the very hook we are preventing.
        def disable_autorun!
          return unless ::Minitest.class_variable_defined?(:@@installed_at_exit)

          ::Minitest.class_variable_set(:@@installed_at_exit, true)
        end

        def capture_load(path)
          load path
          nil
        rescue ScriptError, StandardError => e
          e
        end

        # Which runnable classes belong to the file we just loaded?
        #
        # The obvious answer -- whatever appeared in the registry during the load -- is
        # right exactly once per class per process. `load` on a file whose class constant
        # already exists *reopens* that class instead of creating one, so Runnable.inherited
        # never fires a second time and the registry diff comes back empty. That happens
        # whenever one process runs the same cold case twice (`jail run` after a normal
        # run) and constantly in this repo's own suite.
        #
        # So the diff is the first source and a source-location scan is the second: any
        # runnable class, seen now or on an earlier file, whose test methods were defined
        # in this file. Newly registered classes win on a name collision, which is what
        # keeps a Minitest::Spec `describe` (a brand new anonymous class every load) from
        # running once for its current definition and again for its predecessor.
        def discover_runnables(registry, snapshot, path)
          @known_runnables ||= []

          newly   = (registry - snapshot).select { |klass| runnable_class?(klass) }
          names   = newly.map(&:to_s)
          scanned = (registry | @known_runnables).select do |klass|
            runnable_class?(klass) && !newly.include?(klass) && !names.include?(klass.to_s) &&
              defines_methods_in?(klass, path)
          end

          found = newly + scanned
          warn "DBG path=" + path.to_s + " newly=" + newly.inspect + " scanned=" + scanned.inspect + " snapshot=" + snapshot.inspect + " registry=" + registry.inspect if ENV["CC_DBG"]
          @known_runnables |= found
          found
        end

        def runnable_class?(klass)
          klass.respond_to?(:runnable_methods) && klass.respond_to?(:name)
        end

        def defines_methods_in?(klass, path)
          klass.runnable_methods.any? do |method_name|
            location = klass.instance_method(method_name).source_location
            location && File.expand_path(location.first) == path
          end
        rescue StandardError, NameError
          false
        end

        def run_runnables(runnables, collector)
          reporter = ::Minitest::CompositeReporter.new
          reporter << collector
          reporter.start

          # Constable never re-orders a cold case, so nothing here touches Minitest's
          # own ordering: classes run in declaration order and each class orders its
          # own methods however `test_order` says it should.
          runnables.each do |klass|
            next unless klass.respond_to?(:runnable_methods)

            run_suite(klass, reporter)
          end

          reporter.report
        end

        # minitest 6 renamed the "run every method of this class" entry point from
        # Runnable.run to Runnable.run_suite (Runnable.run now runs a single method).
        def run_suite(klass, reporter)
          if klass.respond_to?(:run_suite)
            klass.run_suite(reporter, {})
          else
            klass.run(reporter, {})
          end
        end

        def build_results(path, minitest_results, config:, seed:, load_error:)
          relative   = ColdCase.relative_path(path, config: config)
          class_name = ColdCase.declared_class_name
          tier       = config.tier_for(path)

          results = minitest_results.map do |mt|
            result_for(mt, path: path, relative: relative, class_name: class_name,
                           config: config, tier: tier, seed: seed)
          end

          results << load_failure_result(path, relative, load_error, config: config, tier: tier, seed: seed) if load_error
          results
        end

        def result_for(mt, path:, relative:, class_name:, config:, tier:, seed:)
          description = description_for(mt)
          file, line  = location_of(mt, relative, config: config)

          result = Constable::Result.new(
            identity: Constable::Identity.for_cold_case(path, description, root: config.root),
            case_name: mt.klass.to_s.empty? ? (class_name || relative) : mt.klass.to_s,
            description: description,
            file: file,
            line: line,
            kind: :cold,
            tier: tier,
            status: status_for(mt),
            duration: mt.time.to_f,
            failure: failure_for(mt)
          )
          result.seed = seed
          result
        end

        # Minitest::Spec turns `it "creates a user"` into the method name
        # test_0001_creates a user. The ordinal is positional -- adding an example above
        # renumbers everything below it -- so stripping it is what keeps a cold case's
        # flake history attached to the right test across an ordinary edit.
        def description_for(mt)
          mt.name.to_s.sub(/\Atest_\d{4}_/, "")
        end

        def status_for(mt)
          return :skipped if mt.skipped?
          return :passed  if mt.failures.empty?
          return :errored if mt.failures.any? { |f| f.is_a?(::Minitest::UnexpectedError) }

          :failed
        end

        def failure_for(mt)
          return nil if mt.failures.empty? || mt.skipped?

          failure = mt.failures.first
          # UnexpectedError is a wrapper Minitest puts around a raised exception; the
          # real one underneath is what a developer needs to see.
          failure = failure.error if failure.is_a?(::Minitest::UnexpectedError) && failure.respond_to?(:error)

          message = mt.failures.size > 1 ? mt.failures.map(&:message).join("\n\n") : failure.message
          Constable::Failure.new(
            message: message.to_s,
            backtrace: Constable::Backtrace.clean(failure.backtrace),
            exception_class: failure.class.name
          )
        end

        def load_failure_result(path, relative, error, config:, tier:, seed:)
          description = "failed to load"
          result = Constable::Result.new(
            identity: Constable::Identity.for_cold_case(path, description, root: config.root),
            case_name: relative,
            description: description,
            file: relative,
            line: 1,
            kind: :cold,
            tier: tier,
            status: :errored,
            duration: 0.0,
            failure: Constable::Failure.from_exception(error)
          )
          result.seed = seed
          result
        end

        def location_of(mt, fallback_relative, config:)
          file, line = mt.source_location if mt.respond_to?(:source_location)
          return [fallback_relative, 1] if file.nil? || file.to_s == "unknown"

          [ColdCase.relative_path(file, config: config), (line || 1).to_i]
        end
      end
    end
  end
end
