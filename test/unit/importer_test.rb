# frozen_string_literal: true

require_relative "../helper"

module Constable
  # The reopener is the default import mode, so these tests are mostly about proving the
  # two promises it makes: the original body is never altered, and existing config is
  # never lost.
  class ImporterTest < TestCase
    RSPEC_BODY = <<~SPEC
      # frozen_string_literal: true
      require "rails_helper"

      RSpec.describe UsersController, type: :controller do
        let(:valid_params) { { user: { email: "a@b.com" } } }

        it "creates a user" do
          post users_path, params: valid_params
          expect(response).to have_http_status(:created)
        end
      end
    SPEC

    MINITEST_BODY = <<~TEST
      # frozen_string_literal: true
      require "test_helper"

      class UserTest < ActiveSupport::TestCase
        def test_is_valid
          assert User.new(email: "a@b.com").valid?
        end
      end
    TEST

    def config_for(root = tmp_root) = Config.load(root: root)

    def import(**kwargs)
      defaults = { from: :rspec, config: config_for, root: tmp_root }
      Importer.run(**defaults, **kwargs)
    end

    def seed_rspec(*relative_paths)
      relative_paths.each { |path| write_file(path, RSPEC_BODY) }
    end

    def read(relative_path) = File.read(File.join(tmp_root, relative_path))

    LINK_PATH = "test/cold_cases.rb"

    # The link lives in test/cold_cases.rb now, as executable Ruby rather than a config
    # key, so read it the way the importer does -- by pattern, without executing it.
    def cold_cases_in_config
      path = File.join(tmp_root, LINK_PATH)
      return [] unless File.exist?(path)

      File.read(path).scan(/^\s*(?:rspec|minitest)\s+"([^"]+)"/).flatten
    end

    def link_file = read(LINK_PATH)

    # ---- discovery ---------------------------------------------------------------

    def test_an_empty_project_imports_nothing_and_says_so
      result = import

      refute_predicate result, :any_changes?
      assert_empty result.changes
      assert_empty result.globs_added
      assert_equal 0, result.imported_count
    end

    def test_discovery_finds_every_spec_file_for_the_engine
      seed_rspec("spec/models/user_spec.rb", "spec/controllers/users_controller_spec.rb")
      write_file("spec/support/factories.rb", "# not a spec\n")

      reopener = Importer::Reopener.new(from: :rspec, config: config_for, root: tmp_root)

      assert_equal ["spec/controllers/users_controller_spec.rb", "spec/models/user_spec.rb"], reopener.discover
    end

    def test_minitest_discovery_uses_the_test_directory
      write_file("test/models/user_test.rb", MINITEST_BODY)
      write_file("spec/models/user_spec.rb", RSPEC_BODY)

      reopener = Importer::Reopener.new(from: :minitest, config: config_for, root: tmp_root)

      assert_equal ["test/models/user_test.rb"], reopener.discover
    end

    def test_an_unknown_engine_is_rejected_loudly
      error = assert_raises(ArgumentError) { import(from: :cucumber) }

      assert_match(/unknown import source/, error.message)
    end

    def test_an_unknown_strategy_is_rejected_loudly
      error = assert_raises(ArgumentError) { import(strategy: :yolo) }

      assert_match(/unknown strategy/, error.message)
    end

    # ---- superclass swap ---------------------------------------------------------

    def test_the_superclass_swap_preserves_the_original_body_byte_for_byte
      path = write_file("spec/models/user_spec.rb", RSPEC_BODY)
      original_bytes = File.binread(path)

      import(paths: ["spec/models/user_spec.rb"], strategy: :superclass)
      rewritten = File.binread(path)

      assert_includes rewritten, original_bytes
      assert_equal original_bytes, rewritten.split("< Constable::ColdCase::RSpec\n", 2).last.sub(/end\n\z/, "")
    end

    def test_the_swap_only_adds_a_header_and_a_trailing_end
      write_file("spec/models/user_spec.rb", RSPEC_BODY)

      import(paths: ["spec/models/user_spec.rb"], strategy: :superclass)
      lines = read("spec/models/user_spec.rb").lines

      assert_equal "class LegacyUserSpec < Constable::ColdCase::RSpec\n", lines[4]
      assert_equal "end\n", lines.last
      assert_equal RSPEC_BODY.lines.size + 6, lines.size
    end

    def test_the_wrapped_file_is_still_valid_ruby
      write_file("spec/models/user_spec.rb", RSPEC_BODY)
      import(paths: ["spec/models/user_spec.rb"], strategy: :superclass)

      assert RubyVM::InstructionSequence.compile(read("spec/models/user_spec.rb"))
    end

    def test_a_body_without_a_trailing_newline_still_wraps_cleanly
      write_file("spec/models/user_spec.rb", "describe X do\nend")

      import(paths: ["spec/models/user_spec.rb"], strategy: :superclass)

      assert read("spec/models/user_spec.rb").end_with?("describe X do\nend\nend\n")
    end

    def test_minitest_files_get_the_minitest_cold_case_superclass
      write_file("test/models/user_test.rb", MINITEST_BODY)

      import(from: :minitest, paths: ["test/models/user_test.rb"], strategy: :superclass)

      assert_includes read("test/models/user_test.rb"), "class LegacyUserTest < Constable::ColdCase::Minitest"
    end

    # ---- class-name derivation ---------------------------------------------------

    def test_class_name_derives_from_the_file_basename
      assert_equal "LegacyUsersControllerSpec",
                   Importer::Reopener.class_name_for("spec/controllers/users_controller_spec.rb")
    end

    def test_class_name_drops_the_engine_root_directory
      assert_equal "LegacyUserSpec", Importer::Reopener.class_name_for("spec/models/user_spec.rb")
      assert_equal "LegacyUserTest", Importer::Reopener.class_name_for("test/models/user_test.rb")
    end

    def test_class_name_widens_with_a_parent_directory_on_a_collision
      taken = ["LegacyUserSpec"]

      assert_equal "LegacyModelsUserSpec", Importer::Reopener.class_name_for("spec/models/user_spec.rb", taken: taken)
    end

    def test_class_name_widens_twice_when_the_parent_also_collides
      taken = %w[LegacyUserSpec LegacyModelsUserSpec]

      assert_equal "LegacyAdminModelsUserSpec",
                   Importer::Reopener.class_name_for("spec/admin/models/user_spec.rb", taken: taken)
    end

    def test_class_name_falls_back_to_a_numeric_suffix_when_it_runs_out_of_parents
      taken = ["LegacyUserSpec"]

      assert_equal "LegacyUserSpec2", Importer::Reopener.class_name_for("user_spec.rb", taken: taken)
    end

    def test_class_name_is_always_a_valid_constant
      %w[spec/1_legacy/9lives_spec.rb spec/odd-name/some.thing_spec.rb].each do |path|
        name = Importer::Reopener.class_name_for(path)

        assert_match(/\A[A-Z][A-Za-z0-9]*\z/, name, "#{path} produced #{name.inspect}")
      end
    end

    def test_a_real_import_hands_out_collision_free_names
      seed_rspec("spec/models/user_spec.rb", "spec/controllers/user_spec.rb")

      result = import(strategy: :superclass)
      names = result.changes.map(&:class_name)

      assert_equal names.uniq, names
      assert_equal 2, names.size
    end

    # ---- config path match --------------------------------------------------------

    def test_auto_strategy_prefers_a_single_glob_over_touching_files
      seed_rspec("spec/models/user_spec.rb", "spec/models/post_spec.rb", "spec/controllers/users_spec.rb")

      result = import

      assert_equal ["spec/**/*_spec.rb"], result.globs_added
      assert_empty result.changes
      assert_equal [:config_path_match], result.routes
      assert_equal 3, result.imported_count
    end

    def test_a_glob_is_only_used_when_it_cleanly_covers_the_directory
      seed_rspec("spec/models/user_spec.rb", "spec/models/post_spec.rb", "spec/controllers/keep_spec.rb")

      # Only the models directory is being imported, so a spec/**/* glob would swallow a
      # file the user didn't ask for.
      result = import(paths: ["spec/models"])

      assert_equal ["spec/models/**/*_spec.rb"], result.globs_added
      assert_empty result.changes
    end

    def test_files_no_glob_can_cover_fall_back_to_the_superclass_swap
      seed_rspec("spec/models/user_spec.rb", "spec/models/post_spec.rb", "spec/controllers/keep_spec.rb",
                 "spec/controllers/take_spec.rb")

      result = import(paths: ["spec/models", "spec/controllers/take_spec.rb"])

      assert_equal ["spec/models/**/*_spec.rb"], result.globs_added
      assert_equal ["spec/controllers/take_spec.rb"], result.files_changed
      assert_equal %i[config_path_match superclass_swap], result.routes
      assert_includes read("spec/controllers/keep_spec.rb"), "RSpec.describe"
      refute_includes read("spec/controllers/keep_spec.rb"), "ColdCase"
    end

    def test_config_strategy_changes_no_source_files_at_all
      seed_rspec("spec/models/user_spec.rb", "spec/controllers/keep_spec.rb", "spec/controllers/take_spec.rb")

      result = import(paths: ["spec/models", "spec/controllers/take_spec.rb"], strategy: :config)

      assert_empty result.changes
      assert_equal ["spec/models/**/*_spec.rb", "spec/controllers/take_spec.rb"].sort, result.globs_added.sort
      assert_equal RSPEC_BODY, read("spec/controllers/take_spec.rb")
    end

    def test_superclass_strategy_never_touches_the_config
      seed_rspec("spec/models/user_spec.rb", "spec/models/post_spec.rb")

      result = import(strategy: :superclass)

      assert_empty result.globs_added
      refute_predicate result, :config_changed?
      assert_equal 2, result.changes.size
    end

    # The link is Ruby in the test tree now, not a config key, so config.yml is not
    # touched at all -- and the settings a user wrote there cannot be disturbed by an
    # import, which is most of what the old YAML-rewriting tests were guarding.
    def test_import_writes_the_link_file_and_leaves_config_alone
      seed_rspec("spec/models/user_spec.rb")
      write_config("# Hand-written, and the comments matter.\nwarrants: true\nparole_period: 3\n")

      import(paths: ["spec/models"])

      assert_equal ["spec/**/*_spec.rb"], cold_cases_in_config
      assert_equal "# Hand-written, and the comments matter.\nwarrants: true\nparole_period: 3\n",
                   read(Config::CONFIG_PATH)

      reloaded = Config.load(root: tmp_root)

      assert_predicate reloaded, :warrants?
      assert_equal 3, reloaded.parole_period
    end

    # The file exists to be read by a person, so it has to say what it is and how to undo
    # it -- not just carry the globs.
    def test_the_link_file_explains_itself
      seed_rspec("spec/models/user_spec.rb")
      import(paths: ["spec/models"])

      assert_match(/RSpec is linked to Constable/, link_file)
      assert_match(/Delete this file to unlink them/, link_file)
      assert_match(/Constable\.cold_cases do/, link_file)
      assert_match(%r{rspec "spec/\*\*/\*_spec\.rb"}, link_file)
      assert_match(/# 1 file$/, link_file)
    end

    # It is loadable Ruby, not a template with holes in it.
    def test_the_link_file_is_valid_ruby_that_declares_the_globs
      seed_rspec("spec/models/user_spec.rb", "spec/models/post_spec.rb")
      import

      Constable.reset!
      Constable.configuration.instance_eval(File.read(File.join(tmp_root, LINK_PATH)).sub("Constable.", "self."))

      assert_equal({ rspec: ["spec/**/*_spec.rb"] }, Constable.configuration.cold_case_links.globs)
    end

    def test_a_second_import_does_not_duplicate_the_glob
      seed_rspec("spec/models/user_spec.rb")
      import
      import(config: Config.load(root: tmp_root))

      assert_equal ["spec/**/*_spec.rb"], cold_cases_in_config
    end

    def test_minitest_writes_a_minitest_link
      write_file("test/legacy/user_test.rb",
                 "require \"minitest/autorun\"\nclass UserTest < Minitest::Test\n  def test_a; end\nend\n")
      import(from: :minitest)

      assert_match(/Minitest is linked to Constable/, link_file)
      assert_match(%r{minitest "test/\*\*/\*_test\.rb"}, link_file)
    end

    # ---- dry run -----------------------------------------------------------------

    def test_dry_run_writes_nothing_but_reports_everything
      seed_rspec("spec/models/user_spec.rb", "spec/controllers/keep_spec.rb", "spec/controllers/take_spec.rb")
      write_config("warrants: true\n")

      result = import(paths: ["spec/models", "spec/controllers/take_spec.rb"], dry_run: true)

      assert_predicate result, :dry_run?
      assert_predicate result, :any_changes?
      assert_equal ["spec/models/**/*_spec.rb"], result.globs_added
      assert_equal ["spec/controllers/take_spec.rb"], result.files_changed
      assert_equal RSPEC_BODY, read("spec/controllers/take_spec.rb")
      refute_includes read(Config::CONFIG_PATH), "cold_cases"
    end

    def test_importer_plan_is_a_dry_run
      seed_rspec("spec/models/user_spec.rb")

      result = Importer.plan(from: :rspec, config: config_for, root: tmp_root)

      assert_predicate result, :dry_run?
      assert_equal RSPEC_BODY, read("spec/models/user_spec.rb")
    end

    def test_a_change_can_say_exactly_what_it_did
      write_file("spec/models/user_spec.rb", RSPEC_BODY)
      result = import(paths: ["spec/models/user_spec.rb"], strategy: :superclass, dry_run: true)
      change = result.changes.first

      assert_equal :superclass_swap, change.action
      assert_equal "LegacyUserSpec", change.class_name
      assert_equal RSPEC_BODY, change.before
      assert_includes change.after, RSPEC_BODY
      assert_includes change.diff, "+class LegacyUserSpec < Constable::ColdCase::RSpec"
      assert_includes change.diff, "#{RSPEC_BODY.lines.size} unchanged lines (byte for byte)"
      assert_includes change.diff, "+end"
    end

    # ---- idempotence / skipping ---------------------------------------------------

    def test_a_file_already_reopened_is_skipped_not_double_wrapped
      seed_rspec("spec/models/user_spec.rb")
      import(paths: ["spec/models/user_spec.rb"], strategy: :superclass)
      once = read("spec/models/user_spec.rb")

      result = import(paths: ["spec/models/user_spec.rb"], strategy: :superclass)

      assert_equal once, read("spec/models/user_spec.rb")
      assert_empty result.changes
      assert_equal 1, result.skipped.size
      assert_match(/already a Constable::ColdCase::RSpec subclass/, result.skipped.first[:reason])
    end

    def test_a_file_already_matched_by_a_glob_is_skipped
      seed_rspec("spec/models/user_spec.rb")
      link_cold_cases(:rspec, "spec/models/**/*_spec.rb")

      result = import(config: Config.load(root: tmp_root))

      refute_predicate result, :any_changes?
      assert_equal 1, result.skipped.size
      assert_match(/already matched by a cold_cases glob/, result.skipped.first[:reason])
    end

    # A second import on a real suite skips every file it adopted the first time. Printing
    # one line each is over a thousand lines of the same sentence, so the reason is stated
    # once and the file list is capped.
    def test_the_skipped_list_is_grouped_and_capped
      seed_rspec(*(1..40).map { |n| "spec/models/model_#{n}_spec.rb" })
      link_cold_cases(:rspec, "spec/models/**/*_spec.rb")

      summary = import(config: Config.load(root: tmp_root)).summary

      assert_match(/40 files skipped -- already matched by a cold_cases glob/, summary)
      assert_match(/\.\.\. and 35 more/, summary)
      assert_operator summary.lines.size, :<, 20
    end

    # "Would adopt 0 files" and nothing else reads like a failure rather than a suite that
    # is already fully adopted.
    def test_a_fully_adopted_suite_says_so_and_points_somewhere
      seed_rspec("spec/models/user_spec.rb")
      link_cold_cases(:rspec, "spec/models/**/*_spec.rb")

      summary = import(config: Config.load(root: tmp_root)).summary

      assert_match(/Nothing to do -- every RSpec file is already adopted/, summary)
      assert_match(/constable modernize PATH --plan/, summary)
    end

    def test_running_the_glob_route_twice_does_not_duplicate_the_entry
      seed_rspec("spec/models/user_spec.rb", "spec/models/post_spec.rb")
      import
      import(config: Config.load(root: tmp_root))

      assert_equal ["spec/**/*_spec.rb"], cold_cases_in_config
    end

    # ---- reporting ----------------------------------------------------------------

    def test_the_summary_names_both_routes_and_the_files_they_touched
      seed_rspec("spec/models/user_spec.rb", "spec/controllers/keep_spec.rb", "spec/controllers/take_spec.rb")

      summary = import(paths: ["spec/models", "spec/controllers/take_spec.rb"]).summary

      assert_includes summary, "spec/models/**/*_spec.rb"
      assert_includes summary, "superclass swap"
      assert_includes summary, "spec/controllers/take_spec.rb -> class LegacyTakeSpec < Constable::ColdCase::RSpec"
    end

    # Written for somebody who has just typed the command and does not yet know what a
    # cold case is. The first version said "did reopen 1277 file(s)" -- "reopen" is this
    # code's internal word and means nothing to a reader, and "import" on its own suggests
    # the files were copied somewhere, which is the opposite of what happened. A real user
    # read it exactly that way.
    def test_the_summary_says_the_files_did_not_move
      seed_rspec("spec/models/user_spec.rb")

      summary = import.summary

      assert_match(/stay exactly where they are/, summary)
      assert_match(/not changed/, summary)
      refute_match(/reopen/, summary, "'reopen' is internal vocabulary")
    end

    def test_the_summary_shows_the_line_it_added
      seed_rspec("spec/models/user_spec.rb")

      summary = import.summary

      assert_match(/Constable\.cold_cases do/, summary)
      assert_match(%r{test/cold_cases\.rb}, summary)
      refute_match(%r{\.constable/config\.yml}, summary)
    end

    def test_the_summary_says_what_to_do_next
      seed_rspec("spec/models/user_spec.rb")

      summary = import.summary

      assert_match(/constable test --full/, summary)
      assert_match(/constable modernize/, summary)
    end

    def test_a_dry_run_does_not_suggest_next_steps
      seed_rspec("spec/models/user_spec.rb")

      summary = import(dry_run: true).summary

      assert_match(/Would adopt/, summary)
      refute_match(/Next:/, summary)
    end

    def test_result_to_h_is_serializable
      seed_rspec("spec/models/user_spec.rb")
      hash = import(strategy: :superclass).to_h

      assert_equal :rspec, hash[:from]
      assert_equal :superclass, hash[:strategy]
      assert_equal [:superclass_swap], hash[:routes]
      assert_equal "spec/models/user_spec.rb", hash[:changes].first[:path]
    end
  end
end
