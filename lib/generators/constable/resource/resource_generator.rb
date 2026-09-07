# frozen_string_literal: true

require "generators/constable/model/model_generator"

module Constable
  module Generators
    # `rails generate resource Post title:string` is a model plus a routed controller, and
    # Rails builds it that way: Rails::Generators::ResourceGenerator inherits from the
    # model generator and hooks the controller separately. So the test-framework side of a
    # resource is the model case -- the controller half arrives through constable:controller,
    # invoked by the resource_controller hook.
    #
    # This subclass exists so that lookup resolves rather than printing
    # "constable:resource [not found]" for anything that asks for the resource generator by
    # name, and so it delegates exactly the way Rails' own does: same superclass, same
    # output, no second copy of the template.
    class ResourceGenerator < ModelGenerator
      # generator_name is "resource", which would send the inherited source_root looking in
      # a templates directory this generator does not have and does not need.
      def self.source_root(path = nil)
        return super if path

        ModelGenerator.source_root
      end
    end
  end
end
