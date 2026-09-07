# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    class UnsafeBlockVisibilityTest < CopTest
      COP = ::RuboCop::Cop::Constable::UnsafeBlockVisibility

      def test_registers_an_offense_for_an_unexplained_unsafe_block
        source = native_source(<<~RUBY)
          investigate "times out" do
            unsafe { sleep(0.1) }
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "has nothing saying why")
      end

      def test_registers_an_offense_for_an_unexplained_unsafe_do_end_block
        source = native_source(<<~RUBY)
          investigate "times out" do
            unsafe do
              sleep(0.1)
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3)
      end

      def test_registers_an_offense_when_the_comment_is_too_far_above
        source = native_source(<<~RUBY)
          investigate "times out" do
            # testing an actual timeout path, not a code smell

            unsafe { sleep(0.1) }
          end
        RUBY

        assert_single_offense(COP, source, line: 5)
      end

      def test_registers_an_offense_for_an_empty_comment
        source = native_source(<<~RUBY)
          investigate "times out" do
            #
            unsafe { sleep(0.1) }
          end
        RUBY

        assert_single_offense(COP, source, line: 4)
      end

      def test_registers_one_offense_per_unexplained_block
        source = native_source(<<~RUBY)
          investigate "times out" do
            unsafe { sleep(0.1) }
            unsafe { sleep(0.2) }
          end
        RUBY

        assert_offense_count(2, COP, source)
      end

      def test_accepts_a_trailing_comment_on_the_same_line
        source = native_source(<<~RUBY)
          investigate "times out" do
            unsafe { sleep(0.1) } # testing an actual timeout path, not a code smell
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_comment_on_the_line_immediately_above
        source = native_source(<<~RUBY)
          investigate "times out" do
            # testing an actual timeout path, not a code smell
            unsafe do
              sleep(0.1)
            end
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_literal_reason_argument
        source = native_source(<<~RUBY)
          investigate "times out" do
            unsafe("testing an actual timeout path, not a code smell") { sleep(0.1) }
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_rejects_a_reason_argument_when_the_option_is_off
        source = native_source(<<~RUBY)
          investigate "times out" do
            unsafe("testing an actual timeout path") { sleep(0.1) }
          end
        RUBY

        assert_single_offense(COP, source, line: 3, cop_options: { "AllowReasonArgument" => false })
      end

      def test_rejects_a_blank_reason_argument
        source = native_source(%(investigate("x") { unsafe("  ") { sleep(0.1) } }\n))

        assert_single_offense(COP, source, line: 2)
      end

      def test_accepts_a_case_with_no_unsafe_blocks_at_all
        source = native_source(<<~RUBY)
          investigate "creates a user" do
            attest(User).to exist(email: "a@b.com")
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_cold_cases_are_exempt
        assert_cold_case_exempt(COP, "it('x') { unsafe { sleep(0.1) } }\n")
      end
    end
  end
end
