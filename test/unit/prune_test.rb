# frozen_string_literal: true

require_relative "../helper"

module Constable
  # A test's key is a content hash of its body, so editing a jailed test gives it a new
  # identity and leaves the old docket row behind -- pointing at a file:line that may now
  # hold something else entirely. That is identity working as designed; `constable prune`
  # is the broom.
  class PruneTest < TestCase
    def setup
      super
      @jail = Jail.new(config: Constable.config, storage: Constable.storage)
    end

    def jail_row(name, file: "test/cases/models/reports_case.rb", line: 2)
      identity = Identity.digest(name)
      @jail.jail_identity(identity, label: "ReportsCase \"#{name}\"", file: file, line: line,
                                    reason: :jail_mode)
      identity
    end

    def cold = ->(path) { Constable.config.cold_case?(path) }

    def stale(known) = @jail.stale_entries(known, cold_case: cold)

    # --- what counts as gone ----------------------------------------------------------

    def test_a_row_whose_test_still_exists_is_kept
      write_file("test/cases/models/reports_case.rb", "# still here\n")
      identity = jail_row("counts overdue tasks")

      assert_empty stale([identity])
    end

    # The case this command exists for: the file is still there, the test's body changed,
    # so its identity did too and the old row now points at a line holding something else.
    def test_a_row_whose_body_changed_is_stale
      write_file("test/cases/models/reports_case.rb", "# still here\n")
      jail_row("counts overdue tasks")

      assert_equal 1, stale(["some-other-identity"]).size
    end

    def test_a_row_whose_file_is_gone_is_stale
      jail_row("counts overdue tasks", file: "test/cases/models/deleted_case.rb")

      assert_equal 1, stale([]).size
    end

    # The path stored beside a row is a display label; the identity is the truth. A test
    # that moved to another file has an out-of-date label, not a missing test, and
    # pruning it would throw away a live docket entry.
    def test_a_known_identity_is_kept_even_when_its_recorded_file_is_gone
      identity = jail_row("counts", file: "test/cases/models/moved_from_case.rb")

      assert_empty stale([identity])
    end

    # Cold-case tests cannot be enumerated without running their own engine, so absence
    # from the known set says nothing about them. Pruning on that would delete live rows.
    def test_a_cold_case_row_is_never_pruned_while_its_file_exists
      write_config("cold_cases:\n  - spec/**/*_spec.rb\n")
      @jail = Jail.new(config: Constable.config, storage: Constable.storage)
      write_file("spec/models/user_spec.rb", "# a real cold case\n")
      jail_row("something", file: "spec/models/user_spec.rb")

      assert_empty stale([])
    end

    def test_a_cold_case_row_is_pruned_once_its_file_is_gone
      write_config("cold_cases:\n  - spec/**/*_spec.rb\n")
      @jail = Jail.new(config: Constable.config, storage: Constable.storage)
      jail_row("something", file: "spec/models/deleted_spec.rb")

      assert_equal 1, stale([]).size
    end

    def test_a_row_with_no_file_recorded_is_stale
      jail_row("orphan", file: "")

      assert_equal 1, stale([]).size
    end

    def test_an_empty_docket_prunes_nothing
      assert_empty stale([])
    end

    # --- the effect ------------------------------------------------------------------

    def test_forgetting_a_row_removes_it_from_the_docket
      write_file("test/cases/models/reports_case.rb", "# still here\n")
      identity = jail_row("counts overdue tasks")

      @jail.forget(identity)

      entry = @jail.entry(identity)
      assert(entry.nil? || entry.released?, "the row should be gone, got #{entry.inspect}")
    end

    def test_pruning_leaves_the_rows_that_are_still_real
      write_file("test/cases/models/reports_case.rb", "# still here\n")
      keep = jail_row("still here", line: 2)
      jail_row("gone", file: "test/cases/models/deleted_case.rb")

      stale([keep]).each { |entry| @jail.forget(entry.identity) }

      assert_equal [keep], @jail.entries.map(&:identity)
    end

    # Warrants rot exactly the same way and share the implementation.
    def test_warrants_go_stale_on_the_same_terms
      warrants = Warrants.new(config: Constable.config, storage: Constable.storage)
      Constable.storage.issue_warrant(Identity.digest("flaky"), label: "BillingCase \"flaky\"",
                                                                file: "test/cases/gone_case.rb",
                                                                line: 9, reason: "passed on retry")

      assert_equal 1, warrants.stale_entries([], cold_case: cold).size
    end
  end
end
