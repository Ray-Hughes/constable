# frozen_string_literal: true

require_relative "../helper"

require "English"
require "rails/generators"
require "generators/constable/base"
require "generators/constable/channel/channel_generator"
require "generators/constable/controller/controller_generator"
require "generators/constable/generator/generator_generator"
require "generators/constable/helper/helper_generator"
require "generators/constable/integration/integration_generator"
require "generators/constable/job/job_generator"
require "generators/constable/mailbox/mailbox_generator"
require "generators/constable/mailer/mailer_generator"
require "generators/constable/model/model_generator"
require "generators/constable/resource/resource_generator"
require "generators/constable/scaffold/scaffold_generator"
require "generators/constable/system/system_generator"

module Constable
  # `rails generate scaffold Post title:string` writes test files by asking whichever
  # generator is registered as the app's test framework. Registering Constable there is
  # the whole point of these generators, so the suite has to prove three separate things,
  # and each one fails silently in production if it isn't checked here:
  #
  #   1. Rails can *find* them. Resolution is by namespace, derived from the class name,
  #      converted back into a file path -- so a generator in the wrong directory is a
  #      generator that never runs, with no error anywhere.
  #   2. What they write is real Constable. Templates are strings until someone runs them;
  #      nothing in a .tt file fails at author time.
  #   3. Registering with Rails did not cost `require "constable"` its ability to load
  #      without Rails, which the :unit tier depends on absolutely.
  class GeneratorsTest < TestCase
    # generator, arguments, and the case file it must write: path, class, tier base class.
    GENERATED = [
      [Generators::ModelGenerator,       %w[Post title:string published:boolean],
       "test/cases/models/post_case.rb", "PostCase", "UnitCase"],
      [Generators::ResourceGenerator,    %w[Author name:string],
       "test/cases/models/author_case.rb", "AuthorCase", "UnitCase"],
      [Generators::ScaffoldGenerator,    %w[Post title:string published:boolean],
       "test/cases/controllers/posts_controller_case.rb", "PostsControllerCase", "IntegrationCase"],
      [Generators::ControllerGenerator,  %w[Pages index show],
       "test/cases/controllers/pages_controller_case.rb", "PagesControllerCase", "IntegrationCase"],
      [Generators::IntegrationGenerator, %w[Checkout],
       "test/cases/controllers/checkout_case.rb", "CheckoutCase", "IntegrationCase"],
      [Generators::SystemGenerator,      %w[Post],
       "test/cases/system/posts_case.rb", "PostsCase", "SystemCase"],
      [Generators::MailerGenerator,      %w[Notifier welcome goodbye],
       "test/cases/mailers/notifier_mailer_case.rb", "NotifierMailerCase", "IntegrationCase"],
      [Generators::JobGenerator,         %w[CleanUp],
       "test/cases/jobs/clean_up_job_case.rb", "CleanUpJobCase", "IntegrationCase"],
      [Generators::HelperGenerator,      %w[Posts],
       "test/cases/helpers/posts_helper_case.rb", "PostsHelperCase", "UnitCase"],
      [Generators::ChannelGenerator,     %w[Room],
       "test/cases/channels/room_channel_case.rb", "RoomChannelCase", "IntegrationCase"],
      [Generators::MailboxGenerator,     %w[Forwards],
       "test/cases/mailboxes/forwards_mailbox_case.rb", "ForwardsMailboxCase", "IntegrationCase"],
      [Generators::GeneratorGenerator,   %w[Awesome],
       "test/cases/generators/awesome_generator_case.rb", "AwesomeGeneratorCase", "UnitCase"]
    ].freeze

    # The `as:` half of every `hook_for :test_framework` (plus :integration_tool and
    # :system_tests) that Rails 8.1 ships. Each one has to resolve to a generator of ours,
    # or that `rails generate` command writes no test file at all.
    HOOKS = %w[
      model scaffold controller mailer job helper integration system channel mailbox generator resource
    ].freeze

    # A case must speak Constable...
    CONSTABLE_VOCABULARY = /\b(?:investigate|witness|briefing|docket|attest)\b/

    # ...and must not speak either of the frameworks it replaces. Anchored deliberately:
    # "it" and "test" are ordinary English, and the templates are full of prose.
    FOREIGN_VOCABULARY = {
      "RSpec's describe" => /^\s*describe\s/,
      "RSpec's it" => /^\s*it\s+["']/,
      "RSpec's let" => /\blet\(/,
      "RSpec's before" => /^\s*before\s*(?:do\b|\{)/,
      "RSpec's expect" => /\bexpect\(/,
      "RSpec itself" => /\bRSpec\b/,
      "Minitest's test" => /^\s*test\s+["']/,
      "Minitest's def test_" => /^\s*def test_/,
      "Minitest's setup" => /^\s*setup\b/,
      "Minitest itself" => /\bMinitest\b/,
      "test_helper" => /require ["']test_helper["']/,
      "ActiveSupport::TestCase" => /ActiveSupport::TestCase/,
      "ActionDispatch::IntegrationTest" => /ActionDispatch::IntegrationTest/,
      "ActionDispatch::SystemTestCase" => /ActionDispatch::SystemTestCase/
    }.freeze

    def generate(klass, args = [])
      capture_stdout { klass.start(args, destination_root: tmp_root) }
    end

    def generated(relative_path)
      File.read(File.join(tmp_root, relative_path))
    end

    def generated?(relative_path)
      File.exist?(File.join(tmp_root, relative_path))
    end

    def written_files
      Dir.glob(File.join(tmp_root, "**/*"), File::FNM_DOTMATCH)
         .select { |path| File.file?(path) }
         .map { |path| path.delete_prefix("#{tmp_root}/") }
         .reject { |path| path.start_with?(".constable/") }
    end

    # Compiling proves the file parses without running it -- generated cases reference an
    # app's models, routes and case_helper, none of which exist inside a temp root.
    def assert_valid_ruby(relative_path)
      RubyVM::InstructionSequence.compile(generated(relative_path), relative_path)
    rescue SyntaxError => e
      flunk "#{relative_path} is not valid Ruby: #{e.message}"
    end

    def assert_speaks_constable(relative_path)
      source = generated(relative_path)

      assert_match CONSTABLE_VOCABULARY, source,
                   "#{relative_path} never mentions investigate/witness/briefing/attest"
      assert_match(/require "case_helper"/, source, "#{relative_path} does not require case_helper")

      FOREIGN_VOCABULARY.each do |description, pattern|
        refute_match pattern, source, "#{relative_path} still speaks #{description}"
      end
    end

    # -- Rails can find them -------------------------------------------------

    # This is exactly how a hook resolves: Rails::Generators::Base#prepare_for_invocation
    # calls find_by_namespace(:constable, in_base, as_hook), which converts "constable:model"
    # into generators/constable/model/model_generator and requires it. A file in the wrong
    # place fails here and nowhere else.
    def test_every_test_framework_hook_rails_ships_resolves_to_a_constable_generator
      HOOKS.each do |hook|
        found = ::Rails::Generators.find_by_namespace("constable", "rails", hook)

        refute_nil found, "constable:#{hook} did not resolve -- `rails generate` would write no test file"
        assert_equal "constable:#{hook}", found.namespace
      end
    end

    def test_generator_namespaces_follow_the_class_names
      GENERATED.each do |row|
        assert_match(/\Aconstable:/, row.first.namespace)
      end

      assert_equal "constable:model", Generators::ModelGenerator.namespace
      assert_equal "constable:scaffold", Generators::ScaffoldGenerator.namespace
      assert_equal "constable:integration", Generators::IntegrationGenerator.namespace
    end

    # Named Base so Rails::Generators::Base.inherited skips it. If it ever gets registered
    # it shows up in `rails generate` as a generator nobody can run.
    def test_the_shared_base_is_not_itself_a_generator
      refute_includes ::Rails::Generators.subclasses, Generators::Base
    end

    def test_every_generator_points_at_its_own_templates_directory
      GENERATED.each do |row|
        klass = row.first

        assert File.directory?(klass.source_root),
               "#{klass}.source_root (#{klass.source_root}) is not a directory"
      end
    end

    # -- what they write -----------------------------------------------------

    def test_each_generator_writes_the_case_file_at_the_expected_path
      GENERATED.each do |klass, args, path, _class_name, _superclass|
        generate(klass, args)

        assert generated?(path), "#{klass.namespace} did not write #{path}"
      end
    end

    def test_every_generated_case_is_valid_ruby
      GENERATED.each do |klass, args, path, _class_name, _superclass|
        generate(klass, args)
        assert_valid_ruby(path)
      end
    end

    def test_every_generated_case_speaks_constable_and_nothing_else
      GENERATED.each do |klass, args, path, _class_name, _superclass|
        generate(klass, args)
        assert_speaks_constable(path)
      end
    end

    def test_every_generated_case_declares_the_right_class_and_tier_base_class
      GENERATED.each do |klass, args, path, class_name, superclass|
        generate(klass, args)

        assert_match(/^class #{Regexp.escape(class_name)} < #{Regexp.escape(superclass)}$/,
                     generated(path),
                     "#{path} should declare `class #{class_name} < #{superclass}`")
      end
    end

    # The tier a case file inherits and the tier its path implies have to agree. They are
    # two independent mechanisms and a case sitting in the wrong directory would silently
    # get a different answer from each.
    def test_generated_paths_agree_with_the_tier_globs_in_config_defaults
      generate(Generators::ModelGenerator, %w[Post title:string])
      generate(Generators::ScaffoldGenerator, %w[Post title:string])
      generate(Generators::SystemGenerator, %w[Post])

      assert_equal :unit, Constable.config.tier_for("test/cases/models/post_case.rb")
      assert_equal :integration, Constable.config.tier_for("test/cases/controllers/posts_controller_case.rb")
      assert_equal :system, Constable.config.tier_for("test/cases/system/posts_case.rb")
    end

    # -- the individual generators ------------------------------------------

    def test_the_model_case_builds_a_witness_and_reads_every_column_back
      generate(Generators::ModelGenerator, %w[Post title:string published:boolean])
      source = generated("test/cases/models/post_case.rb")

      assert_match(/witness\(:post\) \{ Post\.new\(title: "MyString", published: false\) \}/, source)
      assert_match(/investigate "reads back the attributes it was generated with" do/, source)
      assert_match(/attest\(post\.title\)\.to eq\("MyString"\)/, source)
      assert_match(/attest\(post\.published\)\.to eq\(false\)/, source)
    end

    # A model generated with no columns has nothing honest to read back, so it gets a
    # commented shape rather than an investigation that passes by asserting nothing.
    def test_a_model_with_no_attributes_gets_no_vacuous_investigation
      generate(Generators::ModelGenerator, %w[Tag])
      source = generated("test/cases/models/tag_case.rb")

      assert_match(/witness\(:tag\) \{ Tag\.new \}/, source)
      refute_match(/^  investigate /, source)
      assert_match(/^  #   investigate "requires a name" do$/, source)
    end

    # References need another record and rich text/attachments need a file. Guessing either
    # would generate a case that fails for a reason nobody wrote.
    def test_the_model_case_leaves_out_attributes_it_cannot_honestly_invent
      generate(Generators::ModelGenerator, %w[Post title:string author:references body:rich_text])
      source = generated("test/cases/models/post_case.rb")

      assert_match(/Post\.new\(title: "MyString"\)/, source)
      refute_match(/author/, source)
      refute_match(/body/, source)
    end

    def test_the_scaffold_case_covers_every_action_the_scaffold_wrote
      generate(Generators::ScaffoldGenerator, %w[Post title:string])
      source = generated("test/cases/controllers/posts_controller_case.rb")

      assert_match(/witness\(:valid_attributes\) \{ \{ title: "MyString" \} \}/, source)
      assert_match(/witness\(:existing_post\) \{ Post\.create!\(valid_attributes\) \}/, source)

      assert_match(/investigate "index responds successfully" do\n    get posts_url/, source)
      assert_match(/investigate "new renders the form" do\n    get new_post_url/, source)
      assert_match(/assert_difference\("Post\.count", 1\) do\n      post posts_url/, source)
      assert_match(/attest\(response\)\.to redirect_to\(post_url\(Post\.last\)\)/, source)
      assert_match(/get post_url\(existing_post\)/, source)
      assert_match(/get edit_post_url\(existing_post\)/, source)
      assert_match(/patch post_url\(existing_post\), params: \{ post: valid_attributes \}/, source)
      assert_match(/assert_difference\("Post\.count", -1\) do\n      delete post_url\(record\)/, source)
      assert_match(/attest\(response\)\.to redirect_to\(posts_url\)/, source)
    end

    # The witness names the record `existing_post`, never `post`: `post` is the request
    # helper the create investigation calls, and a witness of that name would shadow it.
    def test_the_scaffold_witness_cannot_shadow_the_post_request_helper
      generate(Generators::ScaffoldGenerator, %w[Post title:string])
      source = generated("test/cases/controllers/posts_controller_case.rb")

      refute_match(/witness\(:post\)/, source)
      assert_match(/^      post posts_url, params:/, source)
    end

    def test_the_api_scaffold_case_talks_json_and_skips_the_form_pages
      generate(Generators::ScaffoldGenerator, %w[Widget name:string --api])
      source = generated("test/cases/controllers/widgets_controller_case.rb")

      assert_match(/get widgets_url, as: :json/, source)
      assert_match(/attest\(response\)\.to have_http_status\(:created\)/, source)
      assert_match(/attest\(response\)\.to have_http_status\(:no_content\)/, source)
      refute_match(/new_widget_url/, source)
      refute_match(/edit_widget_url/, source)
    end

    def test_the_scaffold_writes_a_system_case_only_when_rails_asks_for_one
      generate(Generators::ScaffoldGenerator, %w[Post title:string published:boolean])

      refute generated?("test/cases/system/posts_case.rb")

      generate(Generators::ScaffoldGenerator, %w[Post title:string published:boolean --system-tests=true --force])
      source = generated("test/cases/system/posts_case.rb")

      assert_match(/^class PostsCase < SystemCase$/, source)
      assert_match(/investigate "visiting the index" do\n    visit posts_url/, source)
      assert_match(/fill_in "Title", with: "MyString"/, source)
      assert_match(/check "Published"/, source)
      assert_match(/attest\(page\.text\)\.to include\("Post was successfully created"\)/, source)
    end

    def test_the_controller_case_gets_one_investigation_per_action
      generate(Generators::ControllerGenerator, %w[Pages index show])
      source = generated("test/cases/controllers/pages_controller_case.rb")

      assert_match(/investigate "index responds successfully" do\n    get pages_index_url/, source)
      assert_match(/investigate "show responds successfully" do\n    get pages_show_url/, source)
      assert_match(/attest\(response\)\.to have_http_status\(:ok\)/, source)
    end

    # No actions means no routes, and a request to a route that does not exist is not a
    # test -- so the template says what to write instead of pretending to have written it.
    def test_a_controller_with_no_actions_says_so_rather_than_generating_a_dead_request
      generate(Generators::ControllerGenerator, %w[Blank])
      source = generated("test/cases/controllers/blank_controller_case.rb")

      refute_match(/^  investigate /, source)
      assert_match(/ran without any actions/, source)
      assert_match(/^  #   investigate "index responds successfully" do$/, source)
    end

    def test_the_mailer_case_asserts_on_every_method_and_writes_the_preview
      generate(Generators::MailerGenerator, %w[Notifier welcome goodbye])
      source = generated("test/cases/mailers/notifier_mailer_case.rb")

      assert_match(/investigate "welcome" do\n    mail = NotifierMailer\.welcome/, source)
      assert_match(/investigate "goodbye" do\n    mail = NotifierMailer\.goodbye/, source)
      assert_match(/attest\(mail\.subject\)\.to eq\("Welcome"\)/, source)
      assert_match(/attest\(mail\.body\.encoded\)\.to include\("Hi"\)/, source)

      # The preview is a development tool, not a case: it stays where ActionMailer looks.
      preview = generated("test/mailers/previews/notifier_mailer_preview.rb")

      assert_match(/^class NotifierMailerPreview < ActionMailer::Preview$/, preview)
      assert_match(/def welcome\n    NotifierMailer\.welcome\n  end/, preview)
      assert_valid_ruby("test/mailers/previews/notifier_mailer_preview.rb")
    end

    def test_the_helper_case_includes_the_helper_it_covers
      generate(Generators::HelperGenerator, %w[Posts])
      source = generated("test/cases/helpers/posts_helper_case.rb")

      assert_match(/^class PostsHelperCase < UnitCase$/, source)
      assert_match(/^  include PostsHelper$/, source)
    end

    def test_the_job_case_explains_both_halves_worth_testing
      generate(Generators::JobGenerator, %w[CleanUp])
      source = generated("test/cases/jobs/clean_up_job_case.rb")

      assert_match(/CleanUpJob\.perform_now/, source)
      assert_match(/CleanUpJob\.perform_later/, source)
      refute_match(/^  investigate /, source)
    end

    def test_the_channel_case_points_at_action_cables_own_harness
      generate(Generators::ChannelGenerator, %w[Room])
      source = generated("test/cases/channels/room_channel_case.rb")

      assert_match(/^class RoomChannelCase < IntegrationCase$/, source)
      assert_match(/ActionCable::Channel::TestCase::Behavior/, source)
      assert_match(/attest\(subscription\)\.to be_confirmed/, source)
    end

    def test_the_mailbox_case_points_at_action_mailboxes_own_helpers
      generate(Generators::MailboxGenerator, %w[Forwards])
      source = generated("test/cases/mailboxes/forwards_mailbox_case.rb")

      assert_match(/^class ForwardsMailboxCase < IntegrationCase$/, source)
      assert_match(/ActionMailbox::TestHelper/, source)
    end

    def test_the_generator_case_requires_the_generator_it_covers
      generate(Generators::GeneratorGenerator, %w[Awesome])
      source = generated("test/cases/generators/awesome_generator_case.rb")

      assert_match(%r{require "generators/awesome/awesome_generator"}, source)
      assert_match(/self\.generator_class  = AwesomeGenerator/, source)
    end

    # `rails generate resource` is a model plus a routed controller, and Rails builds it
    # by inheriting the model generator. So does this one -- same output, one template.
    def test_the_resource_generator_delegates_to_the_model_generator
      assert_equal Generators::ModelGenerator, Generators::ResourceGenerator.superclass
      assert_equal Generators::ModelGenerator.source_root, Generators::ResourceGenerator.source_root

      generate(Generators::ResourceGenerator, %w[Author name:string])

      assert_match(/^class AuthorCase < UnitCase$/, generated("test/cases/models/author_case.rb"))
    end

    def test_the_suffix_stripping_matches_the_rails_generators_it_stands_in_for
      generate(Generators::JobGenerator, %w[CleanUpJob])
      generate(Generators::MailerGenerator, %w[NotifierMailer])
      generate(Generators::ChannelGenerator, %w[RoomChannel])
      generate(Generators::MailboxGenerator, %w[ForwardsMailbox])
      generate(Generators::IntegrationGenerator, %w[CheckoutTest])

      assert generated?("test/cases/jobs/clean_up_job_case.rb")
      assert generated?("test/cases/mailers/notifier_mailer_case.rb")
      assert generated?("test/cases/channels/room_channel_case.rb")
      assert generated?("test/cases/mailboxes/forwards_mailbox_case.rb")
      assert generated?("test/cases/controllers/checkout_case.rb")
    end

    def test_namespaced_names_keep_their_directories
      generate(Generators::ModelGenerator, %w[admin/note body:text])

      assert generated?("test/cases/models/admin/note_case.rb")
      assert_match(/^class Admin::NoteCase < UnitCase$/, generated("test/cases/models/admin/note_case.rb"))
    end

    # Nothing may land in test/models/, test/controllers/ or anywhere else Minitest would
    # have put it. The mailer preview is the one deliberate exception, and it is not a test.
    def test_nothing_is_written_outside_test_cases_but_the_mailer_preview
      GENERATED.each { |row| generate(row[0], row[1]) }

      stray = written_files.reject do |path|
        path.start_with?("test/cases/") || path.start_with?("test/mailers/previews/")
      end

      assert_empty stray, "these went somewhere Constable does not keep cases: #{stray.inspect}"
    end

    # -- the railtie ---------------------------------------------------------

    # Both railtie checks run in a subprocess on purpose. Loading Rails into this one would
    # change what every other test in the suite sees -- ActiveSupport's travel_to, a live
    # Rails.root, an AR constant -- and the second check is meaningless unless the process
    # genuinely has no Rails in it.
    def ruby_subprocess(code)
      lib = File.expand_path("../../lib", __dir__)
      output = IO.popen([RbConfig.ruby, "-I#{lib}", "-e", code], err: %i[child out], &:read)
      [output, $CHILD_STATUS.success?]
    end

    def test_the_railtie_registers_constable_as_the_generator_test_framework
      output, ok = ruby_subprocess(<<~RUBY)
        require "rails"
        require "constable"

        generators = Rails::Railtie::Configuration.new.app_generators
        puts "superclass: \#{Constable::Railtie.superclass}"
        puts "test_framework: \#{generators.options[:rails][:test_framework].inspect}"
        puts "integration_tool: \#{generators.options[:rails][:integration_tool].inspect}"
        puts "system_tests: \#{generators.options[:rails][:system_tests].inspect}"
        puts "fixture: \#{generators.options[:constable][:fixture].inspect}"
      RUBY

      assert ok, "loading Constable inside Rails failed:\n#{output}"
      assert_match(/^superclass: Rails::Railtie$/, output)
      assert_match(/^test_framework: :constable$/, output)
      assert_match(/^integration_tool: :constable$/, output)
      assert_match(/^system_tests: :constable$/, output)
      # Constable has no fixtures -- a witness builds what one investigation needs and
      # throws it away, which is the same reason there is no before(:all).
      assert_match(/^fixture: false$/, output)
    end

    # The regression this whole feature could plausibly cause, and the one that would hurt
    # most: a :unit-tier run boots without a Rails app, so lib/constable.rb must never pull
    # railties in on its own.
    def test_requiring_constable_still_works_in_a_process_with_no_rails
      output, ok = ruby_subprocess(<<~RUBY)
        require "constable"

        abort "Rails leaked into the process" if defined?(Rails)
        abort "the railtie loaded with no Rails to register with" if defined?(Constable::Railtie)

        Constable::Case
        Constable::Matchers
        Constable::Config::DEFAULTS
        print "clean"
      RUBY

      assert ok, "require \"constable\" failed with no Rails present:\n#{output}"
      assert_equal "clean", output
    end
  end
end
