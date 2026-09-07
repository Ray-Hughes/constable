# frozen_string_literal: true

require "generators/constable/base"
require "rails/generators/resource_helpers"

module Constable
  module Generators
    # Invoked by `rails generate scaffold Post title:string`, via rails:scaffold_controller,
    # which hooks :test_framework as :scaffold.
    #
    #   test/cases/controllers/posts_controller_case.rb   class PostsControllerCase < IntegrationCase
    #   test/cases/system/posts_case.rb                   class PostsCase < SystemCase
    #
    # The system case is written only when Rails asks for one (`--system-tests=true`),
    # matching test_unit exactly: a browser test that nobody asked for is the slowest
    # possible way to find that out.
    class ScaffoldGenerator < Base
      include ::Rails::Generators::ResourceHelpers

      argument :attributes, type: :array, default: [], banner: "field:type field:type"

      class_option :api, type: :boolean,
                         desc: "Generate cases for an API-only controller"
      class_option :system_tests, type: :string,
                                  desc: "Generate a system case (set to 'true' to enable)"

      check_class_collision suffix: "ControllerCase"

      def create_controller_case
        template options.api? ? "api_controller_case.rb.tt" : "controller_case.rb.tt",
                 case_path("controllers", controller_class_path, "#{controller_file_name}_controller_case.rb")
      end

      def create_system_case
        return if options.api?
        return unless options[:system_tests] == "true"

        template "system_case.rb.tt", case_path("system", class_path, "#{plural_file_name}_case.rb")
      end
    end
  end
end
