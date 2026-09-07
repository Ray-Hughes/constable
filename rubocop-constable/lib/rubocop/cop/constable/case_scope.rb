# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # Scopes every `Constable/*` cop to **native** `Constable::Case` files.
      #
      # Constable's whole adoption story is that an existing RSpec or Minitest file
      # can run untouched from day one as a *cold case*. A cold case has explicitly
      # opted out of native rules, so linting it would punish exactly the people who
      # took the on-ramp. Cold-case files are therefore exempt by design, not by
      # oversight -- their escape hatch is already reported once per file, every run,
      # by the runner itself.
      #
      # == The heuristic
      #
      # In order, for each file:
      #
      # 1. *Cold case wins.* If any class in the file inherits from a constant with a
      #    +ColdCase+ segment (+Constable::ColdCase::RSpec+, +Constable::ColdCase::Minitest+,
      #    or a project-local +ColdCase+ base class), the file is exempt. This check runs
      #    first so a cold case is never dragged back in by a path glob.
      # 2. *Native case.* If any class inherits from a constant whose last segment ends in
      #    +Case+ -- +Constable::Case+ itself, or the tier base classes the install
      #    generator writes (+UnitCase+, +IntegrationCase+, +SystemCase+) -- the file is in
      #    scope. Matching on the +Case+ suffix rather than on +Constable::Case+ literally is
      #    deliberate: SPEC.md recommends subclassing a tier base class, so the literal
      #    superclass of a real case file usually *isn't* +Constable::Case+.
      # 3. *Path fallback.* Otherwise, a file sitting under one of the cop's own +Include+
      #    globs (+test/cases/**/*.rb+ and friends) is treated as in scope. This keeps the
      #    cops useful for a shared module under +test/cases/+ or a case file whose class
      #    definition the parser can't see, and it is safe precisely because rule 1 already
      #    took cold cases off the table.
      # 4. Anything else is out of scope and reports nothing.
      #
      # Cops mix this in and guard their handlers with +#constable_case_file?+, rather than
      # overriding +#relevant_file?+, so the exemption is enforced identically whether the
      # cop runs under a full RuboCop team or a bare Commissioner.
      module CaseScope
        COLD_CASE_SEGMENT = "ColdCase"
        NATIVE_CASE_SUFFIX = /Case\z/.freeze

        def on_new_investigation
          @constable_case_file = nil
          super
        end

        # @return [Boolean] whether this file is a native Constable case file.
        def constable_case_file?
          return @constable_case_file unless @constable_case_file.nil?

          @constable_case_file = compute_constable_case_file
        end

        # @return [Boolean] whether the file opted out of native rules.
        def cold_case_file?
          superclass_names.any? { |name| cold_case_superclass?(name) }
        end

        private

        def compute_constable_case_file
          names = superclass_names
          return false if names.any? { |name| cold_case_superclass?(name) }
          return true if names.any? { |name| native_case_superclass?(name) }

          include_path_scope?
        end

        # Every `class Foo < Bar` superclass constant in the file, as dotless
        # `::`-joined strings. Non-constant superclasses (`Class.new(x)`, dynamic
        # superclass expressions) are ignored -- they can't be resolved statically.
        def superclass_names
          @superclass_names ||= begin
            ast = processed_source&.ast
            if ast.nil?
              []
            else
              ast.each_node(:class).filter_map { |node| constant_name(node.parent_class) }
            end
          end
        end

        def constant_name(node)
          return nil unless node.respond_to?(:const_type?) && node.const_type?

          name = node.const_name
          name && name.sub(/\A::/, "")
        end

        def cold_case_superclass?(name)
          name.split("::").include?(COLD_CASE_SEGMENT)
        end

        def native_case_superclass?(name)
          segments = name.split("::")
          return false if segments.include?(COLD_CASE_SEGMENT)

          NATIVE_CASE_SUFFIX.match?(segments.last.to_s)
        end

        def include_path_scope?
          path = current_file_path
          return false if path.nil?

          patterns = Array(cop_config["Include"])
          return false if patterns.empty?

          path_candidates(path).any? do |candidate|
            patterns.any? { |pattern| ::RuboCop::PathUtil.match_path?(pattern, candidate) }
          end
        end

        def current_file_path
          path = processed_source&.file_path
          return nil if path.nil? || path.empty?
          # `(string)` -- source handed to the cop without a path at all.
          return nil if path.start_with?("(")

          path
        end

        def path_candidates(path)
          candidates = [path, path.delete_prefix("#{Dir.pwd}/")]
          begin
            candidates << config.path_relative_to_config(path)
          rescue StandardError # rubocop:disable Lint/SuppressedException
          end
          candidates.compact.uniq
        end
      end
    end
  end
end
