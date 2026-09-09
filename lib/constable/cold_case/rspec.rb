# frozen_string_literal: true

# Only ever reached through Constable::ColdCase, which requires the engine first and
# turns a missing gem into an actionable message. Never require this file directly.
require "rspec/core"
require "stringio"

module Constable
  module ColdCase
    # The one-line superclass swap. The file below keeps its original body character for
    # character; only the wrapper changed:
    #
    #   class LegacyUsersSpec < Constable::ColdCase::RSpec
    #     describe UsersController do
    #       it "creates a user" do
    #         post users_path, params: valid_params
    #         expect(response).to have_http_status(:created)
    #       end
    #     end
    #   end
    #
    # A Ruby class body executes with `self` set to the class, so the bare `describe`,
    # `context`, `it`, `let` and `before` calls in that body land on *this* class's
    # singleton. All we do is forward them into the real RSpec engine:
    #
    #   * group-creating calls (describe/context/shared_examples/feature) go to the
    #     top level, so descriptions read "UsersController creates a user" and not
    #     "LegacyUsersSpec UsersController creates a user" -- the file reports exactly
    #     as it did before adoption;
    #   * anything else (it/let/before/after/subject/around/...) goes to an implicit
    #     top-level group named after the class, so a file with no `describe` at all
    #     still runs.
    #
    # No RSpec behaviour is reimplemented here. Every one of these calls ends up in
    # RSpec::Core, which is the only way a cold case can be trusted to behave the way it
    # did the day before someone changed one line.
    class RSpec
      # Calls that create an example group of their own.
      GROUP_METHODS = %i[
        describe context xdescribe xcontext fdescribe fcontext
        example_group feature xfeature ffeature
        shared_examples shared_examples_for shared_context
      ].freeze

      class << self
        def cold_case_engine = :rspec

        def inherited(subclass)
          super
          ColdCase.note_cold_class(subclass)
        end

        GROUP_METHODS.each do |method_name|
          define_method(method_name) do |*args, **kwargs, &block|
            ColdCase.require_engine!(:rspec)
            target = ::RSpec.respond_to?(method_name) ? ::RSpec : cold_case_group
            target.public_send(method_name, *args, **kwargs, &block)
          end
        end

        # `it`, `let`, `before`, `subject`, `around`, `pending`, custom aliases a user
        # registered with RSpec.configure -- all of them, without us having to keep a
        # list in sync with rspec-core's.
        def method_missing(method_name, ...)
          ColdCase.require_engine!(:rspec)
          return super unless ::RSpec::Core::ExampleGroup.respond_to?(method_name)

          cold_case_group.public_send(method_name, ...)
        end

        def respond_to_missing?(method_name, include_private = false)
          (defined?(::RSpec::Core::ExampleGroup) &&
            ::RSpec::Core::ExampleGroup.respond_to?(method_name)) || super
        end

        # The implicit group, created on first use only. Memoized against the RSpec world
        # it was created in: the adapter installs a fresh world per file, and a class body
        # re-executed by a second `load` must not append examples to a group that belongs
        # to a world nobody is running any more.
        def cold_case_group
          world = ::RSpec.world
          return @cold_case_group if @cold_case_group && @cold_case_group_world.equal?(world)

          @cold_case_group_world = world
          @cold_case_group = ::RSpec.describe(cold_case_description)
        end

        def cold_case_description
          name || "cold case"
        end
      end
    end

    # Drives rspec-core over one file and translates its verdicts into Constable Results.
    module RSpecAdapter
      # A listener rather than a formatter: we want the examples themselves, not text.
      # :example_finished fires once for every example whatever its outcome, so passes,
      # failures and pendings all arrive through one hook in the engine's own order.
      class Collector
        attr_reader :examples

        def initialize
          @examples = []
        end

        def example_finished(notification)
          @examples << notification.example
        end
      end

      class << self
        def engine = :rspec
        def base_class_name = "Constable::ColdCase::RSpec"

        def run_file(path, config: Constable.config, seed: nil)
          ColdCase.require_engine!(:rspec, path: path)

          results = []
          ColdCase.while_loading(path) do
            with_engine do
              collector  = Collector.new
              load_error = capture_load(path)
              load_error ||= quit_flag_error(path)
              unless load_error
                # After the file has loaded -- that load is what registers them -- and
                # before its examples run. See #run_pending_before_suite_hooks.
                run_pending_before_suite_hooks(::RSpec.configuration)
                run_world(collector)
              end

              ColdCase.warn_for_file(path, base_class_name, collector.examples.size, config: config)
              results = build_results(path, collector.examples, config: config, seed: seed,
                                                                load_error: load_error)
            end
          end
          results
        end

        # Forgets the cold-case session entirely. The next run_file builds a fresh
        # configuration -- which also means any RSpec.configure hooks a rails_helper
        # installed are gone, so this is a teardown call, not a between-files call.
        def reset_engine!
          # Inside the global-state swap, not outside it. Building a SuiteHookContext
          # makes rspec-core lazily construct a world and a configuration, so running
          # these hooks bare would leave both behind in a host process that had none --
          # exactly the leak #with_engine exists to prevent.
          with_engine { run_after_suite_hooks! } if after_suite_hooks_pending?

          @session_world = nil
          @session_configuration = nil
          @session_prepared = false
          @ran_before_suite_hooks = nil
          @shared_examples = nil
          nil
        end

        private

        # --- Suite hooks ------------------------------------------------------------
        #
        # RSpec's own Runner wraps its group loop in `configuration.with_suite_hooks`.
        # We drive the groups directly (see #run_world), so without this a cold case
        # never fires `before(:suite)` -- and that is exactly where webmock/rspec calls
        # `WebMock.enable!`, where VCR and DatabaseCleaner install themselves, and where
        # SimpleCov starts. Skipping them fails *open*: a spec that stubs HTTP opens a
        # real socket instead of erroring, which is the worst direction for a testing
        # tool to be wrong in.
        #
        # `with_suite_hooks` itself is the wrong shape here. It is a bracket around one
        # block, but "suite" means the whole run rather than one file: wrapping each file
        # would fire `after(:suite)` after file one and hand file two the wreckage. Nor
        # can the hooks all be run up front, because a legacy file's own
        # `require "rails_helper"` is what registers them -- before the first load there
        # is nothing to run.
        #
        # So each hook runs exactly once, the first time we see it: after a file has
        # loaded, before its examples. `after(:suite)` runs once, from #reset_engine!.
        def run_pending_before_suite_hooks(configuration)
          pending = suite_hooks(configuration, :@before_suite_hooks) - ran_before_suite_hooks
          return if pending.empty?

          ran_before_suite_hooks.concat(pending)
          invoke_suite_hooks(configuration, "a `before(:suite)` hook", pending,
                             scope: :before_suite_hook)
        end

        # Only worth running if we ever ran the matching before(:suite) half -- otherwise
        # this is a teardown for setup that never happened.
        def run_after_suite_hooks!
          configuration = @session_configuration
          return if configuration.nil? || ran_before_suite_hooks.empty?

          hooks = suite_hooks(configuration, :@after_suite_hooks)
          return if hooks.empty?

          invoke_suite_hooks(configuration, "an `after(:suite)` hook", hooks,
                             scope: :after_suite_hook)
        end

        def ran_before_suite_hooks
          @ran_before_suite_hooks ||= []
        end

        # Nothing was set up, so there is nothing to tear down -- and no reason to build
        # an RSpec world to discover that.
        def after_suite_hooks_pending?
          !@session_configuration.nil? &&
            ran_before_suite_hooks.any? &&
            suite_hooks(@session_configuration, :@after_suite_hooks).any?
        end

        # RSpec keeps these in plain ivars with no public reader. Read them defensively:
        # a missing ivar means a version that stores them elsewhere, and running no suite
        # hooks is the behavior we already had.
        def suite_hooks(configuration, ivar)
          return [] unless configuration.respond_to?(:instance_variable_defined?)
          return [] unless configuration.instance_variable_defined?(ivar)

          Array(configuration.instance_variable_get(ivar))
        end

        # `run_suite_hooks` is private on Configuration, and it is the part that builds a
        # SuiteHookContext and keeps one failing before-hook from running the rest. Use it
        # when it is there, and fall back to driving the hooks ourselves when it is not.
        def invoke_suite_hooks(configuration, description, hooks, scope:)
          previous = ::RSpec.current_scope if ::RSpec.respond_to?(:current_scope)
          ::RSpec.current_scope = scope if ::RSpec.respond_to?(:current_scope=)

          if configuration.respond_to?(:run_suite_hooks, true)
            configuration.send(:run_suite_hooks, description, hooks)
          else
            context = ::RSpec::Core::SuiteHookContext.new(description, configuration.reporter)
            hooks.each { |hook| hook.run(context) }
          end
        ensure
          ::RSpec.current_scope = previous if previous && ::RSpec.respond_to?(:current_scope=)
        end

        # Running RSpec in-process is a global-state problem: RSpec.world holds every
        # registered example group and RSpec.configuration holds every hook. We swap in a
        # session world/configuration for the duration of a file and put whatever was
        # there back afterwards, so a host process that has its own RSpec state (or, more
        # often, our own Minitest suite, which has none) is left exactly as we found it.
        #
        # The configuration is deliberately kept ALIVE between files while the world is
        # cleared between them. A legacy spec's `require "rails_helper"` only executes
        # once per process; if we threw the configuration away after each file, every hook
        # and inclusion that rails_helper registered would vanish for file number two.
        def with_engine
          outer_world  = ::RSpec.instance_variable_get(:@world)
          outer_config = ::RSpec.instance_variable_get(:@configuration)

          ::RSpec.instance_variable_set(:@world, @session_world)
          ::RSpec.instance_variable_set(:@configuration, @session_configuration)
          prepare_session_configuration(::RSpec.configuration)
          clear_examples
          restore_shared_examples!

          yield
        ensure
          remember_shared_examples!
          @session_world         = ::RSpec.instance_variable_get(:@world)
          @session_configuration = ::RSpec.instance_variable_get(:@configuration)
          clear_examples
          # Only safe to drop the generated group constants when nobody else owned an
          # RSpec world before us; otherwise they may still be naming someone's groups.
          ::RSpec::ExampleGroups.remove_all_constants if outer_world.nil?
          ::RSpec.instance_variable_set(:@world, outer_world)
          ::RSpec.instance_variable_set(:@configuration, outer_config)
        end

        # stdout belongs to Constable's reporter alone (SPEC.md: "stdout is results
        # only"), so the engine's own progress dots and failure dumps go to a buffer we
        # throw away. Set once, so a spec file's own RSpec.configure can still override.
        def prepare_session_configuration(configuration)
          return if @session_prepared

          configuration.output_stream      = StringIO.new
          configuration.deprecation_stream = StringIO.new
          configuration.error_stream       = StringIO.new if configuration.respond_to?(:error_stream=)
          configuration.color_mode         = :off if configuration.respond_to?(:color_mode=)
          # rspec-core's own default; restated because rspec-rails turns it off and a
          # verbatim legacy file may well open with a bare `describe`.
          configuration.expose_dsl_globally = true if configuration.respond_to?(:expose_dsl_globally=)
          apply_rspec_options(configuration)
          @session_prepared = true
        end

        # `.rspec` is where a suite says what to load before any spec file.
        #
        #   --require spec_helper
        #   --require rails_helper
        #
        # That is what `rspec --init` generates, and it is why a real spec file usually
        # has no `require` line of its own -- there is nothing for it to repeat. RSpec's
        # own runner reads those files; driving example groups directly does not, so
        # without this a cold case runs with no rails_helper at all: no FactoryBot, no
        # shoulda-matchers, no spec/support. In one real suite that was 2,637 tests
        # failing on `undefined method 'create'` -- a suite that is entirely green under
        # `bundle exec rspec`.
        #
        # Only `--require` is taken. Formatters, colour and output streams belong to
        # Constable's reporter, ordering is Constable's job, and a `--tag` filter from a
        # file RSpec would apply to its own run should not silently drop tests from this
        # one. Requires are the part that decides whether the suite can run at all.
        def apply_rspec_options(configuration)
          requires = rspec_option_requires
          return if requires.empty?

          # Deliberately NOT `configuration.requires =`, which is RSpec's own accessor.
          # That routes through Configuration#load_file_handling_errors, which rescues
          # anything raised while loading, reports it through a formatter, and sets
          # `world.wants_to_quit`. Since stdout belongs to Constable's reporter, RSpec's
          # streams are a throwaway StringIO, so that report goes nowhere -- and every
          # later ExampleGroup.run returns immediately. The file loads, the examples
          # register, and none of them run. A forked worker produced no results, no error
          # and no exception, and exited 0.
          #
          # So the load path is set up the same way and the requires are done here, where
          # an exception is an exception and carries its own message and backtrace.
          add_spec_load_paths!(configuration)
          requires.each { |path| require path }
          configuration.instance_variable_set(:@requires, requires)
        rescue Constable::Error
          raise
        rescue StandardError => e
          # A helper that will not load is the suite's problem to fix, and it will say so
          # loudly on the first file. Constable's job here is not to disappear.
          Constable.warn!("could not load what .rspec requires (#{e.class}: #{e.message}). " \
                          "Cold cases will run without it.", kind: :cold_case)
        end

        # What `configuration.requires=` does before requiring anything: puts `lib` and the
        # default path (`spec`) on the load path, which is what makes a bare
        # `require "rails_helper"` resolve at all.
        def add_spec_load_paths!(configuration)
          default_path = configuration.default_path if configuration.respond_to?(:default_path)
          ["lib", default_path].compact.uniq.each do |dir|
            absolute = File.expand_path(dir, Constable.root)
            $LOAD_PATH.unshift(absolute) if File.directory?(absolute) && !$LOAD_PATH.include?(absolute)
          end
        end

        # RSpec does not let an error in a required file reach you.
        # Configuration#load_file_handling_errors rescues anything raised while loading,
        # reports it through `notify_non_example_exception`, and sets
        # `world.wants_to_quit = true`. Every later ExampleGroup.run then returns
        # immediately, so the file loads, the examples register, and none of them run.
        #
        # We point RSpec's output at a throwaway StringIO -- stdout belongs to the
        # reporter -- so that report goes nowhere. The result was a forked worker that
        # produced no results, no error and no exception, and exited 0. It took a probe
        # inside the child to find that `wants_to_quit` was the difference.
        #
        # So: ask, and put the swallowed message back in front of the user.
        def raise_if_loading_failed!(configuration, requires)
          return unless ::RSpec.world.wants_to_quit

          # Clear it, or every later file in this session inherits the flag and runs
          # nothing either.
          ::RSpec.world.wants_to_quit = false

          raise Constable::Error,
                "RSpec could not load #{requires.join(", ")} (from .rspec). " \
                "#{swallowed_output(configuration)}".strip
        end

        # Whatever RSpec wrote about it before we could ask. Its streams are ours, so this
        # is the only copy in existence.
        def swallowed_output(configuration)
          [configuration.error_stream, configuration.output_stream, configuration.deprecation_stream]
            .uniq
            .filter_map { |io| io.string.to_s.strip if io.respond_to?(:string) }
            .reject(&:empty?)
            .first.to_s
        rescue StandardError
          ""
        end

        # Parsed by RSpec itself, so `.rspec`, `~/.rspec`, `.rspec-local` and SPEC_OPTS are
        # all read with its precedence rather than a guess at the format.
        def rspec_option_requires
          return [] unless defined?(::RSpec::Core::ConfigurationOptions)

          options = ::RSpec::Core::ConfigurationOptions.new([]).options
          Array(options[:requires])
        rescue StandardError
          []
        end

        # Shared examples are registered on the world, by `require`, once per process.
        #
        # A suite that keeps them in a plain file next to its specs -- `require_relative
        # "appeal_shared_examples"` at the top of appeal_spec.rb -- registers them while
        # the first file runs. `require` never fires again, so if the registry does not
        # survive into the next file, every later file that shares them dies on load with
        # `Could not find shared examples "toggle overtime"`.
        #
        # Under RSpec that never happens: it loads every spec file first, then runs them.
        # Constable loads one file at a time, which is what makes a cold case cheap, so
        # the registry has to be carried across by hand. Observed on a real suite: twelve
        # files failing to load, all of which pass in isolation.
        def remember_shared_examples!
          world = ::RSpec.instance_variable_get(:@world)
          return unless world.respond_to?(:shared_example_group_registry)

          @shared_examples = world.shared_example_group_registry
        rescue StandardError
          nil
        end

        def restore_shared_examples!
          return if @shared_examples.nil?

          world = ::RSpec.world
          return unless world.respond_to?(:shared_example_group_registry)

          world.instance_variable_set(:@shared_example_group_registry, @shared_examples)
        rescue StandardError
          nil
        end

        def clear_examples
          world = ::RSpec.instance_variable_get(:@world)
          world.reset if world.respond_to?(:reset)

          configuration = ::RSpec.instance_variable_get(:@configuration)
          return unless configuration

          configuration.reset_reporter if configuration.respond_to?(:reset_reporter)
          configuration.reset_filters  if configuration.respond_to?(:reset_filters)
          configuration.start_time = ::RSpec::Core::Time.now if configuration.respond_to?(:start_time=)
        end

        # Same swallowing, one level down: a `require` inside the spec file that fails is
        # rescued by RSpec, flagged, and never surfaced. Without this the file reports as
        # a clean run of zero tests.
        def quit_flag_error(path)
          return nil unless ::RSpec.world.wants_to_quit

          ::RSpec.world.wants_to_quit = false
          Constable::Error.new(
            "RSpec stopped while loading #{path}. #{swallowed_output(::RSpec.configuration)}".strip
          )
        end

        # A file that won't even parse is news, not a crash. Report it as one errored
        # result so the run keeps going and the summary names the file.
        def capture_load(path)
          load path
          nil
        rescue ScriptError, StandardError => e
          e
        end

        def run_world(collector)
          configuration = ::RSpec.configuration
          world         = ::RSpec.world
          reporter      = configuration.reporter
          reporter.register_listener(collector, :example_finished)

          # ordered_example_groups applies RSpec's *own* ordering, which defaults to
          # declaration order. Constable never shuffles a cold case: random order is a
          # native-case guarantee, and imposing it on a suite that was never isolated
          # would invent failures.
          reporter.report(world.example_count) do |rep|
            world.ordered_example_groups.each { |group| group.run(rep) }
          end
        end

        def build_results(path, examples, config:, seed:, load_error:)
          relative = ColdCase.relative_path(path, config: config)
          class_name = ColdCase.declared_class_name
          tier      = config.tier_for(path)

          results = examples.map do |example|
            result_for(example, path: path, relative: relative, class_name: class_name,
                                config: config, tier: tier, seed: seed)
          end

          if load_error
            results << load_failure_result(path, relative, load_error, config: config, tier: tier,
                                                                       seed: seed)
          end
          results
        end

        def result_for(example, path:, relative:, class_name:, config:, tier:, seed:)
          execution   = example.execution_result
          description = example.full_description.to_s
          file, line  = location_of(example, relative, config: config)

          result = Constable::Result.new(
            identity: Constable::Identity.for_cold_case(path, description, root: config.root),
            case_name: class_name || top_group_description(example) || relative,
            description: description,
            file: file,
            line: line,
            kind: :cold,
            tier: tier,
            status: status_for(execution),
            duration: execution.run_time.to_f,
            failure: failure_for(execution)
          )
          result.seed = seed
          result
        end

        def status_for(execution)
          case execution.status
          when :passed  then :passed
          when :pending then :skipped
          else
            expectation_failure?(execution.exception) ? :failed : :errored
          end
        end

        def expectation_failure?(exception)
          return false unless exception
          return true if defined?(::RSpec::Expectations::ExpectationNotMetError) &&
                         exception.is_a?(::RSpec::Expectations::ExpectationNotMetError)
          return true if defined?(::RSpec::Expectations::MultipleExpectationsNotMetError) &&
                         exception.is_a?(::RSpec::Expectations::MultipleExpectationsNotMetError)

          false
        end

        def failure_for(execution)
          return nil if execution.status == :passed

          exception = execution.exception
          return nil unless exception

          Constable::Failure.from_exception(exception)
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

        # RSpec knows exactly which line the `it` block sits on -- that is the line a
        # developer wants in the summary, not a frame from inside the engine.
        def location_of(example, fallback_relative, config:)
          metadata = example.metadata || {}
          file = metadata[:absolute_file_path] || metadata[:file_path]
          line = metadata[:line_number]
          return [fallback_relative, 1] unless file

          [ColdCase.relative_path(file, config: config), (line || 1).to_i]
        end

        def top_group_description(example)
          group = example.example_group
          return nil unless group.respond_to?(:parent_groups)

          outermost = group.parent_groups.last || group
          description = outermost.description.to_s
          description.empty? ? nil : description
        end
      end
    end
  end
end
