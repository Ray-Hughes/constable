# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # Reading the wall clock inside a case makes the test a function of when it
      # runs. Most of the time that is invisible; then the suite goes red at
      # midnight, on the last day of a month, or in the one CI region that isn't
      # UTC. Freeze the clock and the whole class of failure disappears.
      #
      # The cop is satisfied by any of:
      #
      # * a lexically enclosing `freeze_time { }` / `travel_to(...) { }` block,
      # * a bare `freeze_time` / `travel_to` earlier in the same `investigate`,
      # * a `freeze_time` / `travel_to` in any `briefing` in the file (a briefing
      #   runs before every investigation, so it covers all of them),
      # * being the argument to a freeze helper (`freeze_time(Time.now)` is fine),
      # * the `unsafe { }` escape hatch.
      #
      # @example
      #   # bad
      #   investigate "stamps the record" do
      #     attest(record.created_at).to eq(Time.now)
      #   end
      #
      #   # good
      #   investigate "stamps the record" do
      #     freeze_time
      #     attest(record.created_at).to eq(Time.now)
      #   end
      #
      #   # good
      #   briefing { freeze_time }
      #
      #   investigate "stamps the record" do
      #     attest(record.created_at).to eq(Time.current)
      #   end
      class NoUnfrozenTime < Base
        include CaseScope
        include Helpers

        MSG = "`%<call>s` reads the wall clock, which makes this investigation a " \
              "function of when it runs. Call `freeze_time` (or `travel_to`) first, " \
              "or reach for `unsafe { }` if the real clock is genuinely the subject."

        DEFAULT_FORBIDDEN_CALLS = %w[
          Time.now Time.current Time.zone.now
          Date.today Date.current
          DateTime.now DateTime.current
        ].freeze

        DEFAULT_FREEZE_HELPERS = %w[freeze_time travel_to].freeze

        # Blocks whose body is one investigation's worth of scope.
        SCOPE_METHODS = %i[investigate briefing docket witness].freeze

        def on_new_investigation
          @freeze_calls = nil
          super
        end

        def on_send(node)
          return unless constable_case_file?

          name = qualified_call_name(node)
          return unless name && forbidden_calls.include?(name)
          return if exempt?(node)

          add_offense(node, message: format(MSG, call: name))
        end
        alias on_csend on_send

        private

        def exempt?(node)
          inside_unsafe_block?(node) ||
            freeze_helper_argument?(node) ||
            inside_freeze_block?(node) ||
            frozen_by_briefing? ||
            frozen_earlier_in_scope?(node)
        end

        # `freeze_time(Time.now)` / `travel_to(Time.now + 1.day)` -- the clock read
        # is what gets frozen, so it cannot itself be unfrozen.
        def freeze_helper_argument?(node)
          # A freeze helper takes no receiver, so anything below it in the tree is
          # necessarily one of its arguments.
          node.each_ancestor(:send, :csend).any? { |ancestor| freeze_helper?(ancestor) }
        end

        def inside_freeze_block?(node)
          node.each_ancestor(:block, :numblock).any? do |ancestor|
            freeze_helper?(ancestor.send_node)
          end
        end

        def frozen_by_briefing?
          freeze_calls.any? { |call| inside_briefing?(call) }
        end

        # A bare `freeze_time` earlier in the same investigation covers everything
        # after it. When the call isn't inside a recognisable scope block at all
        # (a plain helper method, say), fall back to "anywhere earlier in the file".
        def frozen_earlier_in_scope?(node)
          scope = enclosing_scope(node)

          freeze_calls.any? do |call|
            next false if call.loc.line > node.loc.line

            scope.nil? || enclosing_scope(call).equal?(scope)
          end
        end

        def enclosing_scope(node)
          node.each_ancestor(:block, :numblock).find do |ancestor|
            send_node = ancestor.send_node
            send_node.receiver.nil? && SCOPE_METHODS.include?(send_node.method_name)
          end
        end

        def inside_briefing?(node)
          node.each_ancestor(:block, :numblock).any? do |ancestor|
            send_node = ancestor.send_node
            send_node.receiver.nil? && send_node.method_name == :briefing
          end
        end

        def freeze_helper?(node)
          return false unless node.respond_to?(:method_name)
          return false unless node.receiver.nil?

          freeze_helpers.include?(node.method_name.to_s)
        end

        def freeze_calls
          @freeze_calls ||= begin
            ast = processed_source&.ast
            if ast.nil?
              []
            else
              ast.each_node(:send, :csend).select { |send_node| freeze_helper?(send_node) }
            end
          end
        end

        def forbidden_calls
          @forbidden_calls ||= Array(cop_config.fetch("ForbiddenCalls", DEFAULT_FORBIDDEN_CALLS)).map(&:to_s)
        end

        def freeze_helpers
          @freeze_helpers ||= Array(cop_config.fetch("FreezeHelpers", DEFAULT_FREEZE_HELPERS)).map(&:to_s)
        end
      end
    end
  end
end
