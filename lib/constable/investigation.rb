# frozen_string_literal: true

module Constable
  # One registered test. `investigate` is a registration DSL, not a method definition --
  # each Investigation is run in its own fresh instance of its owning case class, so
  # nothing an investigation does can reach any other one.
  class Investigation
    attr_reader :case_class, :description, :block, :file, :line, :docket_path
    attr_accessor :tier

    def initialize(case_class:, description:, block:, file:, line:, docket_path: [], tier: nil)
      @case_class  = case_class
      @description = description
      @block       = block
      @file        = file
      @line        = line
      @docket_path = docket_path
      @tier        = tier
    end

    # "UsersController::CreatesUserCase" -- the outermost real (non-docket) class.
    def case_name
      @case_name ||=
        if @case_class.respond_to?(:constable_display_name)
          @case_class.constable_display_name
        else
          @case_class.name.to_s
        end
    end

    # Docket nesting folds into the description the way a reader would say it aloud:
    #   docket "as an admin" + investigate "creates a user" => "as an admin creates a user"
    def full_description
      (@docket_path + [@description]).join(" ")
    end

    def identity
      @identity ||= Identity.for_block(@block)
    end

    # Re-keys this investigation because another one has the same body. Called by the
    # registry once the whole suite is loaded, which is the first moment a collision can
    # be seen. See Identity.disambiguate.
    def disambiguate!
      @identity = Identity.disambiguate(identity, case_name: case_name,
                                                  description: full_description)
      self
    end

    def location
      "#{relative_file}:#{@line}"
    end

    def relative_file
      @file.to_s.delete_prefix("#{Constable.root}/")
    end

    def kind = :native

    def to_h
      {
        identity: identity,
        case_name: case_name,
        description: full_description,
        file: relative_file,
        line: @line,
        tier: @tier,
        kind: kind
      }
    end

    def display_label
      "#{case_name} \"#{full_description}\""
    end
  end
end
