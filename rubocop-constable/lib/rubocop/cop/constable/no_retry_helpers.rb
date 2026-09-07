# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # Retrying is how a flaky test hides. `retry`, `eventually { }`, `wait_for`
      # and hand-rolled polling loops all take a test that fails some of the time
      # and turn it into a test that passes most of the time -- which is strictly
      # worse, because now nobody is looking at it. The real defect stays in the
      # code, and the suite gets slower on every run that has to use the retries.
      #
      # Constable has a first-class answer for genuine flakiness: **warrants**.
      # Turn them on and the runner reruns a failing test in isolation, records
      # what it finds in the blotter, and reports it in its own section -- visible,
      # counted, and never quietly swallowed by a `rescue; retry; end`.
      #
      # `wait_for(timeout:, interval:)` does exist in the runtime DSL for genuinely
      # asynchronous things, but it is legal only inside `unsafe { }`; outside it,
      # the DSL raises. This cop enforces the same rule statically.
      #
      # Polling loops are recognised by their signature: a `loop`/`while`/`until`
      # whose body sleeps. That is a deliberately narrow heuristic -- an ordinary
      # `while` that does real work is left alone.
      #
      # @example
      #   # bad
      #   begin
      #     attest(job).to be_finished
      #   rescue Constable::AssertionFailed
      #     retry
      #   end
      #
      #   # bad
      #   eventually { attest(page).to have_content("Done") }
      #
      #   # bad
      #   until job.reload.finished?
      #     sleep 0.1
      #   end
      #
      #   # good
      #   perform_enqueued_jobs
      #   attest(job.reload).to be_finished
      #
      #   # good -- genuinely async, on the record
      #   # the browser drives this repaint on its own schedule
      #   unsafe { wait_for(timeout: 2, interval: 0.05) { page.has_content?("Done") } }
      class NoRetryHelpers < Base
        include CaseScope
        include Helpers

        MSG_RETRY = "`retry` turns a failing investigation into a passing one " \
                    "without fixing anything. Remove the retry and let the failure " \
                    "stand -- if the test is genuinely flaky, that is what warrants " \
                    "(`constable test --warrants`) are for."

        MSG_HELPER = "`%<name>s` is a retry helper, and retrying is how a flaky " \
                     "test hides. Assert on the completed state instead, or wrap it " \
                     "in `unsafe { }` with a comment if the work is genuinely async."

        MSG_LOOP = "This %<construct>s polls with `sleep`, which is a retry loop " \
                   "wearing a different hat: slow when it passes, flaky when it " \
                   "does not. Assert on the completed state, or wrap it in " \
                   "`unsafe { }` with a comment if the work is genuinely async."

        DEFAULT_RETRY_HELPERS = %w[
          wait_for
          eventually
          with_retries
          try_again
          retry_until
          retry_on_failure
          poll_until
          keep_trying
        ].freeze

        LOOP_TYPES = %i[while until while_post until_post].freeze

        def on_retry(node)
          return unless constable_case_file?
          return if inside_unsafe_block?(node)

          add_offense(node, message: MSG_RETRY)
        end

        def on_send(node)
          return unless constable_case_file?
          return unless node.receiver.nil?

          name = node.method_name.to_s
          return unless retry_helpers.include?(name)
          return if inside_unsafe_block?(node)

          add_offense(node, message: format(MSG_HELPER, name: name))
        end
        alias on_csend on_send

        def on_while(node)
          return unless constable_case_file?
          return unless sleeps_in_body?(node.body)
          return if inside_unsafe_block?(node)

          add_offense(offense_range(node), message: format(MSG_LOOP, construct: "`#{node.keyword}`"))
        end
        alias on_until on_while
        alias on_while_post on_while
        alias on_until_post on_while

        def on_block(node)
          return unless constable_case_file?
          return unless kernel_loop?(node)
          return unless sleeps_in_body?(node.body)
          return if inside_unsafe_block?(node)

          add_offense(node.send_node, message: format(MSG_LOOP, construct: "`loop`"))
        end
        alias on_numblock on_block

        private

        def kernel_loop?(node)
          send_node = node.send_node
          send_node.receiver.nil? && send_node.method_name == :loop && send_node.arguments.empty?
        end

        def sleeps_in_body?(body)
          return false if body.nil?

          sleep_call?(body) || body.each_descendant(:send, :csend).any? { |node| sleep_call?(node) }
        end

        def sleep_call?(node)
          return false unless node.respond_to?(:method_name)
          return false unless node.method_name == :sleep

          receiver = node.receiver
          receiver.nil? || (receiver.const_type? && constant_string(receiver) == "Kernel")
        end

        def offense_range(node)
          loc = node.loc
          return loc.keyword if loc.respond_to?(:keyword) && loc.keyword

          node.source_range
        end

        def retry_helpers
          @retry_helpers ||= Array(cop_config.fetch("RetryHelpers", DEFAULT_RETRY_HELPERS)).map(&:to_s)
        end
      end
    end
  end
end
