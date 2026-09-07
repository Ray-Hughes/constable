# frozen_string_literal: true

require_relative "../helper"

module Constable
  class RegistryTest < TestCase
    def registry = Constable.registry

    def test_a_fresh_registry_is_empty
      assert_empty registry.cases
      assert_predicate registry, :empty?
      assert_equal 0, registry.size
    end

    def test_case_subclasses_register_themselves_as_they_are_defined
      klass = build_case("UsersCase")

      assert_includes registry.cases, klass
      assert_equal 1, registry.size
    end

    def test_tier_base_classes_and_their_subclasses_all_register
      unit_case = build_case("UnitCase") { tier :unit }
      users_case = build_case("UsersCase", unit_case)

      assert_equal [unit_case, users_case], registry.cases
    end

    def test_cases_are_listed_in_definition_order
      first  = build_case("FirstCase")
      second = build_case("SecondCase")
      third  = build_case("ThirdCase")

      assert_equal [first, second, third], registry.cases
    end

    def test_anonymous_docket_subclasses_are_excluded_from_the_top_level_list
      klass = build_case("UsersCase") do
        docket "as an admin" do
          docket "with a locked account" do
            investigate("is refused") { :ok }
          end
        end
      end

      assert_equal [klass], registry.cases
      refute_includes registry.cases, klass.dockets.first
    end

    def test_registering_the_same_class_twice_is_a_no_op
      klass = build_case("UsersCase")
      registry.register(klass)

      assert_equal 1, registry.size
    end

    def test_register_returns_the_class
      klass = build_case("UsersCase")

      assert_same klass, registry.register(klass)
    end

    def test_investigations_spans_every_loaded_case_and_its_dockets
      build_case("FirstCase") do
        investigate("one") { :ok }
        docket "in a docket" do
          investigate("two") { :ok }
        end
      end
      build_case("SecondCase") { investigate("three") { :ok } }

      assert_equal %w[one two three], registry.investigations.map(&:description)
      assert(registry.investigations.all? { |inv| inv.is_a?(Investigation) })
    end

    def test_investigations_is_empty_when_cases_declare_nothing
      build_case("EmptyCase")

      assert_empty registry.investigations
    end

    def test_sworn_cases_skips_cases_with_no_investigations
      build_case("UnitCase") { tier :unit }
      users_case = build_case("UsersCase") { investigate("one") { :ok } }

      assert_equal [users_case], registry.sworn_cases
    end

    def test_investigations_in_finds_by_absolute_or_relative_path
      build_case("UsersCase") { investigate("one") { :ok } }

      assert_equal 1, registry.investigations_in(__FILE__).size
      relative = registry.investigations.first.relative_file
      assert_equal 1, registry.investigations_in(relative).size
      assert_empty registry.investigations_in("nowhere/at/all.rb")
    end

    def test_find_case_by_display_name
      klass = build_case("UsersController::CreatesUserCase")

      assert_same klass, registry.find_case("UsersController::CreatesUserCase")
      assert_nil registry.find_case("NoSuchCase")
    end

    def test_clear_empties_the_roll
      build_case("UsersCase") { investigate("one") { :ok } }

      assert_equal 1, registry.size
      registry.clear

      assert_predicate registry, :empty?
      assert_empty registry.investigations
    end

    def test_clear_returns_the_registry
      assert_same registry, registry.clear
    end

    def test_registry_is_enumerable
      first  = build_case("FirstCase")
      second = build_case("SecondCase")

      assert_equal %w[FirstCase SecondCase], registry.map(&:constable_display_name)
      assert_includes registry.to_a, first
      assert registry.include?(second)
    end

    def test_constable_registry_is_memoized_and_reset_returns_a_new_one
      original = Constable.registry
      assert_same original, Constable.registry

      Constable.reset!
      refute_same original, Constable.registry
      assert_predicate Constable.registry, :empty?
    end
  end
end
