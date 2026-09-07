# frozen_string_literal: true

require "helper"

module Constable
  class SelectionTest < Constable::TestCase
    def setup
      super
      write_file("test/cases/models/user_case.rb", "class UserCase < Constable::Case; end\n")
      write_file("test/cases/controllers/sessions_case.rb", "class SessionsCase < Constable::Case; end\n")
      write_file("test/cases/system/checkout_case.rb", "class CheckoutCase < Constable::Case; end\n")
      write_file("spec/legacy/old_users_spec.rb", <<~RUBY)
        class LegacyUsersSpec < Constable::ColdCase::RSpec
          describe "users" do
          end
        end
      RUBY
      write_file("app/models/user.rb", "class User; end\n")
    end

    def selection(args = [], **opts)
      Selection.new(args, config: Constable.config, root: tmp_root, **opts)
    end

    def relative(targets)
      targets.map { |t| t.path.delete_prefix("#{tmp_root}/") }.sort
    end

    def test_full_run_collects_native_and_cold_cases
      targets = selection([], full: true).targets

      assert_includes relative(targets), "test/cases/models/user_case.rb"
      assert_includes relative(targets), "test/cases/controllers/sessions_case.rb"
      assert_includes relative(targets), "spec/legacy/old_users_spec.rb"
    end

    # A file that declares itself a ColdCase is one even without a config glob, because the
    # superclass swap is supposed to be the only edit a legacy file needs.
    def test_cold_case_detected_from_superclass_without_config
      target = selection([], full: true).targets.find { |t| t.path.include?("old_users_spec") }

      assert_predicate target, :cold?
    end

    def test_cold_case_detected_from_config_glob
      write_config("cold_cases:\n  - spec/**/*_spec.rb\n")
      target = selection([], full: true).targets.find { |t| t.path.include?("old_users_spec") }

      assert_predicate target, :cold?
    end

    def test_unsafe_only_selects_cold_cases_alone
      targets = selection([], unsafe_only: true).targets

      assert_equal ["spec/legacy/old_users_spec.rb"], relative(targets)
      assert(targets.all?(&:cold?))
    end

    def test_explicit_path_selects_one_file
      targets = selection(["test/cases/models/user_case.rb"]).targets

      assert_equal ["test/cases/models/user_case.rb"], relative(targets)
    end

    def test_explicit_path_with_line_narrows_to_one_investigation
      targets = selection(["test/cases/models/user_case.rb:12"]).targets

      assert_equal 1, targets.size
      assert_equal 12, targets.first.line
      assert_equal [12], selection(["test/cases/models/user_case.rb:12"])
        .line_filter_for(File.join(tmp_root, "test/cases/models/user_case.rb"))
    end

    def test_explicit_directory_expands_to_its_files
      targets = selection(["test/cases"]).targets

      assert_equal 3, targets.size
    end

    def test_tier_filter_uses_path_convention
      targets = selection([], full: true, tier: :unit).targets

      assert_equal ["test/cases/models/user_case.rb"], relative(targets)
    end

    def test_missing_file_is_dropped_rather_than_raising
      assert_empty selection(["test/cases/nope.rb"]).targets
    end

    def test_reason_is_reported_for_the_summary
      sel = selection([], full: true)
      sel.targets

      assert_equal "full suite", sel.reason
    end
  end
end
