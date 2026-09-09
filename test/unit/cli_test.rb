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

    # --- release --all ------------------------------------------------------------
    #
    # One at a time is unusable at the scale a docket actually reaches. Before 1.4.0 a
    # pass/fail flip jailed a test automatically, and a real suite put 29 on the docket
    # from a single run -- nobody is typing 29 locators.

    def test_release_all_empties_the_docket
      3.times { |i| jail_a_test(file: "test/cases/a_case.rb", line: i + 1, label: "ACase \"#{i}\"") }

      capture { CLI::JailCommand.new([], { "all" => true }).release }

      assert_empty @jail.entries
    end

    def test_release_all_says_how_many_it_freed
      2.times { |i| jail_a_test(file: "test/cases/a_case.rb", line: i + 1, label: "ACase \"#{i}\"") }

      output = capture { CLI::JailCommand.new([], { "all" => true }).release }

      assert_match(/Released 2 tests/, output)
    end

    def test_release_all_on_an_empty_docket_is_not_an_error
      output = capture { CLI::JailCommand.new([], { "all" => true }).release }

      assert_match(/already empty/, output)
    end

    # A locator is still required without --all: releasing everything by accident because
    # an argument was forgotten is not a mistake worth allowing.
    def test_release_without_a_locator_or_all_is_a_usage_error
      jail_a_test

      error = assert_raises(SystemExit) { capture { CLI::JailCommand.new([], {}).release } }

      assert_equal CLI::EXIT_USAGE, error.status
      refute_empty @jail.entries, "nothing should have been released"
    end

    # --- ambiguous targets ------------------------------------------------------
    #
    # A bare path naming several docket rows used to act on whichever row storage
    # returned first -- not even the first by line. Paroling a test the user never
    # named is worse than refusing.

    def three_jailed_in_one_file(file: "test/cases/reports_case.rb")
      %w[first second third].each_with_index do |name, index|
        @jail.jail_identity(Identity.digest(name), label: "ReportsCase \"#{name}\"",
                                                   file: file, line: (index + 1) * 10,
                                                   reason: :jail_mode)
      end
      file
    end

    def test_a_bare_path_matching_several_tests_is_refused
      file = three_jailed_in_one_file

      error = assert_raises(SystemExit) { capture { CLI::JailCommand.new.parole(file) } }

      assert_equal CLI::EXIT_USAGE, error.status
    end

    def test_nothing_is_paroled_when_the_target_is_ambiguous
      file = three_jailed_in_one_file

      assert_raises(SystemExit) { capture { CLI::JailCommand.new.parole(file) } }

      assert_empty @jail.paroled, "an ambiguous target must not parole anything"
      assert_equal 3, @jail.jailed.size
    end

    def test_an_ambiguous_target_lists_the_candidates_in_line_order
      file = three_jailed_in_one_file

      message = capture_stderr do
        assert_raises(SystemExit) { capture { CLI::JailCommand.new.parole(file) } }
      end

      assert_match(/matches 3 tests on the docket/, message)
      assert_equal [10, 20, 30], message.scan(/reports_case\.rb:(\d+)/).flatten.map(&:to_i)
    end

    def test_a_path_with_a_line_is_never_ambiguous
      file = three_jailed_in_one_file

      capture { CLI::JailCommand.new.parole("#{file}:20") }

      assert_equal 1, @jail.paroled.size
      assert_equal 20, @jail.paroled.first.line
    end

    def test_a_file_with_one_jailed_test_still_works_without_a_line
      identity, = jail_a_test(file: "test/cases/only_case.rb", line: 5)

      capture { CLI::JailCommand.new.parole("test/cases/only_case.rb") }

      assert_predicate @jail.entry(identity), :paroled?
    end

    def capture_stderr
      out = StringIO.new
      original = $stderr
      $stderr = out
      yield
      out.string
    ensure
      $stderr = original
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
