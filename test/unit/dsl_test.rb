# frozen_string_literal: true

require "helper"

# The shared harness touches Constable.registry, which component A owns. Until that file
# lands, stand in for it so this suite can run on its own.
begin
  require "constable/registry"
rescue LoadError
  module Constable
    class Registry
      def clear; end
    end
  end
end

require "constable/dsl"
require "net/http"

module Constable
  # Constable::DSL is a plain module, so it is tested the way it is used: mixed into an
  # object. Deliberately *not* Constable::Case -- that is someone else's file.
  class DSLHost
    include Constable::DSL
  end

  class DSLTest < Constable::TestCase
    # Constable's own suite runs every test file in one process, so whether ActiveSupport
    # happens to be loaded is not ours to assume. In-process tests pin the standalone
    # machine; the ActiveSupport delegation is exercised in a clean subprocess below.
    def setup
      super
      Constable::DSL.time_strategy = :standalone
      Constable::DSL.clear_unsafe!
      Constable::DSL::NetworkGuard.disable!
      @host = DSLHost.new
    end

    def teardown
      @host&._constable_dsl_teardown
      Constable::DSL.time_strategy = :auto
      Constable::DSL.clear_unsafe!
      Constable::DSL::NetworkGuard.disable!
      super
    end

    def frozen_at
      Time.at(1_700_000_000)
    end

    # ----------------------------------------------------------------------------
    # Time
    # ----------------------------------------------------------------------------

    def test_freeze_time_with_a_block_stops_the_clock_for_the_block_only
      before = Time.now
      seen   = []

      @host.freeze_time(frozen_at) do
        seen << Time.now
        seen << Time.now
      end

      assert_equal frozen_at.to_i, seen[0].to_i
      assert_equal seen[0], seen[1], "the clock moved inside freeze_time"
      assert Time.now >= before, "the real clock did not come back"
      refute_equal frozen_at.to_i, Time.now.to_i
    end

    def test_freeze_time_freezes_date_and_datetime_too
      @host.freeze_time(frozen_at) do
        assert_equal frozen_at.to_i, Time.now.to_i
        assert_equal Date.new(frozen_at.year, frozen_at.month, frozen_at.day), Date.today
        assert_equal frozen_at.year, DateTime.now.year
        assert_equal frozen_at.hour, DateTime.now.hour
      end
    end

    def test_freeze_time_without_a_block_lasts_until_teardown
      @host.freeze_time(frozen_at)
      first = Time.now
      assert_equal frozen_at.to_i, first.to_i
      assert @host.time_frozen?

      @host._constable_dsl_teardown

      refute @host.time_frozen?
      refute_equal frozen_at.to_i, Time.now.to_i
    end

    def test_freeze_time_defaults_to_now
      @host.freeze_time
      pinned = Time.now
      assert_equal pinned.to_i, Time.now.to_i
      assert_equal pinned.to_i, Time.now.to_i
    end

    def test_travel_to_and_travel_back
      @host.travel_to(frozen_at)
      assert_equal frozen_at.to_i, Time.now.to_i

      @host.travel_back

      refute_equal frozen_at.to_i, Time.now.to_i
      refute @host.time_frozen?
    end

    def test_travel_back_is_safe_when_time_was_never_frozen
      assert_nil @host.travel_back
    end

    def test_travel_to_accepts_a_string_and_epoch_seconds
      @host.travel_to("2020-01-02 03:04:05") do
        assert_equal 2020, Time.now.year
        assert_equal 1, Time.now.month
        assert_equal 2, Time.now.day
      end

      @host.travel_to(1_700_000_000) do
        assert_equal 1_700_000_000, Time.now.to_i
      end
    end

    def test_travel_to_rejects_something_it_cannot_read_as_a_time
      error = assert_raises(Constable::Error) { @host.travel_to(Object.new) }
      assert_match(/Cannot travel to/, error.message)
    end

    def test_standalone_machine_restores_the_original_singleton_methods
      @host.freeze_time(frozen_at) { assert_equal frozen_at.to_i, Time.now.to_i }

      # The singleton methods must come back where they were, still owned by Time/Date
      # themselves -- not left behind as a Constable-shaped hole.
      assert Time.singleton_class.method_defined?(:now, false)
      assert Date.singleton_class.method_defined?(:today, false)
      assert DateTime.singleton_class.method_defined?(:now, false)
      assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME), Time.now.to_f, 5
      assert_equal Time.now.year, Date.today.year
    end

    def test_standalone_machine_freezes_without_activesupport
      refute Constable::DSL.activesupport_time_helpers?, "strategy pinning did not take"
      assert_instance_of Constable::DSL::StandaloneMachine, Constable::DSL::TimeMachine.build

      @host.freeze_time(frozen_at) do
        assert_equal frozen_at.to_i, Time.now.to_i
        assert_equal frozen_at.to_i, Time.now.to_i
        assert_equal Date.new(frozen_at.year, frozen_at.month, frozen_at.day), Date.today
        assert_equal frozen_at.min, DateTime.now.min
      end

      refute_equal frozen_at.to_i, Time.now.to_i
    end

    def test_standalone_machine_supports_nested_travel
      outer = Time.at(1_600_000_000)
      inner = Time.at(1_700_000_000)

      @host.travel_to(outer) do
        assert_equal outer.to_i, Time.now.to_i
        @host.travel_to(inner) do
          assert_equal inner.to_i, Time.now.to_i
        end
        assert_equal outer.to_i, Time.now.to_i
      end

      refute @host.time_frozen?
    end

    # Run in a clean subprocess: loading ActiveSupport into this one would change the
    # ground under every other component's tests.
    def test_delegates_to_activesupport_when_its_time_helpers_are_loaded
      skip "ActiveSupport not installed" unless activesupport_available?

      script = write_file("as_time.rb", <<~RUBY)
        require "active_support"
        require "active_support/time"
        require "active_support/testing/time_helpers"
        require "constable"
        require "constable/dsl"

        class Host
          include Constable::DSL
        end

        def check(label) = (raise "FAILED: \#{label}" unless yield)

        host = Host.new
        pinned = Time.at(1_700_000_000)

        check("picks the ActiveSupport machine") { Constable::DSL::TimeMachine.build.is_a?(Constable::DSL::ActiveSupportMachine) }

        host.freeze_time(pinned) do
          check("Time.now frozen")     { Time.now.to_i == pinned.to_i }
          check("Time.current frozen") { Time.current.to_i == pinned.to_i }
          check("Date.today frozen")   { Date.today == pinned.to_date }
          check("DateTime.now frozen") { DateTime.now.hour == pinned.hour }
        end
        check("block form restored the clock") { Time.now.to_i != pinned.to_i }

        host.freeze_time(pinned)
        check("blockless freeze holds") { Time.now.to_i == pinned.to_i }
        host._constable_dsl_teardown
        check("teardown unfroze the clock") { Time.now.to_i != pinned.to_i }

        puts "ALL GOOD"
      RUBY

      output = `#{RbConfig.ruby} -I#{gem_lib_path} #{script} 2>&1`
      assert_match(/ALL GOOD/, output, output)
    end

    # ----------------------------------------------------------------------------
    # Network
    # ----------------------------------------------------------------------------

    def test_stub_network_raises_on_a_real_connection_attempt
      @host.stub_network!

      error = assert_raises(Constable::Error) do
        Net::HTTP.get(URI("http://constable.invalid/beat"))
      end

      assert_match(/constable\.invalid/, error.message)
      assert_match(/stub_network!/, error.message)
      assert_match(/unsafe/, error.message)
    end

    def test_stub_network_blocks_a_direct_request_too
      @host.stub_network!
      http = Net::HTTP.new("constable.invalid", 80)

      error = assert_raises(Constable::Error) { http.request(Net::HTTP::Get.new("/")) }
      assert_match(/constable\.invalid:80/, error.message)
    end

    def test_stub_network_is_idempotent
      assert @host.stub_network!
      assert @host.stub_network!
      assert @host.network_stubbed?

      assert_raises(Constable::Error) { Net::HTTP.get(URI("http://constable.invalid/")) }
    end

    def test_stub_network_is_lifted_at_teardown
      @host.stub_network!
      @host._constable_dsl_teardown

      refute @host.network_stubbed?
      refute Constable::DSL::NetworkGuard.blocking?
    end

    # Also a subprocess: WebMock patches Net::HTTP process-wide the moment it loads.
    def test_hands_the_job_to_webmock_when_webmock_is_loaded
      skip "WebMock not installed" unless library_available?("webmock")

      script = write_file("webmock_guard.rb", <<~RUBY)
        require "webmock"
        require "constable"
        require "constable/dsl"

        class Host
          include Constable::DSL
        end

        def check(label) = (raise "FAILED: \#{label}" unless yield)

        host = Host.new
        host.stub_network!

        check("did not fight WebMock for Net::HTTP") { !Net::HTTP.ancestors.include?(Constable::DSL::NetHTTPGuard) }
        check("WebMock is doing the blocking") do
          begin
            Net::HTTP.get(URI("http://constable.invalid/"))
            false
          rescue WebMock::NetConnectNotAllowedError
            true
          end
        end

        host._constable_dsl_teardown
        check("guard lifted at teardown") { !Constable::DSL::NetworkGuard.enabled? }

        puts "ALL GOOD"
      RUBY

      output = `#{RbConfig.ruby} -I#{gem_lib_path} #{script} 2>&1`
      assert_match(/ALL GOOD/, output, output)
    end

    def test_network_guard_stands_aside_inside_unsafe
      @host.stub_network!

      silence_warnings do
        @host.unsafe("deliberately reaching out") do
          refute Constable::DSL::NetworkGuard.blocking?
        end
      end

      assert Constable::DSL::NetworkGuard.blocking?
    end

    # ----------------------------------------------------------------------------
    # wait_for
    # ----------------------------------------------------------------------------

    def test_wait_for_outside_unsafe_refuses_and_explains_why
      error = assert_raises(Constable::Error) { @host.wait_for { true } }

      assert_match(/wait_for outside an `unsafe` block/, error.message)
      assert_match(/eliminate/, error.message)
      assert_match(/unsafe \{ wait_for/, error.message)
    end

    def test_wait_for_inside_unsafe_returns_the_first_truthy_value
      attempts = 0

      value = silence_warnings do
        @host.unsafe("polling a genuinely async thing") do
          @host.wait_for(timeout: 1, interval: 0.001) do
            attempts += 1
            attempts >= 3 ? :ready : false
          end
        end
      end

      assert_equal :ready, value
      assert_equal 3, attempts
    end

    def test_wait_for_gives_up_at_the_timeout
      error = nil

      silence_warnings do
        @host.unsafe("bounded poll") do
          error = assert_raises(Constable::Error) do
            @host.wait_for(timeout: 0.05, interval: 0.001) { false }
          end
        end
      end

      assert_match(/wait_for gave up after 0.05s/, error.message)
      assert_match(/never returned a truthy value/, error.message)
    end

    def test_wait_for_reports_the_last_error_it_swallowed
      error = nil

      silence_warnings do
        @host.unsafe("bounded poll") do
          error = assert_raises(Constable::Error) do
            @host.wait_for(timeout: 0.05, interval: 0.001) { raise ArgumentError, "not yet" }
          end
        end
      end

      assert_match(/last error was ArgumentError: not yet/, error.message)
    end

    # ----------------------------------------------------------------------------
    # unsafe
    # ----------------------------------------------------------------------------

    def test_unsafe_always_warns_with_the_call_sites_file_and_line
      line = __LINE__ + 1
      result = @host.unsafe("a stated reason") { :done }

      assert_equal :done, result
      assert_equal 1, Constable.warnings.size
      warning = Constable.warnings.first
      assert_equal :unsafe, warning[:kind]
      assert warning[:location].end_with?("dsl_test.rb:#{line}"), warning[:location].to_s
      assert_match(/"a stated reason"/, warning[:message])
    end

    def test_unsafe_reads_the_adjacent_trailing_comment_as_its_reason
      @host.unsafe { :done } # testing an actual timeout path, not a code smell

      warning = Constable.warnings.first
      assert_equal %(@host.unsafe { :done } — "testing an actual timeout path, not a code smell"),
                   warning[:message]
    end

    def test_unsafe_falls_back_to_a_whole_line_comment_directly_above
      # the queue drains on a real thread here
      @host.unsafe { :done }

      assert_match(/"the queue drains on a real thread here"/, Constable.warnings.first[:message])
    end

    def test_unsafe_says_so_loudly_when_no_reason_is_given
      @host.unsafe { :done }

      assert_match(/no reason given/, Constable.warnings.first[:message])
    end

    def test_an_explicit_reason_beats_the_comment
      @host.unsafe("the explicit one") { :done } # the comment one

      assert_match(/"the explicit one"/, Constable.warnings.first[:message])
    end

    def test_unsafe_warns_once_per_occurrence
      3.times { @host.unsafe("repeated") { :done } }

      assert_equal 3, Constable.warnings.size
    end

    def test_unsafe_sets_observable_state_only_inside_the_block
      refute Constable::DSL.unsafe?

      silence_warnings do
        @host.unsafe("visible state") do
          assert Constable::DSL.unsafe?
          assert @host.unsafe?
          assert_equal "visible state", Constable::DSL.unsafe_reason
          assert Constable::DSL.unsafe_location.to_s.include?("dsl_test.rb")
        end
      end

      refute Constable::DSL.unsafe?
      assert_nil Constable::DSL.unsafe_reason
    end

    def test_unsafe_state_is_cleared_even_when_the_block_raises
      silence_warnings do
        assert_raises(RuntimeError) do
          @host.unsafe("boom") { raise "boom" }
        end
      end

      refute Constable::DSL.unsafe?
    end

    def test_unsafe_nests
      silence_warnings do
        @host.unsafe("outer") do
          @host.unsafe("inner") do
            assert_equal "inner", Constable::DSL.unsafe_reason
          end
          assert_equal "outer", Constable::DSL.unsafe_reason
        end
      end

      refute Constable::DSL.unsafe?
    end

    def test_unsafe_requires_a_block
      assert_raises(Constable::Error) { @host.unsafe("no block") }
    end

    def test_teardown_clears_a_leaked_unsafe_state
      Constable::DSL.unsafe_stack.push(reason: "leaked", location: "x:1")
      @host._constable_dsl_teardown

      refute Constable::DSL.unsafe?
    end

    # ----------------------------------------------------------------------------
    # sleep guard
    # ----------------------------------------------------------------------------

    def test_bare_sleep_is_refused
      error = assert_raises(Constable::Error) { @host.sleep(0.01) }

      assert_match(/Bare sleep in a native case/, error.message)
      assert_match(/unsafe \{ sleep\(0.01\) \}/, error.message)
    end

    def test_sleep_is_allowed_inside_unsafe
      elapsed = nil

      silence_warnings do
        @host.unsafe("real elapsed time under test") do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @host.sleep(0.01)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
      end

      assert elapsed >= 0.005, "sleep did not actually sleep (#{elapsed})"
    end

    # ----------------------------------------------------------------------------
    # Assertion primitives
    # ----------------------------------------------------------------------------

    def test_assertion_count_tracks_every_primitive
      assert_equal 0, @host.assertion_count
      @host.assert(true)
      @host.assert_equal(1, 1)
      @host.refute(false)
      assert_equal 3, @host.assertion_count
      assert_equal 3, @host._constable_assertion_count
    end

    def test_assert_passes_and_fails_specifically
      assert @host.assert("truthy")

      error = failure { @host.assert(nil) }
      assert_equal "Expected a truthy value, got nil.", error.message
    end

    def test_refute_passes_and_fails_specifically
      assert @host.refute(nil)

      error = failure { @host.refute("present") }
      assert_equal %(Expected a falsey value, got "present".), error.message
    end

    def test_assert_equal_names_both_sides
      assert @host.assert_equal(2, 1 + 1)

      error = failure { @host.assert_equal("expected", "actual") }
      assert_equal %(Expected "expected", got "actual".), error.message
    end

    def test_assert_equal_attaches_context_when_the_values_are_big
      long = "x" * 90
      error = failure { @host.assert_equal(long, "#{long}!") }

      assert_match(/expected: /, error.context)
      assert_match(/actual: /, error.context)
    end

    def test_assert_equal_accepts_a_custom_message
      error = failure { @host.assert_equal(1, 2, "the ledger did not balance") }
      assert_equal "the ledger did not balance", error.message
    end

    def test_assert_nil
      assert @host.assert_nil(nil)

      error = failure { @host.assert_nil(:something) }
      assert_equal "Expected nil, got :something.", error.message
    end

    def test_refute_nil
      assert @host.refute_nil(:something)

      error = failure { @host.refute_nil(nil) }
      assert_equal "Expected a value, got nil.", error.message
    end

    def test_assert_empty
      assert @host.assert_empty([])

      error = failure { @host.assert_empty([1, 2]) }
      assert_equal "Expected [1, 2] to be empty, but it holds 2 entries.", error.message
      assert_equal "[1, 2]", error.context

      one = failure { @host.assert_empty([1]) }
      assert_match(/1 entry/, one.message)

      no_predicate = failure { @host.assert_empty(Object.new) }
      assert_match(/has no #empty\?/, no_predicate.message)
    end

    def test_assert_includes
      assert @host.assert_includes([1, 2], 2)

      error = failure { @host.assert_includes([1, 2], 3) }
      assert_equal "Expected [1, 2] to include 3, and it does not.", error.message
      assert_equal "[1, 2]", error.context
    end

    def test_refute_includes
      assert @host.refute_includes([1, 2], 3)

      error = failure { @host.refute_includes([1, 2], 2) }
      assert_equal "Expected [1, 2] not to include 2, but it does.", error.message
    end

    def test_assert_raises_returns_the_exception
      raised = @host.assert_raises(ArgumentError) { raise ArgumentError, "bad witness" }

      assert_instance_of ArgumentError, raised
      assert_equal "bad witness", raised.message
    end

    def test_assert_raises_accepts_several_classes
      raised = @host.assert_raises(TypeError, ArgumentError) { raise TypeError, "wrong shape" }
      assert_instance_of TypeError, raised
    end

    def test_assert_raises_fails_when_nothing_is_raised
      error = failure { @host.assert_raises(ArgumentError) { :quiet } }
      assert_equal "Expected ArgumentError to be raised, but the block completed without raising.", error.message
    end

    def test_assert_raises_fails_specifically_on_the_wrong_class
      error = failure { @host.assert_raises(ArgumentError) { raise TypeError, "wrong shape" } }
      assert_equal "Expected ArgumentError to be raised, got TypeError: wrong shape", error.message
      refute_nil error.context
    end

    def test_assert_raises_lets_an_inner_assertion_failure_through
      error = assert_raises(Constable::AssertionFailed) do
        @host.assert_raises(StandardError) { @host.assert_equal(1, 2) }
      end

      assert_equal "Expected 1, got 2.", error.message
    end

    def test_assert_predicate
      assert @host.assert_predicate([], :empty?)

      error = failure { @host.assert_predicate([1], :empty?) }
      assert_equal "Expected [1] to be empty?, but #empty? returned false.", error.message

      missing = failure { @host.assert_predicate(Object.new, :nonexistent?) }
      assert_match(/does not respond to it/, missing.message)
    end

    def test_refute_predicate
      assert @host.refute_predicate([1], :empty?)

      error = failure { @host.refute_predicate([], :empty?) }
      assert_equal "Expected [] not to be empty?, but #empty? returned true.", error.message
    end

    def test_assert_match_with_a_regexp_and_a_string
      assert @host.assert_match(/beat/, "walking the beat")
      assert @host.assert_match("beat", "walking the beat")

      error = failure { @host.assert_match(/warrant/, "walking the beat") }
      assert_equal %(Expected "walking the beat" to match /warrant/, and it does not.), error.message
      assert_equal %("walking the beat"), error.context
    end

    def test_refute_match
      assert @host.refute_match(/warrant/, "walking the beat")

      error = failure { @host.refute_match(/beat/, "walking the beat") }
      assert_match(/not to match/, error.message)
    end

    def test_assert_difference_with_a_string_expression
      counter = Counter.new

      returned = @host.assert_difference("counter.value", 2) do
        counter.value += 2
        :block_result
      end

      assert_equal :block_result, returned
    end

    def test_assert_difference_with_a_callable
      counter = Counter.new

      @host.assert_difference(-> { counter.value }) { counter.value += 1 }
    end

    def test_assert_difference_with_several_expressions
      counter = Counter.new
      other   = Counter.new

      @host.assert_difference(["counter.value", "other.value"], 1) do
        counter.value += 1
        other.value += 1
      end
    end

    def test_assert_difference_failure_names_the_expression_and_both_values
      counter = Counter.new

      error = failure { @host.assert_difference("counter.value", 1) { counter.value += 5 } }
      assert_equal %(Expected "counter.value" to change by 1, but it changed by 5 (0 → 5).), error.message
    end

    def test_assert_no_difference
      counter = Counter.new
      @host.assert_no_difference("counter.value") { counter.value }

      error = failure { @host.assert_no_difference("counter.value") { counter.value += 3 } }
      assert_equal %(Expected "counter.value" not to change, but it changed by 3 (0 → 3).), error.message
    end

    def test_difference_helpers_require_a_block
      assert_raises(Constable::Error) { @host.assert_difference("1") }
      assert_raises(Constable::Error) { @host.assert_no_difference("1") }
    end

    # ----------------------------------------------------------------------------
    # Teardown contract
    # ----------------------------------------------------------------------------

    def test_teardown_is_idempotent_and_returns_nil
      @host.freeze_time(frozen_at)
      @host.stub_network!

      assert_nil @host._constable_dsl_teardown
      assert_nil @host._constable_dsl_teardown
      refute @host.time_frozen?
      refute @host.network_stubbed?
    end

    private

    class Counter
      attr_accessor :value

      def initialize = @value = 0
    end

    # Runs the block and returns the AssertionFailed it should have raised.
    def failure(&)
      error = assert_raises(Constable::AssertionFailed, &)
      refute_nil error.message
      error
    end

    def gem_lib_path
      File.expand_path("../../lib", __dir__)
    end

    # Asked in a subprocess so this one stays free of whatever it is asking about.
    def activesupport_available?
      library_available?("active_support")
    end

    def library_available?(name)
      system(RbConfig.ruby, "-e", "require #{name.inspect}", out: File::NULL, err: File::NULL)
    end
  end
end
