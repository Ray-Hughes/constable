# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # Small AST helpers shared by every `Constable/*` cop: recognising the
      # `unsafe { }` escape hatch, and rendering receiver chains as readable names.
      #
      # `unsafe` is the one legal way to bend a native rule for a single call. It is
      # never silent -- the runtime emits a warning for every occurrence, with
      # `file:line` and the adjacent comment -- so the cops treat anything lexically
      # inside an `unsafe` block as already accounted for, and stay quiet.
      module Helpers
        extend ::RuboCop::AST::NodePattern::Macros

        # `unsafe { ... }`, `unsafe do ... end`, `unsafe("reason") { ... }`
        def_node_matcher :unsafe_block?, <<~PATTERN
          ({block numblock} (send nil? :unsafe ...) ...)
        PATTERN

        # @return [Boolean] whether the node sits lexically inside an `unsafe` block.
        def inside_unsafe_block?(node)
          node.each_ancestor(:block, :numblock).any? { |ancestor| unsafe_block?(ancestor) }
        end

        # Renders a statically-resolvable receiver chain as a dotted string:
        # `Time.now` -> "Time.now", `Time.zone.now` -> "Time.zone.now",
        # `Net::HTTP.get` -> "Net::HTTP.get". Returns nil when any link in the
        # chain takes arguments or isn't a constant/plain send.
        def qualified_call_name(node)
          return nil if node.nil?

          case node.type
          when :const
            name = node.const_name
            name && name.sub(/\A::/, "")
          when :send
            return nil unless node.arguments.empty?
            return node.method_name.to_s if node.receiver.nil?

            base = qualified_call_name(node.receiver)
            base && "#{base}.#{node.method_name}"
          end
        end

        # A constant node's dotless name: `(const (const nil :Net) :HTTP)` -> "Net::HTTP".
        def constant_string(node)
          name = node.const_name
          name && name.sub(/\A::/, "")
        end
      end
    end
  end
end
