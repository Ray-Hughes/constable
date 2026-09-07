# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate model Post title:string` (and by anything else that ends
    # up at active_record:model -- `rails generate resource`, `rails generate scaffold`).
    #
    #   test/cases/models/post_case.rb   class PostCase < UnitCase
    class ModelGenerator < Base
      argument :attributes, type: :array, default: [], banner: "field:type field:type"

      # Accepted and ignored, so `rails generate model --fixture` still runs for an app
      # that passes it out of habit. Constable has no fixtures: a witness builds exactly
      # what one investigation needs and throws it away with it, which is the same reason
      # there is no before(:all).
      class_option :fixture, type: :boolean

      check_class_collision suffix: "Case"

      def create_case_file
        template "model_case.rb.tt", case_path("models", class_path, "#{file_name}_case.rb")
      end

      # A factory gem registered as the fixture replacement still gets its turn -- factories
      # are a witness's business, not a fixture's, and Constable has no quarrel with them.
      hook_for :fixture_replacement
    end
  end
end
