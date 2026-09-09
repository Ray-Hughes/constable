# frozen_string_literal: true

require_relative "../helper"

module Constable
  # A test's identity is the key everything else hangs off: flake history, the jail
  # docket, warrants, rename detection. If it is not stable, the blotter is fiction; if it
  # is not distinct, two tests share one record.
  class IdentityTest < TestCase
    def test_the_same_body_is_the_same_key
      assert_equal Identity.for_source("attest(1).to eq(1)"), Identity.for_source("attest(1).to eq(1)")
    end

    # The whole promise: reformatting a test is not editing it.
    def test_whitespace_does_not_change_the_key
      assert_equal Identity.for_source("a  +  1"), Identity.for_source("a + 1")
      assert_equal Identity.for_source("a + 1\n"), Identity.for_source("  a + 1  ")
    end

    def test_comments_do_not_change_the_key
      assert_equal Identity.for_source("a + 1 # explains why"), Identity.for_source("a + 1")
    end

    # ...and the other half: changing what a test does starts its history over, which is
    # correct rather than a limitation.
    def test_a_real_change_changes_the_key
      refute_equal Identity.for_source("a + 1"), Identity.for_source("a + 2")
    end

    def test_keys_are_fixed_width_hex
      ["", "a", "é 🚨", "x" * 5000].each do |source|
        assert_match(/\A[0-9a-f]{16}\z/, Identity.for_source(source))
      end
    end

    def test_unicode_is_handled
      refute_equal Identity.for_source("emoji 🚨"), Identity.for_source("emoji 🚔")
    end

    def test_an_empty_body_still_gets_a_key
      assert_match(/\A[0-9a-f]{16}\z/, Identity.for_source(""))
    end

    # --- cold cases -------------------------------------------------------------------

    def test_a_cold_case_is_keyed_by_file_and_description
      a = Identity.for_cold_case("spec/models/user_spec.rb", "is valid")
      b = Identity.for_cold_case("spec/models/user_spec.rb", "is not valid")

      refute_equal a, b
      assert_equal a, Identity.for_cold_case("spec/models/user_spec.rb", "is valid")
    end

    def test_a_cold_case_key_is_relative_to_the_project
      absolute = Identity.for_cold_case(File.join(Constable.root, "spec/a_spec.rb"), "x")

      assert_equal Identity.for_cold_case("spec/a_spec.rb", "x"), absolute
    end

    def test_a_cold_case_with_no_description_still_gets_a_key
      assert_match(/\A[0-9a-f]{16}\z/, Identity.for_cold_case("spec/a_spec.rb", nil))
    end

    # --- disambiguation ---------------------------------------------------------------

    def test_disambiguation_separates_identical_bodies
      base = Identity.for_source("assert(true)")
      a = Identity.disambiguate(base, case_name: "AlphaCase", description: "x")
      b = Identity.disambiguate(base, case_name: "BetaCase", description: "x")

      refute_equal a, b
      refute_equal base, a
    end

    def test_disambiguation_is_stable
      base = Identity.for_source("assert(true)")

      assert_equal Identity.disambiguate(base, case_name: "A", description: "x"),
                   Identity.disambiguate(base, case_name: "A", description: "x")
    end

    # The last resort, for two tests copy-pasted with the same body and description.
    def test_an_ordinal_separates_the_otherwise_identical
      base = Identity.for_source("assert(true)")
      a = Identity.disambiguate(base, case_name: "A", description: "x", ordinal: 0)
      b = Identity.disambiguate(base, case_name: "A", description: "x", ordinal: 1)

      refute_equal a, b
    end
  end
end
