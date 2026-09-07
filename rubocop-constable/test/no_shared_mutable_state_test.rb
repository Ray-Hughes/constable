# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    class NoSharedMutableStateTest < CopTest
      COP = ::RuboCop::Cop::Constable::NoSharedMutableState

      def test_registers_an_offense_for_a_class_variable_assignment
        source = native_source(<<~RUBY)
          @@rows = []
        RUBY

        assert_single_offense(COP, source, line: 2, message_fragment: "Assigning class variable `@@rows`")
      end

      def test_registers_an_offense_for_a_global_assignment
        source = native_source(<<~RUBY)
          investigate "remembers the token" do
            $token = issue_token
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "Assigning global `$token`")
      end

      def test_registers_one_offense_for_an_operator_assignment
        source = native_source("investigate('x') { @@rows ||= [] }\n")

        assert_single_offense(COP, source, line: 2, message_fragment: "class variable `@@rows`")
      end

      def test_registers_one_offense_for_a_global_operator_assignment
        source = native_source("investigate('x') { $counter += 1 }\n")

        assert_single_offense(COP, source, line: 2, message_fragment: "global `$counter`")
      end

      def test_registers_an_offense_for_shovelling_onto_a_class_variable
        source = native_source(<<~RUBY)
          investigate "collects a row" do
            @@rows << build_row
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "Mutating class variable `@@rows` with `<<`")
      end

      def test_registers_an_offense_for_bang_and_index_mutation
        source = native_source(<<~RUBY)
          investigate "x" do
            $cache.merge!(a: 1)
            @@rows[0] = build_row
          end
        RUBY

        found = assert_offense_count(2, COP, source)
        assert_includes found[0].message, "Mutating global `$cache` with `merge!`"
        assert_includes found[1].message, "Mutating class variable `@@rows` with `[]=`"
      end

      def test_accepts_reading_a_class_variable_or_global
        source = native_source(<<~RUBY)
          investigate "reads the registry" do
            attest(@@rows.size).to eq($expected_count)
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_instance_variables_and_witnesses
        source = native_source(<<~RUBY)
          witness(:rows) { [] }

          investigate "collects a row" do
            @row = build_row
            rows << @row
            attest(rows.size).to eq(1)
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_mutation_inside_an_unsafe_block
        source = native_source(<<~RUBY)
          investigate "x" do
            # the C extension reads $LOAD_PATH at require time; nothing else can set it
            unsafe { $extension_root = tmp_dir }
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_cold_cases_are_exempt
        assert_cold_case_exempt(COP, "@@rows = []\n")
      end
    end
  end
end
