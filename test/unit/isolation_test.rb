# frozen_string_literal: true

require "helper"

module Constable
  class IsolationTest < Constable::TestCase
    # Regression: rollback used to be skipped for the :unit tier, on the theory that a unit
    # test has no database. But the default tier config routes test/cases/models/** to
    # :unit, and Rails model tests are exactly the ones that write rows -- so records
    # survived into the next investigation and isolation was silently gone.
    def test_transactionality_does_not_depend_on_the_tier
      %i[unit integration system].each do |tier|
        assert_equal Isolation.transactional?(:integration), Isolation.transactional?(tier),
                     "tier #{tier} must not change whether a test is rolled back"
      end
    end

    def test_no_database_means_no_transaction_rather_than_an_error
      refute_predicate Isolation, :transactional?
    end

    def test_with_rollback_still_yields_when_there_is_no_database
      assert_equal :ran, Isolation.with_rollback(:unit) { :ran }
    end

    def test_a_clean_investigation_reports_no_leak
      before = Isolation.snapshot

      assert_empty Isolation.diff(before, Isolation.snapshot)
    end

    def test_a_new_global_is_reported_as_a_leak
      before = Isolation.snapshot
      eval("$constable_leak_probe = 1", binding, __FILE__, __LINE__)
      leaks = Isolation.diff(before, Isolation.snapshot)

      assert(leaks.any? { |l| l.include?("constable_leak_probe") })
    ensure
      eval("$constable_leak_probe = nil", binding, __FILE__, __LINE__)
    end

    # Regression: written as %i[], a literal backslash escaped the following space and
    # fused two entries into one bogus symbol, dropping both from the ignore list. The
    # leak check then reported them on every single test.
    def test_the_ignore_list_contains_no_fused_entries
      Isolation::IGNORED_GLOBALS.each do |name|
        refute_includes name.to_s, " ", "#{name.inspect} looks like two entries fused together"
      end

      assert_includes Isolation::IGNORED_GLOBALS, :$.
      # rubocop:disable Lint/SymbolConversion -- the bare literal for this one is what the
      # cop's autocorrect turns into a syntax error, which is the bug being tested.
      assert_includes Isolation::IGNORED_GLOBALS, "$\\".to_sym
      # rubocop:enable Lint/SymbolConversion
    end

    def test_interpreter_flag_globals_are_ignored
      before = Isolation.snapshot
      after = Isolation.snapshot

      assert_empty Isolation.diff(before, after).grep(/\$-/)
    end

    # Ruby's own stdlib lazily initialises class variables the first time you touch it.
    # Reporting those as application leaks would train everyone to ignore the section.
    def test_only_project_classes_are_watched
      refute Isolation.app_defined?(String), "a core class is not the app's to leak"
      refute Isolation.app_defined?(Constable::Case), "the framework is not the app"
    end
  end
end
