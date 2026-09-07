# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    class NoSleepTest < CopTest
      COP = ::RuboCop::Cop::Constable::NoSleep

      def test_registers_an_offense_for_a_bare_sleep
        source = native_source(<<~RUBY)
          investigate "expires the session" do
            sleep(0.2)
            attest(session).to be_expired
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "Do not `sleep` in a case")
      end

      def test_registers_an_offense_for_sleep_without_parentheses
        source = native_source("investigate('x') { sleep 1 }\n")

        assert_single_offense(COP, source, line: 2)
      end

      def test_registers_an_offense_for_kernel_sleep
        source = native_source("investigate('x') { Kernel.sleep(1) }\n")

        assert_single_offense(COP, source, line: 2)
      end

      def test_registers_one_offense_per_sleep
        source = native_source(<<~RUBY)
          investigate "x" do
            sleep 1
            sleep 2
          end
        RUBY

        assert_offense_count(2, COP, source)
      end

      def test_accepts_a_case_that_never_sleeps
        source = native_source(<<~RUBY)
          investigate "expires the session" do
            travel_to(2.hours.from_now)
            attest(session).to be_expired
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_sleep_inside_an_unsafe_block
        source = native_source(<<~RUBY)
          investigate "times out after thirty seconds" do
            unsafe { sleep(0.1) }
            attest(subject).to have_timed_out
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_sleep_inside_an_unsafe_do_end_block
        source = native_source(<<~RUBY)
          investigate "times out" do
            unsafe do
              sleep(0.1)
            end
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_sleep_on_an_unrelated_receiver
        source = native_source("investigate('x') { scheduler.sleep(1) }\n")

        assert_no_offenses(COP, source)
      end

      def test_cold_cases_are_exempt
        assert_cold_case_exempt(COP, "investigate('x') { sleep(1) }\n")
      end
    end
  end
end
