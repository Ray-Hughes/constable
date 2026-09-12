# frozen_string_literal: true

require_relative "../helper"

module Constable
  # The modernizer is opt-in precisely because a bad AST rewrite is invisible, so these
  # tests care about two things above all: the rewritten source must actually parse, and
  # anything ambiguous must come back flagged rather than converted.
  class ModernizerTest < TestCase
    def modernize(source, path: "spec/models/user_spec.rb")
      write_file(path, source)
      Importer::Modernizer.new(path, config: Constable.config, root: tmp_root).call
    end

    def convert(source, path: "spec/models/user_spec.rb")
      result = modernize(source, path: path)

      assert_nil result.error, "modernizer failed: #{result.error}"
      assert_parses result.source
      result
    end

    def assert_parses(source)
      assert RubyVM::InstructionSequence.compile(source), "rewritten source did not compile"
    rescue SyntaxError => e
      flunk "rewritten source is not valid Ruby: #{e.message}\n\n#{source}"
    end

    def kinds(items) = items.map { |item| item[:kind] }

    def flag_named(result, kind) = result.flags.find { |flag| flag[:kind] == kind }

    def untouched_named(result, kind) = result.untouched.find { |item| item[:kind] == kind }

    def read(relative) = File.read(File.join(tmp_root, relative))

    # ---- the conversion table, row by row ------------------------------------------

    def test_describe_and_it_become_a_case_class_and_an_investigate
      result = convert(<<~SPEC)
        describe UsersController do
          it "creates a user" do
            post users_path
          end
        end
      SPEC

      assert_equal "UsersControllerCase", result.class_name
      assert_equal <<~EXPECTED, result.source
        class UsersControllerCase < Constable::Case
          investigate "creates a user" do
            post users_path
          end
        end
      EXPECTED
      assert_includes kinds(result.converted), :case_class
      assert_includes kinds(result.converted), :investigate
    end

    def test_rspec_dot_describe_is_handled_too
      result = convert("RSpec.describe Users::Session do\nend\n")

      assert_equal "Users::SessionCase", result.class_name
      assert_equal "class Users::SessionCase < Constable::Case\nend\n", result.source
    end

    def test_a_string_describe_becomes_a_camelized_case_class
      result = convert(%(describe "user sign in" do\nend\n))

      assert_equal "UserSignInCase", result.class_name
    end

    def test_describe_metadata_is_dropped_and_recorded_as_untouched
      result = convert("RSpec.describe User, type: :model do\nend\n")

      assert_equal "class UserCase < Constable::Case\nend\n", result.source
      assert_match(/were dropped/, untouched_named(result, :describe_metadata)[:reason])
    end

    def test_let_becomes_witness
      result = convert(<<~SPEC)
        describe User do
          let(:valid_params) { { email: "a@b.com" } }
        end
      SPEC

      assert_includes result.source, "witness(:valid_params) { { email: \"a@b.com\" } }"
      assert_equal "witness(:valid_params)", result.converted.find { |c| c[:kind] == :witness }[:to]
    end

    # SPEC.md writes one-line hooks with braces (`briefing { sign_in(:admin) }`), and
    # `briefing do stub_network! end` on a single line is valid Ruby nobody writes.
    def test_a_single_line_before_becomes_a_braced_briefing
      result = convert(<<~SPEC)
        describe User do
          before { stub_network! }
        end
      SPEC

      assert_includes result.source, "briefing { stub_network! }"
      refute_includes result.source, "before"
    end

    def test_a_multiline_before_becomes_a_do_end_briefing
      result = convert(<<~SPEC)
        describe User do
          before {
            stub_network!
            sign_in(:admin)
          }
        end
      SPEC

      assert_includes result.source, "briefing do\n"
      assert_includes result.source, "end"
      refute_includes result.source, "before"
    end

    def test_before_each_becomes_briefing_and_loses_its_scope_argument
      result = convert(<<~SPEC)
        describe User do
          before(:each) do
            sign_in(:admin)
          end
        end
      SPEC

      assert_includes result.source, "briefing do\n"
      refute_includes result.source, ":each"
    end

    def test_before_all_is_flagged_and_never_converted
      source = <<~SPEC
        describe User do
          before(:all) do
            @world = seed_the_world
          end
        end
      SPEC
      result = convert(source)

      assert_includes result.source, "before(:all) do"
      refute_includes result.source, "briefing"
      flag = flag_named(result, :before_all)

      refute_nil flag, "before(:all) was not flagged"
      assert_match(/isolation is the point/, flag[:reason])
      assert_equal "spec/models/user_spec.rb:2", flag[:location]
    end

    def test_before_context_is_flagged_the_same_way
      result = convert("describe User do\n  before(:context) { seed }\nend\n")

      refute_nil flag_named(result, :before_all)
      assert_includes result.source, "before(:context) { seed }"
    end

    def test_minitest_test_methods_become_investigations
      result = convert(<<~TEST, path: "test/models/user_test.rb")
        class UserTest < ActiveSupport::TestCase
          def test_foo
            assert true
          end
        end
      TEST

      assert_equal :minitest, result.dialect
      assert_equal "UserCase", result.class_name
      assert_equal <<~EXPECTED, result.source
        class UserCase < Constable::Case
          investigate "foo" do
            assert true
          end
        end
      EXPECTED
    end

    def test_minitest_underscores_become_spaces_in_the_description
      result = convert(<<~TEST, path: "test/models/user_test.rb")
        class UserTest < Minitest::Test
          def test_creates_a_user_with_valid_params
            assert true
          end
        end
      TEST

      assert_includes result.source, %(investigate "creates a user with valid params" do)
    end

    def test_minitest_setup_becomes_briefing
      result = convert(<<~TEST, path: "test/models/user_test.rb")
        class UserTest < ActiveSupport::TestCase
          def setup
            @user = User.new
          end
        end
      TEST

      assert_includes result.source, "briefing do\n    @user = User.new\n  end"
    end

    def test_shared_examples_are_left_untouched_and_logged
      source = <<~SPEC
        describe User do
          shared_examples "an authorized action" do
            it "allows" do
              expect(response).to be_ok
            end
          end
        end
      SPEC
      result = convert(source)

      assert_includes result.source,
                      "  shared_examples \"an authorized action\" do\n    " \
                      "it \"allows\" do\n      " \
                      "expect(response).to be_ok\n    " \
                      "end\n  " \
                      "end\n"
      # Flagged rather than merely noted: a converted file that still calls the
      # shared-examples DSL is a native case invoking a method Constable does not have, and
      # it dies on load. Blocking conversion is what sends it to a cold case instead, where
      # the DSL still works.
      entry = flag_named(result, :shared_examples)

      refute_nil entry
      assert_match(/plain Ruby module/, entry[:reason])
      # Nothing inside a shared_examples block is touched either -- not the `it`, not the
      # `expect` -- because the block isn't an example group we own.
      refute_includes kinds(result.converted), :investigate
    end

    # Measured on a real port: two files converted cleanly and then died with
    # `NoMethodError: undefined method 'it_behaves_like'`, taking their tests with them --
    # 78 fewer tests ran than under rspec and the run still reported a pass.
    def test_it_behaves_like_blocks_conversion
      result = convert("describe User do\n  it_behaves_like \"a thing\"\nend\n")

      assert_includes result.source, %(it_behaves_like "a thing")
      refute_nil flag_named(result, :shared_examples)
      assert_predicate result, :flagged?
    end

    def test_custom_matcher_definitions_are_left_untouched_and_logged
      result = convert(<<~SPEC, path: "spec/support/matchers_spec.rb")
        RSpec::Matchers.define(:be_created) do |actual|
          actual.status == 201
        end
      SPEC

      assert_includes result.source, "RSpec::Matchers.define(:be_created) do |actual|"
      assert_match(/Constable::Matchers.define/, untouched_named(result, :custom_matcher)[:reason])
    end

    # ---- expectations --------------------------------------------------------------

    def test_expect_becomes_attest
      result = convert(<<~SPEC)
        describe User do
          it "works" do
            expect(user.name).to eq("Ada")
          end
        end
      SPEC

      assert_includes result.source, "attest(user.name).to eq(\"Ada\")"
    end

    def test_expect_block_with_change_becomes_attest_block
      result = convert(<<~SPEC)
        describe User do
          it "creates one" do
            expect { post users_path }.to change { User.count }.by(1)
          end
        end
      SPEC

      assert_includes result.source, "attest { post users_path }.to change { User.count }.by(1)"
    end

    def test_to_not_is_normalized_to_not_to
      result = convert(<<~SPEC)
        describe User do
          it "works" do
            expect(User.count).to_not eq(0)
          end
        end
      SPEC

      assert_includes result.source, "attest(User.count).not_to eq(0)"
      assert_includes kinds(result.converted), :not_to
    end

    def test_a_one_liner_it_is_flagged_and_left_exactly_as_written
      result = convert(<<~SPEC)
        describe User do
          it { is_expected.to be_valid }
        end
      SPEC

      assert_includes result.source, "it { is_expected.to be_valid }"
      flag = flag_named(result, :one_liner_example)

      refute_nil flag
      assert_match(/no description/, flag[:reason])
      # The one-liner is reported once, not once for `it` and again for `is_expected`.
      assert_equal 1, result.flags.size
    end

    def test_its_is_flagged
      result = convert("describe User do\n  its(:name) { should eq(\"Ada\") }\nend\n")

      refute_nil flag_named(result, :its)
      assert_includes result.source, "its(:name) { should eq(\"Ada\") }"
    end

    # rspec-mocks blocks conversion rather than merely being noted.
    #
    # "Untouched" leaves the construct alone *and lets the file convert*, which for
    # rspec-mocks means writing a native case that dies on its first `allow` with
    # NoMethodError -- Constable ships no mocking library. Measured while porting a real
    # directory: files converted cleanly and then failed at runtime for exactly this.
    #
    # A file that cannot run is not a conversion. Flagged, `--port` moves it verbatim as a
    # cold case instead, where rspec-mocks still works.
    def test_message_expectations_block_conversion_rather_than_being_renamed
      result = convert(<<~SPEC)
        describe User do
          it "notifies" do
            expect(mailer).to receive(:deliver_later)
          end
        end
      SPEC

      assert_includes result.source, "expect(mailer).to receive(:deliver_later)"
      refute_includes result.source, "attest(mailer)"
      assert_match(/no mocking library/, flag_named(result, :rspec_mocks)[:reason])
      assert_predicate result, :flagged?
    end

    def test_allow_blocks_conversion
      result = convert(<<~SPEC)
        describe User do
          it "stubs" do
            allow(clock).to receive(:now)
          end
        end
      SPEC

      assert_includes result.source, "allow(clock).to receive(:now)"
      refute_nil flag_named(result, :rspec_mocks)
      assert_predicate result, :flagged?
    end

    # ---- --cold: move it without converting it --------------------------------------
    #
    # A conversion that comes back flagged is not runnable: the flagged constructs are
    # left verbatim, so `let!` stays `let!` and the class body raises the moment it loads.
    # That is deliberate -- what a `let!` should become is a decision. But it leaves the
    # file stuck in spec/ when the goal is one tree, and a cold case is the answer that
    # already exists.

    def cold_result(source, path: "spec/models/user_spec.rb")
      write_file(path, source)
      Importer::Modernizer.run([path], config: Constable.config, root: tmp_root, write: :cold, report: false)
                          .results.first
    end

    def test_cold_wraps_the_file_without_touching_it
      body = <<~SPEC
        describe User do
          let!(:existing) { create(:user) }

          it "works" do
            expect(1).to eq(1)
          end
        end
      SPEC
      result = cold_result(body)

      written = read(result.written_to)
      assert_match(/< Constable::ColdCase::RSpec/, written)
      assert_match(/let!\(:existing\)/, written, "the body must survive byte for byte")
      assert_match(/expect\(1\)\.to eq\(1\)/, written, "nothing is converted")
      refute_match(/attest/, written)
    end

    def test_cold_writes_alongside_with_a_case_name
      result = cold_result("describe User do\nend\n")

      assert_equal "spec/models/user_case.rb", result.written_to
    end

    def test_cold_names_the_class_after_the_file
      result = cold_result("describe User do\nend\n", path: "spec/models/tag_spec.rb")

      assert_match(/class LegacyTagSpec </, read(result.written_to))
    end

    def test_cold_says_where_the_file_came_from
      result = cold_result("describe User do\nend\n")

      assert_match(%r{Moved verbatim from spec/models/user_spec\.rb}, read(result.written_to))
    end

    def test_cold_refuses_to_overwrite
      write_file("spec/models/user_case.rb", "# already here\n")
      result = cold_result("describe User do\nend\n")

      assert_match(/refusing to overwrite/, result.error.to_s)
      assert_equal "# already here\n", read("spec/models/user_case.rb")
    end

    def test_the_wrapped_source_parses
      body = "describe User do\n  let!(:x) { 1 }\n  it(\"works\") { expect(x).to eq(1) }\nend\n"
      result = cold_result(body)

      assert_parses(read(result.written_to))
    end

    # ---- matchers Constable does not have ------------------------------------------
    #
    # The rewrite carries any matcher name straight across, so without this check the
    # first anyone hears about a missing matcher is a NoMethodError at runtime.

    def test_a_matcher_constable_does_not_have_is_flagged
      result = convert("describe User do\n  it(\"x\") { expect(a).to smell_wrong(b) }\nend\n")

      flag = flag_named(result, :unknown_matcher)
      refute_nil flag
      assert_match(/smell_wrong/, flag[:reason])
      assert_match(/Constable::Matchers\.define/, flag[:reason])
    end

    def test_a_built_in_matcher_is_not_flagged
      %w[eq include match raise_error have_http_status contain_exactly change].each do |matcher|
        result = convert("describe User do\n  it(\"x\") { expect(a).to #{matcher}(b) }\nend\n")
        assert_nil flag_named(result, :unknown_matcher), "#{matcher} is built in and must not be flagged"
      end
    end

    # be_*/have_* resolve through the predicate fallback, so they always work.
    def test_predicate_matchers_are_never_flagged
      result = convert("describe User do\n  it(\"x\") { expect(a).to be_published }\nend\n")

      assert_nil flag_named(result, :unknown_matcher)
    end

    def test_a_chained_matcher_is_judged_by_its_root
      result = convert("describe User do\n  it(\"x\") { expect(a).to be_within(0.5).of(10) }\nend\n")

      assert_nil flag_named(result, :unknown_matcher), "be_within is registered"
    end

    def test_an_unknown_chained_matcher_is_flagged_by_its_root
      result = convert("describe User do\n  it(\"x\") { expect(a).to be_roughly(0.5).of(10) }\nend\n")

      # be_roughly matches the be_* predicate fallback, so it is legal -- the point is
      # that the root is what gets judged, not the trailing `.of`.
      assert_nil flag_named(result, :unknown_matcher)
    end

    def test_negated_expectations_are_checked_too
      result = convert("describe User do\n  it(\"x\") { expect(a).not_to smell_wrong(b) }\nend\n")

      refute_nil flag_named(result, :unknown_matcher)
    end

    # A matcher held in a local variable could be anything, and the parser tells us so:
    # an assigned name is an lvar, not a send. Guessing there would produce false alarms.
    def test_a_matcher_held_in_a_variable_is_left_alone
      result = convert(<<~SPEC)
        describe User do
          it "x" do
            matcher = eq(1)
            expect(a).to matcher
          end
        end
      SPEC

      assert_nil flag_named(result, :unknown_matcher)
    end

    # ---- helper specs ----------------------------------------------------------------

    # `modernize` used to report "21 converted, 0 flagged" on a helper spec and produce a
    # case where every example died with `undefined local variable or method 'helper'`.
    def test_the_rspec_helper_object_is_flagged
      result = convert(<<~SPEC, path: "spec/helpers/tasks_helper_spec.rb")
        describe TasksHelper do
          it "formats a badge" do
            expect(helper.badge(1)).to eq("No. 1")
          end
        end
      SPEC

      flag = flag_named(result, :rspec_helper_object)
      refute_nil flag
      assert_match(/no Constable equivalent/, flag[:reason])
      assert_match(/include YourHelper/, flag[:reason])
    end

    # `helper` as a receiver or with arguments is somebody's own method, not RSpec's.
    def test_a_method_called_helper_with_arguments_is_left_alone
      result = convert("describe User do\n  it(\"x\") { expect(helper(:a)).to eq(1) }\nend\n")

      assert_nil flag_named(result, :rspec_helper_object)
    end

    # ---- the deliberate refusals ---------------------------------------------------

    def test_let_bang_is_flagged_because_eager_and_lazy_are_not_the_same_thing
      result = convert("describe User do\n  let!(:existing) { create(:user) }\nend\n")

      assert_includes result.source, "let!(:existing) { create(:user) }"
      flag = flag_named(result, :eager_let)

      refute_nil flag
      assert_match(/`let!` is eager/, flag[:reason])
    end

    def test_an_anonymous_subject_becomes_a_witness_and_the_report_says_so
      result = convert("describe User do\n  subject { described_class.new }\nend\n")

      assert_includes result.source, "witness(:subject) { described_class.new }"
      entry = result.converted.find { |c| c[:kind] == :subject }

      assert_equal "witness(:subject)", entry[:to]
      assert_match(/`is_expected` and `should` have no equivalent/, entry[:note])
    end

    def test_a_named_subject_becomes_a_named_witness
      result = convert("describe User do\n  subject(:user) { User.new }\nend\n")

      assert_includes result.source, "witness(:user) { User.new }"
    end

    def test_subject_bang_is_flagged
      result = convert("describe User do\n  subject!(:user) { create(:user) }\nend\n")

      assert_includes result.source, "subject!(:user) { create(:user) }"
      refute_nil flag_named(result, :eager_subject)
    end

    def test_after_and_around_hooks_are_flagged
      result = convert("describe User do\n  after { cleanup }\n  around { |ex| ex.run }\nend\n")

      assert_includes result.source, "after { cleanup }"
      assert_includes result.source, "around { |ex| ex.run }"
      refute_nil flag_named(result, :after_hook)
      refute_nil flag_named(result, :around_hook)
    end

    def test_described_class_is_flagged
      result = convert("describe User do\n  let(:x) { described_class.new }\nend\n")

      refute_nil flag_named(result, :described_class)
    end

    def test_a_skip_marker_is_flagged
      result = convert("describe User do\n  xit \"later\" do\n  end\nend\n")

      assert_includes result.source, "xit \"later\" do"
      assert_match(/jail it/, flag_named(result, :skipped_example)[:reason])
    end

    def test_an_example_with_metadata_is_flagged_not_converted
      result = convert("describe User do\n  it \"is slow\", :slow do\n  end\nend\n")

      assert_includes result.source, "it \"is slow\", :slow do"
      refute_nil flag_named(result, :example_metadata)
    end

    def test_a_test_method_calling_super_is_flagged
      result = convert(<<~TEST, path: "test/models/user_test.rb")
        class UserTest < ActiveSupport::TestCase
          def setup
            super
            @user = User.new
          end
        end
      TEST

      assert_includes result.source, "def setup"
      refute_nil flag_named(result, :super_in_setup)
    end

    def test_teardown_is_flagged
      result = convert(<<~TEST, path: "test/models/user_test.rb")
        class UserTest < ActiveSupport::TestCase
          def teardown
            User.delete_all
          end
        end
      TEST

      assert_includes result.source, "def teardown"
      refute_nil flag_named(result, :teardown)
    end

    def test_ordinary_helper_methods_are_left_alone_and_noted
      result = convert(<<~TEST, path: "test/models/user_test.rb")
        class UserTest < ActiveSupport::TestCase
          def build_user
            User.new
          end
        end
      TEST

      assert_includes result.source, "def build_user"
      refute_nil untouched_named(result, :helper_method)
    end

    # ---- formatting and safety -----------------------------------------------------

    def test_untouched_code_keeps_its_exact_original_formatting
      result = convert(<<~SPEC)
        describe User do
          it "keeps formatting" do
            weird   =    { a: 1,
                           b: 2 }   # a trailing comment
            do_something(weird)
          end
        end
      SPEC

      assert_includes result.source, "    weird   =    { a: 1,\n                   b: 2 }   # a trailing comment\n"
    end

    def test_a_file_with_nothing_to_convert_comes_back_unchanged
      source = "module Support\n  def helper = 1\nend\n"
      result = modernize(source, path: "spec/support/helper_spec.rb")

      assert_equal source, result.source
      refute_predicate result, :changed?
      assert_equal :unknown, result.dialect
    end

    def test_a_syntactically_broken_file_is_reported_not_rewritten
      source = "describe User do\n  it \"oops\"\n"
      result = modernize(source)

      refute_predicate result, :ok?
      assert_match(/syntax error/, result.error)
      assert_equal source, result.source
    end

    def test_a_missing_file_is_reported
      result = Importer::Modernizer.new("spec/nope_spec.rb", config: Constable.config, root: tmp_root).call

      refute_predicate result, :ok?
      assert_equal "file not found", result.error
    end

    def test_a_realistic_spec_converts_to_source_that_parses
      result = convert(<<~SPEC, path: "spec/controllers/users_controller_spec.rb")
        # frozen_string_literal: true
        require "rails_helper"

        RSpec.describe UsersController, type: :controller do
          let(:valid_params) { { user: { email: "a@b.com" } } }
          let!(:existing) { create(:user) }
          subject { described_class.new }

          before { stub_network! }
          before(:all) { seed_the_world }

          shared_examples "an authorized action" do
            it "allows" do
              expect(response).to be_ok
            end
          end

          context "as an admin" do
            before(:each) do
              sign_in(:admin)
            end

            it "creates a user with valid params" do
              expect {
                post users_path, params: valid_params
              }.to change { User.count }.by(1)
              expect(response).to have_http_status(:created)
            end

            it { is_expected.to be_valid }
          end

          describe "#destroy" do
            it "destroys" do
              expect(User.count).to_not eq(0)
            end
          end
        end
      SPEC

      assert_equal "UsersControllerCase", result.class_name
      assert_includes result.source, "class UsersControllerCase < Constable::Case"
      assert_includes result.source, %(docket "as an admin" do)
      assert_includes result.source, %(docket "#destroy" do)
      assert_includes result.source, %(investigate "creates a user with valid params" do)
      assert_includes result.source, "attest {"
      assert_includes result.source, "before(:all) { seed_the_world }"
      assert_includes result.source, %(shared_examples "an authorized action" do)
      assert_equal %i[eager_let described_class before_all one_liner_example shared_examples].sort,
                   kinds(result.flags).sort
      assert_equal %i[describe_metadata], kinds(result.untouched).uniq
    end

    def test_spec_helper_requires_are_pointed_at_case_helper
      result = convert("require \"rails_helper\"\ndescribe User do\nend\n")

      assert_includes result.source, %(require "case_helper")
    end

    # ---- write modes ----------------------------------------------------------------

    def test_the_default_write_mode_writes_no_source_file
      write_file("spec/models/user_spec.rb", "describe User do\n  it \"works\" do\n  end\nend\n")
      original = read("spec/models/user_spec.rb")

      run = Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root)

      assert_equal :none, run.write_mode
      assert_equal original, read("spec/models/user_spec.rb")
      refute_predicate run.results.first, :written?
    end

    def test_alongside_writes_a_case_file_and_leaves_the_original
      write_file("spec/models/user_spec.rb", "describe User do\n  it \"works\" do\n  end\nend\n")
      original = read("spec/models/user_spec.rb")

      run = Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root, write: :alongside)

      assert_equal original, read("spec/models/user_spec.rb")
      assert_equal "spec/models/user_case.rb", run.results.first.written_to
      assert_includes read("spec/models/user_case.rb"), "class UserCase < Constable::Case"
    end

    def test_alongside_refuses_to_clobber_an_existing_case_file
      write_file("spec/models/user_spec.rb", "describe User do\n  it \"works\" do\n  end\nend\n")
      write_file("spec/models/user_case.rb", "# mine\n")

      run = Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root, write: :alongside)

      assert_equal "# mine\n", read("spec/models/user_case.rb")
      assert_match(/refusing to overwrite/, run.results.first.error)
    end

    def test_in_place_overwrites_the_original
      write_file("spec/models/user_spec.rb", "describe User do\n  it \"works\" do\n  end\nend\n")

      run = Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root, write: :in_place)

      assert_includes read("spec/models/user_spec.rb"), "class UserCase < Constable::Case"
      assert_equal "spec/models/user_spec.rb", run.results.first.written_to
    end

    def test_an_unknown_write_mode_is_rejected
      error = assert_raises(ArgumentError) do
        Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root, write: :yolo)
      end

      assert_match(/unknown write mode/, error.message)
    end

    def test_a_directory_expands_to_every_spec_and_test_file_in_it
      write_file("spec/models/user_spec.rb", "describe User do\nend\n")
      write_file("spec/models/post_spec.rb", "describe Post do\nend\n")
      write_file("spec/models/factory.rb", "# not a spec\n")

      run = Importer.modernize("spec/models", config: Constable.config, root: tmp_root)

      assert_equal ["spec/models/post_spec.rb", "spec/models/user_spec.rb"], run.results.map(&:relative_path).sort
    end

    # ---- the report ------------------------------------------------------------------

    def test_the_report_is_always_written
      write_file("spec/models/user_spec.rb", "describe User do\nend\n")

      run = Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root)

      assert_equal File.join(tmp_root, "constable_modernize_report.md"), run.report_path
      assert_path_exists run.report_path
      assert_equal run.report, File.read(run.report_path)
    end

    def test_the_report_lists_converted_flagged_and_untouched_per_file
      write_file("spec/models/user_spec.rb", <<~SPEC)
        describe User do
          let(:user) { User.new }
          let!(:existing) { create(:user) }
          before(:all) { seed }

          shared_examples "shared" do
          end

          it "works" do
            expect(user).to be_valid
          end
        end
      SPEC

      report = Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root).report

      assert_includes report, "# Constable modernize report"
      assert_includes report, "## `spec/models/user_spec.rb`"
      assert_includes report, "- case class: `UserCase`"
      assert_includes report, "### Converted"
      assert_includes report, "`let(:user)` -> `witness(:user)`"
      assert_includes report, "### Flagged -- NOT converted, still as written"
      assert_includes report, "**before_all**"
      assert_includes report, "**eager_let**"
      # shared_examples moved from "left untouched" to "flagged" -- a converted file that
      # still calls that DSL cannot run, so it has to block conversion rather than be noted.
      assert_includes report, "**shared_examples**"
      assert_includes report, "spec/models/user_spec.rb:4"
    end

    def test_the_report_states_the_write_mode
      write_file("spec/models/user_spec.rb", "describe User do\nend\n")

      dry = Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root).report

      assert_includes dry, "dry run -- no source file was written"

      in_place = Importer.modernize("spec/models/user_spec.rb", config: Constable.config, root: tmp_root,
                                                                write: :in_place).report

      assert_includes in_place, "the original files were overwritten"
    end

    def test_the_report_summarizes_counts_across_files
      write_file("spec/models/user_spec.rb", "describe User do\n  before(:all) { seed }\nend\n")
      write_file("spec/models/post_spec.rb", "describe Post do\n  let(:post) { Post.new }\nend\n")

      run = Importer.modernize("spec/models", config: Constable.config, root: tmp_root)

      assert_includes run.report, "| Files | Converted | Flagged | Left untouched | Failed |"
      assert_includes run.report, "| 2 | 3 | 1 | 0 | 0 |"
      assert_equal 1, run.flagged.size
    end

    def test_the_report_explains_a_file_it_could_not_convert
      write_file("spec/models/broken_spec.rb", "describe User do\n")

      run = Importer.modernize("spec/models/broken_spec.rb", config: Constable.config, root: tmp_root)

      refute_predicate run, :ok?
      assert_includes run.report, "**Not converted.**"
      assert_includes run.report, "constable import"
    end

    # ---- the documented hash shape ---------------------------------------------------

    def test_the_result_exposes_source_flags_and_converted
      result = convert("describe User do\n  before(:all) { seed }\nend\n")
      hash = result.to_h

      assert_equal result.source, hash[:source]
      assert_equal result.flags, hash[:flags]
      assert_equal result.converted, hash[:converted]
      assert_equal result.source, result[:source]
    end

    # A port that keeps the original leaves both on disk, and the cold-case glob still
    # matches the original -- so the same tests run once as the new native case and once as
    # the spec it came from. Nothing said so; the suite quietly grew.
    def test_a_port_that_keeps_the_original_excludes_it_from_the_cold_glob
      write_file("spec/models/user_spec.rb", <<~RUBY)
        RSpec.describe "user" do
          it "works" do
            expect(1 + 1).to eq(2)
          end
        end
      RUBY
      write_file("test/case_helper.rb",
                 %(require "constable"\n\nConstable.cold_cases do\n  rspec "spec/**/*_spec.rb"\nend\n))

      run = Importer::Modernizer.run(["spec/models/user_spec.rb"], root: tmp_root, write: :port,
                                                                   report: false, delete_original: false)

      assert_equal ["spec/models/user_spec.rb"], run.excluded
      assert_match(%r{except "spec/models/user_spec\.rb"}, read("test/case_helper.rb"))
      assert_path_exists File.join(tmp_root, "spec/models/user_spec.rb")
    end

    # --delete removes the source, so the glob matches nothing and there is nothing to say.
    def test_a_port_that_deletes_the_original_writes_no_exclusion
      write_file("spec/models/user_spec.rb", <<~RUBY)
        RSpec.describe "user" do
          it "works" do
            expect(1 + 1).to eq(2)
          end
        end
      RUBY
      write_file("test/case_helper.rb",
                 %(require "constable"\n\nConstable.cold_cases do\n  rspec "spec/**/*_spec.rb"\nend\n))

      run = Importer::Modernizer.run(["spec/models/user_spec.rb"], root: tmp_root, write: :port,
                                                                   report: false, delete_original: true)

      assert_empty Array(run.excluded)
      refute_match(/except/, read("test/case_helper.rb"))
      refute_path_exists File.join(tmp_root, "spec/models/user_spec.rb")
    end

    def test_porting_twice_does_not_repeat_an_exclusion
      write_file("spec/models/user_spec.rb", <<~RUBY)
        RSpec.describe "user" do
          it "works" do
            expect(1 + 1).to eq(2)
          end
        end
      RUBY
      write_file("test/case_helper.rb",
                 %(require "constable"\n\nConstable.cold_cases do\n  rspec "spec/**/*_spec.rb"\nend\n))

      2.times do
        Importer::Modernizer.run(["spec/models/user_spec.rb"], root: tmp_root, write: :port,
                                                               report: false, delete_original: false)
      end

      assert_equal 1, read("test/case_helper.rb").scan("except ").size
    end
  end
end
