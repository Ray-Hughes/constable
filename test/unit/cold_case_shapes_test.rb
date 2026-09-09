# frozen_string_literal: true

require_relative "../helper"

module Constable
  # The shapes a real suite actually contains, run through both engines end to end.
  #
  # Every serious bug this project has had lived in the cold-case adapters -- `.rspec`
  # never being read, shared examples not surviving between files, RSpec swallowing a
  # load error and silently running nothing. None of them were subtle once seen, and all
  # of them needed a real spec file to surface. These are those files, kept.
  class ColdCaseShapesTest < TestCase
    def setup
      super
      ColdCase.reset_engines!
    end

    def teardown
      ColdCase.reset_engines!
      super
    end

    def statuses(path, body)
      file = write_file(path, body)
      ColdCase.run_file(file, config: Constable.config).map(&:status).tally
    end

    # --- RSpec ------------------------------------------------------------------------

    def test_pending_and_xit_are_skipped_not_failed
      result = statuses("spec/a_spec.rb", <<~SPEC)
        describe "x" do
          xit("skipped") { raise "never" }
          it("pending") { pending("later"); raise "expected" }
        end
      SPEC

      assert_equal({ skipped: 2 }, result)
    end

    def test_before_hooks_run
      assert_equal({ passed: 1 }, statuses("spec/b_spec.rb", <<~SPEC))
        describe "x" do
          before { @value = 2 }
          it("sees it") { expect(@value).to eq(2) }
        end
      SPEC
    end

    def test_around_hooks_run
      assert_equal({ passed: 1 }, statuses("spec/c_spec.rb", <<~SPEC))
        describe "x" do
          around { |example| example.run }
          it("ok") { expect(1).to eq(1) }
        end
      SPEC
    end

    # A tag is metadata, not a filter, unless someone asks for it. Dropping tagged
    # examples would silently shrink the suite.
    def test_a_tagged_example_still_runs
      assert_equal({ passed: 1 }, statuses("spec/d_spec.rb", <<~SPEC))
        describe "x" do
          it("tagged", :slow) { expect(1).to eq(1) }
        end
      SPEC
    end

    def test_aggregate_failures_is_one_failure
      assert_equal({ failed: 1 }, statuses("spec/e_spec.rb", <<~SPEC))
        describe "x" do
          it("agg", :aggregate_failures) do
            expect(1).to eq(2)
            expect(2).to eq(3)
          end
        end
      SPEC
    end

    # An exception in a hook is an error, not a pass and not a silence.
    def test_a_raising_hook_errors_the_example
      assert_equal({ errored: 1 }, statuses("spec/f_spec.rb", <<~SPEC))
        describe "x" do
          before { raise "hook boom" }
          it("never runs") { expect(1).to eq(1) }
        end
      SPEC
    end

    def test_shared_examples_defined_in_the_same_file
      assert_equal({ passed: 1 }, statuses("spec/g_spec.rb", <<~SPEC))
        shared_examples("s") { it("shared") { expect(1).to eq(1) } }
        describe("x") { it_behaves_like "s" }
      SPEC
    end

    def test_rspec_configure_inside_a_spec_file
      assert_equal({ passed: 1 }, statuses("spec/h_spec.rb", <<~SPEC))
        RSpec.configure { |c| c.before { @z = 9 } }
        describe("x") { it("z") { expect(@z).to eq(9) } }
      SPEC
    end

    def test_deeply_nested_contexts
      assert_equal({ passed: 1 }, statuses("spec/i_spec.rb", <<~SPEC))
        describe("a") { context("b") { context("c") { it("d") { expect(1).to eq(1) } } } }
      SPEC
    end

    # The session is reused between files, so a file that runs twice must behave the same
    # both times -- the world and configuration are swapped, not rebuilt.
    def test_running_the_same_file_twice_gives_the_same_answer
      body = <<~SPEC
        describe "x" do
          before { @value = 2 }
          it("sees it") { expect(@value).to eq(2) }
        end
      SPEC

      assert_equal statuses("spec/j_spec.rb", body), statuses("spec/j_spec.rb", body)
    end

    # --- Minitest ---------------------------------------------------------------------

    def test_minitest_plain_class
      assert_equal({ passed: 1, failed: 1 }, statuses("test/a_test.rb", <<~TEST))
        class ATest < Minitest::Test
          def test_ok; assert(true); end
          def test_bad; assert(false); end
        end
      TEST
    end

    def test_minitest_setup_runs
      assert_equal({ passed: 1 }, statuses("test/b_test.rb", <<~TEST))
        class BTest < Minitest::Test
          def setup; @x = 1; end
          def test_x; assert_equal 1, @x; end
        end
      TEST
    end

    def test_minitest_class_nested_in_a_module
      assert_equal({ passed: 1 }, statuses("test/c_test.rb", <<~TEST))
        module Outer
          class CTest < Minitest::Test
            def test_y; assert(true); end
          end
        end
      TEST
    end

    def test_two_minitest_classes_in_one_file
      assert_equal({ passed: 2 }, statuses("test/d_test.rb", <<~TEST))
        class D1Test < Minitest::Test
          def test_a; assert(true); end
        end
        class D2Test < Minitest::Test
          def test_b; assert(true); end
        end
      TEST
    end

    def test_minitest_spec_syntax
      assert_equal({ passed: 1 }, statuses("test/e_test.rb", <<~TEST))
        require "minitest/spec"
        describe "thing" do
          it("works") { assert(true) }
        end
      TEST
    end

    def test_minitest_skip
      assert_equal({ skipped: 1 }, statuses("test/f_test.rb", <<~TEST))
        class FTest < Minitest::Test
          def test_s; skip "later"; end
        end
      TEST
    end

    def test_a_file_with_no_tests_produces_nothing_rather_than_erroring
      assert_empty statuses("test/g_test.rb", "class GTest < Minitest::Test\nend\n")
    end

    # --- .rspec ------------------------------------------------------------------------

    # A helper named in .rspec that raises must stop the run, not downgrade to a warning.
    #
    # This was a warning once, and it ran the cold cases anyway. What that produced, on a
    # real suite: forked workers whose rails_helper died on Errno::EEXIST racing to mkdir
    # a shared tmp directory, so DatabaseCleaner's per-test transaction was never
    # registered in those workers. Their writes committed. Tests passed that had never
    # been isolated, and later files died on unique indexes naming rows nobody could
    # account for. A green run that was never isolated is the worst output this gem has.
    def test_a_raising_dot_rspec_require_is_fatal
      write_file(".rspec", "--require boom_helper\n")
      write_file("spec/boom_helper.rb", 'raise Errno::EEXIST, "tmp/browser_cache_all"')
      file = write_file("spec/h_spec.rb", "describe('x') { it('runs') { expect(1).to eq(1) } }")

      error = assert_raises(Constable::Error) do
        Dir.chdir(tmp_root) { ColdCase.run_file(file, config: Constable.config) }
      end

      assert_match(/could not load what .rspec requires/, error.message)
      assert_match(/EEXIST/, error.message)
      assert_match(/fatal rather than a warning/, error.message)
    end

    # The other half of the same guarantee: a helper that loads is loaded, and what it
    # defines is there for the file. Without this, `.rspec` could "pass" by never being
    # read at all -- which is the bug the fatal path above exists to keep honest.
    def test_a_working_dot_rspec_require_is_loaded_before_the_file
      write_file(".rspec", "--require ok_helper\n")
      write_file("spec/ok_helper.rb", "def helper_was_loaded = :yes")
      file = write_file("spec/i_spec.rb", <<~SPEC)
        describe "x" do
          it("sees the helper") { expect(helper_was_loaded).to eq(:yes) }
        end
      SPEC

      results = Dir.chdir(tmp_root) { ColdCase.run_file(file, config: Constable.config) }

      assert_equal([:passed], results.map(&:status))
    end
  end
end
