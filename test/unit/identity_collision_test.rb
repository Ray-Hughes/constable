# frozen_string_literal: true

require_relative "../helper"

module Constable
  # A test's key is a content hash of its body, which is what lets history survive a
  # rename. The cost is that two tests with byte-identical bodies hash to the same key --
  # and bodies repeat constantly. `attest(build(:thing, name: nil)).not_to be_valid` is
  # the same handful of tokens in every model case, and the model generator writes an
  # identical first investigation into every file it touches.
  #
  # Left alone, the blotter treats those two tests as one: jail either and both go, and
  # their flake histories merge into a single misleading record.
  class IdentityCollisionTest < TestCase
    def build_case(class_name, &)
      klass = Class.new(Constable::Case)
      Object.const_set(class_name, klass) unless Object.const_defined?(class_name)
      klass = Object.const_get(class_name)
      klass.class_eval(&)
      klass
    end

    def teardown
      %w[AlphaCase BetaCase GammaCase].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name)
      end
      super
    end

    def identical_bodies
      build_case("AlphaCase") do
        investigate("alpha does the thing") { assert(true) }
      end
      build_case("BetaCase") do
        investigate("beta does something else") { assert(true) }
      end
    end

    def investigations = Constable.registry.investigations

    def test_identical_bodies_collide_before_disambiguation
      identical_bodies

      keys = investigations.map(&:identity)
      assert_equal 1, keys.uniq.size, "the collision this class exists to fix should be real"
    end

    def test_disambiguation_separates_them
      identical_bodies

      Constable.registry.disambiguate_identities!

      keys = investigations.map(&:identity)
      assert_equal 2, keys.uniq.size, "two different tests must not share one blotter row"
    end

    def test_disambiguation_reports_what_it_re_keyed
      identical_bodies

      groups = Constable.registry.disambiguate_identities!

      assert_equal 1, groups.size
      assert_equal 2, groups.first.size
    end

    def test_a_suite_with_no_collisions_is_untouched
      build_case("AlphaCase") { investigate("a") { assert(true) } }
      build_case("BetaCase")  { investigate("b") { assert_equal(2, 1 + 1) } }
      before = investigations.map(&:identity)

      assert_empty Constable.registry.disambiguate_identities!
      assert_equal before, investigations.map(&:identity)
    end

    # Deterministic: the same suite must key the same way on every machine and in every
    # load order, or CI and a laptop disagree about who is on the docket.
    def test_disambiguation_is_deterministic
      identical_bodies
      Constable.registry.disambiguate_identities!
      first = investigations.map(&:identity).sort

      Constable.registry.clear
      %w[AlphaCase BetaCase].each { |n| Object.send(:remove_const, n) if Object.const_defined?(n) }
      identical_bodies
      Constable.registry.disambiguate_identities!

      assert_equal first, investigations.map(&:identity).sort
    end

    # Three-way collisions are the generator's normal output, not an exotic case.
    def test_three_identical_bodies_all_separate
      build_case("AlphaCase") { investigate("a") { assert(true) } }
      build_case("BetaCase")  { investigate("b") { assert(true) } }
      build_case("GammaCase") { investigate("c") { assert(true) } }

      Constable.registry.disambiguate_identities!

      assert_equal 3, investigations.map(&:identity).uniq.size
    end

    # Two tests in the *same* case with the same body still have different descriptions.
    def test_a_collision_inside_one_case_is_separated_too
      build_case("AlphaCase") do
        investigate("first way of saying it")  { assert(true) }
        investigate("second way of saying it") { assert(true) }
      end

      Constable.registry.disambiguate_identities!

      assert_equal 2, investigations.map(&:identity).uniq.size
    end

    def test_disambiguated_keys_still_look_like_identities
      identical_bodies
      Constable.registry.disambiguate_identities!

      investigations.each do |investigation|
        assert_match(/\A[0-9a-f]{16}\z/, investigation.identity)
      end
    end

    # Running it twice must not keep re-keying, or every run would invent new history.
    def test_disambiguation_is_idempotent
      identical_bodies
      Constable.registry.disambiguate_identities!
      once = investigations.map(&:identity).sort

      Constable.registry.disambiguate_identities!

      assert_equal once, investigations.map(&:identity).sort
    end
  end
end
