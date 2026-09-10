# frozen_string_literal: true

require_relative "../helper"

module Constable
  # `spec/**/*_case.rb` is a generous net, and in a real app it catches things that merely
  # share the suffix. Caseflow has a FactoryBot factory at
  # spec/factories/distributed_case.rb; Constable loaded it as a test file, FactoryBot
  # raised DuplicateDefinitionError because the factory was already registered, and the
  # run reported a failing "test" in a file containing none.
  class CaseDiscoveryTest < TestCase
    def selection = Selection.new([], config: Constable.config, root: tmp_root, full: true)

    def native_paths = selection.native_targets.map { |t| t.path.delete_prefix("#{tmp_root}/") }

    # --- what is not a case ----------------------------------------------------------

    def test_a_factory_that_merely_ends_in_case_is_not_a_test_file
      write_file("spec/factories/distributed_case.rb", <<~RUBY)
        FactoryBot.define do
          factory :distributed_case do
            case_id { "123" }
          end
        end
      RUBY

      assert_empty native_paths
    end

    def test_a_plain_class_that_ends_in_case_is_not_a_test_file
      write_file("app/models/upper_case.rb", "class UpperCase\n  def shout = \"HI\"\nend\n")
      write_file("spec/support/edge_case.rb", "module EdgeCase\nend\n")

      assert_empty native_paths
    end

    # --- what is -----------------------------------------------------------------------

    def test_a_case_subclass_is_found_wherever_it_lives
      write_file("spec/models/user_case.rb", <<~RUBY)
        class UserCase < Constable::Case
          investigate("works") { assert(true) }
        end
      RUBY

      assert_equal ["spec/models/user_case.rb"], native_paths
    end

    def test_a_tier_base_class_subclass_is_found
      write_file("spec/models/user_case.rb", <<~RUBY)
        class UserCase < UnitCase
          investigate("works") { assert(true) }
        end
      RUBY

      assert_equal ["spec/models/user_case.rb"], native_paths
    end

    # The conventional directories are taken at their word -- that is what they are for,
    # and an empty file there is a case somebody is part-way through writing.
    def test_anything_under_a_cases_directory_is_taken_at_its_word
      write_file("test/cases/models/half_written_case.rb", "# TODO: write this\n")

      assert_equal ["test/cases/models/half_written_case.rb"], native_paths
    end

    def test_a_reopened_case_using_the_dsl_is_found
      write_file("spec/extra/more_user_case.rb", <<~RUBY)
        UserCase.class_eval do
          investigate "another thing" do
            assert(true)
          end
        end
      RUBY

      assert_equal ["spec/extra/more_user_case.rb"], native_paths
    end

    # A case whose superclass is named somewhere else entirely -- assigned to a constant,
    # or built by a helper -- still declares its tier in the body.
    def test_a_case_that_only_declares_a_tier_is_found
      write_file("spec/models/thing_case.rb", <<~RUBY)
        ThingCase = Class.new(BaseCase) do
          tier :unit

          investigate "does the thing" do
            assert(true)
          end
        end
      RUBY

      assert_equal ["spec/models/thing_case.rb"], native_paths
    end

    # --- the boundaries ---------------------------------------------------------------

    def test_a_cold_case_is_still_never_a_native_case
      link_cold_cases(:rspec, "spec/legacy/**/*.rb")
      write_file("spec/legacy/old_case.rb", "class OldCase < Constable::Case\nend\n")

      assert_empty native_paths
    end

    def test_an_unreadable_file_is_skipped_rather_than_crashing_the_run
      path = write_file("spec/models/broken_case.rb", "class BrokenCase < Constable::Case\nend\n")
      File.chmod(0o000, path)

      assert_empty native_paths
    ensure
      File.chmod(0o644, path) if path && File.exist?(path)
    end

    def test_a_file_with_invalid_encoding_does_not_stop_discovery
      write_file("spec/models/binary_case.rb", "\xFF\xFE not really ruby")
      write_file("spec/models/real_case.rb", "class RealCase < Constable::Case\nend\n")

      assert_equal ["spec/models/real_case.rb"], native_paths
    end
  end
end
