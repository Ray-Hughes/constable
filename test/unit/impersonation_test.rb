# frozen_string_literal: true

require_relative "../helper"

module Constable
  # Constable shipped no mocking library, which made `allow(x).to receive(:y)` the single
  # largest reason a file could not be converted. These are about whether the replacement
  # is honest: that it restores what it replaced, and that it refuses what rspec-mocks
  # would let you get away with.
  class ImpersonationTest < TestCase
    class Client
      def fetch(id, mode: :sync) = "real-#{id}-#{mode}"
      def close = :real_close
    end

    def setup
      super
      @client = Client.new
      @context = Object.new
      @context.extend(Constable::Impersonation)
      @context.extend(Constable::Matchers::Expectations)
    end

    def teardown
      @context.constable_restore_impersonations!
      super
    end

    def test_a_method_can_be_given_a_return_value
      @context.impersonate(@client, :fetch, returns: :stubbed)

      assert_equal :stubbed, @client.fetch(1)
    end

    def test_a_method_can_be_given_a_body
      @context.impersonate(@client, :fetch) { |id| "fake-#{id}" }

      assert_equal "fake-7", @client.fetch(7)
    end

    def test_a_method_can_be_made_to_raise
      @context.impersonate(@client, :fetch, raises: ArgumentError)

      assert_raises(ArgumentError) { @client.fetch(1) }
    end

    def test_an_impersonated_method_returns_nil_by_default
      @context.impersonate(@client, :fetch)

      assert_nil @client.fetch(1)
    end

    # The whole contract. A test that replaces a method and leaves it replaced is a test
    # that breaks a later, unrelated one -- and Constable owns teardown, so this never
    # depends on the author remembering.
    def test_the_original_comes_back
      @context.impersonate(@client, :fetch, returns: :stubbed)
      @context.constable_restore_impersonations!

      assert_equal "real-1-sync", @client.fetch(1)
    end

    def test_the_original_comes_back_for_a_class_method
      klass = Class.new { def self.build = :real }
      @context.impersonate(klass, :build, returns: :fake)

      assert_equal :fake, klass.build

      @context.constable_restore_impersonations!

      assert_equal :real, klass.build
    end

    # Impersonating twice must unwind to the original, not to the first impersonation.
    def test_impersonating_the_same_method_twice_still_restores_the_original
      @context.impersonate(@client, :fetch, returns: :first)
      @context.impersonate(@client, :fetch, returns: :second)

      assert_equal :second, @client.fetch(1)

      @context.constable_restore_impersonations!

      assert_equal "real-1-sync", @client.fetch(1)
    end

    # rspec calls this verify_partial_doubles and makes it optional. Here it is the
    # default: a stub of a method that does not exist passes forever and proves nothing,
    # which is exactly what a rename leaves behind.
    def test_impersonating_a_method_the_object_does_not_have_is_refused
      error = assert_raises(Constable::Error) { @context.impersonate(@client, :nope) }

      assert_match(/does not respond to :nope/, error.message)
      assert_match(/passes forever and proves nothing/, error.message)
    end

    def test_verification_can_be_waived
      @context.impersonate(@client, :defined_later, returns: :ok, allow_missing: true)

      assert_equal :ok, @client.defined_later
    end

    def test_calls_are_recorded
      @context.impersonate(@client, :fetch, returns: :ok)
      @client.fetch(1)
      @client.fetch(2, mode: :async)

      @context.attest(@client).to @context.have_been_asked(:fetch)
      @context.attest(@client).to @context.have_been_asked(:fetch).times(2)
    end

    def test_calls_can_be_matched_by_argument
      @context.impersonate(@client, :fetch, returns: :ok)
      @client.fetch(1)

      @context.attest(@client).to @context.have_been_asked(:fetch).with(1)
    end

    def test_never_is_expressible
      @context.impersonate(@client, :close, returns: :ok)

      @context.attest(@client).to @context.have_been_asked(:close).never
    end

    # "expected fetch to have been called" and nothing else is the least useful sentence
    # in testing, so the message says what actually arrived.
    def test_the_failure_says_what_the_method_actually_received
      @context.impersonate(@client, :fetch, returns: :ok)
      @client.fetch(99)

      error = assert_raises(Constable::AssertionFailed) do
        @context.attest(@client).to @context.have_been_asked(:fetch).with(1)
      end

      assert_match(/it received: \(99\)/, error.message)
    end

    def test_asking_about_an_object_that_was_never_impersonated_says_so
      error = assert_raises(Constable::AssertionFailed) do
        @context.attest(@client).to @context.have_been_asked(:fetch)
      end

      assert_match(/has no impersonated methods/, error.message)
    end

    def test_a_decoy_answers_what_it_was_told_to
      api = @context.decoy(:api, ping: :pong)

      assert_equal :pong, api.ping
      @context.attest(api).to @context.have_been_asked(:ping)
    end

    # A decoy stands for nothing, so there is no real method to verify against.
    def test_a_decoy_needs_no_verification
      api = @context.decoy(:api)
      @context.impersonate(api, :anything, returns: :ok)

      assert_equal :ok, api.anything
    end

    def test_any_instance_replaces_the_method_for_every_instance
      @context.impersonate_any(Client, :fetch, returns: :everyone)

      assert_equal :everyone, Client.new.fetch(1)
      assert_equal :everyone, Client.new.fetch(2)
    end

    def test_any_instance_restores_the_original
      @context.impersonate_any(Client, :fetch, returns: :everyone)
      @context.constable_restore_impersonations!

      assert_equal "real-1-sync", Client.new.fetch(1)
    end

    def test_any_instance_verifies_the_method_exists
      assert_raises(Constable::Error) { @context.impersonate_any(Client, :nope) }
    end

    # The ledger is attached to the object so the matcher can find it. An object that
    # outlives the test must not carry it away.
    def test_restoring_removes_the_ledger_from_the_object
      @context.impersonate(@client, :fetch, returns: :ok)

      assert_respond_to @client, :constable_ledger

      @context.constable_restore_impersonations!

      refute_respond_to @client, :constable_ledger
    end
  end
end
