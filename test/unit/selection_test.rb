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
      link_cold_cases(:rspec, "spec/**/*_spec.rb")
      target = selection([], full: true).targets.find { |t| t.path.include?("old_users_spec") }

      assert_predicate target, :cold?
    end

    def test_only_cold_selects_cold_cases_alone
      targets = selection([], only: "cold").targets

      assert_equal ["spec/legacy/old_users_spec.rb"], relative(targets)
      assert(targets.all?(&:cold?))
    end

    # The missing opposite. There was no way to say "skip the legacy suite", which is the
    # thing you want while working on a native case in a repo that is 99% cold.
    def test_only_native_skips_every_cold_case
      targets = selection([], full: true, only: "native").targets

      refute_empty targets
      assert(targets.none?(&:cold?))
      refute_includes relative(targets), "spec/legacy/old_users_spec.rb"
    end

    def test_only_an_engine_narrows_to_that_engine
      write_file("test/legacy/thing_test.rb",
                 "require \"minitest/autorun\"\nclass ThingTest < Minitest::Test\n  def test_a; end\nend\n")
      link_cold_cases(:rspec, "spec/**/*_spec.rb")
      link_cold_cases(:minitest, "test/legacy/**/*_test.rb")

      rspec_only = selection([], full: true, only: "rspec").targets

      assert_equal ["spec/legacy/old_users_spec.rb"], relative(rspec_only)

      minitest_only = selection([], full: true, only: "minitest").targets

      assert_equal ["test/legacy/thing_test.rb"], relative(minitest_only)
    end

    # --only narrows what runs; --full says how much. Both at once is the CI case.
    def test_only_composes_with_full
      assert(selection([], full: true, only: "native").targets.none?(&:cold?))
      assert(selection([], full: true, only: "cold").targets.all?(&:cold?))
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

    # --- what counts as a test file -----------------------------------------------------
    #
    # Pointing at a directory used to glob `**/*.rb` and load whatever was in it. A support
    # file produces no tests, which looks harmless and is not: one that calls
    # `shared_examples_for` registers into a world the cold-case engine does not own and
    # marks itself loaded, so the `require_relative` in the specs that need it becomes a
    # no-op and every one of them dies with `Could not find shared examples`.
    #
    # Measured on a real port: seven files and seventy-eight tests lost to three support
    # files in the directory. The same seven passed when the case files were listed
    # explicitly -- which is why every reproduction attempt that named files rather than a
    # directory worked perfectly, and why this took three attempts to find.

    def test_a_directory_collects_test_files_and_not_their_support_files
      write_file("test/cases/models/widget_case.rb", "class WidgetCase < Constable::Case; end\n")
      write_file("test/cases/models/shared_examples.rb", <<~RUBY)
        shared_examples_for "a thing" do
          it("works") { expect(1).to eq(1) }
        end
      RUBY

      paths = Selection.new(["test/cases/models"], config: Constable.config, root: tmp_root)
                       .targets.map(&:path)

      collected = paths.map { |path| path.delete_prefix("#{tmp_root}/") }

      assert_includes collected, "test/cases/models/widget_case.rb"
      refute_includes collected, "test/cases/models/shared_examples.rb"
    end

    # `test/cases/**/*.rb` is deliberately permissive so a case can live anywhere under it,
    # so the same rule has to apply to a full-suite run or the bug just moves.
    def test_a_full_run_skips_support_files_in_the_case_tree
      write_file("test/cases/widget_case.rb", "class WidgetCase < Constable::Case; end\n")
      write_file("test/cases/support_helpers.rb", "module SupportHelpers; end\n")

      paths = Selection.new([], config: Constable.config, root: tmp_root, full: true)
                       .targets.map(&:path)

      refute(paths.any? { |path| path.end_with?("support_helpers.rb") })
      assert(paths.any? { |path| path.end_with?("widget_case.rb") })
    end

    # A case that declares itself is a case whatever it is called -- the permissive glob
    # exists for exactly that, and narrowing it purely by filename would break it.
    def test_a_file_declaring_a_case_is_collected_whatever_its_name
      write_file("test/cases/oddly_named.rb", "class OddlyNamed < Constable::Case; end\n")

      paths = Selection.new(["test/cases"], config: Constable.config, root: tmp_root)
                       .targets.map(&:path)

      assert(paths.any? { |path| path.end_with?("oddly_named.rb") })
    end
  end
end
