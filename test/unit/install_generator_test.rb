# frozen_string_literal: true

require_relative "../helper"

require "yaml"
require "rails/generators"
require "generators/constable/install_generator"
require "generators/constable/import_generator"

module Constable
  # The installer is the first Constable code anyone reads, and everything it writes is a
  # template rather than executed code -- which means nothing here fails at author time.
  # So the suite compiles the generated Ruby, parses the generated YAML, and holds the
  # generated config against Config::DEFAULTS, because a template that drifts from the
  # code it configures is a silent bug in every new install until someone notices.
  class InstallGeneratorTest < TestCase
    EXPECTED_FILES = %w[
      test/case_helper.rb
      test/support/matchers.rb
      test/support/authenticatable.rb
      test/cases/example_case.rb
      .constable/config.yml
      .rubocop.yml
      .gitignore
    ].freeze

    def install(args = [])
      capture_stdout { Generators::InstallGenerator.start(args, destination_root: tmp_root) }
    end

    def generated(relative_path)
      File.read(File.join(tmp_root, relative_path))
    end

    def generated?(relative_path)
      File.exist?(File.join(tmp_root, relative_path))
    end

    # Compiling proves the file parses without running it -- these templates reference
    # Rails.root and a config/environment that don't exist inside a temp root.
    def assert_valid_ruby(relative_path)
      source = generated(relative_path)
      RubyVM::InstructionSequence.compile(source, relative_path)
    rescue SyntaxError => e
      flunk "#{relative_path} is not valid Ruby: #{e.message}"
    end

    # -- files produced ------------------------------------------------------

    def test_install_creates_every_expected_file
      install

      EXPECTED_FILES.each do |path|
        assert generated?(path), "expected the installer to create #{path}"
      end
    end

    def test_install_creates_nothing_outside_the_documented_list
      install

      written = Dir.glob(File.join(tmp_root, "**/*"), File::FNM_DOTMATCH)
                   .select { |path| File.file?(path) }
                   .map { |path| path.delete_prefix("#{tmp_root}/") }

      assert_equal EXPECTED_FILES.sort, written.sort
    end

    def test_skip_options_suppress_their_own_files
      install(["--skip-rubocop", "--skip-example", "--skip-support"])

      assert generated?("test/case_helper.rb")
      assert generated?(".constable/config.yml")
      refute generated?(".rubocop.yml")
      refute generated?("test/cases/example_case.rb")
      refute generated?("test/support/matchers.rb")
    end

    # -- generated Ruby is real Ruby ----------------------------------------

    def test_generated_case_helper_is_syntactically_valid_ruby
      install

      assert_valid_ruby("test/case_helper.rb")
    end

    def test_generated_example_case_is_syntactically_valid_ruby
      install

      assert_valid_ruby("test/cases/example_case.rb")
    end

    def test_generated_support_files_are_syntactically_valid_ruby
      install

      assert_valid_ruby("test/support/matchers.rb")
      assert_valid_ruby("test/support/authenticatable.rb")
    end

    # -- the case helper teaches the model ----------------------------------

    def test_case_helper_defines_one_base_class_per_tier
      install
      helper = generated("test/case_helper.rb")

      assert_match(/class UnitCase < Constable::Case\n  tier :unit\nend/, helper)
      assert_match(/class IntegrationCase < Constable::Case\b/, helper)
      assert_match(/tier :integration/, helper)
      assert_match(/class SystemCase < Constable::Case\b/, helper)
      assert_match(/tier :system/, helper)
    end

    # The tier base classes are only useful if they actually carry the request and
    # browser stacks -- an IntegrationCase with no `post` is the headline example of
    # the spec failing to run.
    def test_case_helper_wires_the_rails_support_modules
      install
      helper = generated("test/case_helper.rb")

      assert_match(/include Constable::RailsSupport::Integration/, helper)
      assert_match(/include Constable::RailsSupport::System/, helper)
    end

    # Capybara is not a dependency; a suite with no browser tests must still boot.
    def test_system_case_guards_the_capybara_include
      install

      assert_match(/include Constable::RailsSupport::System if defined\?\(Capybara\)/,
                   generated("test/case_helper.rb"))
    end

    def test_case_helper_boots_rails_and_requires_the_gem
      install
      helper = generated("test/case_helper.rb")

      assert_match(/ENV\["RAILS_ENV"\] \|\|= "test"/, helper)
      assert_match(%r{require_relative "\.\./config/environment"}, helper)
      assert_match(/require "constable"/, helper)
    end

    def test_case_helper_auto_requires_support_files
      install

      assert_match(
        %r{Dir\[Rails\.root\.join\("test/support/\*\*/\*\.rb"\)\]\.sort\.each \{ \|f\| require f \}},
        generated("test/case_helper.rb")
      )
    end

    def test_case_helper_carries_a_configure_block_with_commented_examples
      install
      helper = generated("test/case_helper.rb")

      assert_match(/Constable\.configure do \|c\|/, helper)
      assert_match(/# c\.before_suite do/, helper)
      assert_match(/# Constable::Matchers\.define\(:be_created\)/, helper)
    end

    # The two rules the helper exists to explain.
    def test_case_helper_explains_the_missing_before_all_and_per_test_memoization
      install
      helper = generated("test/case_helper.rb")

      assert_match(/There is no before\(:all\)/, helper)
      assert_match(/`witness` memoizes per test, and never per process/, helper)
    end

    def test_support_files_match_the_spec_examples
      install

      assert_match(/Constable::Matchers\.define\(:be_created\)/, generated("test/support/matchers.rb"))
      assert_match(/Constable::Matchers\.define\(:exist\)/, generated("test/support/matchers.rb"))

      authenticatable = generated("test/support/authenticatable.rb")

      assert_match(/module Authenticatable/, authenticatable)
      assert_match(/def sign_in\(user\)/, authenticatable)
      assert_match(/no shared-examples DSL/, authenticatable)
    end

    def test_example_case_uses_the_dsl_and_a_tier_base_class
      install
      example = generated("test/cases/example_case.rb")

      assert_match(/class ExampleCase < UnitCase/, example)
      assert_match(/witness\(:badge\)/, example)
      assert_match(/^  briefing do$/, example)
      assert_match(/investigate "runs the moment the gem is installed" do/, example)
      assert_match(/docket "with a nested docket" do/, example)
      assert_match(/attest\(/, example)
    end

    # -- config.yml is the reference, and cannot drift ----------------------

    def test_generated_config_is_valid_yaml
      install

      assert_kind_of Hash, YAML.safe_load(generated(".constable/config.yml"), permitted_classes: [], aliases: true)
    end

    def test_generated_config_keys_match_config_defaults_exactly
      install
      parsed = YAML.safe_load(generated(".constable/config.yml"), permitted_classes: [], aliases: true)

      assert_equal Config::DEFAULTS.keys.sort, parsed.keys.sort
      assert_equal Config::DEFAULTS["storage"].keys.sort, parsed["storage"].keys.sort
      assert_equal Config::DEFAULTS["tiers"].keys.sort, parsed["tiers"].keys.sort
    end

    # Not just the keys: every documented default is the actual default.
    def test_generated_config_values_match_config_defaults_exactly
      install
      parsed = YAML.safe_load(generated(".constable/config.yml"), permitted_classes: [], aliases: true)

      assert_equal Config::DEFAULTS, parsed
    end

    # And it survives the real loader, not just YAML.safe_load.
    def test_generated_config_round_trips_through_the_config_loader
      install
      Constable.reset!

      assert_equal Config::DEFAULTS, Constable.config.to_h
      assert_equal "sqlite", Constable.config.storage_adapter
      assert_empty Constable.config.cold_cases
      assert_equal 10, Constable.config.parole_period
      refute_predicate Constable.config, :warrants?
    end

    def test_generated_config_leaves_the_cold_case_example_commented_out
      install
      config = generated(".constable/config.yml")

      assert_match(/^cold_cases: \[\]$/, config)
      assert_match(%r{^#   - spec/controllers/\*\*/\*_spec\.rb$}, config)
    end

    # -- the :cold_case Gemfile group ---------------------------------------

    def write_gemfile(body = "source \"https://rubygems.org\"\n\ngem \"rails\"\n")
      write_file("Gemfile", body)
    end

    def write_legacy_spec
      write_file("spec/models/user_spec.rb", "describe User do; end\n")
    end

    def write_legacy_test
      write_file("test/models/user_test.rb", "class UserTest < Minitest::Test; end\n")
    end

    def test_cold_case_group_is_appended_when_a_legacy_suite_exists
      write_gemfile
      write_legacy_spec
      install

      gemfile = generated("Gemfile")

      assert_match(/^group :cold_case do$/, gemfile)
      assert_match(/gem "rspec-rails"/, gemfile)
      assert_match(/delete the group/, gemfile)
    end

    # Only the engines this repo has files for. A pure-RSpec app should not be handed a
    # minitest dependency for a migration it is never going to do.
    def test_only_the_engines_with_files_present_are_added
      write_gemfile
      write_legacy_spec
      install

      refute_match(/gem "minitest"/, generated("Gemfile"))
    end

    def test_both_engines_are_added_when_both_suites_exist
      write_gemfile
      write_legacy_spec
      write_legacy_test
      install

      gemfile = generated("Gemfile")
      assert_match(/gem "rspec-rails"/, gemfile)
      assert_match(/gem "minitest"/, gemfile)
    end

    # The bug this guards. Any app adopting Constable *from RSpec* already declares
    # rspec-rails, and a second declaration is not a style problem: Bundler refuses to
    # parse the Gemfile at all, so the install leaves the app unbootable.
    def test_a_gem_the_gemfile_already_declares_is_never_declared_twice
      write_gemfile("source \"https://rubygems.org\"\n\ngem \"rspec-rails\", \"~> 8.0\"\n")
      write_legacy_spec
      install

      assert_equal 1, generated("Gemfile").scan(/gem ["']rspec-rails["']/).size
    end

    def test_the_group_is_skipped_entirely_when_every_engine_is_already_declared
      write_gemfile("source \"https://rubygems.org\"\n\ngem \"rspec-rails\"\n")
      write_legacy_spec
      install

      refute_match(/group :cold_case/, generated("Gemfile"))
    end

    # A commented-out gem line is a suggestion, not a declaration.
    def test_a_commented_out_gem_line_does_not_count_as_declared
      write_gemfile("source \"https://rubygems.org\"\n\n# gem \"rspec-rails\"\n")
      write_legacy_spec
      install

      assert_match(/^  gem "rspec-rails"$/, generated("Gemfile"))
    end

    # --- the blotter is machine state ------------------------------------------------

    def test_install_ignores_the_blotter
      install

      assert_match(%r{/\.constable/\*\.sqlite3}, generated(".gitignore"))
    end

    def test_an_existing_gitignore_is_appended_to_not_replaced
      write_file(".gitignore", "/log/*.log\n")
      install

      gitignore = generated(".gitignore")
      assert_match(%r{/log/\*\.log}, gitignore)
      assert_match(%r{/\.constable/\*\.sqlite3}, gitignore)
    end

    def test_the_blotter_is_not_ignored_twice_when_run_again
      install
      install(["--force"])

      assert_equal 1, generated(".gitignore").scan(%r{^/\.constable/\*\.sqlite3$}).size
    end

    def test_cold_case_group_is_appended_only_once_when_run_twice
      write_gemfile
      write_legacy_spec
      install
      install(["--force"])

      assert_equal 1, generated("Gemfile").scan(/^group :cold_case do$/).size
    end

    def test_existing_gemfile_content_is_preserved
      write_gemfile("source \"https://rubygems.org\"\n\ngem \"rails\"\ngem \"puma\"\n")
      write_legacy_spec
      install

      assert_match(/gem "puma"/, generated("Gemfile"))
    end

    def test_a_minitest_suite_also_counts_as_something_to_import
      write_gemfile
      write_file("test/models/user_test.rb", "class UserTest < ActiveSupport::TestCase; end\n")
      install

      assert_match(/^group :cold_case do$/, generated("Gemfile"))
    end

    # A greenfield app gets no extra dependencies for a migration it will never do.
    def test_cold_case_group_is_skipped_when_there_is_nothing_to_import
      write_gemfile
      install

      refute_match(/cold_case/, generated("Gemfile"))
    end

    def test_the_installers_own_example_case_does_not_count_as_a_legacy_suite
      write_gemfile
      install

      assert generated?("test/cases/example_case.rb")
      refute_match(/cold_case/, generated("Gemfile"))
    end

    def test_skip_gemfile_leaves_the_gemfile_alone
      write_gemfile
      write_legacy_spec
      install(["--skip-gemfile"])

      refute_match(/cold_case/, generated("Gemfile"))
    end

    def test_a_missing_gemfile_is_reported_rather_than_created
      output = install

      refute generated?("Gemfile")
      assert_match(/Gemfile not found/, output)
    end

    # -- .rubocop.yml merging ------------------------------------------------

    def test_rubocop_config_is_created_when_absent
      install
      rubocop = generated(".rubocop.yml")

      assert_match(/^require:$/, rubocop)
      assert_match(/^  - rubocop-constable$/, rubocop)
      assert_match(/ColdCase/, rubocop)
    end

    def test_existing_rubocop_require_list_gains_one_entry_and_keeps_everything_else
      write_file(".rubocop.yml", <<~YAML)
        require:
          - rubocop-rails

        AllCops:
          TargetRubyVersion: 3.1

        # We disable this on purpose, see PR #412.
        Style/Documentation:
          Enabled: false
      YAML
      install

      rubocop = generated(".rubocop.yml")

      assert_match(/^  - rubocop-rails$/, rubocop)
      assert_match(/^  - rubocop-constable$/, rubocop)
      assert_match(/TargetRubyVersion: 3\.1/, rubocop)
      assert_match(/# We disable this on purpose, see PR #412\./, rubocop)
      assert_match(%r{Style/Documentation:\n  Enabled: false}, rubocop)

      parsed = YAML.safe_load(rubocop, permitted_classes: [], aliases: true)

      assert_equal %w[rubocop-rails rubocop-constable], parsed["require"]
      assert_equal 3.1, parsed["AllCops"]["TargetRubyVersion"]
    end

    def test_an_inline_require_is_promoted_to_a_list_holding_both
      write_file(".rubocop.yml", "require: rubocop-performance\n\nAllCops:\n  NewCops: enable\n")
      install

      parsed = YAML.safe_load(generated(".rubocop.yml"), permitted_classes: [], aliases: true)

      assert_equal %w[rubocop-performance rubocop-constable], parsed["require"]
      assert_equal "enable", parsed["AllCops"]["NewCops"]
    end

    def test_a_rubocop_config_with_no_require_gets_the_snippet_appended
      write_file(".rubocop.yml", "AllCops:\n  NewCops: enable\n")
      install

      rubocop = generated(".rubocop.yml")
      parsed  = YAML.safe_load(rubocop, permitted_classes: [], aliases: true)

      assert_equal ["rubocop-constable"], parsed["require"]
      assert_equal "enable", parsed["AllCops"]["NewCops"]
      assert_match(/NewCops: enable/, rubocop)
    end

    def test_rubocop_config_is_left_untouched_on_a_second_run
      write_file(".rubocop.yml", "require:\n  - rubocop-rails\n")
      install
      first = generated(".rubocop.yml")
      install(["--force"])

      assert_equal first, generated(".rubocop.yml")
      assert_equal 1, generated(".rubocop.yml").scan("rubocop-constable").size
    end

    def test_skip_rubocop_never_touches_the_file
      write_file(".rubocop.yml", "AllCops:\n  NewCops: enable\n")
      install(["--skip-rubocop"])

      assert_equal "AllCops:\n  NewCops: enable\n", generated(".rubocop.yml")
    end

    # -- discoverability -----------------------------------------------------

    def test_generators_are_discoverable_under_the_constable_namespace
      assert_equal "constable:install", Generators::InstallGenerator.namespace
      assert_equal "constable:import", Generators::ImportGenerator.namespace
    end

    def test_generators_declare_a_source_root_and_a_description
      assert_equal File.expand_path("../../lib/generators/constable/templates", __dir__),
                   Generators::InstallGenerator.source_root
      assert_equal Generators::InstallGenerator.source_root, Generators::ImportGenerator.source_root

      refute_empty Generators::InstallGenerator.desc.to_s
      refute_empty Generators::ImportGenerator.desc.to_s
    end

    def test_install_generator_exposes_its_skip_options
      options = Generators::InstallGenerator.class_options

      assert_includes options.keys, :skip_gemfile
      assert_includes options.keys, :skip_rubocop
      # --force comes free from Thor::Actions and is not redefined here.
      assert_includes options.keys, :force
    end

    def test_import_generator_validates_its_options_before_touching_the_importer
      # debug: true makes Thor re-raise instead of printing and exiting.
      error = assert_raises(Thor::Error) do
        capture_stdout do
          Generators::ImportGenerator.start(["--from=cucumber"], destination_root: tmp_root, debug: true)
        end
      end

      assert_match(/--from must be one of rspec, minitest/, error.message)

      error = assert_raises(Thor::Error) do
        capture_stdout do
          Generators::ImportGenerator.start(["--strategy=vibes"], destination_root: tmp_root, debug: true)
        end
      end

      assert_match(/--strategy must be one of reopen, modernize/, error.message)
    end
  end
end
