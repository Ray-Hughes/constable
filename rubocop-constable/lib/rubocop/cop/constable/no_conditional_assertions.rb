# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # An assertion behind a branch is an assertion that might not run. The test
      # goes green either way, so nobody notices when the interesting branch stops
      # being taken -- the case quietly stops testing anything while still counting
      # itself as coverage. Worse, the branch condition is usually the very thing
      # that varies between machines: an environment flag, a record that may or may
      # not exist, a feature toggle.
      #
      # Split the branches into separate investigations (or separate `docket`
      # blocks) so each one asserts unconditionally, and each one's name says which
      # world it describes.
      #
      # Only the outermost conditional wrapping an assertion is reported, so one
      # nested `if` tree yields one offense, not five.
      #
      # @example
      #   # bad
      #   investigate "creates the user" do
      #     if admin?
      #       attest(response).to be_created
      #     else
      #       attest(response).to be_forbidden
      #     end
      #   end
      #
      #   # bad
      #   attest(response).to be_created unless skip_check
      #
      #   # good
      #   docket "as an admin" do
      #     investigate("creates the user") { attest(response).to be_created }
      #   end
      #
      #   docket "as a guest" do
      #     investigate("is forbidden") { attest(response).to be_forbidden }
      #   end
      class NoConditionalAssertions < Base
        include CaseScope
        include Helpers

        MSG = "This %<construct>s decides whether an assertion runs at all, so the " \
              "case passes whichever way the branch falls. Split it into separate " \
              "investigations (or `docket` blocks) that each assert unconditionally."

        DEFAULT_ASSERTION_METHODS = %w[attest].freeze
        DEFAULT_ASSERTION_PREFIXES = %w[assert refute].freeze

        CONDITIONAL_TYPES = %i[if case case_match].freeze

        def on_if(node)
          return unless constable_case_file?

          check_conditional(node, node.ternary? ? "ternary" : "conditional")
        end

        def on_case(node)
          return unless constable_case_file?

          check_conditional(node, "`case`")
        end

        def on_case_match(node)
          return unless constable_case_file?

          check_conditional(node, "`case/in`")
        end

        private

        def check_conditional(node, construct)
          return unless assertion_in_branches?(node)
          return if outer_conditional?(node)
          return if inside_unsafe_block?(node)

          add_offense(offense_range(node), message: format(MSG, construct: construct))
        end

        # Report only the outermost conditional that guards an assertion.
        def outer_conditional?(node)
          node.each_ancestor(*CONDITIONAL_TYPES).any? { |ancestor| assertion_in_branches?(ancestor) }
        end

        # The condition itself may legitimately call a predicate; only the branch
        # bodies decide whether an assertion runs.
        def assertion_in_branches?(node)
          branch_bodies(node).any? { |body| assertion?(body) || body.each_descendant(:send, :csend).any? { |d| assertion?(d) } }
        end

        def branch_bodies(node)
          case node.type
          when :if
            [node.if_branch, node.else_branch].compact
          when :case
            (node.when_branches.map(&:body) + [node.else_branch]).compact
          when :case_match
            (node.in_pattern_branches.map(&:body) + [node.else_branch]).compact
          else
            []
          end
        end

        def assertion?(node)
          return false unless node.respond_to?(:send_type?) && (node.send_type? || node.csend_type?)

          name = node.method_name.to_s
          assertion_methods.include?(name) ||
            assertion_prefixes.any? { |prefix| name == prefix || name.start_with?("#{prefix}_") }
        end

        def offense_range(node)
          loc = node.loc
          return loc.keyword if loc.respond_to?(:keyword) && loc.keyword
          return loc.question if loc.respond_to?(:question) && loc.question

          node.source_range
        end

        def assertion_methods
          @assertion_methods ||= Array(cop_config.fetch("AssertionMethods", DEFAULT_ASSERTION_METHODS)).map(&:to_s)
        end

        def assertion_prefixes
          @assertion_prefixes ||= Array(cop_config.fetch("AssertionPrefixes", DEFAULT_ASSERTION_PREFIXES)).map(&:to_s)
        end
      end
    end
  end
end
