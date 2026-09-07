# frozen_string_literal: true

# Rails generator machinery is required *here*, not from lib/constable.rb.
# `require "constable"` has to work in a process with no Rails app at all --
# that is the entire point of the :unit tier -- so railties is only ever pulled
# in by the files that genuinely cannot exist without it.
require "rails/generators/named_base"
require "constable"

module Constable
  module Generators
    # Shared ground for the generators Rails invokes on Constable's behalf.
    #
    # Once Constable::Railtie has registered the app's test framework, every
    # `rails generate` command that hooks :test_framework goes looking for a generator
    # called constable:<something>. Rails resolves that by namespace, the namespace comes
    # from the class name, and the file is found by converting the namespace back into a
    # path -- so the layout is not a matter of taste. Each generator lives at
    # generators/constable/<name>/<name>_generator.rb and is called <Name>Generator.
    # rspec-rails is arranged the same way, for the same reason.
    #
    # Named Base deliberately: Rails::Generators::Base.inherited skips registering any
    # class whose name ends in "Base", so this never turns up in `rails generate` output
    # as a generator of its own.
    class Base < ::Rails::Generators::NamedBase
      # Each generator keeps its templates beside itself. Rails' default looks for them
      # under railties' own directory, which is no use to a gem that isn't railties.
      def self.source_root(path = nil)
        return @_constable_source_root = path if path

        @_constable_source_root ||= File.expand_path(File.join(__dir__, generator_name, "templates"))
      end

      private

      # Where a generated case file goes. `test/cases/<area>/...` is the shape the `tiers:`
      # globs in Constable::Config::DEFAULTS already use, so the path-based tier fallback
      # and the tier base class the file inherits from agree with each other instead of
      # quietly disagreeing. The base class still wins; agreeing just means nobody has to
      # work out which one applied.
      def case_path(area, *parts)
        File.join("test/cases", area, *parts)
      end

      # The attributes worth putting in a witness. References and virtual attributes
      # (rich text, attachments) are dropped: their value is another record or an
      # uploaded file, and inventing one would generate a test that fails for a reason
      # nobody wrote.
      def case_attributes
        @case_attributes ||= attributes.reject { |attribute| attribute.reference? || attribute.virtual? }
      end

      # `title: "MyString", published: false` -- the body of the witness a case starts from.
      def attributes_arguments
        case_attributes.map { |attribute| "#{attribute.column_name}: #{attribute_value(attribute)}" }.join(", ")
      end

      def attributes_literal
        case_attributes.empty? ? "{}" : "{ #{attributes_arguments} }"
      end

      # `Post.new(title: "MyString")`, or a bare `Post.new` for a model generated with
      # nothing to fill in.
      def new_record_expression(klass = class_name)
        case_attributes.empty? ? "#{klass}.new" : "#{klass}.new(#{attributes_arguments})"
      end

      def attribute_value(attribute)
        return '"secret"' if %w[password password_confirmation].include?(attribute.name)

        attribute.default.inspect
      end
    end
  end
end
