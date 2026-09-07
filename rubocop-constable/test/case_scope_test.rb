# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    # The scoping rule every cop shares, exercised through one representative cop.
    class CaseScopeTest < CopTest
      COP = ::RuboCop::Cop::Constable::NoSleep

      def test_in_scope_for_constable_case_subclass
        source = <<~RUBY
          class UsersCase < Constable::Case
            investigate("x") { sleep(1) }
          end
        RUBY

        assert_single_offense(COP, source, line: 2)
      end

      def test_in_scope_for_tier_base_classes
        %w[UnitCase IntegrationCase SystemCase].each do |base|
          source = <<~RUBY
            class UsersCase < #{base}
              investigate("x") { sleep(1) }
            end
          RUBY

          assert_single_offense(COP, source, line: 2)
        end
      end

      def test_in_scope_for_namespaced_and_cbase_superclasses
        source = <<~RUBY
          module Admin
            class UsersCase < ::Constable::Case
              investigate("x") { sleep(1) }
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3)
      end

      def test_cold_case_rspec_is_exempt
        source = <<~RUBY
          class LegacyUsersSpec < Constable::ColdCase::RSpec
            describe UsersController do
              it("creates a user") { sleep(1) }
            end
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_cold_case_minitest_is_exempt
        source = <<~RUBY
          class LegacyUsersTest < Constable::ColdCase::Minitest
            def test_creates_a_user
              sleep(1)
            end
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_project_local_cold_case_base_class_is_exempt
        source = <<~RUBY
          class LegacyUsersSpec < ColdCase::RSpec
            it("creates a user") { sleep(1) }
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_cold_case_wins_over_the_include_path_fallback
        source = <<~RUBY
          class LegacyUsersSpec < Constable::ColdCase::RSpec
            it("creates a user") { sleep(1) }
          end
        RUBY

        assert_no_offenses(COP, source, path: IN_INCLUDE_PATH)
      end

      def test_ordinary_class_outside_include_paths_is_out_of_scope
        source = <<~RUBY
          class ImportJob
            def call
              sleep(1)
            end
          end
        RUBY

        assert_no_offenses(COP, source, path: OUT_OF_INCLUDE_PATH)
      end

      def test_include_path_fallback_brings_an_unrecognised_file_into_scope
        source = <<~RUBY
          module SharedSteps
            def wait_a_moment
              sleep(1)
            end
          end
        RUBY

        assert_no_offenses(COP, source, path: OUT_OF_INCLUDE_PATH)
        assert_single_offense(COP, source, line: 3, path: IN_INCLUDE_PATH)
      end

      def test_include_path_fallback_matches_absolute_paths
        source = <<~RUBY
          module SharedSteps
            def wait_a_moment
              sleep(1)
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3, path: File.join(Dir.pwd, IN_INCLUDE_PATH))
      end

      def test_pathless_source_falls_back_to_the_superclass_heuristic_only
        assert_no_offenses(COP, "sleep(1)\n", path: nil)
      end

      def test_a_native_case_alongside_a_cold_case_in_one_file_is_exempt
        # Conservative on purpose: if a file contains any cold case, we cannot tell
        # which class a given line belongs to without resolving scope, so the whole
        # file gets the benefit of the doubt.
        source = <<~RUBY
          class LegacyUsersSpec < Constable::ColdCase::RSpec
            it("creates a user") { sleep(1) }
          end

          class UsersCase < Constable::Case
            investigate("x") { sleep(1) }
          end
        RUBY

        assert_no_offenses(COP, source)
      end
    end
  end
end
