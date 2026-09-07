# frozen_string_literal: true

module Constable
  # The roll call of every case file loaded into this process.
  #
  # `Constable::Case.inherited` reports each new subclass here as it's defined, so by the
  # time the Runner has required the case files it can ask one object what there is to
  # run. Dockets are deliberately left off the roll -- they're anonymous subclasses that
  # belong to the case that opened them, and they're reached through it.
  class Registry
    include Enumerable

    def initialize
      @cases = []
    end

    # Called from the `inherited` hook. Dockets and duplicates are ignored.
    def register(case_class)
      return case_class if case_class.respond_to?(:docket?) && case_class.docket?
      return case_class if @cases.include?(case_class)

      @cases << case_class
      case_class
    end

    # Top-level case classes in definition order. Tier base classes appear here too --
    # they simply have no investigations of their own.
    def cases = @cases.dup

    # Every investigation across every loaded case, dockets included.
    def investigations = @cases.flat_map(&:investigations)

    # Cases that actually declared something to run.
    def sworn_cases = @cases.reject { |klass| klass.investigations.empty? }

    def investigations_in(file)
      path = file.to_s
      investigations.select { |inv| inv.file.to_s == path || inv.relative_file == path }
    end

    def find_case(name)
      @cases.find { |klass| klass.constable_display_name == name.to_s || klass.name == name.to_s }
    end

    def each(&block) = @cases.each(&block)

    def size    = @cases.size
    def empty?  = @cases.empty?
    def include?(case_class) = @cases.include?(case_class)

    # Test isolation, ours as much as anyone's.
    def clear
      @cases = []
      self
    end
  end
end
