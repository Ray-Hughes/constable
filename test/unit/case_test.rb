# frozen_string_literal: true

require_relative "../helper"

module Constable
  class CaseTest < TestCase
    # --- registration ---------------------------------------------------------

    def test_investigate_registers_an_investigation_without_defining_a_method
      klass = build_case { investigate("creates a user") { :ok } }

      assert_equal 1, klass.investigations.size
      investigation = klass.investigations.first
      assert_kind_of Investigation, investigation
      assert_equal "creates a user", investigation.description
      refute_includes klass.instance_methods(false), :"creates a user"
      refute_includes klass.instance_methods(false), :test_creates_a_user
    end

    def test_investigate_returns_the_investigation
      klass = build_case
      investigation = klass.investigate("returns itself") { :ok }

      assert_same investigation, klass.investigations.first
      assert_same klass, investigation.case_class
    end

    def test_descriptions_are_plain_strings_with_punctuation_and_interpolation
      subject = "admin"
      klass = build_case do
        investigate("rejects a #{subject}'s request -- politely, twice!") { :ok }
      end

      assert_equal "rejects a admin's request -- politely, twice!",
                   klass.investigations.first.description
    end

    def test_investigate_captures_file_and_line_from_the_block
      klass = build_case { investigate("here") { :ok } }
      investigation = klass.investigations.first

      assert_equal __FILE__, investigation.file
      assert_operator investigation.line, :>, 0
      assert_match(/case_test\.rb:\d+/, investigation.location)
    end

    def test_investigations_have_a_content_identity
      klass = build_case { investigate("hashes") { 1 + 1 } }

      assert_match(/\A[0-9a-f]{16}\z/, klass.investigations.first.identity)
    end

    def test_investigate_without_a_block_raises
      klass = build_case
      assert_raises(ArgumentError) { klass.investigate("no block") }
    end

    def test_investigations_are_returned_in_declaration_order
      klass = build_case do
        investigate("first") { :ok }
        docket "in a docket" do
          investigate("second") { :ok }
          docket "nested deeper" do
            investigate("third") { :ok }
          end
        end
        investigate("fourth") { :ok }
      end

      assert_equal %w[first second third fourth], klass.investigations.map(&:description)
    end

    # --- fresh instance per investigation -------------------------------------

    def test_each_investigation_runs_in_its_own_fresh_instance
      seen = []
      klass = build_case do
        investigate("leaves state behind") do
          seen << [object_id, @leak]
          @leak = :left_behind
        end
        investigate("must not see it") { seen << [object_id, @leak] }
      end

      klass.investigations.each { |investigation| klass.run(investigation) }

      ids = seen.map(&:first)
      assert_equal ids.uniq.size, ids.size, "investigations shared an instance"
      assert(seen.all? { |(_id, leak)| leak.nil? }, "instance state leaked between investigations")
    end

    # --- witnesses ------------------------------------------------------------

    def test_witness_is_memoized_within_a_single_investigation
      calls = 0
      klass = build_case do
        witness(:token) do
          calls += 1
          "token-#{calls}"
        end
        investigate("uses the witness twice") { [token, token] }
      end

      values = klass.run(klass.investigations.first)

      assert_equal %w[token-1 token-1], values
      assert_equal 1, calls
    end

    def test_witness_is_never_shared_between_investigations
      calls = 0
      klass = build_case do
        witness(:token) do
          calls += 1
          "token-#{calls}"
        end
        investigate("first") { token }
        investigate("second") { token }
      end

      first  = klass.run(klass.investigations[0])
      second = klass.run(klass.investigations[1])

      assert_equal "token-1", first
      assert_equal "token-2", second, "witness value leaked across investigations"
      assert_equal 2, calls
    end

    def test_witness_memoizes_nil_and_false
      calls = 0
      klass = build_case do
        witness(:nothing) do
          calls += 1
          nil
        end
        investigate("asks twice") { [nothing, nothing] }
      end

      assert_equal [nil, nil], klass.run(klass.investigations.first)
      assert_equal 1, calls
    end

    def test_witness_memo_lives_on_the_instance_not_the_class
      klass = build_case do
        witness(:value) { "v" }
        investigate("reads") { value }
      end
      instance = klass.new
      instance.run_investigation(klass.investigations.first)

      assert_equal({ value: "v" }, instance.constable_witnesses)
      assert_empty klass.new.constable_witnesses
      refute klass.instance_variables.include?(:@constable_witnesses)
    end

    def test_witnesses_can_reference_other_witnesses
      klass = build_case do
        witness(:base) { 2 }
        witness(:doubled) { base * 2 }
        investigate("composes") { doubled }
      end

      assert_equal 4, klass.run(klass.investigations.first)
    end

    def test_witness_is_inherited_and_overridable
      parent = build_case("ParentCase") { witness(:name) { "parent" } }
      child  = build_case("ChildCase", parent) do
        investigate("inherits") { name }
      end
      overriding = build_case("OverridingCase", parent) do
        witness(:name) { "child" }
        investigate("overrides") { name }
      end

      assert_equal "parent", child.run(child.investigations.first)
      assert_equal "child", overriding.run(overriding.investigations.first)
      assert_equal %i[name], child.witness_names
    end

    def test_witness_without_a_block_raises
      klass = build_case
      assert_raises(ArgumentError) { klass.witness(:nope) }
    end

    # --- briefings ------------------------------------------------------------

    def test_briefing_runs_before_every_investigation
      runs = []
      klass = build_case do
        briefing { runs << :briefed }
        investigate("one") { runs << :one }
        investigate("two") { runs << :two }
      end

      klass.investigations.each { |investigation| klass.run(investigation) }

      assert_equal %i[briefed one briefed two], runs
    end

    def test_multiple_briefings_run_in_declaration_order
      runs = []
      klass = build_case do
        briefing { runs << :first }
        briefing { runs << :second }
        investigate("body") { runs << :body }
      end

      klass.run(klass.investigations.first)

      assert_equal %i[first second body], runs
    end

    def test_parent_briefings_run_before_child_briefings
      runs = []
      parent = build_case("ParentCase") { briefing { runs << :parent } }
      child  = build_case("ChildCase", parent) do
        briefing { runs << :child }
        investigate("body") { runs << :body }
      end

      child.run(child.investigations.first)

      assert_equal %i[parent child body], runs
      assert_equal 2, child.briefings.size
      assert_equal 1, child.own_briefings.size
    end

    def test_briefings_share_instance_state_with_the_investigation
      klass = build_case do
        briefing { @prepared = "ready" }
        investigate("sees briefing state") { @prepared }
      end

      assert_equal "ready", klass.run(klass.investigations.first)
    end

    def test_briefing_without_a_block_raises
      klass = build_case
      assert_raises(ArgumentError) { klass.briefing }
    end

    def test_there_is_no_before_all_equivalent
      refute_respond_to Constable::Case, :before_all
      refute_respond_to Constable::Case, :before
      refute_respond_to Constable::Case, :setup_all
    end

    # --- dockets --------------------------------------------------------------

    def test_docket_creates_an_anonymous_subclass_with_a_docket_path
      klass = build_case do
        docket "as an admin" do
          investigate("creates a user") { :ok }
        end
      end
      subclass = klass.dockets.first

      assert_operator subclass, :<, klass
      assert_predicate subclass, :docket?
      refute_predicate klass, :docket?
      assert_equal ["as an admin"], subclass.docket_path
      assert_equal "as an admin", subclass.docket_description
      assert_empty klass.docket_path
    end

    def test_docket_description_folds_into_the_investigation_description
      klass = build_case do
        docket "as an admin" do
          investigate("creates a user") { :ok }
        end
      end
      investigation = klass.investigations.first

      assert_equal "creates a user", investigation.description
      assert_equal "as an admin creates a user", investigation.full_description
      assert_equal ["as an admin"], investigation.docket_path
    end

    def test_dockets_nest_arbitrarily_deep
      klass = build_case do
        docket "as an admin" do
          docket "with a locked account" do
            docket "on a weekend" do
              investigate("is refused") { :ok }
            end
          end
        end
      end

      assert_equal "as an admin with a locked account on a weekend is refused",
                   klass.investigations.first.full_description
    end

    def test_docket_witnesses_are_scoped_to_the_docket
      klass = build_case do
        docket "inside" do
          witness(:secret) { "docket only" }
          investigate("sees it") { secret }
        end
        investigate("does not see it") { respond_to?(:secret) }
      end
      inside, outside = klass.investigations

      assert_equal "docket only", klass.run(inside)
      refute klass.run(outside), "docket witness leaked to the enclosing case"
      refute_includes klass.witness_names, :secret
    end

    def test_docket_briefings_are_scoped_to_the_docket
      runs = []
      klass = build_case do
        briefing { runs << :outer }
        docket "inside" do
          briefing { runs << :inner }
          investigate("inside") { runs << :inside_body }
        end
        investigate("outside") { runs << :outside_body }
      end
      inside, outside = klass.investigations

      klass.run(inside)
      assert_equal %i[outer inner inside_body], runs

      runs.clear
      klass.run(outside)
      assert_equal %i[outer outside_body], runs
    end

    def test_sibling_dockets_share_no_state
      klass = build_case do
        docket "first" do
          briefing { @role = :admin }
          investigate("admin") { @role }
        end
        docket "second" do
          investigate("guest") { defined?(@role) ? @role : :none }
        end
      end
      admin, guest = klass.investigations

      assert_equal :admin, klass.run(admin)
      assert_equal :none, klass.run(guest)
    end

    def test_docket_investigations_run_in_the_docket_subclass
      klass = build_case do
        docket "inside" do
          investigate("reports its class") { self.class }
        end
      end
      investigation = klass.investigations.first

      assert_same klass.dockets.first, investigation.case_class
      assert_same klass.dockets.first, klass.run(investigation)
    end

    def test_docket_without_a_block_raises
      klass = build_case
      assert_raises(ArgumentError) { klass.docket("no block") }
    end

    # --- tiers ----------------------------------------------------------------

    def test_tier_is_set_and_read_back
      klass = build_case { tier :unit }

      assert_equal :unit, klass.tier
    end

    def test_tier_is_inherited_by_subclasses
      unit_case = build_case("UnitCase") { tier :unit }
      real_case = build_case("UsersCase", unit_case) { investigate("x") { :ok } }
      grandchild = build_case("DeeperCase", real_case)

      assert_equal :unit, real_case.tier
      assert_equal :unit, grandchild.tier
      assert_equal :unit, real_case.investigations.first.tier
    end

    def test_tier_can_be_overridden_by_a_subclass
      unit_case = build_case("UnitCase") { tier :unit }
      system_case = build_case("SystemishCase", unit_case) { tier :system }

      assert_equal :system, system_case.tier
      assert_equal :unit, unit_case.tier
    end

    def test_tier_is_inherited_into_dockets
      klass = build_case do
        tier :integration
        docket "inside" do
          investigate("x") { :ok }
        end
      end

      assert_equal :integration, klass.dockets.first.tier
      assert_equal :integration, klass.investigations.first.tier
    end

    def test_tier_defaults_to_nil_without_a_declaration_or_matching_path
      klass = build_case { investigate("x") { :ok } }

      assert_nil klass.tier
      assert_nil klass.investigations.first.tier
    end

    # --- display names --------------------------------------------------------

    def test_display_name_of_a_named_case
      klass = build_case("UsersController::CreatesUserCase")

      assert_equal "UsersController::CreatesUserCase", klass.constable_display_name
    end

    def test_anonymous_docket_subclass_reports_the_nearest_named_ancestor
      klass = build_case("UsersController::CreatesUserCase") do
        docket "as an admin" do
          docket "with a locked account" do
            investigate("is refused") { :ok }
          end
        end
      end
      deepest = klass.dockets.first.dockets.first

      assert_equal "UsersController::CreatesUserCase", deepest.constable_display_name
      assert_equal "UsersController::CreatesUserCase", klass.investigations.first.case_name
      assert_equal 'UsersController::CreatesUserCase "as an admin with a locked account is refused"',
                   klass.investigations.first.display_label
    end

    def test_display_name_falls_back_for_a_wholly_anonymous_case
      klass = Class.new(Constable::Case)

      assert_equal "AnonymousCase", klass.constable_display_name
    end

    def test_instances_report_the_display_name_too
      klass = build_case("SessionsCase")

      assert_equal "SessionsCase", klass.new.constable_display_name
    end

    # --- runner entry point ---------------------------------------------------

    def test_run_investigation_runs_setup_then_body_and_returns_the_body_value
      runs = []
      klass = build_case do
        witness(:token) { "t" }
        briefing { runs << :briefed }
        investigate("body") do
          runs << :body
          token
        end
      end
      investigation = klass.investigations.first
      instance = klass.new

      assert_equal "t", instance.run_investigation(investigation)
      assert_equal %i[briefed body], runs
      assert_same investigation, instance.constable_investigation
    end

    def test_run_setup_runs_briefings_without_the_body
      runs = []
      klass = build_case do
        briefing { runs << :briefed }
        investigate("never runs") { runs << :body }
      end
      instance = klass.new

      instance.run_setup(klass.investigations.first)

      assert_equal %i[briefed], runs
    end

    def test_run_setup_clears_witness_memoization
      calls = 0
      klass = build_case do
        witness(:token) do
          calls += 1
          calls
        end
        investigate("reads") { token }
      end
      investigation = klass.investigations.first
      instance = klass.new

      assert_equal 1, instance.run_investigation(investigation)
      assert_equal 2, instance.run_investigation(investigation)
    end

    def test_class_level_run_builds_a_fresh_instance_each_time
      instances = []
      klass = build_case { investigate("who am i") { instances << self } }
      investigation = klass.investigations.first

      klass.run(investigation)
      klass.run(investigation)

      assert_equal 2, instances.size
      refute_same instances[0], instances[1]
    end

    def test_run_accepts_a_prepared_instance
      klass = build_case { investigate("x") { self } }
      instance = klass.new

      assert_same instance, klass.run(klass.investigations.first, instance: instance)
    end

    def test_constable_instance_for_binds_the_investigation
      klass = build_case { investigate("x") { :ok } }
      investigation = klass.investigations.first
      instance = klass.constable_instance_for(investigation)

      assert_kind_of klass, instance
      assert_same investigation, instance.constable_investigation
    end

    def test_failures_inside_an_investigation_propagate_to_the_caller
      klass = build_case { investigate("explodes") { raise Constable::AssertionFailed, "nope" } }

      error = assert_raises(Constable::AssertionFailed) { klass.run(klass.investigations.first) }
      assert_equal "nope", error.message
    end

    # --- shared behaviour is just Ruby ----------------------------------------

    def test_a_plain_module_supplies_shared_behaviour
      helpers = Module.new do
        def sign_in(role) = "signed in as #{role}"
      end
      klass = build_case do
        include helpers
        investigate("uses the module") { sign_in(:admin) }
      end

      assert_equal "signed in as admin", klass.run(klass.investigations.first)
    end
  end
end
