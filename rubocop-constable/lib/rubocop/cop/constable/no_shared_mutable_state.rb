# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # Isolation is non-negotiable in native code. A class variable or a global
      # written from inside a case survives the investigation that wrote it, which
      # means the suite's result now depends on its order -- and the failure lands
      # on whichever test happened to run second, not on the one that caused it.
      # This is the single hardest class of flake to debug, so Constable simply
      # does not have a `before(:all)`.
      #
      # Reading `@@x` or `$x` is fine. This cop is about *writing*: assignment,
      # `||=`, `<<`, and the other in-place mutators.
      #
      # Use `witness` for per-test memoized data (never per-process), `briefing`
      # for per-test setup, and an ordinary instance variable for anything an
      # investigation needs to remember about itself.
      #
      # @example
      #   # bad
      #   class ImportCase < UnitCase
      #     @@rows = []
      #
      #     investigate "collects a row" do
      #       @@rows << build_row
      #       attest(@@rows.size).to eq(1)
      #     end
      #   end
      #
      #   # bad
      #   investigate "remembers the token" do
      #     $token = issue_token
      #   end
      #
      #   # good
      #   class ImportCase < UnitCase
      #     witness(:rows) { [] }
      #
      #     investigate "collects a row" do
      #       rows << build_row
      #       attest(rows.size).to eq(1)
      #     end
      #   end
      class NoSharedMutableState < Base
        include CaseScope
        include Helpers

        MSG_ASSIGN = "Assigning %<kind>s `%<name>s` leaks state between " \
                     "investigations and makes the suite order-dependent. Use " \
                     "`witness` for per-test data or `briefing` for per-test setup."

        MSG_MUTATE = "Mutating %<kind>s `%<name>s` with `%<method>s` leaks state " \
                     "between investigations and makes the suite order-dependent. " \
                     "Use `witness` for per-test data or `briefing` for per-test setup."

        ASSIGNMENT_TYPES = %i[cvasgn gvasgn].freeze
        OP_ASSIGNMENT_TYPES = %i[op_asgn or_asgn and_asgn].freeze

        # In-place mutators. Anything ending in `!` or `=` counts too, which is why
        # this list only needs the ones that break the convention.
        MUTATING_METHODS = %i[
          << push pop shift unshift concat insert append prepend
          clear delete delete_at delete_if keep_if
          replace fill store update
        ].freeze

        def on_cvasgn(node)
          return unless constable_case_file?
          return if operator_assignment_target?(node)
          return if inside_unsafe_block?(node)

          add_offense(node, message: format(MSG_ASSIGN, kind: "class variable", name: node.name))
        end

        def on_gvasgn(node)
          return unless constable_case_file?
          return if operator_assignment_target?(node)
          return if inside_unsafe_block?(node)

          add_offense(node, message: format(MSG_ASSIGN, kind: "global", name: node.name))
        end

        def on_op_asgn(node)
          return unless constable_case_file?
          return if inside_unsafe_block?(node)

          target = node.children.first
          return unless target.respond_to?(:type) && shared_state_type?(target.type)

          add_offense(node, message: format(MSG_ASSIGN, kind: kind_for(target), name: variable_name(target)))
        end
        alias on_or_asgn on_op_asgn
        alias on_and_asgn on_op_asgn

        def on_send(node)
          return unless constable_case_file?
          return if inside_unsafe_block?(node)

          receiver = node.receiver
          return unless receiver.respond_to?(:type) && shared_state_read_type?(receiver.type)
          return unless mutating_method?(node.method_name)

          add_offense(
            node,
            message: format(
              MSG_MUTATE,
              kind: kind_for(receiver),
              name: variable_name(receiver),
              method: node.method_name
            )
          )
        end
        alias on_csend on_send

        private

        # `@@x ||= []` parses as `(or-asgn (cvasgn :@@x) ...)`; the inner `cvasgn`
        # would otherwise be reported alongside its own operator assignment.
        def operator_assignment_target?(node)
          parent = node.parent
          !parent.nil? && OP_ASSIGNMENT_TYPES.include?(parent.type)
        end

        def shared_state_type?(type)
          ASSIGNMENT_TYPES.include?(type) || shared_state_read_type?(type)
        end

        def shared_state_read_type?(type)
          %i[cvar gvar].include?(type)
        end

        def kind_for(node)
          node.type.to_s.start_with?("cv") ? "class variable" : "global"
        end

        def variable_name(node)
          node.children.first
        end

        def mutating_method?(method_name)
          name = method_name.to_s
          MUTATING_METHODS.include?(method_name) || name.end_with?("!", "=")
        end
      end
    end
  end
end
