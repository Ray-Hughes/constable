# frozen_string_literal: true

require_relative "../helper"

module Constable
  # Result is the wire format between a parallel worker and the parent: every result is
  # marshalled through a pipe. Anything that does not survive `to_h` / `from_h` is data
  # the run silently loses, and only in parallel -- which is the worst way to find out.
  class ResultTest < TestCase
    def full_result
      failure = Failure.new(message: "boom", context: { "Body" => "{}" },
                            exception_class: "RuntimeError", backtrace: ["a.rb:1"])
      result = Result.new(identity: "a" * 16, case_name: "BillingCase", description: "charges",
                          file: "test/cases/billing_case.rb", line: 9, kind: :cold, tier: :unit,
                          status: :failed, duration: 1.5, failure: failure,
                          warnings: [{ message: "w", kind: :unsafe }], retries: %i[passed failed])
      result.seed = 7
      result.parole_day = 3
      result.times_jailed = 2
      result.jail_reason = "flake history flip"
      result
    end

    def round_trip(result) = Result.from_h(Marshal.load(Marshal.dump(result.to_h)))

    def test_every_attribute_survives_the_worker_pipe
      original = full_result
      back = round_trip(original)

      %i[identity case_name description file line kind tier status duration seed
         parole_day times_jailed jail_reason retries warnings].each do |attribute|
        assert_equal original.public_send(attribute), back.public_send(attribute),
                     "#{attribute} did not survive the round trip"
      end
    end

    def test_the_failure_survives_intact
      back = round_trip(full_result)

      assert_equal "boom", back.failure.message
      assert_equal({ "Body" => "{}" }, back.failure.context)
      assert_equal "RuntimeError", back.failure.exception_class
      assert_includes back.failure.backtrace, "a.rb:1"
    end

    def test_a_result_with_no_failure_round_trips
      back = round_trip(Result.new(identity: "b" * 16, case_name: "C", description: "d",
                                   file: "f.rb", line: 1))

      assert_nil back.failure
      assert_predicate back, :passed?
    end

    # Marshal is the actual transport, so anything unmarshallable is a crash in a worker
    # rather than a failing test.
    def test_a_result_is_marshallable
      assert Marshal.dump(full_result.to_h)
    end

    def test_to_h_has_no_attribute_that_from_h_drops
      hash = full_result.to_h
      back = Result.from_h(hash).to_h

      assert_equal hash.keys.sort, back.keys.sort,
                   "an attribute that to_h writes and from_h ignores is data lost in a parallel run"
      assert_equal hash, back
    end

    # --- status predicates ------------------------------------------------------------

    def test_status_predicates
      { passed: %i[passed?], failed: %i[failed?], errored: %i[failed?],
        jailed: %i[jailed?], parole_violation: %i[jailed? parole_violation?],
        warranted: %i[warranted?], skipped: %i[skipped?] }.each do |status, predicates|
        result = Result.new(identity: "c" * 16, case_name: "C", description: "d",
                            file: "f.rb", line: 1, status: status)
        predicates.each { |p| assert result.public_send(p), "#{status} should answer #{p}" }
      end
    end

    def test_a_parole_violation_counts_as_jailed_but_not_as_a_plain_failure
      result = Result.new(identity: "d" * 16, case_name: "C", description: "d",
                          file: "f.rb", line: 1, status: :parole_violation)

      assert_predicate result, :jailed?
      refute_predicate result, :failed?
    end

    def test_rerun_command_names_the_seed_and_the_line
      result = full_result

      assert_match(%r{test/cases/billing_case\.rb:9}, result.rerun_command)
      assert_match(/--seed 7/, result.rerun_command)
    end

    # A cold case reruns through its own engine, so the command has to say so.
    def test_a_cold_result_reruns_as_a_cold_case
      assert_match(/--only=cold/, full_result.rerun_command)
    end
  end
end
