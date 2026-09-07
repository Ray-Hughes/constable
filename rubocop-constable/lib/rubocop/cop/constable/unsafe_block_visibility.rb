# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # Every escape hatch is visible. `unsafe { }` is allowed to exist -- it is the
      # honest way to say "this one call really does need to bend a rule" -- but an
      # `unsafe` with nothing next to it is just a rule being broken quietly, and
      # the next person to read it has no way to tell whether it is still needed.
      #
      # So this cop does not object to `unsafe` at all. It objects only to an
      # `unsafe` that does not say why. A trailing comment on the same line, or a
      # comment on the line immediately above, satisfies it -- and that comment is
      # what the runner quotes in the WARNINGS section of every run summary:
      #
      #   ⚠ spec/controllers/sessions_case.rb:44
      #     unsafe { sleep(0.1) } -- "testing an actual timeout path, not a code smell"
      #
      # A literal reason passed to `unsafe("...")` counts as well, since the runtime
      # DSL reports that string the same way. Set `AllowReasonArgument: false` to
      # insist on a comment.
      #
      # @example
      #   # bad
      #   unsafe { sleep(0.1) }
      #
      #   # good
      #   unsafe { sleep(0.1) } # testing an actual timeout path, not a code smell
      #
      #   # good
      #   # testing an actual timeout path, not a code smell
      #   unsafe do
      #     sleep(0.1)
      #   end
      #
      #   # good (with AllowReasonArgument: true, the default)
      #   unsafe("testing an actual timeout path, not a code smell") { sleep(0.1) }
      class UnsafeBlockVisibility < Base
        include CaseScope
        include Helpers

        MSG = "This `unsafe` block has nothing saying why. Every escape hatch is " \
              "reported in the run summary, so give it a reason: a trailing comment, " \
              "a comment on the line above, or `unsafe(\"reason\") { }`."

        def on_block(node)
          return unless constable_case_file?
          return unless unsafe_block?(node)
          return if justified?(node)

          add_offense(node.send_node)
        end
        alias on_numblock on_block

        private

        def justified?(node)
          reason_argument?(node.send_node) || adjacent_comment?(node)
        end

        def reason_argument?(send_node)
          return false unless allow_reason_argument?

          argument = send_node.first_argument
          return false if argument.nil?
          return false unless argument.respond_to?(:type)

          case argument.type
          when :str then !argument.value.to_s.strip.empty?
          when :dstr, :sym then true
          else false
          end
        end

        # "Adjacent" means the same line (a trailing comment) or the line directly
        # above. A comment three lines up is documenting something else.
        def adjacent_comment?(node)
          line = node.send_node.loc.line

          comment_text?(line) || comment_text?(line - 1)
        end

        def comment_text?(line)
          return false if line < 1

          comment = processed_source.comment_at_line(line)
          return false if comment.nil?

          !comment.text.to_s.sub(/\A#+/, "").strip.empty?
        end

        def allow_reason_argument?
          cop_config.fetch("AllowReasonArgument", true)
        end
      end
    end
  end
end
