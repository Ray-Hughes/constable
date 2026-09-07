# frozen_string_literal: true

require "helper"

module Constable
  # Drives the real Runner over real case files on disk. Everything below the CLI is
  # exercised here: registration, isolation, ordering, the blotter, and the verdict.
  class RunTest < Constable::TestCase
    def setup
      super
      write_config(<<~YAML)
        storage:
          adapter: sqlite
          path: .constable/constable.sqlite3
        parallel_workers: 1
      YAML
    end

    def write_case(name, body)
      write_file("test/cases/models/#{name}_case.rb", body)
    end

    def run_suite(args = [], **opts)
      selection = Selection.new(args, config: Constable.config, root: tmp_root, full: true, **opts)
      reporter = Reporter.new(io: StringIO.new, config: Constable.config, color: false)
      runner = Runner.new(
        selection: selection,
        config: Constable.config,
        reporter: reporter,
        storage: Constable.storage,
        workers: 1
      )
      status = runner.call
      [status, runner.results]
    end

    def test_a_passing_case_runs_and_reports_clean
      write_case("passing", <<~RUBY)
        class PassingCase < Constable::Case
          witness(:total) { 2 + 2 }

          investigate "adds up" do
            attest(total).to eq(4)
          end
        end
      RUBY

      status, results = run_suite

      assert_equal 0, status
      assert_equal 1, results.size
      assert_predicate results.first, :passed?
      assert_equal "PassingCase", results.first.case_name
      assert_equal "adds up", results.first.description
    end

    def test_a_failing_case_fails_the_build_and_keeps_its_context
      write_case("failing", <<~RUBY)
        class FailingCase < Constable::Case
          investigate "does not add up" do
            attest(2 + 2).to eq(5)
          end
        end
      RUBY

      status, results = run_suite

      assert_equal 1, status
      assert_predicate results.first, :failed?
      assert_match(/5/, results.first.failure.message)
      assert_includes results.first.rerun_command, "constable test"
    end

    # The isolation promise: a witness memoizes within one investigation and is rebuilt for
    # the next, so nothing one test does can be seen by another.
    def test_witnesses_do_not_leak_between_investigations
      write_case("isolation", <<~RUBY)
        class IsolationCase < Constable::Case
          witness(:bucket) { [] }

          investigate "first fills the bucket" do
            bucket << :first
            attest(bucket.size).to eq(1)
          end

          investigate "second finds it empty again" do
            attest(bucket).to be_empty
            bucket << :second
            attest(bucket.size).to eq(1)
          end
        end
      RUBY

      status, results = run_suite

      assert_equal 0, status, results.map { |r| r.failure&.message }.compact.join("\n")
      assert_equal 2, results.size
      assert(results.all?(&:passed?))
    end

    def test_briefings_run_before_every_investigation_and_inherit
      write_case("briefing", <<~RUBY)
        class BriefingCase < Constable::Case
          briefing { @trail = [:parent] }

          docket "in a docket" do
            briefing { @trail << :docket }

            investigate "sees both briefings in order" do
              attest(@trail).to eq([:parent, :docket])
            end
          end

          investigate "outside the docket sees only the parent" do
            attest(@trail).to eq([:parent])
          end
        end
      RUBY

      status, results = run_suite

      assert_equal 0, status, results.map { |r| r.failure&.message }.compact.join("\n")
      assert_equal 2, results.size
    end

    def test_docket_descriptions_fold_into_the_reported_description
      write_case("docketed", <<~RUBY)
        class DocketedCase < Constable::Case
          docket "as an admin" do
            investigate "creates a user" do
              attest(1).to eq(1)
            end
          end
        end
      RUBY

      _status, results = run_suite

      assert_equal "as an admin creates a user", results.first.description
      assert_equal "DocketedCase", results.first.case_name
    end

    # An unsafe block is allowed, but it is never silent -- that is the whole bargain.
    def test_unsafe_always_warns
      write_case("unsafe", <<~RUBY)
        class UnsafeCase < Constable::Case
          investigate "takes the escape hatch" do
            unsafe { sleep(0.001) } # deliberately exercising a real timeout path
            attest(1).to eq(1)
          end
        end
      RUBY

      status, = run_suite

      assert_equal 0, status
      unsafe_warnings = Constable.warnings.select { |w| w[:kind] == :unsafe }

      assert_equal 1, unsafe_warnings.size
      assert_match(/timeout path/, unsafe_warnings.first[:message])
    end

    def test_the_run_is_recorded_on_the_blotter
      write_case("recorded", <<~RUBY)
        class RecordedCase < Constable::Case
          investigate "gets written down" do
            attest(1).to eq(1)
          end
        end
      RUBY

      _status, results = run_suite
      identity = results.first.identity

      history = Constable.storage.history_for(identity)

      refute_empty history
      assert_equal "passed", history.first[:status].to_s
    end

    # Identity is a content hash, so a renamed class with an untouched body keeps its
    # history. This is the promise that makes flake tracking survive ordinary refactoring.
    def test_history_survives_a_rename
      write_case("named", <<~RUBY)
        class OriginalNameCase < Constable::Case
          investigate "the original description" do
            attest(:steady).to eq(:steady)
          end
        end
      RUBY

      _status, first = run_suite
      original_identity = first.first.identity

      Constable.registry.clear
      FileUtils.rm_f(File.join(tmp_root, "test/cases/models/named_case.rb"))
      write_case("renamed", <<~RUBY)
        class CompletelyDifferentNameCase < Constable::Case
          investigate "a totally reworded description" do
            attest(:steady).to eq(:steady)
          end
        end
      RUBY

      _status, second = run_suite

      assert_equal original_identity, second.first.identity,
                   "renaming the class and description must not change the content hash"
    end

    def test_a_seed_replays_the_same_order
      write_case("ordered", <<~RUBY)
        class OrderedCase < Constable::Case
          investigate "a" do; attest(1).to eq(1); end
          investigate "b" do; attest(2).to eq(2); end
          investigate "c" do; attest(3).to eq(3); end
          investigate "d" do; attest(4).to eq(4); end
        end
      RUBY

      first = ordered_descriptions(seed: 4242)
      second = ordered_descriptions(seed: 4242)

      assert_equal first, second, "the same seed must replay the same order"
    end

    # No registry.clear here on purpose: `require` is idempotent, so clearing would leave
    # the second run with nothing to order.
    def ordered_descriptions(seed:)
      selection = Selection.new([], config: Constable.config, root: tmp_root, full: true)
      runner = Runner.new(
        selection: selection, config: Constable.config,
        reporter: Reporter.new(io: StringIO.new, config: Constable.config, color: false),
        storage: Constable.storage, seed: seed, workers: 1
      )
      runner.call
      runner.results.map(&:description)
    end
  end
end
