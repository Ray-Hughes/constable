# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    class NoConditionalAssertionsTest < CopTest
      COP = ::RuboCop::Cop::Constable::NoConditionalAssertions

      def test_registers_an_offense_for_an_if_else_around_attest
        source = native_source(<<~RUBY)
          investigate "creates the user" do
            if admin?
              attest(response).to be_created
            else
              attest(response).to be_forbidden
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "decides whether an assertion runs at all")
      end

      def test_registers_an_offense_for_a_modifier_if
        source = native_source(<<~RUBY)
          investigate "creates the user" do
            attest(response).to be_created if admin?
          end
        RUBY

        assert_single_offense(COP, source, line: 3)
      end

      def test_registers_an_offense_for_unless
        source = native_source(<<~RUBY)
          investigate "creates the user" do
            unless skip_check
              assert_equal 201, response.status
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3)
      end

      def test_registers_an_offense_for_a_ternary
        source = native_source(<<~RUBY)
          investigate "creates the user" do
            admin? ? attest(response).to(be_created) : attest(response).to(be_forbidden)
          end
        RUBY

        assert_single_offense(COP, source, line: 3)
      end

      def test_registers_an_offense_for_case_when
        source = native_source(<<~RUBY)
          investigate "creates the user" do
            case role
            when :admin then attest(response).to be_created
            else attest(response).to be_forbidden
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "`case`")
      end

      def test_registers_an_offense_for_refute_behind_a_branch
        source = native_source(<<~RUBY)
          investigate "x" do
            refute_predicate(user, :admin?) if user
          end
        RUBY

        assert_single_offense(COP, source, line: 3)
      end

      def test_reports_only_the_outermost_conditional
        source = native_source(<<~RUBY)
          investigate "creates the user" do
            if admin?
              if verified?
                attest(response).to be_created
              end
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3)
      end

      def test_accepts_a_conditional_that_does_not_wrap_an_assertion
        source = native_source(<<~RUBY)
          investigate "creates the user" do
            params = admin? ? admin_params : guest_params
            post users_path, params: params
            attest(response).to be_created
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_an_assertion_whose_condition_is_a_predicate_call
        source = native_source(<<~RUBY)
          investigate "creates the user" do
            attest(response.created? && user.persisted?).to be_truthy
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_separate_docket_blocks
        source = native_source(<<~RUBY)
          docket "as an admin" do
            investigate("creates the user") { attest(response).to be_created }
          end

          docket "as a guest" do
            investigate("is forbidden") { attest(response).to be_forbidden }
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_conditional_assertion_inside_an_unsafe_block
        source = native_source(<<~RUBY)
          investigate "x" do
            # the vendor API returns either shape depending on account age; both are valid
            unsafe do
              if legacy_payload?
                attest(body).to have_key("id")
              else
                attest(body).to have_key("uuid")
              end
            end
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_cold_cases_are_exempt
        assert_cold_case_exempt(COP, <<~RUBY)
          it "creates the user" do
            if admin?
              attest(response).to be_created
            end
          end
        RUBY
      end
    end
  end
end
