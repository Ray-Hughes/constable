# frozen_string_literal: true

module Constable
  # Shared behaviour, as a thing with a name rather than a string in a registry.
  #
  #   # test/support/procedures.rb
  #   TaskProcedure = Constable.procedure do
  #     witness(:task) { create(:task) }
  #
  #     investigate "starts unassigned" do
  #       attest(task.assignee).to be_nil
  #     end
  #   end
  #
  #   class ColocatedTaskCase < UnitCase
  #     follows TaskProcedure
  #   end
  #
  # RSpec's `shared_examples` registers a block under a string and `it_behaves_like` looks
  # it up at run time. Two costs fall out of that. A typo is found when the suite runs, as
  # "Could not find shared examples", rather than when the file loads. And the registry is
  # global, so two files that both define "a task" silently fight over the name -- which is
  # why suites end up with names like "a task (from the appeals side)".
  #
  # A procedure is a constant. A typo is a NameError at load, on the line that made it.
  # Two of them cannot collide, because Ruby will not let them. And it can live anywhere a
  # constant can, so sharing across files needs no index of the whole suite.
  #
  # Inside the block, the case DSL: investigate, witness, witness_all, briefing, teardown,
  # docket, and anything else the case responds to. `follows` evaluates it in the case, so
  # a witness the procedure declares can be overridden by the case that follows it -- the
  # same scoping `it_behaves_like` has, and the reason procedures are worth having at all.
  class Procedure
    attr_reader :description, :block

    def initialize(description = nil, &block)
      raise ArgumentError, "Constable.procedure requires a block" unless block

      @description = description
      @block = block
    end

    # Run the procedure's declarations in `case_class`. Called by Case#follows.
    def apply_to(case_class)
      case_class.class_eval(&@block)
      self
    end

    # Which file is currently following a procedure, if any.
    #
    # A stack rather than a flag, because a procedure may follow another one, and the
    # attribution has to unwind to the right file rather than to nothing.
    class << self
      def stack = (@stack ||= [])

      def following_from = stack.last

      def following(case_class)
        stack.push(constable_caller_file(case_class))
        yield
      ensure
        stack.pop
      end

      # The first frame outside the gem: the file that said `follows`.
      def constable_caller_file(_case_class)
        gem_dir = File.expand_path("..", __dir__)
        caller_locations(1, 30).map(&:path).find { |path| !path.start_with?(gem_dir) }
      end
    end

    def to_s = @description ? "#{self.class}(#{@description})" : super
    alias inspect to_s
  end
end
