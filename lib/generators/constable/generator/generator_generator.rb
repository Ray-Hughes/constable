# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate generator Awesome`.
    #
    #   test/cases/generators/awesome_generator_case.rb   class AwesomeGeneratorCase < UnitCase
    class GeneratorGenerator < Base
      check_class_collision suffix: "GeneratorCase"

      class_option :namespace, type: :boolean, default: true,
                               desc: "Namespace generator under lib/generators/name"

      def create_case_file
        template "generator_case.rb.tt", case_path("generators", class_path, "#{file_name}_generator_case.rb")
      end

      private

      def generator_path
        if options[:namespace]
          File.join("generators", regular_class_path, file_name, "#{file_name}_generator")
        else
          File.join("generators", regular_class_path, "#{file_name}_generator")
        end
      end
    end
  end
end
