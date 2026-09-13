# frozen_string_literal: true

require_relative "../helper"

module Constable
  # RSpec registers shared examples under a string and looks them up at run time. A typo is
  # found when the suite runs, as "Could not find shared examples", and the registry is
  # global so two files defining "a task" silently fight over the name. A procedure is a
  # constant: the typo is a NameError at load, and two of them cannot collide.
  class ProcedureTest < TestCase
    def test_a_procedure_declares_investigations_on_the_case_that_follows_it
      steps = Constable.procedure { investigate("works") { attest(1).to eq(1) } }
      klass = build_case { follows steps }

      assert_equal ["works"], klass.investigations.map(&:description)
    end

    def test_a_case_can_follow_several
      one = Constable.procedure { investigate("one") { attest(1).to eq(1) } }
      two = Constable.procedure { investigate("two") { attest(1).to eq(1) } }
      klass = build_case { follows one, two }

      assert_equal %w[one two], klass.investigations.map(&:description)
    end

    # The whole reason to follow a procedure rather than copy it: what the case declares
    # afterwards wins, which is the scoping `it_behaves_like` has.
    def test_the_case_can_override_a_witness_the_procedure_declared
      steps = Constable.procedure do
        witness(:value) { :from_procedure }
        investigate("reads the value") { attest(value).to eq(:from_case) }
      end
      klass = build_case do
        follows steps
        witness(:value) { :from_case }
      end

      assert_equal :from_case, Case.run(klass.investigations.first)
    end

    def test_a_procedure_can_declare_witnesses_and_briefings
      steps = Constable.procedure do
        witness(:seen) { [] }
        briefing { seen << :briefed }
        investigate("ran the briefing") { attest(seen).to eq([:briefed]) }
      end
      klass = build_case { follows steps }

      Case.run(klass.investigations.first)
    end

    def test_a_procedure_can_nest_dockets
      steps = Constable.procedure do
        docket "in a group" do
          investigate("nested") { attest(1).to eq(1) }
        end
      end
      klass = build_case { follows steps }

      assert_equal [["in a group"]], klass.investigations.map(&:docket_path)
    end

    # A procedure's tests belong to the file that followed it, so `constable test <file>`
    # runs them. Without that, selecting the case file finds nothing -- the blocks were
    # written in the procedure's file.
    def test_investigations_are_attributed_to_the_following_file
      steps = Constable.procedure { investigate("works") { attest(1).to eq(1) } }
      klass = build_case { follows steps }

      assert_equal __FILE__, klass.investigations.first.file
    end

    def test_following_something_that_is_not_a_procedure_says_so
      error = assert_raises(ArgumentError) { build_case { follows :not_a_procedure } }

      assert_match(/expects a Constable\.procedure/, error.message)
      assert_match(/NameError/, error.message)
    end

    def test_a_procedure_requires_a_block
      assert_raises(ArgumentError) { Constable.procedure }
    end

    def test_a_procedure_can_carry_a_description
      assert_equal "a task", Constable.procedure("a task") { nil }.description
    end
  end
end
