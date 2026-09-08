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

    # Re-keys any investigations that share a body with another, so the blotter never
    # treats two tests as one. Runs once, after the whole suite is loaded -- a collision
    # is invisible until every case file has been seen.
    #
    # Returns the groups it re-keyed, so a caller can report them if it wants to.
    def disambiguate_identities!
      collisions = investigations.group_by(&:identity).select { |_key, group| group.size > 1 }
      return [] if collisions.empty?

      collisions.each_value { |group| group.each(&:disambiguate!) }

      # Class and description are usually enough to tell two identical bodies apart. When
      # they are not -- a copy-pasted `investigate` with the same name and the same body
      # in the same case -- fall back to position, which is the only thing left that
      # differs. History for those resets whenever the file is reordered, which is the
      # honest cost of two tests that are indistinguishable by anything a human wrote.
      still_colliding = investigations.group_by(&:identity).select { |_key, group| group.size > 1 }
      still_colliding.each_value do |group|
        group.each_with_index { |investigation, index| investigation.disambiguate!(ordinal: index) }
      end

      collisions.values
    end

    def each(&) = @cases.each(&)

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
