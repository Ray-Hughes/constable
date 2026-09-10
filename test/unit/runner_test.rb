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

    # A worker has to be able to say which worker it is.
    #
    # Anything a suite keeps on disk per process -- a browser cache, a download directory,
    # a screenshot path -- needs a name that differs per worker, and there was no way to
    # ask. Every worker computed the same path and raced for it. On a real suite that
    # raced inside a spec/support file, which meant it raced while rails_helper was
    # loading, which meant the workers that lost ran their files with no database cleaning
    # at all.
    def test_each_worker_is_told_which_worker_it_is
      skip "fork is unavailable here" unless Process.respond_to?(:fork)

      2.times do |i|
        write_file("test/cases/models/worker_#{i}_case.rb", <<~RUBY)
          class Worker#{i}Case < Constable::Case
            investigate "knows its worker index" do
              attest(%w[0 1].include?(ENV["CONSTABLE_WORKER"])).to eq(true)
            end

            investigate "knows how many workers there are" do
              attest(ENV["CONSTABLE_WORKERS"]).to eq("2")
            end
          end
        RUBY
      end

      _status, runner = run_suite(workers: 2)

      failures = runner.results.select(&:failed?).map { |r| r.failure&.message }
      assert_empty failures, "workers were not told their identity"
      assert_equal 4, runner.results.size
    end

    # --- balancing ----------------------------------------------------------------------
    #
    # Longest-processing-time-first only works if the runner knows what things cost. A cold
    # item is a whole file, and its identity is `for_cold_case(path, "file")` -- a key
    # nothing records, because durations are stored per example keyed by description. So
    # every cold file weighed 0.0, the sort was a no-op, and a suite that is entirely cold
    # cases (the normal state of a freshly adopted app) got no balancing whatsoever.

    def test_cold_files_are_weighted_by_their_recorded_duration
      slow = write_file("spec/slow_spec.rb", "describe('s') { it('a') { expect(1).to eq(1) } }")
      quick = write_file("spec/quick_spec.rb", "describe('q') { it('a') { expect(1).to eq(1) } }")
      items = [Runner::Item.new(path: quick, kind: :cold), Runner::Item.new(path: slow, kind: :cold)]

      _status, runner = run_suite
      runner.stub(:file_durations, { "spec/slow_spec.rb" => { tests: 10, seconds: 30.0 },
                                     "spec/quick_spec.rb" => { tests: 1, seconds: 0.5 } }) do
        buckets = runner.send(:balance, items, 2)

        assert_equal 2, buckets.size
        # Slowest first: it is handed out before the quick one rather than by discovery order.
        assert_equal "spec/slow_spec.rb", buckets.first.first.path.delete_prefix("#{tmp_root}/")
      end
    end

    def test_a_cold_file_with_no_history_still_gets_scheduled
      file = write_file("spec/new_spec.rb", "describe('n') { it('a') { expect(1).to eq(1) } }")
      items = [Runner::Item.new(path: file, kind: :cold)]

      _status, runner = run_suite
      runner.stub(:file_durations, {}) do
        assert_equal 1, runner.send(:balance, items, 2).flatten.size
      end
    end

    # --- a worker that dies beside living ones ------------------------------------------
    #
    # The worst bug this runner has had. `worker_errors` was only ever read on the path
    # where *nothing* came back, so a worker that died next to healthy ones was collected
    # and never mentioned: the parent reported the results it happened to receive, called
    # them the whole suite, and exited 0. Measured on the test app -- 192 tests reporting
    # "99 passed, 0 failed". Green, with 93 tests that never ran.

    def test_work_a_dead_worker_abandoned_is_finished_by_the_parent
      files = 3.times.map do |i|
        write_file("spec/abandoned_#{i}_spec.rb", <<~SPEC)
          describe "file #{i}" do
            it("a") { expect(1).to eq(1) }
            it("b") { expect(2).to eq(2) }
          end
        SPEC
      end
      items = files.map { |f| Runner::Item.new(path: f, kind: :cold) }

      _status, runner = run_suite
      # Worker 0 finished its one item; worker 1 died having finished none of its two.
      runner.send(:worker_progress)[0] = 1
      runner.send(:worker_progress)[1] = 0

      results = runner.send(:finish_abandoned_work, [[items[0]], [items[1], items[2]]])

      assert_equal 4, results.size, "both of the dead worker's files have to be run"
      assert(results.all?(&:passed?))
      assert(Constable.warnings.any? { |w| w.to_s.include?("did not come back") },
             "silently making up the work is how the original bug looked from outside")
    end

    def test_nothing_is_rerun_when_every_worker_finished_its_share
      file = write_file("spec/complete_spec.rb", "describe('x') { it('a') { expect(1).to eq(1) } }")
      items = [Runner::Item.new(path: file, kind: :cold)]

      _status, runner = run_suite
      runner.send(:worker_progress)[0] = 1

      assert_empty runner.send(:finish_abandoned_work, [items])
    end

    # The reason the worker died is the most useful thing the run knows, and it used to be
    # thrown away whenever any other worker survived.
    def test_the_reason_a_worker_died_reaches_the_warning
      file = write_file("spec/reason_spec.rb", "describe('x') { it('a') { expect(1).to eq(1) } }")
      items = [Runner::Item.new(path: file, kind: :cold)]

      _status, runner = run_suite
      runner.send(:worker_errors) << "SystemExit: Migrations are pending"
      runner.send(:worker_progress)[0] = 0

      runner.send(:finish_abandoned_work, [items])

      assert(Constable.warnings.any? { |w| w.to_s.include?("Migrations are pending") })
    end

    # And the parent must not be left holding them: a value that outlives the fork would
    # make a later serial run look like worker 0 of a parallel one.
    def test_worker_identity_does_not_leak_into_the_parent
      skip "fork is unavailable here" unless Process.respond_to?(:fork)

      write_file("test/cases/models/leak_case.rb", <<~RUBY)
        class LeakCase < Constable::Case
          investigate("a") { attest(1).to eq(1) }
          investigate("b") { attest(2).to eq(2) }
        end
      RUBY

      run_suite(workers: 2)

      assert_nil ENV.fetch("CONSTABLE_WORKER", nil)
      assert_nil ENV.fetch("CONSTABLE_WORKERS", nil)
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
