# frozen_string_literal: true

require "rails/railtie"

module Constable
  # The one file in the gem that cannot exist without Rails.
  #
  # `rails generate scaffold Post title:string` does not know what a test file looks
  # like. It asks whatever generator is registered as the app's test framework, and
  # unless something says otherwise that is always test_unit. So an app can install
  # Constable, write its whole suite in cases, and still have every `rails generate`
  # quietly drop Minitest files into test/ -- for the one framework the app deliberately
  # replaced. Registering here is what closes that gap, and it is exactly what
  # rspec-rails does for the same reason.
  #
  # Loaded conditionally from lib/constable.rb, never unconditionally: `require
  # "constable"` has to keep working in a process with no Rails app at all, which is the
  # whole premise of the :unit tier.
  class Railtie < ::Rails::Railtie
    config.app_generators do |g|
      # `fixture: false` is not an oversight. Constable has no fixtures: a witness builds
      # exactly what one investigation needs and throws it away again, which is the same
      # reason there is no before(:all). Generating a fixtures.yml alongside a case would
      # be handing the suite the shared mutable state it exists to prevent.
      g.test_framework :constable, fixture: false

      # Rails resolves these two separately from :test_framework -- its own test_unit
      # railtie claims all three. Claiming only the first would leave
      # `rails generate integration_test` and `rails generate system_test` writing
      # Minitest into a Constable app, which is the bug this railtie exists to fix.
      g.integration_tool :constable
      g.system_tests :constable
    end
  end
end
