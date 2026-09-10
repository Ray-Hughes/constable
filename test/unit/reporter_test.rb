# frozen_string_literal: true

require_relative "../helper"

module Constable
  # The summary is the deliverable, so these tests assert against literal expected
  # strings: a formatting regression here is a product regression.
  class ReporterTest < TestCase
    RULE = "━" * 60

    def setup
      super
      @io = StringIO.new
    end

    def reporter(**options)
      Reporter.new(io: @io, config: Constable.config, color: false, **options)
    end

    def output = @io.string

    def lines = output.split("\n", -1)

    # Hints wrap to the frame, so assertions about their prose have to ignore where the
    # line breaks happen to fall.
    def unwrapped = output.gsub(/\s+/, " ")

    # --- fixtures ------------------------------------------------------------------

    def build_result(case_name: "SessionsCase", description: "does the thing",
                     status: :passed, duration: 0.0, file: "spec/cases/sessions_case.rb",
                     line: 12, kind: :native, failure: nil, seed: nil,
                     parole_day: nil, times_jailed: nil, jail_reason: nil, retries: [])
      result = Result.new(
        identity: Identity.digest("#{case_name}#{description}"),
        case_name: case_name, description: description, file: file, line: line,
        kind: kind, status: status, duration: duration, failure: failure
      )
      result.seed         = seed
      result.parole_day   = parole_day
      result.times_jailed = times_jailed
      result.jail_reason  = jail_reason
      result.retries      = retries
      result
    end

    def build_failure(message: "Expected response to be :created, got :unprocessable_entity",
                      context: nil, exception_class: nil)
      Failure.new(message: message, context: context, exception_class: exception_class)
    end

    def passing(count, case_name: "SessionsCase")
      Array.new(count) { |i| build_result(case_name: case_name, description: "passes #{i}") }
    end

    # The six-result run behind the golden summary. Deliberately shaped like the spec's
    # published example so the two can be diffed by eye.
    def spec_shaped_results
      [
        build_result(case_name: "UsersController::CreatesUserCase",
                     description: "creates a user with valid params",
                     file: "spec/cases/users_controller/creates_user_case.rb", line: 8,
                     status: :parole_violation, duration: 3.2, parole_day: 3, times_jailed: 2),
        build_result(case_name: "SessionsCase", description: "expires after inactivity",
                     status: :failed, duration: 0.4, seed: 8841,
                     failure: build_failure(context: response_body_context)),
        build_result(case_name: "SessionsCase", description: "times out after thirty seconds", duration: 1.1),
        build_result(case_name: "SessionsCase", description: "signs a user in", duration: 0.2, parole_day: 4),
        build_result(case_name: "BillingCase", description: "charges a card", status: :warranted,
                     duration: 0.3, retries: %i[passed failed passed passed passed]),
        build_result(case_name: "BillingCase", description: "refunds a charge", status: :jailed,
                     duration: 0.0, jail_reason: "assertion failed on the amount")
      ]
    end

    def response_body_context
      %(Response body:\n  { "errors": ["Email has already been taken"] })
    end

    def spec_shaped_warnings
      [
        { message: "running as a cold case (Constable::ColdCase::RSpec) — 12 tests not yet under native rules",
          location: "spec/legacy/old_users_spec.rb", kind: :cold_case },
        { message: %(unsafe { sleep(0.1) } — "testing an actual timeout path, not a code smell"),
          location: "spec/controllers/sessions_case.rb:44", kind: :unsafe }
      ]
    end

    # --- output modes ---------------------------------------------------------------

    def test_concise_is_the_default_and_streams_one_glyph_per_test
      r = reporter
      refute_predicate r, :expanded?

      passing(3).each { |result| r.record(result) }
      r.flush!

      assert_match(/SessionsCase\s+✓✓✓/, output)
      refute_includes output, "passes 0"
    end

    def test_expanded_streams_a_line_per_test_with_its_description
      r = reporter(mode: :expanded)
      assert_predicate r, :expanded?

      passing(2).each { |result| r.record(result) }
      r.flush!

      assert_includes output, "  SessionsCase"
      assert_includes output, "✓ passes 0"
      assert_includes output, "✓ passes 1"
    end

    def test_expanded_prints_a_duration_for_tests_that_actually_ran
      r = reporter(mode: :expanded)
      r.record(build_result(description: "is quick", duration: 0.012))
      r.flush!

      assert_match(/✓ is quick\s+12ms/, output)
    end

    # A jailed test never ran its body, so there is no honest duration to print. "0ms"
    # would be a claim about work that never happened.
    def test_expanded_prints_no_duration_for_a_jailed_test
      r = reporter(mode: :expanded)
      r.record(build_result(description: "is jailed", status: :jailed, duration: 0.0,
                            jail_reason: "assertion failed on the amount"))
      r.flush!

      assert_includes output, "is jailed"
      assert_includes output, "assertion failed on the amount"
      refute_match(/is jailed\s+\d/, output)
    end

    # Workers interleave. A case that comes back gets a second header rather than having
    # its later tests appended silently under whatever spoke last.
    def test_expanded_reprints_the_case_header_when_a_case_comes_back
      r = reporter(mode: :expanded)
      r.record(build_result(case_name: "AlphaCase", description: "first"))
      r.record(build_result(case_name: "BetaCase", description: "second"))
      r.record(build_result(case_name: "AlphaCase", description: "third"))
      r.flush!

      assert_equal(2, lines.count { |line| line.strip == "AlphaCase" })
    end

    def test_an_explicit_mode_beats_the_config_file
      Constable.config.raw["output"] = "expanded"
      assert_predicate reporter, :expanded?
      refute_predicate reporter(mode: :concise), :expanded?
    ensure
      Constable.config.raw.delete("output")
    end

    def test_an_unrecognized_mode_falls_back_rather_than_raising
      refute_predicate reporter(mode: "sideways"), :expanded?
    end

    # --- supervision sections ---------------------------------------------------------

    def test_jailed_tests_get_their_own_section_with_a_next_step
      reporter.finish(results: [
                        build_result(description: "refunds a charge", status: :jailed,
                                     jail_reason: "assertion failed on the amount")
                      ], warnings: [])

      assert_includes output, "JAILED"
      assert_includes output, "Assertion failed on the amount."
      assert_includes unwrapped, "constable jail parole PATH:LINE"
    end

    def test_a_repeat_offender_says_how_many_times_it_has_been_jailed
      reporter.finish(results: [
                        build_result(status: :jailed, jail_reason: "still red", times_jailed: 3)
                      ], warnings: [])

      assert_includes output, "Its 3rd time in jail."
    end

    def test_warrants_get_their_own_section_with_a_next_step
      reporter.finish(results: [
                        build_result(case_name: "BillingCase", description: "charges a card",
                                     status: :warranted, retries: %i[passed failed passed passed passed])
                      ], warnings: [])

      assert_includes output, "WARRANTS"
      assert_includes output, "Failed, then passed 4 of 5 retries run in isolation."
      assert_includes unwrapped, "constable warrants release PATH:LINE"
    end

    def test_tests_on_parole_get_their_own_section_showing_progress
      reporter.finish(results: [build_result(description: "signs a user in", parole_day: 4)],
                      warnings: [])

      assert_includes output, "ON PAROLE"
      assert_includes output, "Day 4 of 10 — 6 clean runs to go."
      assert_includes unwrapped, "constable watchlist"
    end

    def test_the_last_run_of_a_parole_says_so_rather_than_counting_to_zero
      reporter.finish(results: [build_result(parole_day: 10)], warnings: [])

      assert_includes output, "releases after this run."
    end

    # A hint printed on a run with nothing to hint about is noise, and noise is what
    # stops people reading the summary at all.
    def test_supervision_sections_are_absent_when_nothing_is_under_supervision
      reporter.finish(results: passing(2), warnings: [])

      refute_includes output, "JAILED"
      refute_includes output, "WARRANTS"
      refute_includes output, "ON PAROLE"
      refute_includes output, "→"
    end

    # Prose that runs past the frame reads as a bug in the tool.
    def test_hints_wrap_to_the_frame
      reporter.finish(results: [build_result(status: :jailed, jail_reason: "still red")],
                      warnings: [])

      hint_lines = lines.select { |line| line.include?("→") || line.strip.start_with?("constable jail") }
      refute_empty hint_lines
      lines.each { |line| assert_operator line.length, :<=, RULE.length, "line ran past the frame: #{line.inspect}" }
    end

    # --- cold cases at scale -----------------------------------------------------------
    #
    # A suite part-way through adoption has hundreds of cold-case files -- one real app
    # had 1,277 -- and each one warns. Printed individually that is four thousand lines
    # of the same sentence, and the warnings that need a decision are buried in it.

    def cold_case_warnings(count, tests_each: 5)
      Array.new(count) do |i|
        { kind: :cold_case, location: "spec/models/thing_#{i}_spec.rb", tests: tests_each,
          message: "running as a cold case (Constable::ColdCase::RSpec) — " \
                   "#{tests_each} tests not yet under native rules" }
      end
    end

    def test_a_few_cold_cases_are_still_listed_one_by_one
      reporter.finish(results: passing(1), warnings: cold_case_warnings(3))

      assert_equal 3, output.scan(/thing_\d+_spec\.rb/).size
    end

    def test_many_cold_cases_collapse_into_one_line
      reporter.finish(results: passing(1), warnings: cold_case_warnings(1277))

      assert_empty output.scan(/thing_\d+_spec\.rb/), "1,277 filenames is not a summary"
      assert_match(/1277 files running as cold cases/, output)
    end

    # The count is the point of the warning: it is the number that is supposed to shrink.
    def test_the_collapsed_line_keeps_the_totals
      reporter.finish(results: passing(1), warnings: cold_case_warnings(20, tests_each: 7))

      assert_match(/20 files running as cold cases, 140 tests/, output)
      assert_match(/constable test --unsafe/, output, "it should say how to run just those")
    end

    def test_collapsing_does_not_swallow_other_warnings
      warnings = cold_case_warnings(50) +
                 [{ kind: :unsafe, location: "test/cases/a_case.rb:9",
                    message: "unsafe { sleep(0.1) } — waiting on a real timeout" }]

      reporter.finish(results: passing(1), warnings: warnings)

      assert_match(/files running as cold cases/, output)
      assert_match(/a_case\.rb:9/, output, "an unsafe block still needs a decision")
    end

    # The headline count is unaffected: the summary line is about how they are displayed,
    # not how many there are.
    def test_the_headline_still_counts_every_warning
      reporter.finish(results: passing(1), warnings: cold_case_warnings(1277))

      assert_match(/1277 warnings/, output)
    end

    # --- the whole summary ----------------------------------------------------------

    def test_the_summary_renders_exactly_as_specified
      reporter(slowest: 2).finish(
        results: spec_shaped_results, duration: 12.4, seed: 8841,
        coverage: { percent: 92, unpatrolled: 3 }, warnings: spec_shaped_warnings
      )

      expected = <<~REPORT
        #{RULE}
          CONSTABLE            6 tests · 3 cases · 12.4s
        #{RULE}
          ✓ 2 passed   ✗ 1 failed   ⛓ 2 jailed (1 parole violation)   ◑ 1 on parole   ⚖ 1 warrant issued   ⚠ 2 warnings   ◐ 92% covered (3 files unpatrolled)

          PAROLE VIOLATED
          ───────────────
          ⛓ UsersController::CreatesUserCase
            "creates a user with valid params"
            spec/cases/users_controller/creates_user_case.rb:8
            Failed on day 3 of a 10-run parole — back to jail. This is its 2nd time in jail.

          → Somebody trusted this test again and it let them down,
            so it is back on the docket. Fix it before the next
            constable jail parole — a second violation is the signal
            that the test, not the flake, is the problem.

          FAILURES
          ────────
          ✗ SessionsCase
            "expires after inactivity"
            spec/cases/sessions_case.rb:12
            400ms

            Expected response to be :created, got :unprocessable_entity

            Response body:
              { "errors": ["Email has already been taken"] }

            Rerun just this test:
              constable test spec/cases/sessions_case.rb:12 --seed 8841

          WARRANTS
          ────────
          ⚖ BillingCase
            "charges a card"
            spec/cases/sessions_case.rb:12
            Failed, then passed 4 of 5 retries run in isolation.

          → A warrant is "not reproducible", not "not a problem" —
            it stops blocking the build and stays visible until
            someone deals with it. Fixed the flake? constable
            warrants release PATH:LINE

          JAILED
          ──────
          ⛓ BillingCase
            "refunds a charge"
            spec/cases/sessions_case.rb:12
            Assertion failed on the amount.

          → Jailed means skipped and tracked, not passing. Think one
            is fixed? constable jail parole PATH:LINE runs it for
            real again — 10 clean runs and it releases itself.

          ON PAROLE
          ─────────
          ◑ SessionsCase
            "signs a user in"
            spec/cases/sessions_case.rb:12
            Day 4 of 10 — 6 clean runs to go.

          → A paroled test runs for real and is watched: one failure
            sends it straight back to jail. constable watchlist
            shows everything under supervision.

          WARNINGS
          ────────
          ⚠ spec/legacy/old_users_spec.rb
            running as a cold case (Constable::ColdCase::RSpec) — 12
            tests not yet under native rules

          ⚠ spec/controllers/sessions_case.rb:44
            unsafe { sleep(0.1) } — "testing an actual timeout path,
            not a code smell"

          SLOWEST
          ────────
          3.2s  UsersController::CreatesUserCase "creates a user with valid params"
          1.1s  SessionsCase "times out after thirty seconds"

          RECOMMENDATIONS
          ───────────────
          2 jailed tests did not run
            `constable jail run` reruns them in isolation;
            `constable jail list` says why each is there.

          SUMMARY
          ───────
          6 tests   2 passed   1 failed   2 jailed   1 warranted
          12.4s total · seed 8841 · 2 warnings
        #{RULE}
      REPORT

      assert_equal expected, output
    end

    def test_the_frame_is_sixty_columns_and_stats_start_in_a_fixed_column
      reporter.finish(results: passing(3), duration: 12.4, warnings: [])

      assert_equal RULE, lines.first
      assert_equal 60, lines.first.length
      assert_equal "  CONSTABLE            3 tests · 1 case · 12.4s", lines[1]
      assert_equal RULE, lines[2]
      assert_equal RULE, lines[-2]
    end

    def test_long_runs_read_in_minutes_and_seconds
      reporter.finish(results: passing(1), duration: 754.2, warnings: [])

      assert_includes lines[1], "12m 34.2s"
    end

    # --- the headline ---------------------------------------------------------------

    def test_the_headline_matches_the_published_example
      results = passing(477) +
                [build_result(description: "on parole", parole_day: 5),
                 build_result(description: "a", status: :failed, failure: build_failure),
                 build_result(description: "b", status: :failed, failure: build_failure),
                 build_result(description: "c", status: :jailed),
                 build_result(description: "d", status: :parole_violation, parole_day: 3, times_jailed: 2),
                 build_result(description: "e", status: :warranted)]
      3.times { |i| Constable.warn!("unsafe #{i}", location: "spec/a_case.rb:#{i}") }

      reporter.finish(results: results, duration: 12.4, coverage: 92)

      assert_equal "  ✓ 478 passed   ✗ 2 failed   ⛓ 2 jailed (1 parole violation)   " \
                   "◑ 1 on parole   ⚖ 1 warrant issued   ⚠ 3 warnings   ◐ 92% covered",
                   headline
    end

    def test_a_clean_run_shows_only_passed_and_failed
      reporter.finish(results: passing(4), duration: 1.0, warnings: [])

      assert_equal "  ✓ 4 passed   ✗ 0 failed", headline
    end

    def test_jailed_without_a_parole_violation_does_not_print_the_parenthetical
      results = passing(1) + [build_result(status: :jailed), build_result(status: :jailed)]

      reporter.finish(results: results, duration: 1.0, warnings: [])

      assert_equal "  ✓ 1 passed   ✗ 0 failed   ⛓ 2 jailed", headline
    end

    def test_multiple_parole_violations_are_pluralized_inside_the_split
      results = [build_result(description: "a", status: :parole_violation, parole_day: 1, times_jailed: 2),
                 build_result(description: "b", status: :parole_violation, parole_day: 2, times_jailed: 3),
                 build_result(description: "c", status: :jailed)]

      reporter.finish(results: results, duration: 1.0, warnings: [])

      assert_equal "  ✓ 0 passed   ✗ 0 failed   ⛓ 3 jailed (2 parole violations)", headline
    end

    def test_errored_results_count_as_failures
      results = [build_result(status: :errored,
                              failure: build_failure(message: "boom", exception_class: "RuntimeError"))]

      reporter.finish(results: results, duration: 1.0, warnings: [])

      assert_equal "  ✓ 0 passed   ✗ 1 failed", headline
    end

    def test_singular_categories_read_naturally
      Constable.warn!("unsafe { sleep }", location: "spec/a_case.rb:3")

      reporter.finish(results: [build_result(status: :warranted)], duration: 1.0)

      assert_equal "  ✓ 0 passed   ✗ 0 failed   ⚖ 1 warrant issued   ⚠ 1 warning", headline
    end

    def test_skipped_results_are_counted_but_never_folded_into_passed
      results = passing(2) + [build_result(status: :skipped)]

      reporter.finish(results: results, duration: 1.0, warnings: [])

      assert_equal "  ✓ 2 passed   ✗ 0 failed   ○ 1 skipped", headline
    end

    def test_a_parole_violation_is_not_also_counted_as_on_parole
      results = [build_result(status: :parole_violation, parole_day: 3, times_jailed: 1)]

      reporter.finish(results: results, duration: 1.0, warnings: [])

      refute_includes headline, "on parole"
    end

    # --- coverage --------------------------------------------------------------------

    def test_coverage_is_omitted_when_none_was_recorded
      reporter.finish(results: passing(1), duration: 1.0, warnings: [])

      refute_includes headline, "covered"
    end

    def test_coverage_accepts_a_bare_number
      reporter.finish(results: passing(1), duration: 1.0, coverage: 92.0, warnings: [])

      assert_includes headline, "◐ 92% covered"
      refute_includes headline, "unpatrolled"
    end

    def test_coverage_names_unpatrolled_files_when_there_are_any
      reporter.finish(results: passing(1), duration: 1.0, warnings: [],
                      coverage: { percent: 87.5, unpatrolled_files: %w[a.rb b.rb c.rb] })

      assert_includes headline, "◐ 87.5% covered (3 files unpatrolled)"
    end

    def test_a_single_unpatrolled_file_is_singular
      reporter.finish(results: passing(1), duration: 1.0, warnings: [],
                      coverage: { percent: 100, unpatrolled: 1 })

      assert_includes headline, "◐ 100% covered (1 file unpatrolled)"
    end

    # --- section ordering and omission ------------------------------------------------

    def test_sections_print_worst_to_least_urgent
      Constable.warn!("unsafe { sleep }", location: "spec/a_case.rb:3")
      results = [build_result(description: "violates", status: :parole_violation, parole_day: 1, times_jailed: 1),
                 build_result(description: "fails", status: :failed, failure: build_failure),
                 build_result(description: "is slow", duration: 2.0)]

      reporter.finish(results: results, duration: 1.0)

      # SUMMARY last on purpose: after a long run the headline at the top has scrolled
      # away, so the counts someone goes looking for are the ones they would have to
      # scroll back for.
      # RECOMMENDATIONS then SUMMARY at the end: what to do next, then what just happened.
      assert_equal ["PAROLE VIOLATED", "FAILURES", "WARNINGS", "SLOWEST",
                    "RECOMMENDATIONS", "SUMMARY"],
                   section_titles
    end

    def test_empty_sections_are_omitted_entirely
      reporter.finish(results: passing(2), duration: 1.0, warnings: [])

      # SUMMARY is the one section that is never empty and always prints -- it is the
      # point of having it at the bottom.
      assert_equal ["SUMMARY"], section_titles
      refute_includes output, "FAILURES"
      refute_includes output, "PAROLE VIOLATED"
      refute_includes output, "WARNINGS"
      refute_includes output, "RECOMMENDATIONS"
    end

    def test_slowest_is_omitted_when_nothing_took_measurable_time
      reporter.finish(results: passing(2), duration: 1.0, warnings: [])

      refute_includes output, "SLOWEST"
    end

    def test_section_underlines_sit_directly_under_their_titles
      Constable.warn!("unsafe { sleep }", location: "spec/a_case.rb:3")

      reporter.finish(results: [build_result(status: :failed, failure: build_failure)], duration: 1.0)

      assert_includes output, "  FAILURES\n  ────────\n"
      assert_includes output, "  WARNINGS\n  ────────\n"
    end

    # --- failures ---------------------------------------------------------------------

    def test_a_failure_block_carries_everything_needed_to_act_on_it
      result = build_result(case_name: "SessionsCase", description: "expires after inactivity",
                            file: "spec/cases/sessions_case.rb", line: 12, status: :failed,
                            seed: 8841, failure: build_failure(context: response_body_context))

      reporter.finish(results: [result], duration: 1.0, warnings: [])

      assert_includes output, indent(<<~BLOCK, 2)
        ✗ SessionsCase
          "expires after inactivity"
          spec/cases/sessions_case.rb:12

          Expected response to be :created, got :unprocessable_entity

          Response body:
            { "errors": ["Email has already been taken"] }

          Rerun just this test:
            constable test spec/cases/sessions_case.rb:12 --seed 8841
      BLOCK
    end

    def test_a_failure_without_context_skips_the_context_block
      result = build_result(status: :failed, seed: 1, failure: build_failure(message: "nope"))

      reporter.finish(results: [result], duration: 1.0, warnings: [])

      assert_includes output, indent(<<~BLOCK, 4)
        spec/cases/sessions_case.rb:12

        nope

        Rerun just this test:
      BLOCK
    end

    def test_hash_context_renders_one_attribute_per_line
      result = build_result(status: :failed,
                            failure: build_failure(context: { email: "a@b.com", state: "pending" }))

      reporter.finish(results: [result], duration: 1.0, warnings: [])

      assert_includes output, "    email: a@b.com\n    state: pending\n"
    end

    def test_a_cold_case_rerun_command_keeps_its_unsafe_flag
      result = build_result(kind: :cold, status: :failed, seed: 22, failure: build_failure,
                            file: "spec/legacy/old_users_spec.rb", line: 4)

      reporter.finish(results: [result], duration: 1.0, warnings: [])

      assert_includes output, "      constable test spec/legacy/old_users_spec.rb:4 --unsafe --seed 22\n"
    end

    def test_an_errored_result_names_its_exception_class
      result = build_result(status: :errored,
                            failure: build_failure(message: "undefined method `foo'",
                                                   exception_class: "NoMethodError"))

      reporter.finish(results: [result], duration: 1.0, warnings: [])

      assert_includes output, "    NoMethodError: undefined method `foo'\n"
    end

    def test_a_failure_with_nothing_recorded_still_prints_a_usable_block
      reporter.finish(results: [build_result(status: :failed)], duration: 1.0, warnings: [])

      assert_includes output, "    (no failure message recorded)\n"
      assert_includes output, "      constable test spec/cases/sessions_case.rb:12\n"
    end

    def test_multiple_failures_are_separated_by_a_blank_line
      results = [build_result(description: "one", status: :failed, failure: build_failure(message: "first")),
                 build_result(description: "two", status: :failed, failure: build_failure(message: "second"))]

      reporter.finish(results: results, duration: 1.0, warnings: [])

      assert_includes output, "      constable test spec/cases/sessions_case.rb:12\n\n  ✗ SessionsCase\n    \"two\"\n"
    end

    # --- parole violations --------------------------------------------------------------

    def test_a_parole_violation_explains_itself_in_full
      result = build_result(case_name: "UsersController::CreatesUserCase",
                            description: "creates a user with valid params",
                            status: :parole_violation, parole_day: 3, times_jailed: 2)

      reporter.finish(results: [result], duration: 1.0, warnings: [])

      assert_includes output, indent(<<~BLOCK, 2)
        ⛓ UsersController::CreatesUserCase
          "creates a user with valid params"
          spec/cases/sessions_case.rb:12
          Failed on day 3 of a 10-run parole — back to jail. This is its 2nd time in jail.
      BLOCK
    end

    def test_the_parole_period_comes_from_config
      write_config("parole_period: 4\n")
      result = build_result(status: :parole_violation, parole_day: 2, times_jailed: 1)

      reporter.finish(results: [result], duration: 1.0, warnings: [])

      assert_includes output, "Failed on day 2 of a 4-run parole — back to jail. This is its 1st time in jail."
    end

    def test_the_jail_count_sentence_is_dropped_when_the_docket_does_not_know
      result = build_result(status: :parole_violation, parole_day: 2)

      reporter.finish(results: [result], duration: 1.0, warnings: [])

      assert_includes output, "Failed on day 2 of a 10-run parole — back to jail.\n"
      refute_includes output, "time in jail"
    end

    def test_jail_counts_are_ordinalized_correctly
      counts   = [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112]
      expected = %w[1st 2nd 3rd 4th 11th 12th 13th 21st 22nd 23rd 101st 111th 112th]
      results = counts.map.with_index do |count, i|
        build_result(description: "violation #{i}", status: :parole_violation, parole_day: 1, times_jailed: count)
      end

      reporter.finish(results: results, duration: 1.0, warnings: [])

      expected.each { |ordinal| assert_includes output, "This is its #{ordinal} time in jail." }
    end

    # --- warnings ------------------------------------------------------------------------

    def test_warnings_default_to_the_ones_collected_during_the_run
      Constable.warn!("running as a cold case (Constable::ColdCase::RSpec) — 12 tests not yet under native rules",
                      location: "spec/legacy/old_users_spec.rb", kind: :cold_case)

      reporter.finish(results: passing(1), duration: 1.0)

      # Wrapped to the frame; the assertion carries the break so a regression in the
      # wrapping shows up here rather than only in somebody's terminal.
      assert_includes output, indent(<<~BLOCK, 2)
        ⚠ spec/legacy/old_users_spec.rb
          running as a cold case (Constable::ColdCase::RSpec) — 12
          tests not yet under native rules
      BLOCK
    end

    def test_identical_warnings_from_several_workers_collapse_into_one
      3.times do
        Constable.warn!("running as a cold case", location: "spec/legacy/old_users_spec.rb", kind: :cold_case)
      end

      reporter.finish(results: passing(1), duration: 1.0)

      assert_equal 1, output.scan("⚠ spec/legacy/old_users_spec.rb").size
      assert_includes headline, "⚠ 1 warning"
    end

    def test_a_warning_without_a_location_still_gets_a_line
      Constable.warn!("something bent the rules", location: nil)

      reporter.finish(results: passing(1), duration: 1.0)

      assert_includes output, "  ⚠ something bent the rules\n"
    end

    def test_warnings_are_never_silent_even_when_everything_passed
      Constable.warn!("unsafe { sleep(0.1) }", location: "spec/a_case.rb:44")

      reporter.finish(results: passing(3), duration: 1.0)

      assert_includes output, "  WARNINGS\n"
      assert_includes headline, "⚠ 1 warning"
    end

    # --- slowest --------------------------------------------------------------------------

    def test_slowest_lists_the_worst_offenders_longest_first
      results = [build_result(case_name: "BillingCase", description: "charges a card", duration: 0.5),
                 build_result(case_name: "SessionsCase", description: "times out", duration: 3.25),
                 build_result(case_name: "UsersCase", description: "creates", duration: 1.14)]

      reporter(slowest: 2).finish(results: results, duration: 1.0, warnings: [])

      assert_includes output, indent(<<~BLOCK, 2)
        SLOWEST
        ────────
        3.2s  SessionsCase "times out"
        1.1s  UsersCase "creates"
      BLOCK
      refute_includes output, "BillingCase"
    end

    def test_slowest_right_aligns_durations_so_the_names_line_up
      results = [build_result(description: "slow", duration: 12.0),
                 build_result(description: "quick", duration: 1.0)]

      reporter.finish(results: results, duration: 1.0, warnings: [])

      assert_includes output, "  12.0s  SessionsCase \"slow\"\n"
      assert_includes output, "   1.0s  SessionsCase \"quick\"\n"
    end

    def test_jailed_tests_never_appear_in_slowest_because_their_body_never_ran
      results = [build_result(description: "jailed", status: :jailed, duration: 9.9),
                 build_result(description: "real", duration: 1.0)]

      reporter.finish(results: results, duration: 1.0, warnings: [])

      refute_includes output, "9.9s"
      assert_includes output, "1.0s  SessionsCase \"real\""
    end

    # --- rename suggestions ------------------------------------------------------------------

    def test_rename_suggestions_are_emitted_verbatim
      suggestions = [{ old_label: "OldCase#old description", new_label: "NewCase#new description",
                       old_hash: "abc123", new_hash: "def456" }]

      reporter.finish(results: passing(1), duration: 1.0, warnings: [], suggestions: suggestions)

      assert_includes output, "RENAMED?"
      assert_includes output, "OldCase#old description"
      assert_includes output, "→ NewCase#new description"
      assert_includes output, "constable history relink abc123 def456"
    end

    def test_rename_suggestions_can_be_built_from_case_and_description_parts
      suggestions = [{ old_case: "OldCase", old_description: "old description",
                       new_case: "NewCase", new_description: "new description",
                       old_identity: "abc123", new_identity: "def456" }]

      reporter.finish(results: passing(1), duration: 1.0, warnings: [], suggestions: suggestions)

      assert_includes output, "OldCase#old description"
      assert_includes output, "→ NewCase#new description"
    end

    def test_no_suggestions_means_no_extra_output
      reporter.finish(results: passing(1), duration: 1.0, warnings: [], suggestions: [])

      refute_includes output, "RENAMED?"
    end

    # A real suite produced two hundred suggestions and several hundred lines of output --
    # unlabelled, after SLOWEST, one long line each carrying two full descriptions and two
    # hashes. It read as a wall of text and buried every section above it.
    def test_many_suggestions_are_capped
      suggestions = Array.new(200) do |i|
        { old_label: "OldCase#thing #{i}", new_label: "NewCase#thing #{i}",
          old_hash: "abc#{i}", new_hash: "def#{i}" }
      end

      reporter.finish(results: passing(1), warnings: [], suggestions: suggestions)

      assert_operator output.scan("constable history relink").size, :<=, 8
      assert_match(/and 192 more/, output)
    end

    # An RSpec description built from a matcher carries the whole inspected object -- every
    # column of a record, ids and timestamps included. Printed in full it is unreadable.
    def test_a_very_long_description_is_truncated
      suggestions = [{ old_label: "OldCase#{"x" * 400}", new_label: "NewCase#short",
                       old_hash: "abc", new_hash: "def" }]

      reporter.finish(results: passing(1), warnings: [], suggestions: suggestions)

      lines.each { |line| assert_operator line.length, :<=, RULE.length, "ran past the frame" }
      assert_includes output, "…"
    end

    # --- exit status -----------------------------------------------------------------------

    def test_a_clean_run_exits_zero
      assert_equal 0, reporter.finish(results: passing(3), duration: 1.0, warnings: [])
    end

    def test_failures_exit_one
      rep = reporter
      status = rep.finish(results: [build_result(status: :failed, failure: build_failure)],
                          duration: 1.0, warnings: [])

      assert_equal 1, status
      assert_equal 1, rep.exit_status
      assert_predicate rep, :failed?
    end

    def test_jailed_warranted_and_warned_runs_do_not_block_the_build
      rep = reporter
      Constable.warn!("unsafe", location: "a.rb:1")
      results = [build_result(status: :jailed), build_result(status: :warranted),
                 build_result(status: :parole_violation, parole_day: 1, times_jailed: 1)]

      assert_equal 0, rep.finish(results: results, duration: 1.0)
      assert_predicate rep, :success?
    end

    def test_fail_on_warnings_turns_warnings_into_a_failing_build
      write_config("fail_on_warnings: true\n")
      Constable.warn!("unsafe", location: "a.rb:1")

      assert_equal 1, reporter.finish(results: passing(2), duration: 1.0)
    end

    def test_exit_status_tracks_failures_seen_live_before_the_summary
      rep = reporter
      rep.record(build_result(status: :failed, failure: build_failure))

      assert_equal 1, rep.exit_status
    end

    # --- the live glyph stream ----------------------------------------------------------------

    def test_glyphs_stream_grouped_by_case
      rep = reporter
      3.times { rep.record(build_result(case_name: "UsersController::CreatesUserCase")) }
      rep.record(build_result(case_name: "UsersController::CreatesUserCase", status: :failed))
      rep.record(build_result(case_name: "UsersController::CreatesUserCase"))
      2.times { rep.record(build_result(case_name: "SessionsCase")) }
      rep.record(build_result(case_name: "SessionsCase", status: :jailed))
      rep.record(build_result(case_name: "SessionsCase"))
      rep.flush!

      assert_equal ["UsersController::CreatesUserCase  ✓✓✓✗✓",
                    "SessionsCase                      ✓✓⛓✓"], lines.first(2)
    end

    def test_glyph_columns_line_up_across_cases
      rep = reporter
      rep.record(build_result(case_name: "A"))
      rep.record(build_result(case_name: "LongerCaseName"))
      rep.flush!

      columns = lines.first(2).map { |line| line.index("✓") }

      assert_equal [34, 34], columns
    end

    def test_a_case_appearing_after_another_has_started_does_not_corrupt_its_line
      rep = reporter
      rep.record(build_result(case_name: "AlphaCase"))
      rep.record(build_result(case_name: "BetaCase", status: :failed))
      rep.record(build_result(case_name: "AlphaCase"))
      rep.flush!

      assert_equal ["AlphaCase                         ✓✓",
                    "BetaCase                          ✗"], lines.first(2)
    end

    def test_a_case_that_keeps_arriving_after_its_line_closed_gets_a_fresh_line
      rep = reporter
      rep.record(build_result(case_name: "AlphaCase"))
      Reporter::STREAM_FLUSH_THRESHOLD.times { rep.record(build_result(case_name: "BetaCase")) }
      rep.record(build_result(case_name: "AlphaCase", status: :failed))
      rep.flush!

      assert_equal ["AlphaCase                         ✓",
                    "BetaCase                          #{"✓" * Reporter::STREAM_FLUSH_THRESHOLD}",
                    "AlphaCase                         ✗"], lines.first(3)
    end

    def test_a_stalled_case_does_not_hold_the_stream_hostage
      rep = reporter
      rep.record(build_result(case_name: "QuietCase"))
      Reporter::STREAM_FLUSH_THRESHOLD.times { rep.record(build_result(case_name: "BusyCase")) }

      assert_equal "QuietCase                         ✓", lines.first
      assert_includes lines[1], "BusyCase"
    end

    def test_flushing_an_empty_stream_writes_nothing
      reporter.flush!

      assert_empty output
    end

    def test_finish_flushes_the_stream_before_printing_the_summary
      rep = reporter
      results = passing(2)
      results.each { |result| rep.record(result) }
      rep.finish(results: results, duration: 1.0, warnings: [])

      assert_equal "SessionsCase                      ✓✓", lines.first
      assert_empty lines[1]
      assert_equal RULE, lines[2]
    end

    def test_results_with_no_case_name_still_stream
      rep = reporter
      rep.record(build_result(case_name: ""))
      rep.flush!

      assert_includes lines.first, "(anonymous)"
    end

    # --- start ------------------------------------------------------------------------------

    def test_start_announces_the_total_and_the_seed
      reporter.start(total: 482, seed: 8841)

      assert_equal ["constable · 482 tests · seed 8841", ""], lines.first(2)
    end

    def test_start_says_nothing_when_it_has_nothing_to_say
      reporter.start

      assert_empty output
    end

    # --- colour --------------------------------------------------------------------------------

    def test_colour_is_off_for_a_non_tty
      rep = Reporter.new(io: @io, config: Constable.config)

      refute_predicate rep, :color?
      rep.finish(results: [build_result(status: :failed, failure: build_failure)], duration: 1.0, warnings: [])

      refute_includes output, "\e["
    end

    def test_colour_is_on_for_a_tty
      io = tty_io
      rep = Reporter.new(io: io, config: Constable.config)

      assert_predicate rep, :color?
      rep.finish(results: passing(1), duration: 1.0, warnings: [])

      assert_includes io.string, "\e[32m✓ 1 passed\e[0m"
    end

    def test_no_color_env_wins_over_a_tty
      with_env("NO_COLOR" => "1") do
        refute_predicate Reporter.new(io: tty_io, config: Constable.config), :color?
      end
    end

    def test_an_empty_no_color_is_ignored
      with_env("NO_COLOR" => "", "TERM" => "xterm") do
        assert_predicate Reporter.new(io: tty_io, config: Constable.config), :color?
      end
    end

    def test_a_dumb_terminal_gets_no_colour
      with_env("TERM" => "dumb") do
        refute_predicate Reporter.new(io: tty_io, config: Constable.config), :color?
      end
    end

    def test_explicit_colour_overrides_detection
      assert_predicate Reporter.new(io: @io, config: Constable.config, color: true), :color?
      refute_predicate Reporter.new(io: tty_io, config: Constable.config, color: false), :color?
    end

    def test_colour_never_changes_the_layout
      plain   = StringIO.new
      fancy   = StringIO.new
      results = spec_shaped_results
      args    = { duration: 12.4, coverage: { percent: 92, unpatrolled: 3 }, warnings: spec_shaped_warnings }

      Reporter.new(io: plain, config: Constable.config, color: false, slowest: 2).finish(results: results, **args)
      Reporter.new(io: fancy, config: Constable.config, color: true, slowest: 2).finish(results: results, **args)

      assert_equal plain.string, fancy.string.gsub(/\e\[[0-9;]*m/, "")
    end

    def test_passes_are_green_and_failures_are_red
      rep = Reporter.new(io: @io, config: Constable.config, color: true)
      rep.record(build_result)
      rep.record(build_result(case_name: "OtherCase", status: :failed))
      rep.flush!

      assert_includes output, "\e[32m✓\e[0m"
      assert_includes output, "\e[31m✗\e[0m"
    end

    # --- helpers ------------------------------------------------------------------------------

    private

    def headline = lines[3]

    def section_titles
      lines.grep(/\A  [A-Z][A-Z ]+\z/).map(&:strip)
    end

    # Squiggly heredocs strip exactly the leading indentation these blocks are asserting
    # about, so it gets put back explicitly.
    def indent(text, spaces)
      text.lines.map { |line| line.strip.empty? ? line : (" " * spaces) + line }.join
    end

    def tty_io
      io = StringIO.new
      def io.tty? = true
      io
    end

    def with_env(values)
      previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
  end
end

module Constable
  # stdout is results only -- the log router is the half of that promise the reporter
  # can't keep on its own.
  class LogRouterTest < TestCase
    def teardown
      LogRouter.restore!
      unstub_rails!
      super
    end

    def test_routing_is_a_no_op_with_a_clear_reason_when_rails_is_not_loaded
      skip "another test in this process loaded Rails for real" if defined?(::Rails)

      routing = LogRouter.route!

      refute_predicate routing, :routed?
      refute_predicate LogRouter, :routed?
      assert_includes routing.reason, "Rails is not loaded"
      refute_path_exists File.join(tmp_root, "log")
    end

    def test_the_destination_is_log_test_log_under_the_project_root
      assert_equal File.join(tmp_root, "log/test.log"), LogRouter.default_path
    end

    def test_every_rails_logger_is_pointed_at_test_log
      stub_rails!

      routing = LogRouter.route!

      assert_predicate routing, :routed?
      assert_equal File.join(tmp_root, "log/test.log"), routing.path
      assert_same Rails.logger, ActiveRecord::Base.logger
      refute_predicate ActiveRecord::Base, :verbose_query_logs

      Rails.logger.info(%(SELECT "users".* FROM "users"))

      assert_includes File.read(routing.path), %(SELECT "users".* FROM "users")
    end

    def test_quiet_mode_writes_to_the_file_and_nowhere_else
      stub_rails!
      stdout = StringIO.new

      LogRouter.route!(io: stdout)
      Rails.logger.info("chatter")

      assert_empty stdout.string
    end

    def test_verbose_tees_the_same_lines_to_stdout
      stub_rails!
      stdout = StringIO.new

      routing = LogRouter.route!(verbose: true, io: stdout)
      Rails.logger.info("chatter")

      assert_predicate routing, :verbose?
      assert_includes stdout.string, "chatter"
      assert_includes File.read(routing.path), "chatter"
    end

    def test_an_explicit_path_is_honoured
      stub_rails!

      routing = LogRouter.route!(path: "tmp/other.log")

      assert_equal File.join(tmp_root, "tmp/other.log"), routing.path
    end

    def test_restore_puts_the_original_loggers_back
      stub_rails!
      original = Object.new
      Rails.logger = original

      LogRouter.route!

      refute_same original, Rails.logger

      LogRouter.restore!

      assert_same original, Rails.logger
      assert_nil LogRouter.current
    end

    def test_the_tee_writes_to_every_target
      first  = StringIO.new
      second = StringIO.new

      LogRouter::Tee.new(first, second).write("both")

      assert_equal "both", first.string
      assert_equal "both", second.string
    end

    STUBBED_CONSTANTS = %i[Rails ActiveRecord].freeze

    private

    # A real Rails may already be loaded by another test file in the same process, so
    # anything we shadow is put back exactly as it was.
    def stub_rails!
      @stubbed = STUBBED_CONSTANTS.select { |name| Object.const_defined?(name, false) }
                                  .to_h { |name| [name, Object.const_get(name)] }
      @stubbed.each_key { |name| Object.send(:remove_const, name) }

      Object.const_set(:Rails, Module.new { class << self; attr_accessor :logger; end })
      active_record = Module.new
      active_record.const_set(:Base, Class.new do
        class << self
          attr_accessor :logger, :verbose_query_logs
        end
      end)
      Object.const_set(:ActiveRecord, active_record)
    end

    def unstub_rails!
      return if @stubbed.nil?

      STUBBED_CONSTANTS.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
      @stubbed.each { |name, value| Object.const_set(name, value) }
      @stubbed = nil
    end
  end
end
