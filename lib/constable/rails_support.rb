# frozen_string_literal: true

module Constable
  # Rails' own testing behaviour, borrowed for a Constable::Case.
  #
  #   class IntegrationCase < Constable::Case
  #     include Constable::RailsSupport::Integration
  #     tier :integration
  #   end
  #
  # Rails ships the request stack and the browser stack as ordinary modules -- there is no
  # need to reimplement `post users_path` or `click_on "Save"`, and every reimplementation
  # would be a slightly wrong one. What those modules *do* assume is Minitest's lifecycle:
  # `setup`/`teardown` class macros and the `before_setup`/`after_teardown` instance hooks.
  # Constable::Case answers that contract (see its "Minitest lifecycle compatibility"
  # section), so the modules drop straight in.
  #
  # Nothing here is loaded until a case_helper asks for it. `require "constable"` must
  # still work in a process with no Rails at all -- that is the whole premise of the :unit
  # tier -- so every Rails constant below is reached through a lazy require.
  module RailsSupport
    # The request stack: get/post/patch/put/delete, `response`, `follow_redirect!`,
    # cookies, and the application's URL helpers (`articles_url`, `article_path`).
    #
    # Include it into a tier base class, not into an individual case.
    module Integration
      def self.included(base)
        behavior = RailsSupport.integration_behavior
        RailsSupport.shim_fixture_paths(base)
        base.include(behavior)
      end
    end

    # The browser stack: Capybara's DSL (`visit`, `click_on`, `fill_in`, `page`), Capybara's
    # Minitest assertions, Rails' `driven_by`/`served_by` configuration and its failure
    # screenshots.
    #
    # Rails' own ActionDispatch::SystemTestCase is a class, not a module, so it cannot be
    # mixed in. What it actually does, though, is a short list -- driver selection, a Puma
    # server, session reset, screenshots, URL helpers off the Capybara host -- and each of
    # those is reproduced below against the same Rails objects rather than reinvented.
    module System
      DEFAULT_HOST = "http://127.0.0.1"

      def self.included(base)
        RailsSupport.load_system!

        base.extend(ClassMethods)
        base.include(::Capybara::DSL)
        base.include(::Capybara::Minitest::Assertions)
        base.include(::ActionDispatch::SystemTesting::TestHelpers::ScreenshotHelper)
        base.include(::ActionDispatch::SystemTesting::TestHelpers::SetupAndTeardown)
        base.include(InstanceMethods)
      end

      module ClassMethods
        # Same signature as ActionDispatch::SystemTestCase.driven_by, and it builds the
        # same driver object, so every driver Rails supports is supported here.
        def driven_by(driver, using: :chrome, screen_size: [1400, 1400], options: {}, &capabilities)
          self.constable_driver = ::ActionDispatch::SystemTesting::Driver.new(
            driver, using: using, screen_size: screen_size, options: options, &capabilities
          )
        end

        def served_by(host:, port:)
          ::Capybara.server_host = host
          ::Capybara.server_port = port
        end

        # Inherited the same way `tier` is: declare the driver once on SystemCase and every
        # case below it is driven the same way.
        def constable_driver
          return @constable_driver if defined?(@constable_driver) && @constable_driver

          superclass.respond_to?(:constable_driver) ? superclass.constable_driver : nil
        end

        attr_writer :constable_driver
      end

      module InstanceMethods
        # Registering the driver with Capybara is deferred to the first investigation that
        # actually runs, so merely loading a suite that contains system cases never starts
        # a browser.
        def before_setup
          driver = self.class.constable_driver || self.class.driven_by(:selenium)
          driver.use
          super if defined?(super)
        end

        # Rails' screenshot helper asks the test whether it failed. Constable knows the
        # answer while teardown runs, because the lifecycle stashes the exception first.
        def failed? = !constable_failure.nil?
        def passed? = constable_failure.nil?

        # Minitest hangs arbitrary reporter data off each test; the screenshot helper
        # writes the failure image path into it. Constable has no such reporter channel,
        # so this is somewhere harmless for it to land.
        # rubocop:disable Naming/MemoizedInstanceVariableName -- class-level and instance
        # state on a Case carries a constable_ prefix so it can never collide with an
        # instance variable a user's own case sets.
        def metadata = (@constable_metadata ||= {})
        # rubocop:enable Naming/MemoizedInstanceVariableName

        # Capybara's assertions bump Minitest's counter directly (`self.assertions += 1`).
        # Constable keeps the same tally under its own name, so point one at the other
        # rather than let `assert_text` die counting.
        def assertions = assertion_count

        def assertions=(count)
          @assertion_count = count
        end

        private

        # Capybara drives a real server over HTTP, so a system case's URL helpers must
        # generate absolute URLs pointed at that server -- not the relative paths an
        # integration case wants. This is Rails' own arrangement, kept verbatim.
        def url_helpers
          @url_helpers ||= build_url_helpers
        end

        def build_url_helpers
          app = ::ActionDispatch.test_app
          return nil unless app

          Class.new do
            include app.routes.url_helpers
            include app.routes.mounted_helpers

            def url_options = default_url_options.reverse_merge(host: app_host)

            def app_host
              ::Capybara.app_host || ::Capybara.current_session.server_url || DEFAULT_HOST
            end
          end.new
        end

        def method_missing(name, ...)
          helpers = url_helpers
          return super unless helpers.respond_to?(name)

          helpers.public_send(name, ...)
        end

        def respond_to_missing?(name, include_private = false)
          url_helpers.respond_to?(name) || super
        end
      end
    end

    class << self
      # ActionDispatch::IntegrationTest::Behavior is an ActiveSupport::Concern, so it has
      # to be included into the *class* rather than into a module in front of it --
      # otherwise its `included` block configures the wrapper module instead of the case.
      def integration_behavior
        require "action_dispatch"
        # Behavior mixes in ActionController::TemplateAssertions without requiring it --
        # inside a booted app something else always has by then.
        require "action_controller"
        require "action_dispatch/testing/integration"
        ::ActionDispatch::IntegrationTest::Behavior
      rescue LoadError, NameError => e
        raise Constable::ConfigurationError, <<~MESSAGE
          Constable::RailsSupport::Integration needs Action Pack's integration test
          helpers, and they could not be loaded (#{e.class}: #{e.message}).

          An :integration case drives the real request stack, so Rails has to be booted
          before the tier base class is defined. In test/case_helper.rb that means:

              require_relative "../config/environment"
              require "constable"

          must come before `class IntegrationCase < Constable::Case`.
        MESSAGE
      end

      def load_system!
        require "action_dispatch"
        # Loading this file is what starts the Capybara/Puma server plumbing -- Rails does
        # the setup at require time rather than in a hook we could call ourselves.
        require "action_dispatch/system_test_case"
        require "capybara/minitest"
        ::ActionDispatch::SystemTesting::Driver
      rescue LoadError, NameError => e
        raise Constable::ConfigurationError, <<~MESSAGE
          Constable::RailsSupport::System needs Rails' system testing support and
          Capybara, and they could not be loaded (#{e.class}: #{e.message}).

          System cases are opt-in. Add them to your Gemfile's :test group:

              gem "capybara"
              gem "selenium-webdriver"

          and make sure test/case_helper.rb requires config/environment before it defines
          SystemCase.
        MESSAGE
      end

      # `rails/test_help` registers an :action_dispatch_integration_test load hook that
      # does `self.fixture_paths += ActiveSupport::TestCase.fixture_paths`, on the
      # assumption that anything including Behavior is an ActiveSupport::TestCase. A Case
      # is not one, and Constable does not use Rails fixtures, so give the hook somewhere
      # harmless to write rather than let it take the whole suite down.
      def shim_fixture_paths(base)
        return if base.respond_to?(:fixture_paths)

        base.singleton_class.send(:attr_accessor, :fixture_paths)
        base.fixture_paths = []
      end
    end
  end
end
