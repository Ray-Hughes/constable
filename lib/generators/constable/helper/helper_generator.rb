# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate helper Posts` (and by `rails generate controller`, which
    # hooks the helper generator alongside the test framework).
    #
    #   test/cases/helpers/posts_helper_case.rb   class PostsHelperCase < UnitCase
    #
    # Rails' own test_unit generator writes nothing here at all. A helper is the cheapest
    # thing in a Rails app to test -- a module, a method, a return value -- so the file is
    # worth having, even when it starts out with the module included and nothing to call.
    class HelperGenerator < Base
      check_class_collision suffix: "HelperCase"

      def create_case_file
        template "helper_case.rb.tt", case_path("helpers", class_path, "#{file_name}_helper_case.rb")
      end
    end
  end
end
