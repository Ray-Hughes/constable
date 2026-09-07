# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate system_test Posts`, which hooks :system_tests as :system.
    #
    #   test/cases/system/posts_case.rb   class PostsCase < SystemCase
    class SystemGenerator < Base
      check_class_collision suffix: "Case"

      strips_suffix(/_test\z/i)

      def create_case_file
        template "system_case.rb.tt", case_path("system", class_path, "#{plural_file_name}_case.rb")
      end
    end
  end
end
