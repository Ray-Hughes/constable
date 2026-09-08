# frozen_string_literal: true

require_relative "../helper"

module Constable
  # A run that was asked for something specific and found nothing used to print
  # "0 passed, 0 failed" and exit 0. A mistyped path in a CI script therefore produced a
  # green build that ran no tests at all -- the most expensive kind of bug a test runner
  # can have, because it is invisible for months.
  class EmptySelectionTest < TestCase
    def setup
      super
      write_config("storage:\n  adapter: sqlite\n  path: .constable/constable.sqlite3\n")
      write_file("test/cases/models/tagging_case.rb", <<~CASE)
        class TaggingCase < Constable::Case
          investigate "first" do
            assert(true)
          end

          investigate "second" do
            assert(true)
          end
        end
      CASE
    end

    # The case class is defined at the top level by `load`, and a constant that survives
    # into the next test means `inherited` never fires again and the case silently fails
    # to register. Each test gets a clean slate.
    def teardown
      Object.send(:remove_const, :TaggingCase) if Object.const_defined?(:TaggingCase)
      super
    end

    def run_suite(args = [], **opts)
      selection = Selection.new(args, config: Constable.config, root: tmp_root, full: true, **opts)
      Runner.new(selection: selection, config: Constable.config,
                 reporter: Reporter.new(io: StringIO.new, config: Constable.config, color: false),
                 storage: Constable.storage, workers: 1).call
    end

    # --- explicit paths ---------------------------------------------------------------

    def test_a_path_that_matches_nothing_is_an_error
      error = assert_raises(Constable::Error) { run_suite(["test/cases/no_such_case.rb"]) }

      assert_match(%r{no tests matched test/cases/no_such_case\.rb}, error.message)
    end

    def test_a_real_path_still_runs
      assert_equal 0, run_suite(["test/cases/models/tagging_case.rb"])
    end

    # --- PATH:LINE --------------------------------------------------------------------

    def test_a_line_that_names_an_investigation_runs_only_that_one
      assert_equal 0, run_suite(["test/cases/models/tagging_case.rb:2"])
    end

    # Developers point at any line inside the block, not just the declaration.
    def test_a_line_inside_a_block_runs_that_investigation
      assert_equal 0, run_suite(["test/cases/models/tagging_case.rb:3"])
    end

    # The bug: unbounded, this ran the *last* investigation in the file. Not the test
    # asked for, not an error, and green either way.
    def test_a_line_past_the_end_of_the_file_is_an_error
      error = assert_raises(Constable::Error) { run_suite(["test/cases/models/tagging_case.rb:999"]) }

      assert_match(/no tests matched/, error.message)
    end

    def test_a_non_numeric_line_is_an_error
      assert_raises(Constable::Error) { run_suite(["test/cases/models/tagging_case.rb:banana"]) }
    end

    # --- tiers ------------------------------------------------------------------------

    def test_an_unknown_tier_names_the_ones_that_exist
      error = assert_raises(Constable::Error) { run_suite([], tier: "nonsense") }

      assert_match(/unknown tier/, error.message)
      assert_match(/unit, integration, system/, error.message)
    end

    def test_a_tier_is_case_insensitive
      assert_equal 0, run_suite([], tier: "UNIT")
    end

    def test_a_valid_tier_with_no_matching_cases_still_explains_itself
      error = assert_raises(Constable::Error) { run_suite([], tier: "system") }

      assert_match(/no tests matched/, error.message)
      assert_match(/system tier/, error.message)
    end

    # --- what must stay quiet ---------------------------------------------------------

    # An empty suite is a fact about the project, not a mistake in the command.
    def test_a_full_run_of_an_empty_suite_is_not_an_error
      FileUtils.rm_rf(File.join(tmp_root, "test/cases"))
      Constable.registry.clear

      assert_equal 0, run_suite([])
    end

    def test_an_empty_string_argument_is_not_treated_as_a_request
      FileUtils.rm_rf(File.join(tmp_root, "test/cases"))
      Constable.registry.clear

      assert_equal 0, run_suite([""])
    end
  end
end
