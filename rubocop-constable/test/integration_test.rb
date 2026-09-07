# frozen_string_literal: true

require "helper"
require "fileutils"
require "tmpdir"

module RuboCop
  module Constable
    # Runs the whole department the way RuboCop itself does -- a real `Team`, the
    # injected default configuration, real files on disk -- so `Include` filtering
    # and the cold-case exemption are proven end to end, not just per cop.
    class IntegrationTest < CopTest
      NATIVE_CASE = <<~RUBY
        # frozen_string_literal: true

        class UsersController::CreatesUserCase < IntegrationCase
          investigate "creates a user" do
            sleep(0.2)
            attest(record.created_at).to eq(Time.now)
            $token = issue_token
            attest(response).to be_created if admin?
            eventually { attest(User).to exist }
            unsafe { Net::HTTP.get(uri) }
          end
        end
      RUBY

      COLD_CASE = <<~RUBY
        # frozen_string_literal: true

        class LegacyUsersSpec < Constable::ColdCase::RSpec
          describe UsersController do
            it "creates a user" do
              sleep(0.2)
              $token = issue_token
              expect(Net::HTTP.get(uri)).to include("ok")
            end
          end
        end
      RUBY

      ORDINARY_CODE = <<~RUBY
        # frozen_string_literal: true

        class ImportJob
          def call
            sleep(1)
            $last_run = Time.now
          end
        end
      RUBY

      CLEAN_CASE = <<~RUBY
        # frozen_string_literal: true

        class UsersController::ShowsUserCase < IntegrationCase
          briefing do
            stub_network!
            freeze_time
          end

          witness(:user) { User.new(email: "a@b.com") }

          investigate "renders the user" do
            get user_path(user)

            attest(response).to be_ok
            attest(response.body).to include(user.email)
          end

          investigate "times out after thirty seconds" do
            unsafe { sleep(0.1) } # testing an actual timeout path, not a code smell

            attest(response).to have_timed_out
          end
        end
      RUBY

      def test_the_department_flags_a_native_case_and_spares_everything_else
        in_project do |root|
          write(root, "test/cases/users_case.rb", NATIVE_CASE)
          write(root, "test/cases/legacy_users_case.rb", COLD_CASE)
          write(root, "test/cases/shows_user_case.rb", CLEAN_CASE)
          write(root, "app/jobs/import_job.rb", ORDINARY_CODE)

          by_file = inspect_project(root)

          assert_equal(
            %w[
              Constable/NoConditionalAssertions
              Constable/NoRetryHelpers
              Constable/NoSharedMutableState
              Constable/NoSleep
              Constable/NoUnfrozenTime
              Constable/UnsafeBlockVisibility
            ],
            by_file.fetch("test/cases/users_case.rb").map(&:cop_name).uniq.sort
          )

          assert_empty by_file.fetch("test/cases/legacy_users_case.rb"),
                       "cold cases opted out of native rules and must not be linted"
          assert_empty by_file.fetch("test/cases/shows_user_case.rb"),
                       "a well-formed native case must be clean"
          assert_empty by_file.fetch("app/jobs/import_job.rb"),
                       "ordinary application code is outside the Include globs"
        end
      end

      def test_the_unsafe_escape_hatch_silences_the_guards_it_covers
        in_project do |root|
          write(root, "test/cases/users_case.rb", NATIVE_CASE)

          offenses = inspect_project(root).fetch("test/cases/users_case.rb")

          # `unsafe { Net::HTTP.get(uri) }` is the only network call in the file, and
          # it is wrapped -- so NoNetworkWithoutStub stays quiet while
          # UnsafeBlockVisibility still insists the block say why it exists.
          refute_includes offenses.map(&:cop_name), "Constable/NoNetworkWithoutStub"
          assert_includes offenses.map(&:cop_name), "Constable/UnsafeBlockVisibility"
        end
      end

      private

      def in_project
        Dir.mktmpdir("rubocop-constable") { |root| yield root }
      end

      def write(root, relative_path, contents)
        path = File.join(root, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
        path
      end

      # @return [Hash{String => Array<RuboCop::Cop::Offense>}] offenses per file.
      def inspect_project(root)
        config = project_config(root)
        registry = ::RuboCop::Cop::Registry.new(constable_cops)

        Dir.glob(File.join(root, "**", "*.rb")).sort.to_h do |path|
          team = ::RuboCop::Cop::Team.mobilize(registry, config, raise_error: true)
          source = ::RuboCop::ProcessedSource.from_file(path, ruby_version)
          [path.delete_prefix("#{root}/"), team.investigate(source).offenses.reject(&:disabled?)]
        end
      end

      def project_config(root)
        hash = ::RuboCop::ConfigLoader.send(:load_yaml_configuration, ::RuboCop::Constable.config_default.to_s)
        ::RuboCop::Config.create(hash, File.join(root, ".rubocop.yml"), check: false)
      end

      def constable_cops
        ::RuboCop::Cop::Registry.global.cops.select { |cop| cop.badge.department == :Constable }
      end
    end
  end
end
