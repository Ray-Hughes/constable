# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate controller Posts index show`.
    #
    #   test/cases/controllers/posts_controller_case.rb   class PostsControllerCase < IntegrationCase
    class ControllerGenerator < Base
      argument :actions, type: :array, default: [], banner: "action action"

      # Rails passes this through when it skipped writing routes. Without a route there is
      # nothing to drive, so the template says so instead of generating a request that
      # cannot resolve.
      class_option :skip_routes, type: :boolean

      check_class_collision suffix: "ControllerCase"

      def create_case_file
        template "controller_case.rb.tt", case_path("controllers", class_path, "#{file_name}_controller_case.rb")
      end
    end
  end
end
