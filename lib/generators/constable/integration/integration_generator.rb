# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate integration_test Checkout`, which hooks :integration_tool
    # as :integration -- so the command Rails calls integration_test resolves to a
    # generator that has to be called IntegrationGenerator.
    #
    #   test/cases/controllers/checkout_case.rb   class CheckoutCase < IntegrationCase
    #
    # It lands under test/cases/controllers because that is the directory the `tiers:`
    # globs in Constable::Config::DEFAULTS map to :integration. A request case is exactly
    # what that directory is for -- driving the real stack from the outside, which is the
    # level Constable's own spec example works at.
    class IntegrationGenerator < Base
      check_class_collision suffix: "Case"

      def create_case_file
        template "request_case.rb.tt", case_path("controllers", class_path, "#{file_name}_case.rb")
      end

      private

      def file_name
        @_file_name ||= super.sub(/_test\z/i, "")
      end
    end
  end
end
