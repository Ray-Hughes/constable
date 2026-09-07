# frozen_string_literal: true

require "helper"

module Constable
  class RunnerTest < Constable::TestCase
    def setup
      super
      write_config("storage:\n  adapter: sqlite\n  path: .constable/constable.sqlite3\n")
    end

    def run_suite(workers: 1, **opts)
      selection = Selection.new([], config: Constable.config, root: tmp_root, full: true)
      runner = Runner.new(
        selection: selection, config: Constable.config,
        reporter: Reporter.new(io: StringIO.new, config: Constable.config, color: false),
        storage: Constable.storage, workers: workers, **opts
      )
      [runner.call, runner]
    end

    # Regression: a case file that raised on load was collected into an array that was
    # never rendered, so a whole file of tests vanished from the run without a word.
    def test_a_case_file_that_cannot_be_loaded_is_reported_as_a_failure
      write_file("test/cases/models/broken_case.rb", "this is not valid ruby ((((\n")

      status, runner = run_suite

      assert_equal 1, status, "a file that will not load has to fail the build"
      result = runner.results.find { |r| r.file.include?("broken_case") }

      refute_nil result, "the unloadable file must appear in the results, not disappear"
      assert_predicate result, :failed?
      assert_equal "could not be loaded", result.description
      assert_match(/never ran/, result.failure.context.to_s)
    end

    def test_a_missing_constant_in_a_case_file_is_reported_rather_than_swallowed
      write_file("test/cases/models/undefined_case.rb", "class UndefinedCase < NoSuchParent; end\n")

      status, runner = run_suite

      assert_equal 1, status
      assert(runner.results.any? { |r| r.failure&.message.to_s.include?("NoSuchParent") })
    end

    # --- the jailed path -------------------------------------------------------
    #
    # A jailed test still runs its setup, so setup rot surfaces on the next ordinary run
    # rather than lying in wait until someone gets around to `constable jail run`. Its
    # teardown has to run for the same reason the body's does: skipping the body is the
    # point of the jail, leaving a session or a clock open for the next test is not.

    def jailed_runner
      selection = Selection.new([], config: Constable.config, root: tmp_root, full: true)
      Runner.new(
        selection: selection, config: Constable.config,
        reporter: Reporter.new(io: StringIO.new, config: Constable.config, color: false),
        storage: Constable.storage
      )
    end

    def jail_entry = Struct.new(:reason, :times_jailed).new("flaky", 2)

    def test_a_jailed_test_runs_setup_and_teardown_but_never_its_body
      runs = []
      klass = build_case("JailedCase") do
        briefing { runs << :briefed }
        teardown { runs << :torn_down }
        investigate("body") { runs << :body }
      end

      result = jailed_runner.send(:run_jailed_setup, klass.investigations.first, jail_entry)

      assert_equal %i[briefed torn_down], runs
      assert_predicate result, :jailed?
      assert_nil result.failure
    end

    # Regression: the teardown call sat behind an `||=`, so the one case that needed it
    # most -- a briefing that blew up mid-way -- was the one case that never got it.
    def test_a_jailed_test_tears_down_even_when_its_briefing_raises
      runs = []
      klass = build_case("RottenJailedCase") do
        briefing { raise "setup rot" }
        teardown { runs << :torn_down }
        investigate("body") { runs << :body }
      end

      result = jailed_runner.send(:run_jailed_setup, klass.investigations.first, jail_entry)

      assert_equal %i[torn_down], runs
      assert_match(/setup rot/, result.failure.message)
      assert_match(/jailed test still runs/, result.failure.context.to_s)
    end

    # Regression: worker pipes were opened in text mode while Marshal payloads are binary,
    # so the first byte that was not valid UTF-8 killed the worker.
    def test_results_survive_the_worker_pipe_when_they_contain_binary_bytes
      skip "fork is unavailable here" unless Process.respond_to?(:fork)

      write_file("test/cases/models/binary_case.rb", <<~RUBY)
        class BinaryCase < Constable::Case
          investigate "fails with a message full of awkward bytes" do
            attest("caf\\xC3\\xA9 \\xAE \\xFF".dup.force_encoding("ASCII-8BIT")).to eq("nope")
          end

          investigate "passes quietly" do
            attest(1).to eq(1)
          end
        end
      RUBY

      _status, runner = run_suite(workers: 2)

      assert_equal 2, runner.results.size, "both results must make it back across the pipe"
    end

    def test_the_seed_replays_the_same_order
      write_file("test/cases/models/ordered_case.rb", <<~RUBY)
        class OrderedCase < Constable::Case
          investigate("a") { attest(1).to eq(1) }
          investigate("b") { attest(2).to eq(2) }
          investigate("c") { attest(3).to eq(3) }
          investigate("d") { attest(4).to eq(4) }
        end
      RUBY

      _, first = run_suite(seed: 99)
      _, second = run_suite(seed: 99)

      assert_equal first.results.map(&:description), second.results.map(&:description)
    end
  end

  class CoverageMergeTest < Constable::TestCase
    # Ruby's Coverage counts lines in the process that ran them, so a forked worker's hits
    # only come home if they are summed into the parent's.
    def test_line_counts_are_summed_across_processes
      merged = Constable::Coverage.merge_raw(
        { "a.rb" => [1, 0, 2] },
        { "a.rb" => [2, 5, 0] }
      )

      assert_equal [3, 5, 2], merged["a.rb"]
    end

    # A nil line is not executable. Turning it into a zero invents an uncovered line that
    # never existed, and quietly drags the percentage down.
    def test_non_executable_lines_stay_nil
      merged = Constable::Coverage.merge_raw(
        { "a.rb" => [1, nil, nil] },
        { "a.rb" => [1, nil, 3] }
      )

      assert_equal [2, nil, 3], merged["a.rb"]
    end

    def test_a_file_only_one_process_saw_is_kept
      merged = Constable::Coverage.merge_raw({ "a.rb" => [1] }, { "b.rb" => [4] })

      assert_equal [1], merged["a.rb"]
      assert_equal [4], merged["b.rb"]
    end

    def test_the_lines_hash_shape_is_handled_too
      merged = Constable::Coverage.merge_raw(
        { "a.rb" => { lines: [1, nil] } },
        { "a.rb" => { lines: [2, nil] } }
      )

      assert_equal [3, nil], merged["a.rb"][:lines]
    end

    def test_merging_with_nothing_is_a_no_op
      assert_equal({ "a.rb" => [1] }, Constable::Coverage.merge_raw({ "a.rb" => [1] }, nil))
      assert_equal({ "a.rb" => [1] }, Constable::Coverage.merge_raw(nil, { "a.rb" => [1] }))
    end
  end
end
