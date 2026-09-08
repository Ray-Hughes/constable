# frozen_string_literal: true

require_relative "../helper"
require "constable/cli"

module Constable
  # The CLI had no test file at all, which is how `constable jail parole`,
  # `constable jail release` and `constable warrants release` all shipped calling a
  # method -- `identity_for` -- that exists on neither Jail nor Warrants. Every one of
  # them is in the published command reference, and every one of them raised
  # NoMethodError the moment it was run.
  #
  # These tests drive the Thor commands the way a shell does, against the real SQLite
  # blotter, because the bug lived precisely in the wiring between the two.
  class CliTest < TestCase
    def setup
      super
      @jail = Jail.new(config: Constable.config, storage: Constable.storage)
    end

    # Puts a real row on the docket and hands back its locator.
    def jail_a_test(file: "test/cases/reports_case.rb", line: 12, label: "ReportsCase \"is red\"")
      identity = Identity.digest("#{file}:#{line}")
      @jail.jail_identity(identity, label: label, file: file, line: line, reason: :jail_mode)
      [identity, "#{file}:#{line}"]
    end

    def capture
      out = StringIO.new
      original = $stdout
      $stdout = out
      yield
      out.string
    ensure
      $stdout = original
    end

    # --- jail parole / release --------------------------------------------------

    def test_jail_parole_moves_a_jailed_test_to_parole
      identity, locator = jail_a_test

      capture { CLI::JailCommand.new.parole(locator) }

      assert_predicate @jail.entry(identity), :paroled?
      refute_predicate @jail.entry(identity), :jailed?
    end

    def test_jail_release_removes_the_test_from_the_docket
      identity, locator = jail_a_test

      capture { CLI::JailCommand.new.release(locator) }

      entry = @jail.entry(identity)
      assert(entry.nil? || entry.released?, "expected the docket row to be gone, got #{entry.inspect}")
    end

    def test_jail_parole_accepts_a_bare_identity
      identity, = jail_a_test

      capture { CLI::JailCommand.new.parole(identity) }

      assert_predicate @jail.entry(identity), :paroled?
    end

    # A locator naming nothing is a usage error, not a stack trace.
    def test_jail_parole_exits_with_a_usage_error_for_an_unknown_locator
      error = assert_raises(SystemExit) do
        capture { CLI::JailCommand.new.parole("test/cases/nope_case.rb:1") }
      end

      assert_equal CLI::EXIT_USAGE, error.status
    end

    # --- warrants release -------------------------------------------------------

    def test_warrants_release_clears_a_standing_warrant
      identity = Identity.digest("BillingCase charges a card")
      Constable.storage.issue_warrant(identity, label: "BillingCase \"charges a card\"",
                                                file: "test/cases/billing_case.rb", line: 9,
                                                reason: "passed on retry")

      capture { CLI::WarrantsCommand.new.release("test/cases/billing_case.rb:9") }

      warrants = Warrants.new(config: Constable.config, storage: Constable.storage)
      assert_empty(warrants.entries.select { |entry| entry.identity == identity })
    end

    def test_warrants_release_exits_with_a_usage_error_for_an_unknown_locator
      error = assert_raises(SystemExit) do
        capture { CLI::WarrantsCommand.new.release("test/cases/nope_case.rb:1") }
      end

      assert_equal CLI::EXIT_USAGE, error.status
    end
  end
end
