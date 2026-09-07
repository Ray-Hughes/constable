# frozen_string_literal: true

module Constable
  # Isolation is non-negotiable in native code. Everything that makes one investigation
  # unable to reach another lives here: the rolled-back transaction, the fresh instance,
  # and the leak check that catches what the transaction can't (globals, ENV, class
  # variables -- the state a database rollback never touches).
  module Isolation
    # Tiers below :integration are supposed to boot without a database at all, so wrapping
    # them in a transaction would force the very connection the tier exists to avoid.
    NON_TRANSACTIONAL_TIERS = %i[unit].freeze

    module_function

    def transactional?(tier)
      return false if NON_TRANSACTIONAL_TIERS.include?(tier)
      return false unless defined?(::ActiveRecord::Base)

      ::ActiveRecord::Base.connected? || ::ActiveRecord::Base.respond_to?(:connection)
    rescue StandardError
      false
    end

    # Runs the block inside a transaction that is always rolled back, so nothing a test
    # writes survives it. Falls through to a plain yield when there's no database.
    def with_rollback(tier)
      return yield unless transactional?(tier)

      result = nil
      ::ActiveRecord::Base.transaction(requires_new: true) do
        result = yield
        raise ::ActiveRecord::Rollback
      end
      result
    end

    # A cheap snapshot of the process-level state a rollback would never restore.
    def snapshot
      {
        globals: global_snapshot,
        env: ENV.to_h,
        class_variables: class_variable_snapshot,
        constants: Object.constants.size
      }
    end

    # Compares two snapshots and describes what leaked, in the terms a developer can act
    # on. Returns [] when the investigation left the process as it found it.
    def diff(before, after)
      leaks = []

      added_globals = after[:globals].keys - before[:globals].keys
      changed_globals = (after[:globals].keys & before[:globals].keys).reject do |key|
        after[:globals][key] == before[:globals][key]
      end
      leaks << "set global #{added_globals.join(', ')}" if added_globals.any?
      leaks << "mutated global #{changed_globals.join(', ')}" if changed_globals.any?

      added_env = after[:env].keys - before[:env].keys
      changed_env = (after[:env].keys & before[:env].keys).reject { |k| after[:env][k] == before[:env][k] }
      leaks << "set ENV #{added_env.join(', ')}" if added_env.any?
      leaks << "mutated ENV #{changed_env.join(', ')}" if changed_env.any?

      added_cvars = after[:class_variables] - before[:class_variables]
      leaks << "set class variable #{added_cvars.join(', ')}" if added_cvars.any?

      leaks
    end

    # $stdout and friends move around legitimately during a run (the reporter captures
    # them), and read-only specials are noise rather than signal.
    IGNORED_GLOBALS = %i[
      $stdout $stderr $stdin $! $@ $~ $& $` $' $+ $1 $2 $3 $4 $5 $6 $7 $8 $9
      $0 $PROGRAM_NAME $LOAD_PATH $LOADED_FEATURES $" $: $$ $? $, $; $/ $\ $. $_
      $DEBUG $VERBOSE $FILENAME $stdlog
    ].freeze

    def global_snapshot
      (global_variables - IGNORED_GLOBALS).each_with_object({}) do |name, out|
        value = begin
          eval(name.to_s) # rubocop:disable Security/Eval -- the only way to read a global by name
        rescue StandardError
          :unreadable
        end
        out[name] = safe_identity(value)
      end
    end

    def class_variable_snapshot
      ObjectSpace.each_object(Class).flat_map do |klass|
        next [] unless user_defined?(klass)

        klass.class_variables.map { |cvar| "#{klass}.#{cvar}" }
      rescue StandardError
        []
      end.sort
    end

    # Only the app's own classes matter -- walking every gem's constants would make the
    # leak check cost more than the tests it guards.
    def user_defined?(klass)
      return false if klass.singleton_class?

      name = klass.name
      return false if name.nil?
      return false if name.start_with?("Constable", "Minitest", "RSpec", "ActiveSupport", "ActiveRecord")

      true
    rescue StandardError
      false
    end

    # Compares by value where that's cheap and safe, by object identity otherwise, so the
    # check never accidentally deep-freezes or serializes an application object.
    def safe_identity(value)
      case value
      when nil, true, false, Numeric, Symbol then value
      when String then value.dup
      when Array, Hash then value.size
      else value.object_id
      end
    end
  end
end
