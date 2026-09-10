# frozen_string_literal: true

require "helper"
require "English"

module Constable
  # Cold cases are the adoption story, so these tests are deliberately end-to-end: real
  # fixture files, the real RSpec and Minitest engines, real Constable::Results.
  #
  # Note what this file is doing when it exercises the Minitest adapter -- it runs
  # Minitest inside Minitest. The inner run must not touch the outer one's runnable
  # registry, reporter or exit status, which is exactly the isolation the adapter
  # promises a real Constable run. If that isolation were wrong, this file would fail
  # loudly (or, worse, silently double-count), so the awkwardness is the point.
  class ColdCaseTest < TestCase
    # ------------------------------------------------------------------ fixtures

    RSPEC_PLAIN = <<~SPEC
      describe "Arithmetic" do
        it "adds" do
          expect(1 + 1).to eq(2)
        end

        it "subtracts wrongly" do
          expect(3 - 1).to eq(5)
        end

        it "is not done yet" do
          pending("waiting on the API")
          raise "not implemented"
        end

        context "with negatives" do
          it "negates" do
            expect(-1).to be < 0
          end
        end
      end
    SPEC

    MINITEST_PLAIN = <<~TEST
      class ColdArithmeticTest < Minitest::Test
        def test_adds
          assert_equal 2, 1 + 1
        end

        def test_subtracts_wrongly
          assert_equal 5, 3 - 1
        end

        def test_not_ready
          skip "not ready"
        end

        def test_explodes
          raise ArgumentError, "boom"
        end
      end
    TEST

    # A cold case that installs suite hooks the way webmock/rspec, VCR, DatabaseCleaner
    # and SimpleCov all do. Constable drives example groups directly rather than through
    # RSpec's Runner, so these hooks are the ones easiest to skip by accident -- and
    # skipping them fails open, which is how a stubbed spec ends up opening a real socket.
    RSPEC_SUITE_HOOKS = <<~SPEC
      RSpec.configure do |config|
        config.before(:suite) { Constable::ColdCaseTest.suite_events << :before_suite }
        config.after(:suite)  { Constable::ColdCaseTest.suite_events << :after_suite }
      end

      describe "Suite hooks" do
        it "runs with before(:suite) already fired" do
          expect(Constable::ColdCaseTest.suite_events).to include(:before_suite)
        end
      end
    SPEC

    RSPEC_SUITE_HOOKS_SECOND_FILE = <<~SPEC
      describe "A second file in the same session" do
        it "does not re-fire before(:suite)" do
          expect(Constable::ColdCaseTest.suite_events.count(:before_suite)).to eq(1)
        end
      end
    SPEC

    # The fixture specs below are loaded into a separate RSpec world, so they need a
    # named channel to report back through. A class-level array is that channel -- a
    # global would do the same job and trip the suite's own linter.
    class << self
      def suite_events = (@suite_events ||= [])
    end

    def setup
      super
      self.class.suite_events.clear
      ColdCase.reset_engines!
    end

    def teardown
      ColdCase.reset_engines!
      super
    end

    # ------------------------------------------------------------------ suite hooks

    def test_rspec_cold_case_fires_before_suite_hooks
      path = write_file("spec/suite_hooks_spec.rb", RSPEC_SUITE_HOOKS)

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal [:passed], results.map(&:status),
                   "before(:suite) never ran, so the example could not see its effect"
      assert_includes Constable::ColdCaseTest.suite_events, :before_suite
    ensure
      self.class.suite_events.clear
    end

    # "Suite" means the run, not the file. Firing them per file would re-run setup that
    # is meant to happen once, and tear it down while later files still need it.
    def test_rspec_cold_case_fires_before_suite_hooks_once_per_session
      first  = write_file("spec/suite_hooks_spec.rb", RSPEC_SUITE_HOOKS)
      second = write_file("spec/second_spec.rb", RSPEC_SUITE_HOOKS_SECOND_FILE)

      results = ColdCase.run_files([first, second], config: Constable.config)

      assert_equal %i[passed passed], results.map(&:status)
      assert_equal 1, Constable::ColdCaseTest.suite_events.count(:before_suite)
    ensure
      self.class.suite_events.clear
    end

    # after(:suite) belongs at the end of the session, not the end of a file -- otherwise
    # file one's teardown pulls the rug out from under file two.
    def test_rspec_cold_case_defers_after_suite_hooks_to_engine_reset
      path = write_file("spec/suite_hooks_spec.rb", RSPEC_SUITE_HOOKS)

      ColdCase.run_file(path, config: Constable.config)
      refute_includes Constable::ColdCaseTest.suite_events, :after_suite,
                      "after(:suite) must not fire while more files could still run"

      ColdCase.reset_engines!
      assert_equal 1, Constable::ColdCaseTest.suite_events.count(:after_suite)
    ensure
      self.class.suite_events.clear
    end

    # Nothing was set up, so there is nothing to tear down. A reset with no session must
    # not invent an after(:suite) run.
    def test_rspec_engine_reset_without_a_session_runs_no_after_suite_hooks
      ColdCase.reset_engines!

      assert_empty Constable::ColdCaseTest.suite_events
    ensure
      self.class.suite_events.clear
    end

    # ------------------------------------------------------------------ engine_for

    def test_engine_for_uses_filename_convention
      assert_equal :rspec, ColdCase.engine_for("spec/models/user_spec.rb")
      assert_equal :minitest, ColdCase.engine_for("test/models/user_test.rb")
    end

    def test_engine_for_prefers_an_explicit_cold_case_superclass
      # A .rb with no convention in its name, but the file says what it is.
      rspec_path = write_file("legacy/whatever.rb", <<~SPEC)
        class WhateverSpec < Constable::ColdCase::RSpec
        end
      SPEC
      minitest_path = write_file("legacy/other.rb", <<~TEST)
        class OtherThing < Constable::ColdCase::Minitest
        end
      TEST

      assert_equal :rspec, ColdCase.engine_for(rspec_path)
      assert_equal :minitest, ColdCase.engine_for(minitest_path)
    end

    def test_engine_for_sniffs_content_then_directory
      described = write_file("legacy/described.rb", "RSpec.describe \"thing\" do\nend\n")
      assert_equal :rspec, ColdCase.engine_for(described)

      methods = write_file("legacy/methods.rb", "class Foo\n  def test_thing; end\nend\n")
      assert_equal :minitest, ColdCase.engine_for(methods)

      assert_equal :rspec, ColdCase.engine_for("spec/support/thing.rb")
      assert_equal :minitest, ColdCase.engine_for("test/support/thing.rb")
      assert_nil ColdCase.engine_for("lib/thing.rb")
    end

    # ------------------------------------------------------------------ cold_case_files

    def test_cold_case_files_expands_config_globs
      write_file("spec/controllers/users_controller_spec.rb", RSPEC_PLAIN)
      write_file("spec/controllers/nested/sessions_controller_spec.rb", RSPEC_PLAIN)
      write_file("spec/models/user_spec.rb", RSPEC_PLAIN)
      config = link_cold_cases(:rspec, "spec/controllers/**/*_spec.rb")

      files = ColdCase.cold_case_files(config: config)

      assert_equal 2, files.size
      assert files.all? { |f| f.start_with?(tmp_root) }, "expected absolute paths, got #{files.inspect}"
      assert_equal files.sort, files, "expected a stable sorted order"
      refute(files.any? { |f| f.include?("models") })
    end

    def test_config_cold_case_predicate_and_files_agree
      write_file("spec/controllers/users_controller_spec.rb", RSPEC_PLAIN)
      config = link_cold_cases(:rspec, "spec/controllers/**/*_spec.rb")

      ColdCase.cold_case_files(config: config).each do |file|
        assert config.cold_case?(file), "#{file} should satisfy Config#cold_case?"
      end
    end

    # ------------------------------------------------------------------ RSpec, zero file changes

    def test_rspec_file_runs_untouched_and_produces_cold_results
      path = write_file("spec/arithmetic_spec.rb", RSPEC_PLAIN)

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal 4, results.size
      assert results.all?(&:cold?), "every cold-case result must report kind: :cold"
      refute results.any?(&:native?)

      by_description = results.to_h { |r| [r.description, r] }
      assert_equal :passed, by_description["Arithmetic adds"].status
      assert_equal :failed, by_description["Arithmetic subtracts wrongly"].status
      assert_equal :skipped, by_description["Arithmetic is not done yet"].status
      assert_equal :passed, by_description["Arithmetic with negatives negates"].status

      failure = by_description["Arithmetic subtracts wrongly"].failure
      refute_nil failure
      assert_match(/expected: 5/, failure.message)
      assert_match(/got: 2/, failure.message)
      assert_equal "RSpec::Expectations::ExpectationNotMetError", failure.exception_class
      assert failure.backtrace.any? { |line| line.include?("arithmetic_spec.rb") },
             "backtrace should point at the spec file, got #{failure.backtrace.inspect}"
    end

    def test_rspec_results_carry_identity_location_and_duration
      path = write_file("spec/arithmetic_spec.rb", RSPEC_PLAIN)

      results = ColdCase.run_file(path, config: Constable.config, seed: 8841)
      adds = results.find { |r| r.description == "Arithmetic adds" }

      assert_equal Identity.for_cold_case(path, "Arithmetic adds", root: tmp_root), adds.identity
      assert_equal "spec/arithmetic_spec.rb", adds.file
      assert_equal 2, adds.line
      assert_equal "Arithmetic", adds.case_name
      assert adds.duration.positive?, "expected a real duration, got #{adds.duration}"
      assert_equal 8841, adds.seed
      assert_equal "constable test spec/arithmetic_spec.rb:2 --only=cold --seed 8841", adds.rerun_command
    end

    def test_rspec_keeps_its_own_declaration_order
      path = write_file("spec/ordered_spec.rb", <<~SPEC)
        describe "Ordering" do
          it "one" do; end
          it "two" do; end
          it "three" do; end
          it "four" do; end
          it "five" do; end
        end
      SPEC

      descriptions = ColdCase.run_file(path, config: Constable.config).map(&:description)

      assert_equal ["Ordering one", "Ordering two", "Ordering three", "Ordering four", "Ordering five"],
                   descriptions,
                   "cold cases must keep their engine's order -- shuffling is a native-case rule"
    end

    # ------------------------------------------------------------------ RSpec, superclass swap

    def test_rspec_superclass_swap_runs_the_original_body_verbatim
      path = write_file("spec/legacy_users_spec.rb", <<~SPEC)
        class LegacyUsersSpec < Constable::ColdCase::RSpec
          describe "UsersController" do
            let(:answer) { 42 }
            before { @briefed = true }

            it "creates a user" do
              expect(answer).to eq(42)
              expect(@briefed).to be(true)
            end

            it "reports a failure like it always did" do
              expect(answer).to eq(0)
            end
          end
        end
      SPEC

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal 2, results.size
      # The class name wins as the case label -- the file's own describe still shapes
      # the description, so nothing about the report reads differently from before.
      assert_equal ["LegacyUsersSpec"], results.map(&:case_name).uniq
      assert_equal "UsersController creates a user", results[0].description
      assert_equal :passed, results[0].status
      assert_equal :failed, results[1].status
    end

    def test_rspec_superclass_swap_supports_a_body_with_no_describe
      path = write_file("spec/flat_spec.rb", <<~SPEC)
        class FlatColdSpec < Constable::ColdCase::RSpec
          let(:name) { "flat" }

          it "runs without a describe wrapper" do
            expect(name).to eq("flat")
          end
        end
      SPEC

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal 1, results.size
      assert_equal :passed, results.first.status
      assert_equal "FlatColdSpec runs without a describe wrapper", results.first.description
    end

    # ------------------------------------------------------------------ Minitest

    def test_minitest_file_runs_untouched_and_produces_cold_results
      path = write_file("test/arithmetic_test.rb", MINITEST_PLAIN)

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal 4, results.size
      assert results.all?(&:cold?)
      assert_equal ["ColdArithmeticTest"], results.map(&:case_name).uniq

      by_description = results.to_h { |r| [r.description, r] }
      assert_equal :passed, by_description["test_adds"].status
      assert_equal :failed, by_description["test_subtracts_wrongly"].status
      assert_equal :skipped, by_description["test_not_ready"].status
      assert_equal :errored, by_description["test_explodes"].status

      assert_match(/Expected: 5/, by_description["test_subtracts_wrongly"].failure.message)
      assert_equal "Minitest::Assertion", by_description["test_subtracts_wrongly"].failure.exception_class

      exploded = by_description["test_explodes"].failure
      assert_equal "ArgumentError", exploded.exception_class
      assert_match(/boom/, exploded.message)
    end

    def test_minitest_results_carry_identity_and_location
      path = write_file("test/arithmetic_test.rb", MINITEST_PLAIN)

      adds = ColdCase.run_file(path, config: Constable.config).find { |r| r.description == "test_adds" }

      assert_equal Identity.for_cold_case(path, "test_adds", root: tmp_root), adds.identity
      assert_equal "test/arithmetic_test.rb", adds.file
      assert_equal 2, adds.line
      assert_nil adds.failure
    end

    def test_minitest_superclass_swap_runs_the_original_body_verbatim
      path = write_file("test/swapped_test.rb", <<~TEST)
        class SwappedColdTest < Constable::ColdCase::Minitest
          def setup
            @greeting = "hello"
          end

          def test_uses_setup
            assert_equal "hello", @greeting
          end

          def test_still_fails_the_same_way
            assert_equal 1, 2
          end
        end
      TEST

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal 2, results.size
      assert_equal ["SwappedColdTest"], results.map(&:case_name).uniq
      assert_equal({ "test_uses_setup" => :passed, "test_still_fails_the_same_way" => :failed },
                   results.to_h { |r| [r.description, r.status] })
    end

    def test_minitest_spec_style_descriptions_drop_the_positional_ordinal
      path = write_file("test/spec_style_test.rb", <<~TEST)
        require "minitest/spec"

        describe "Coffee" do
          it "is hot" do
            assert true
          end
        end
      TEST

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal 1, results.size
      assert_equal "is hot", results.first.description,
                   "the test_NNNN_ ordinal is positional, so it must not be part of the identity"
    end

    # ------------------------------------------------------------------ warnings

    def test_emits_exactly_one_warning_per_rspec_file_with_the_real_count
      path = write_file("spec/arithmetic_spec.rb", RSPEC_PLAIN)

      ColdCase.run_file(path, config: Constable.config)

      warnings = Constable.warnings.select { |w| w[:kind] == :cold_case }
      assert_equal 1, warnings.size, "one warning per FILE, never per test"
      assert_equal "spec/arithmetic_spec.rb", warnings.first[:location]
      assert_equal "running as a cold case (Constable::ColdCase::RSpec) — 4 tests not yet under native rules",
                   warnings.first[:message]
    end

    def test_emits_exactly_one_warning_per_minitest_file_with_the_real_count
      path = write_file("test/arithmetic_test.rb", MINITEST_PLAIN)

      ColdCase.run_file(path, config: Constable.config)

      warnings = Constable.warnings.select { |w| w[:kind] == :cold_case }
      assert_equal 1, warnings.size
      assert_equal "test/arithmetic_test.rb", warnings.first[:location]
      assert_equal "running as a cold case (Constable::ColdCase::Minitest) — 4 tests not yet under native rules",
                   warnings.first[:message]
    end

    def test_warning_is_singular_for_a_single_example
      path = write_file("spec/one_spec.rb", "describe(\"One\") { it(\"is alone\") { expect(1).to eq(1) } }\n")

      ColdCase.run_file(path, config: Constable.config)

      assert_equal "running as a cold case (Constable::ColdCase::RSpec) — 1 test not yet under native rules",
                   Constable.warnings.first[:message]
    end

    def test_each_cold_case_file_gets_its_own_single_warning
      rspec_path    = write_file("spec/arithmetic_spec.rb", RSPEC_PLAIN)
      minitest_path = write_file("test/arithmetic_test.rb", MINITEST_PLAIN)

      ColdCase.run_files([rspec_path, minitest_path], config: Constable.config)

      warnings = Constable.warnings.select { |w| w[:kind] == :cold_case }
      assert_equal ["spec/arithmetic_spec.rb", "test/arithmetic_test.rb"], warnings.map { |w| w[:location] }.sort
    end

    # ------------------------------------------------------------------ zero-change adoption path

    def test_config_globs_run_files_that_were_never_touched
      write_file("spec/controllers/users_controller_spec.rb", RSPEC_PLAIN)
      original = File.read(File.join(tmp_root, "spec/controllers/users_controller_spec.rb"))
      config = link_cold_cases(:rspec, "spec/controllers/**/*_spec.rb")

      files   = ColdCase.cold_case_files(config: config)
      results = ColdCase.run_files(files, config: config)

      assert_equal 4, results.size
      assert results.all?(&:cold?)
      assert_equal original, File.read(File.join(tmp_root, "spec/controllers/users_controller_spec.rb")),
                   "the zero-file-change path must not rewrite a single byte"
      assert_equal(1, Constable.warnings.count { |w| w[:kind] == :cold_case })
    end

    def test_mixed_engines_in_one_config_glob_set
      write_file("legacy/users_spec.rb", RSPEC_PLAIN)
      write_file("legacy/users_test.rb", MINITEST_PLAIN)
      config = link_cold_cases(:rspec, "legacy/*.rb")

      results = ColdCase.run_files(ColdCase.cold_case_files(config: config), config: config)

      assert_equal 8, results.size
      assert_equal(2, Constable.warnings.count { |w| w[:kind] == :cold_case })
    end

    # ------------------------------------------------------------------ failure paths

    def test_a_file_that_cannot_be_loaded_becomes_one_errored_result
      path = write_file("spec/broken_spec.rb", "describe \"Broken\" do\n  it \"never closes\"\n")

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal 1, results.size
      assert_equal :errored, results.first.status
      assert results.first.cold?
      assert_equal "spec/broken_spec.rb", results.first.file
      refute_nil results.first.failure
    end

    def test_unclassifiable_file_raises_a_clear_error
      path = write_file("lib/mystery.rb", "puts 'nothing testy here'\n")

      error = assert_raises(Constable::Error) { ColdCase.run_file(path, config: Constable.config) }

      assert_match(%r{lib/mystery\.rb}, error.message)
      assert_match(/Constable::ColdCase::RSpec/, error.message)
    end

    # ------------------------------------------------------------------ missing engine

    def test_missing_engine_raises_an_actionable_error_pointing_at_the_gemfile_group
      path = write_file("spec/arithmetic_spec.rb", RSPEC_PLAIN)

      error = with_broken_require do
        assert_raises(ColdCase::EngineMissing) { ColdCase.run_file(path, config: Constable.config) }
      end

      assert_match(/need RSpec/, error.message)
      assert_match(%r{require "rspec/core"}, error.message)
      assert_match(/group :cold_case do/, error.message)
      assert_match(/gem "rspec-rails"/, error.message)
      assert_match(/gem "minitest"/, error.message)
      assert_match(/bundle install/, error.message)
    end

    def test_missing_minitest_message_names_minitest
      message = ColdCase.missing_engine_message(:minitest)

      assert_match(/need Minitest/, message)
      assert_match(/require "minitest"/, message)
      assert_match(/group :cold_case do/, message)
    end

    def test_engine_missing_is_a_constable_error
      assert_operator ColdCase::EngineMissing, :<, Constable::Error
    end

    def test_constable_loads_without_either_engine_installed
      # Nothing in the eager load path may reference RSpec or Minitest -- the :cold_case
      # group is optional, and an app with no cold cases must never need it.
      script = <<~RUBY
        $LOAD_PATH.unshift #{File.expand_path("../../lib", __dir__).inspect}
        require "constable"
        raise "RSpec leaked in"    if defined?(::RSpec)
        raise "Minitest leaked in" if defined?(::Minitest)
        Constable.config
        Constable::ColdCase.engine_for("spec/foo_spec.rb")
        puts "ok"
      RUBY
      output = IO.popen([RbConfig.ruby, "-e", script], err: %i[child out], &:read)

      assert_equal "ok", output.strip
    end

    # ------------------------------------------------------------------ engine isolation

    def test_running_an_rspec_cold_case_leaves_no_rspec_globals_behind
      path = write_file("spec/arithmetic_spec.rb", RSPEC_PLAIN)

      ColdCase.run_file(path, config: Constable.config)

      # A host with no RSpec state of its own -- Constable's own process, normally --
      # must end the run exactly as it started: nothing built, nothing registered.
      assert_nil ::RSpec.instance_variable_get(:@world)
      assert_nil ::RSpec.instance_variable_get(:@configuration)
    end

    def test_running_an_rspec_cold_case_restores_a_hosts_own_rspec_globals
      path = write_file("spec/arithmetic_spec.rb", RSPEC_PLAIN)
      ColdCase.run_file(path, config: Constable.config) # force rspec-core to be loaded

      host_config = ::RSpec::Core::Configuration.new
      host_world  = ::RSpec::Core::World.new(host_config)
      ::RSpec.instance_variable_set(:@configuration, host_config)
      ::RSpec.instance_variable_set(:@world, host_world)

      begin
        results = ColdCase.run_file(path, config: Constable.config)

        assert_equal 4, results.size
        assert_same host_world, ::RSpec.instance_variable_get(:@world)
        assert_same host_config, ::RSpec.instance_variable_get(:@configuration)
        assert_empty host_world.example_groups,
                     "a cold case must not register its groups in the host's world"
      ensure
        ::RSpec.instance_variable_set(:@world, nil)
        ::RSpec.instance_variable_set(:@configuration, nil)
      end
    end

    def test_rspec_groups_do_not_leak_from_one_cold_case_file_to_the_next
      first  = write_file("spec/first_spec.rb", "describe(\"First\") { it(\"a\") { } }\n")
      second = write_file("spec/second_spec.rb", "describe(\"Second\") { it(\"b\") { } }\n")

      ColdCase.run_file(first, config: Constable.config)
      results = ColdCase.run_file(second, config: Constable.config)

      assert_equal ["Second b"], results.map(&:description),
                   "the first file's groups must not re-run with the second's"
    end

    def test_running_a_minitest_cold_case_restores_the_runnable_registry
      path = write_file("test/arithmetic_test.rb", MINITEST_PLAIN)
      # Touch the adapter first so its own base class registers before we snapshot.
      ColdCase.adapter_for(:minitest)

      before = ::Minitest::Runnable.runnables.dup

      ColdCase.run_file(path, config: Constable.config)

      assert_equal before, ::Minitest::Runnable.runnables,
                   "a cold-case class must not stay in the registry -- it would run again at exit"
      refute(::Minitest::Runnable.runnables.any? { |k| k.to_s == "ColdArithmeticTest" })
    end

    def test_minitest_autorun_is_neutralised_so_nothing_runs_twice
      path = write_file("test/autorun_test.rb", <<~TEST)
        require "minitest/autorun"

        class AutorunColdTest < Minitest::Test
          def test_one
            assert true
          end
        end
      TEST

      results = ColdCase.run_file(path, config: Constable.config)

      assert_equal 1, results.size
      assert ::Minitest.class_variable_get(:@@installed_at_exit),
             "the at_exit autorun hook must be claimed, or the docket runs again at process exit"
      refute(::Minitest::Runnable.runnables.any? { |k| k.to_s == "AutorunColdTest" })
    end

    def test_the_outer_minitest_reporter_never_sees_inner_results
      path = write_file("test/arithmetic_test.rb", MINITEST_PLAIN)
      before = assertions

      results = ColdCase.run_file(path, config: Constable.config)
      leaked = assertions - before

      # The inner suite has a failure and an error in it. If either had reached the outer
      # reporter this test would already be red, and the inner assertions must be counted
      # against the inner instances, never against this one.
      assert_equal 0, leaked, "the inner Minitest run leaked #{leaked} assertions into the outer one"
      assert_equal 4, results.size
    end

    def test_neither_engine_writes_to_stdout
      spec = write_file("spec/arithmetic_spec.rb", RSPEC_PLAIN)
      test = write_file("test/arithmetic_test.rb", MINITEST_PLAIN)

      output = capture_stdout { ColdCase.run_files([spec, test], config: Constable.config) }

      assert_equal "", output,
                   "stdout belongs to Constable's reporter -- the engines must not print into it"
    end

    # Our own suite runs *inside* Minitest.run, which quietly sets Minitest.seed and has
    # already installed the autorun at_exit hook. A real `constable test` process has
    # neither, and both of those globals bite there and only there -- so this one has to
    # be a subprocess to mean anything.
    def test_a_fresh_constable_process_runs_cold_cases_of_both_engines
      write_file("spec/legacy_spec.rb", <<~SPEC)
        describe "Legacy" do
          it "passes" do
            expect(1).to eq(1)
          end
        end
      SPEC
      write_file("test/legacy_test.rb", <<~TEST)
        require "minitest/autorun"

        class FreshProcessColdTest < Minitest::Test
          def test_passes
            assert true
          end
        end
      TEST

      script = <<~RUBY
        $LOAD_PATH.unshift #{File.expand_path("../../lib", __dir__).inspect}
        require "constable"
        Constable.root = #{tmp_root.inspect}
        files = %w[spec/legacy_spec.rb test/legacy_test.rb].map { |f| File.join(Constable.root, f) }
        results = Constable::ColdCase.run_files(files, seed: 4242)
        puts results.map { |r| [r.case_name, r.description, r.status].join("|") }
        puts "warnings=" + Constable.warnings.size.to_s
        at_exit { puts "at_exit_ran_once" }
      RUBY
      output = IO.popen([RbConfig.ruby, "-e", script], err: %i[child out], &:read)
      status = $CHILD_STATUS

      assert_predicate status, :success?, "subprocess failed:\n#{output}"
      assert_includes output, "Legacy|Legacy passes|passed"
      assert_includes output, "FreshProcessColdTest|test_passes|passed"
      assert_includes output, "warnings=2"
      assert_equal 1, output.scan("at_exit_ran_once").size,
                   "Minitest's autorun hook must not fire a second run at process exit"
      refute_match(/1 runs|Finished in/, output, "no engine may print its own summary")
    end

    def test_running_the_same_file_twice_is_stable
      path = write_file("test/arithmetic_test.rb", MINITEST_PLAIN)

      first  = ColdCase.run_file(path, config: Constable.config)
      second = ColdCase.run_file(path, config: Constable.config)

      assert_equal first.map(&:identity).sort, second.map(&:identity).sort
      assert_equal first.map { |r| [r.description, r.status] }.sort,
                   second.map { |r| [r.description, r.status] }.sort
    end

    private

    # Makes `require` blow up the way a missing gem does, without uninstalling anything.
    def with_broken_require
      ColdCase.singleton_class.send(:define_method, :require) do |name|
        raise ::LoadError, "cannot load such file -- #{name}"
      end
      yield
    ensure
      ColdCase.singleton_class.send(:remove_method, :require)
    end
  end
end
