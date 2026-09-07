# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # A bare `sleep` is the single most common way a suite becomes both slow and
      # flaky at once. It buys time the machine may not need and, on a loaded CI
      # box, may not be enough of -- so it costs seconds on every green run and
      # still fails on the red one.
      #
      # Wait on the condition itself instead. If the sleep *is* the subject under
      # test -- you are exercising a real timeout path -- say so out loud with the
      # `unsafe` escape hatch, which is reported in every run summary until someone
      # deals with it.
      #
      # @example
      #   # bad
      #   investigate "expires the session" do
      #     sleep(0.2)
      #     attest(session).to be_expired
      #   end
      #
      #   # good
      #   investigate "expires the session" do
      #     travel_to(2.hours.from_now)
      #     attest(session).to be_expired
      #   end
      #
      #   # good -- the timeout is the thing under test, and it says so
      #   investigate "times out after thirty seconds" do
      #     # testing an actual timeout path, not a code smell
      #     unsafe { sleep(0.1) }
      #     attest(subject).to have_timed_out
      #   end
      class NoSleep < Base
        include CaseScope
        include Helpers

        MSG = "Do not `sleep` in a case. It makes this investigation slow on every " \
              "green run and flaky on the red one -- wait on the condition, freeze " \
              "time, or if the delay itself is under test, wrap it in `unsafe { }` " \
              "with a comment saying why."

        RESTRICT_ON_SEND = %i[sleep].freeze

        def on_send(node)
          return unless constable_case_file?
          return unless bare_sleep?(node)
          return if inside_unsafe_block?(node)

          add_offense(node)
        end
        alias on_csend on_send

        private

        # `sleep(0.1)` and `Kernel.sleep(0.1)` both count. `foo.sleep` does not --
        # that is somebody's own object, not the process going to bed.
        def bare_sleep?(node)
          receiver = node.receiver
          return true if receiver.nil?

          receiver.const_type? && constant_string(receiver) == "Kernel"
        end
      end
    end
  end
end
