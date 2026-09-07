# frozen_string_literal: true

require_relative "../helper"

module Constable
  class MatchersTest < TestCase
    # Expectations is exercised through a bare host rather than Constable::Case, so this
    # suite says nothing about the Case DSL and cannot fail because of it.
    class Subject
      include Constable::Matchers::Expectations
    end

    # -- Test doubles ------------------------------------------------------------------
    # Duck types only. Nothing here loads Rails, which is the point: the built-ins have to
    # work against anything that quacks like a response or a record.

    class FakeResponse
      attr_reader :status, :body, :headers

      def initialize(status:, body: "", headers: {})
        @status  = status
        @body    = body
        @headers = headers
      end

      def location = @headers["Location"]
    end

    class FakeRecord
      attr_reader :email, :role

      def initialize(email:, role: "member", created: false, timed_out: false)
        @email     = email
        @role      = role
        @created   = created
        @timed_out = timed_out
      end

      def attributes = { "email" => @email, "role" => @role }
      def created? = @created
      def admin? = @role == "admin"
      def has_timed_out? = @timed_out
    end

    class FakeModel
      class << self
        def name = "User"
        def rows = @rows ||= []
        def reset! = @rows = []
        def count = rows.size

        def exists?(attrs = nil)
          return !rows.empty? if attrs.nil?

          rows.any? { |row| attrs.all? { |k, v| row[k] == v } }
        end
      end
    end

    def setup
      super
      Matchers.clear!
      FakeModel.reset!
      @subject = Subject.new
    end

    def teardown
      Matchers.clear!
      super
    end

    # -- define / registry -------------------------------------------------------------

    def test_define_registers_a_matcher_that_passes_on_a_truthy_return
      Matchers.define(:be_created) { |response| response.status == 201 }

      assert Matchers.registered?(:be_created)
      assert_equal :be_created, Matchers.matcher_for(:be_created).name
      in_case { attest(FakeResponse.new(status: 201)).to be_created }
    end

    def test_define_supports_extra_arguments_exactly_as_the_spec_writes_them
      Matchers.define(:exist) { |model_class, attrs| model_class.exists?(attrs) }
      FakeModel.rows << { email: "a@b.com" }

      in_case { attest(FakeModel).to exist(email: "a@b.com") }
      error = assert_fails { in_case { attest(FakeModel).to exist(email: "nope@b.com") } }
      assert_includes error.message, "User"
      assert_includes error.message, 'email: "nope@b.com"'
    end

    def test_define_requires_a_block
      assert_raises(ArgumentError) { Matchers.define(:no_block) }
    end

    def test_a_custom_matcher_may_return_a_message_and_context_tuple
      Matchers.define(:be_shipped) do |order|
        [order[:state] == "shipped", "expected order #{order[:id]} to be shipped, but it is #{order[:state]}",
         { "Order" => order.inspect }]
      end

      error = assert_fails { in_case { attest({ id: 7, state: "pending" }).to be_shipped } }
      assert_equal "expected order 7 to be shipped, but it is pending", error.message
      assert_equal({ "Order" => { id: 7, state: "pending" }.inspect }, error.context)
    end

    def test_a_tuple_shaped_return_value_is_not_mistaken_for_a_failure_tuple
      # [true, "x"] is a legitimate truthy value for a matcher to return by accident;
      # only a genuine [bool, String|nil, ...] triple is treated as the rich form.
      Matchers.define(:be_listy) { |actual| actual }

      in_case { attest([1, 2, 3]).to be_listy }
      assert_fails { in_case { attest(nil).to be_listy } }
      assert_fails { in_case { attest(false).to be_listy } }
    end

    def test_a_custom_matcher_overrides_a_built_in_and_clear_restores_it
      Matchers.define(:eq) { |_actual, _expected| true }
      in_case { attest(1).to eq(2) } # the override says everything is equal

      Matchers.clear!

      refute Matchers.registered?(:be_shipped)
      assert Matchers.registered?(:eq), "clear! resets to the built-ins, it does not wipe them"
      assert_fails { in_case { attest(1).to eq(2) } }
    end

    def test_clear_removes_custom_matchers_only
      Matchers.define(:be_purple) { |_| true }
      assert Matchers.registered?(:be_purple)

      Matchers.clear!

      refute Matchers.registered?(:be_purple)
      assert_includes Matchers.names, :eq
    end

    def test_matcher_for_returns_nil_for_an_unknown_name
      assert_nil Matchers.matcher_for(:no_such_matcher)
      refute Matchers.registered?(:no_such_matcher)
    end

    # -- attest / bare resolution ------------------------------------------------------

    def test_bare_matcher_calls_resolve_through_method_missing
      deferred = @subject.send(:eq, 1)

      assert_kind_of Matchers::Deferred, deferred
      assert_equal :eq, deferred.name
      assert_equal [1], deferred.args
      assert @subject.respond_to?(:be_whatever)
    end

    def test_an_unmatcherlike_missing_method_still_raises_no_method_error
      assert_raises(NoMethodError) { in_case { totally_bogus_helper(1) } }
    end

    def test_matcher_helper_is_an_explicit_escape_hatch
      in_case { attest(3).to matcher(:eq, 3) }
    end

    def test_to_rejects_something_that_is_not_a_matcher
      error = assert_raises(Constable::Error) { @subject.attest(1).to 1 }
      assert_includes error.message, "expects a matcher"
    end

    def test_attest_needs_a_value_or_a_block
      assert_raises(Constable::Error) { @subject.attest }
    end

    def test_to_returns_the_actual_so_it_can_be_chained
      record = FakeRecord.new(email: "a@b.com")
      assert_same record, @subject.attest(record).to(@subject.send(:be_a, FakeRecord))
    end

    def test_not_to_passes_when_the_matcher_fails
      in_case { attest(1).not_to eq(2) }
      in_case { attest([1]).to_not be_empty }
    end

    def test_negated_failure_names_both_sides
      error = assert_fails { in_case { attest(1).not_to eq(1) } }
      assert_equal "expected 1 not to eq 1", error.message
    end

    # -- be_* predicate fallback -------------------------------------------------------

    def test_be_predicate_fallback_calls_the_question_mark_method
      refute Matchers.registered?(:be_admin)

      in_case { attest(FakeRecord.new(email: "a@b.com", role: "admin")).to be_admin }
      in_case { attest(FakeRecord.new(email: "a@b.com")).not_to be_admin }
    end

    def test_be_predicate_fallback_failure_names_the_predicate
      error = assert_fails { in_case { attest(FakeRecord.new(email: "a@b.com")).to be_admin } }
      assert_includes error.message, "to be admin"
      assert_includes error.message, "#admin? returned false"
      assert_equal({ "Attributes" => { "email" => "a@b.com", "role" => "member" }.inspect }, error.context)
    end

    def test_negated_predicate_fallback_failure_reads_correctly
      error = assert_fails { in_case { attest(FakeRecord.new(email: "a@b.com", role: "admin")).not_to be_admin } }
      assert_includes error.message, "not to be admin"
      assert_includes error.message, "#admin? returned true"
    end

    def test_be_created_falls_back_to_the_created_predicate_for_a_plain_object
      in_case { attest(FakeRecord.new(email: "a@b.com", created: true)).to be_created }
      assert_fails { in_case { attest(FakeRecord.new(email: "a@b.com")).to be_created } }
    end

    def test_have_predicate_fallback_uses_has_prefix
      in_case { attest(FakeRecord.new(email: "a@b.com", timed_out: true)).to have_timed_out }
      error = assert_fails { in_case { attest(FakeRecord.new(email: "a@b.com")).to have_timed_out } }
      assert_includes error.message, "to have timed out"
      assert_includes error.message, "#has_timed_out? returned false"
    end

    def test_predicate_fallback_says_so_when_the_object_has_no_such_predicate
      error = assert_fails { in_case { attest("a string").to be_wibbly } }
      assert_includes error.message, "to respond to #wibbly?"
      assert_includes error.message, "no matcher named :be_wibbly is registered"
    end

    def test_deferred_for_raises_for_a_name_that_is_neither_registered_nor_predicate_shaped
      assert_raises(Constable::Error) { Matchers.deferred_for(:frobnicate) }
    end

    # -- eq / eql ----------------------------------------------------------------------

    def test_eq
      in_case { attest(1 + 1).to eq(2) }
      error = assert_fails { in_case { attest(3).to eq(2) } }
      assert_equal "expected 3 to eq 2", error.message
    end

    def test_eq_flags_a_type_mismatch_that_would_otherwise_look_identical
      error = assert_fails { in_case { attest("1").to eq(1) } }
      assert_equal 'expected "1" to eq 1 (String vs Integer)', error.message
    end

    def test_eql
      in_case { attest(1).to eql(1) }
      in_case { attest(1).not_to eql(1.0) }
      error = assert_fails { in_case { attest(1.0).to eql(1) } }
      assert_includes error.message, "to eql 1"
      assert_includes error.message, "Float vs Integer"
    end

    # -- include -----------------------------------------------------------------------

    def test_include_on_arrays_and_strings
      in_case { attest([1, 2, 3]).to include(2) }
      in_case { attest("hello world").to include("world") }
      in_case { attest([1, 2, 3]).to include(1, 3) }
    end

    def test_include_on_hashes_matches_keys_and_pairs
      in_case { attest({ a: 1, b: 2 }).to include(:a) }
      in_case { attest({ a: 1, b: 2 }).to include(a: 1) }
      assert_fails { in_case { attest({ a: 1 }).to include(a: 2) } }
    end

    def test_include_failure_names_what_is_missing
      error = assert_fails { in_case { attest([1, 2]).to include(3, 4) } }
      assert_equal "expected [1, 2] to include 3, 4, but 3, 4 are missing", error.message
    end

    def test_include_on_something_without_include
      error = assert_fails { in_case { attest(42).to include(1) } }
      assert_includes error.message, "has no #include?"
    end

    def test_include_negated
      in_case { attest([1, 2]).not_to include(3) }
      error = assert_fails { in_case { attest([1, 2]).not_to include(1) } }
      assert_equal "expected [1, 2] not to include 1", error.message
    end

    # -- match -------------------------------------------------------------------------

    def test_match
      in_case { attest("hello").to match(/ell/) }
      in_case { attest("hello").not_to match(/nope/) }
      error = assert_fails { in_case { attest("hello").to match(/^world/) } }
      assert_equal 'expected "hello" to match /^world/', error.message
    end

    def test_match_against_a_non_string
      assert_fails { in_case { attest(42).to match(/4/) } }
    end

    # -- raise_error -------------------------------------------------------------------

    def test_raise_error_with_a_class
      in_case { attest { raise ArgumentError, "bad" }.to raise_error(ArgumentError) }
    end

    def test_raise_error_when_nothing_is_raised
      error = assert_fails { in_case { attest { 1 + 1 }.to raise_error(ArgumentError) } }
      assert_equal "expected the block to raise ArgumentError, but nothing was raised", error.message
    end

    def test_raise_error_when_a_different_error_is_raised
      error = assert_fails { in_case { attest { raise TypeError, "nope" }.to raise_error(ArgumentError) } }
      assert_includes error.message, "but it raised TypeError: nope"
      assert_equal({ "Raised" => "TypeError: nope" }, error.context)
    end

    def test_raise_error_with_a_message
      in_case { attest { raise ArgumentError, "too small" }.to raise_error(ArgumentError, /small/) }
      in_case { attest { raise ArgumentError, "too small" }.to raise_error(ArgumentError, "too small") }
      error = assert_fails do
        in_case { attest { raise ArgumentError, "too small" }.to raise_error(ArgumentError, /large/) }
      end
      assert_includes error.message, 'the message was "too small"'
    end

    def test_raise_error_negated
      in_case { attest { 1 + 1 }.not_to raise_error }
      error = assert_fails { in_case { attest { raise "boom" }.not_to raise_error } }
      assert_includes error.message, "not to raise error"
    end

    def test_raise_error_without_a_block_says_so
      error = assert_fails { in_case { attest(1).to raise_error(ArgumentError) } }
      assert_includes error.message, "needs the block form"
    end

    # -- have_attributes ---------------------------------------------------------------

    def test_have_attributes
      record = FakeRecord.new(email: "a@b.com", role: "admin")
      in_case { attest(record).to have_attributes(email: "a@b.com", role: "admin") }
    end

    def test_have_attributes_failure_names_expected_and_actual
      record = FakeRecord.new(email: "a@b.com")
      error = assert_fails { in_case { attest(record).to have_attributes(email: "z@z.com") } }
      assert_includes error.message, 'to have attributes email: "z@z.com"'
      assert_includes error.message, 'email: expected "z@z.com", got "a@b.com"'
      assert_includes error.context.fetch("Attributes"), "a@b.com"
    end

    def test_have_attributes_on_a_hash
      in_case { attest({ email: "a@b.com" }).to have_attributes(email: "a@b.com") }
    end

    def test_have_attributes_reports_a_missing_reader
      error = assert_fails { in_case { attest(Object.new).to have_attributes(email: "a@b.com") } }
      assert_includes error.message, "does not respond to #email"
    end

    # -- exist -------------------------------------------------------------------------

    def test_exist_on_a_model_class
      FakeModel.rows << { email: "a@b.com" }
      in_case { attest(FakeModel).to exist(email: "a@b.com") }
      in_case { attest(FakeModel).to exist }
    end

    def test_exist_failure_names_the_class_and_the_criteria
      error = assert_fails { in_case { attest(FakeModel).to exist(email: "a@b.com") } }
      assert_equal 'expected User to have a record matching email: "a@b.com", but none exists', error.message
      assert_equal({ "Rows in table" => "0" }, error.context)
    end

    def test_exist_on_a_filesystem_path
      path = write_file("present.txt", "hi")
      missing = File.join(tmp_root, "absent.txt")
      in_case { attest(path).to exist }
      in_case { attest(missing).not_to exist }
    end

    def test_exist_on_something_that_cannot_answer
      error = assert_fails { in_case { attest(42).to exist } }
      assert_includes error.message, "responds to neither #exists? nor #exist?"
    end

    # -- be_created / have_http_status / redirect_to -----------------------------------

    def test_be_created_on_a_response
      in_case { attest(FakeResponse.new(status: 201)).to be_created }
    end

    def test_be_created_failure_names_the_status_and_carries_the_body
      response = FakeResponse.new(status: 422, body: '{"errors":["Email has already been taken"]}')
      error = assert_fails { in_case { attest(response).to be_created } }
      assert_equal "expected response to be created (201), but got :unprocessable_entity (422)", error.message
      assert_includes error.context.fetch("Response body"), "Email has already been taken"
    end

    def test_have_http_status_by_symbol_and_integer
      response = FakeResponse.new(status: 201)
      in_case { attest(response).to have_http_status(:created) }
      in_case { attest(response).to have_http_status(201) }
      in_case { attest(response).to have_http_status(:success) }
      in_case { attest(response).not_to have_http_status(:ok) }
    end

    def test_have_http_status_groups
      in_case { attest(FakeResponse.new(status: 302)).to have_http_status(:redirect) }
      in_case { attest(FakeResponse.new(status: 404)).to have_http_status(:missing) }
      in_case { attest(FakeResponse.new(status: 500)).to have_http_status(:error) }
      in_case { attest(FakeResponse.new(status: 200)).not_to have_http_status(:redirect) }
    end

    def test_have_http_status_failure_names_both_statuses
      response = FakeResponse.new(status: 422, body: "boom")
      error = assert_fails { in_case { attest(response).to have_http_status(:created) } }
      assert_equal "expected response to have HTTP status :created (201), " \
                   "but got :unprocessable_entity (422)", error.message
      assert_equal({ "Response body" => "boom" }, error.context)
    end

    def test_have_http_status_rejects_an_unknown_status_name
      error = assert_fails { in_case { attest(FakeResponse.new(status: 200)).to have_http_status(:banana) } }
      assert_includes error.message, "does not know the status :banana"
    end

    def test_have_http_status_on_something_with_no_status
      error = assert_fails { in_case { attest("nope").to have_http_status(:ok) } }
      assert_includes error.message, "has no status"
    end

    def test_redirect_to
      response = FakeResponse.new(status: 302, headers: { "Location" => "/sessions/new" })
      in_case { attest(response).to redirect_to("/sessions/new") }
      in_case { attest(response).to redirect_to(%r{/sessions}) }
    end

    def test_redirect_to_ignores_scheme_and_host
      response = FakeResponse.new(status: 302, headers: { "Location" => "http://example.test/sessions/new" })
      in_case { attest(response).to redirect_to("/sessions/new") }
    end

    def test_redirect_to_failure_names_the_actual_location
      response = FakeResponse.new(status: 302, headers: { "Location" => "/dashboard" })
      error = assert_fails { in_case { attest(response).to redirect_to("/sessions/new") } }
      assert_equal 'expected response to redirect to "/sessions/new", but it redirected to "/dashboard"', error.message
    end

    def test_redirect_to_when_there_was_no_redirect_at_all
      response = FakeResponse.new(status: 200, body: "hello")
      error = assert_fails { in_case { attest(response).to redirect_to("/sessions/new") } }
      assert_includes error.message, "returned :ok (200) with no redirect"
      assert_equal({ "Response body" => "hello" }, error.context)
    end

    # -- be_a / be_nil / be_empty / be_truthy / be_falsey ------------------------------

    def test_be_a_and_aliases
      in_case { attest("x").to be_a(String) }
      in_case { attest("x").to be_an(Object) }
      in_case { attest("x").to be_kind_of(Comparable) }
      error = assert_fails { in_case { attest("x").to be_a(Integer) } }
      assert_equal 'expected "x" to be a Integer, but it is a String', error.message
    end

    def test_be_nil
      in_case { attest(nil).to be_nil }
      error = assert_fails { in_case { attest("x").to be_nil } }
      assert_equal 'expected nil, but got "x" (String)', error.message
    end

    def test_be_empty
      in_case { attest([]).to be_empty }
      in_case { attest("").to be_empty }
      error = assert_fails { in_case { attest([1, 2]).to be_empty } }
      assert_equal "expected [1, 2] to be empty, but it is not (2 entries)", error.message
      assert_includes assert_fails { in_case { attest(42).to be_empty } }.message, "has no #empty?"
    end

    def test_be_truthy_and_be_falsey
      in_case { attest("x").to be_truthy }
      in_case { attest(nil).to be_falsey }
      in_case { attest(false).to be_falsey }
      assert_equal "expected a truthy value, but got nil",
                   assert_fails { in_case { attest(nil).to be_truthy } }.message
      assert_equal 'expected a falsey value, but got "x"',
                   assert_fails { in_case { attest("x").to be_falsey } }.message
    end

    # -- change ------------------------------------------------------------------------
    #
    # `attest { ... }.to change { ... }` is the documented syntax, and the trailing block
    # binds to `change` exactly as intended -- which is the thing the cop below warns about.
    # rubocop:disable Lint/AmbiguousBlockAssociation

    def test_change_detects_any_change
      counter = 0
      in_case { attest { counter += 1 }.to change { counter } }
    end

    def test_change_failure_names_the_watched_expression
      counter = 0
      error = assert_fails { in_case { attest { counter }.to change { counter } } }
      assert_includes error.message, "expected the block to change `counter`"
      assert_includes error.message, "stayed at 0"
    end

    def test_change_by
      counter = 0
      in_case { attest { counter += 2 }.to change { counter }.by(2) }
      error = assert_fails { in_case { attest { counter += 1 }.to change { counter }.by(5) } }
      assert_includes error.message, "change `counter` by 5"
      assert_includes error.message, "changed by 1 (2 to 3)"
    end

    def test_change_from_and_to
      state = "pending"
      in_case { attest { state = "shipped" }.to change { state }.from("pending").to("shipped") }
    end

    def test_change_from_mismatch_is_reported_specifically
      state = "shipped"
      error = assert_fails { in_case { attest { state = "delivered" }.to change { state }.from("pending") } }
      assert_includes error.message, 'started at "shipped", not "pending"'
    end

    def test_change_to_mismatch_is_reported_specifically
      state = "pending"
      error = assert_fails { in_case { attest { state = "cancelled" }.to change { state }.to("shipped") } }
      assert_includes error.message, 'went from "pending" to "cancelled"'
    end

    def test_change_watches_a_receiver_and_message_too
      list = []
      in_case { attest { list << 1 }.to change(list, :size).by(1) }
    end

    def test_change_negated
      counter = 0
      in_case { attest { counter }.not_to change { counter } }
      error = assert_fails { in_case { attest { counter += 1 }.not_to change { counter } } }
      assert_includes error.message, "expected the block not to change `counter`"
      assert_includes error.message, "changed from 0 to 1"
    end

    def test_change_on_a_mutable_object_compares_snapshots_not_identity
      list = []
      in_case { attest { list << 1 }.to change { list }.from([]).to([1]) }
    end

    def test_change_without_the_block_form_says_so
      counter = 0
      error = assert_raises(Constable::Error) { in_case { attest(counter).to change { counter } } }
      assert_includes error.message, "needs the block form"
    end
    # rubocop:enable Lint/AmbiguousBlockAssociation

    # -- context -----------------------------------------------------------------------

    def test_context_gathers_response_body_attributes_and_errors
      record = FakeRecord.new(email: "a@b.com")
      def record.errors = Struct.new(:full_messages).new(["Email has already been taken"])

      error = assert_fails { in_case { attest(record).to have_attributes(email: "z@z.com") } }
      assert_includes error.context.fetch("Attributes"), "a@b.com"
      assert_equal "Email has already been taken", error.context.fetch("Errors")
    end

    def test_context_is_nil_when_there_is_nothing_worth_showing
      assert_nil assert_fails { in_case { attest(1).to eq(2) } }.context
    end

    def test_context_survives_an_object_that_raises_from_its_own_readers
      exploding = Object.new
      def exploding.body = raise("kaboom")
      def exploding.created? = false

      error = assert_fails { in_case { attest(exploding).to be_created } }
      assert_includes error.message, "to be created"
    end

    def test_a_negated_failure_still_carries_context
      response = FakeResponse.new(status: 201, body: '{"id":1}')
      error = assert_fails { in_case { attest(response).not_to be_created } }
      assert_equal "expected response not to be created", error.message
      assert_equal({ "Response body" => '{"id":1}' }, error.context)
    end

    private

    # Runs the block with `self` set to the bare Expectations host, so the assertions read
    # exactly as they would inside an investigate block -- bare `be_created` and all.
    def in_case(&)
      @subject.instance_exec(&)
    end

    def assert_fails(&)
      assert_raises(Constable::AssertionFailed, &)
    end
  end
end
