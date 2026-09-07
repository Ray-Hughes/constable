# frozen_string_literal: true

require_relative "../helper"

module Constable
  # The bridge between a Constable::Case and Rails' own testing modules.
  #
  # These run against real Action Pack rather than a stand-in, because the whole point of
  # RailsSupport is that Rails' modules -- not an approximation of them -- are what a case
  # gets. A stubbed ActionDispatch would prove nothing about the contract that broke.
  class RailsSupportTest < TestCase
    # A route set and a rack app are all the request stack actually needs. No Rails
    # application is booted here, which keeps this test honest about what RailsSupport
    # requires: Action Pack, not an app.
    def self.test_app
      @test_app ||= begin
        routes = ::ActionDispatch::Routing::RouteSet.new
        routes.draw do
          get  "/widgets",     to: ->(_env) { [200, { "Content-Type" => "text/plain" }, ["listed"]] }, as: :widgets
          post "/widgets",     to: ->(_env) { [201, { "Content-Type" => "text/plain" }, ["made"]] }
          get  "/widgets/:id", to: ->(_env) { [200, { "Content-Type" => "text/plain" }, ["one"]] }, as: :widget
          get  "/moved",       to: ->(_env) { [302, { "Location" => "/widgets" }, []] }
        end

        Class.new do
          define_method(:routes) { routes }
          define_method(:call) { |env| routes.call(env) }
        end.new
      end
    end

    def setup
      super
      # Referencing the constant is what pulls Action Pack in -- the same lazy path a
      # case_helper takes.
      Constable::RailsSupport.integration_behavior
      ::ActionDispatch.test_app = self.class.test_app
    end

    def integration_case(&block)
      build_case("WidgetsCase") do
        include Constable::RailsSupport::Integration

        tier :integration
        class_eval(&block) if block
      end
    end

    # --- the request stack ----------------------------------------------------

    def test_an_integration_case_can_make_a_request_and_read_the_response
      klass = integration_case do
        investigate("gets") do
          get "/widgets"
          [response.status, response.body]
        end
      end

      assert_equal [200, "listed"], klass.run(klass.investigations.first)
    end

    # The headline example in docs/SPEC.md, and the thing that did not work before
    # RailsSupport existed.
    def test_url_helpers_are_available_inside_an_investigation
      klass = integration_case do
        investigate("creates a widget with valid params") do
          post widgets_url
          attest(response).to be_created
        end
      end

      assert klass.run(klass.investigations.first)
    end

    def test_url_helpers_take_arguments
      klass = integration_case { investigate("names one") { widget_url(7) } }

      assert_equal "http://www.example.com/widgets/7", klass.run(klass.investigations.first)
    end

    def test_follow_redirect_is_available
      klass = integration_case do
        investigate("follows") do
          get "/moved"
          follow_redirect!
          response.body
        end
      end

      assert_equal "listed", klass.run(klass.investigations.first)
    end

    def test_every_http_verb_reaches_the_app
      klass = integration_case do
        investigate("verbs") do
          %i[get post patch put delete].each { |verb| public_send(verb, "/widgets") }
          :survived
        end
      end

      assert_equal :survived, klass.run(klass.investigations.first)
    end

    # Rails' Integration::Runner delegates unknown messages to the session. Constable's
    # matcher fallback does the same for be_*/have_*. Both live on the same instance, so
    # the one that does not recognise a name has to hand it on rather than swallow it.
    def test_matcher_fallbacks_still_work_alongside_the_rails_delegation
      klass = integration_case do
        investigate("both") do
          post widgets_url
          attest(response).to be_created
          attest(response).to have_http_status(:created)
        end
      end

      assert klass.run(klass.investigations.first)
    end

    def test_a_failing_attestation_still_raises_assertion_failed
      klass = integration_case do
        investigate("wrong status") do
          get widgets_url
          attest(response).to have_http_status(:created)
        end
      end

      assert_raises(Constable::AssertionFailed) { klass.run(klass.investigations.first) }
    end

    # --- the lifecycle contract Rails depends on ------------------------------

    def test_rails_before_setup_hook_is_reached_through_the_case_lifecycle
      klass = integration_case do
        briefing { @seen_app = app }
        investigate("x") { @seen_app }
      end

      # Integration::Runner#before_setup resets @app and then supers into Constable::Case.
      # If that chain were broken the briefing would never see an app at all.
      assert_same self.class.test_app, klass.run(klass.investigations.first)
    end

    def test_each_investigation_gets_its_own_session
      sessions = []
      klass = integration_case do
        investigate("one") do
          get "/widgets"
          sessions << integration_session
        end
      end
      investigation = klass.investigations.first

      klass.run(investigation)
      klass.run(investigation)

      assert_equal 2, sessions.size
      refute_same sessions[0], sessions[1]
    end

    def test_a_case_can_declare_setup_and_teardown_the_way_rails_modules_do
      runs = []
      klass = integration_case do
        setup { runs << :setup }
        teardown { runs << :teardown }
        investigate("body") do
          get "/widgets"
          runs << :body
        end
      end

      klass.run(klass.investigations.first)

      assert_equal %i[setup body teardown], runs
    end

    # --- the fixture_paths shim -----------------------------------------------

    # rails/test_help's :action_dispatch_integration_test load hook writes fixture_paths
    # onto whatever includes Behavior, assuming it is an ActiveSupport::TestCase.
    def test_including_integration_gives_the_class_somewhere_to_put_fixture_paths
      klass = integration_case

      assert_respond_to klass, :fixture_paths
      assert_equal [], klass.fixture_paths

      klass.fixture_paths += ["test/fixtures"]

      assert_equal ["test/fixtures"], klass.fixture_paths
    end

    def test_the_fixture_paths_shim_never_overwrites_a_real_one
      klass = build_case("FixturedCase") do
        singleton_class.send(:attr_accessor, :fixture_paths)
        self.fixture_paths = ["already here"]
      end

      Constable::RailsSupport.shim_fixture_paths(klass)

      assert_equal ["already here"], klass.fixture_paths
    end

    # --- failing loudly -------------------------------------------------------

    def test_system_support_explains_itself_when_capybara_is_missing
      skip "Capybara is installed in this process" if defined?(::Capybara)

      error = assert_raises(Constable::ConfigurationError) do
        build_case("BrowserCase") { include Constable::RailsSupport::System }
      end

      assert_match(/System cases are opt-in/, error.message)
      assert_match(/gem "capybara"/, error.message)
    end

    def test_integration_support_explains_itself_when_action_pack_is_missing
      missing = ->(*) { raise LoadError, "cannot load such file -- action_dispatch" }

      error = Constable::RailsSupport.stub(:require, missing) do
        assert_raises(Constable::ConfigurationError) { Constable::RailsSupport.integration_behavior }
      end

      assert_match(/needs Action Pack's integration test/, error.message)
      assert_match(%r{require_relative "\.\./config/environment"}, error.message)
    end

    # --- the hard requirement: no Rails, no problem ---------------------------

    # The :unit tier's whole premise is that Constable boots in a process with no Rails in
    # it. A stray top-level require in this file would break that silently, so it is
    # checked in a subprocess rather than asserted about this one.
    def test_requiring_constable_loads_no_rails_at_all
      script = <<~RUBY
        require "constable"
        loaded = %w[Rails ActiveSupport ActionDispatch ActionController Capybara]
                 .select { |name| Object.const_defined?(name) }
        abort("loaded: \#{loaded.join(", ")}") if loaded.any?
        abort("RailsSupport was eagerly loaded") unless Constable.autoload?(:RailsSupport)
        klass = Class.new(Constable::Case) { tier :unit }
        klass.setup { @ready = true }
        klass.teardown { @ready = false }
        investigation = klass.investigate("runs") { @ready }
        abort("lifecycle did not run") unless Constable::Case.run(investigation) == true
        print "clean"
      RUBY

      out = IO.popen([RbConfig.ruby, "-I#{File.expand_path("../../lib", __dir__)}", "-e", script],
                     err: %i[child out], &:read)

      assert_equal "clean", out
    end
  end
end
