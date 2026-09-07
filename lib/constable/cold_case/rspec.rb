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
              run_world(collector) unless load_error

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
          @session_world = nil
          @session_configuration = nil
          @session_prepared = false
          nil
        end

        private

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

          yield
        ensure
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
          @session_prepared = true
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
