# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    # Guards the wiring users actually depend on: `require: rubocop-constable`
    # gives them every cop, configured, without touching their `.rubocop.yml`.
    class DefaultConfigTest < CopTest
      REQUIRED_KEYS = %w[Enabled Description VersionAdded Include].freeze

      def test_every_registered_cop_is_configured
        cop_badges.each do |badge|
          assert_includes default_config.keys, badge, "#{badge} is missing from config/default.yml"
        end
      end

      def test_every_configured_cop_is_registered
        configured_cops.each do |badge|
          assert_includes cop_badges, badge, "config/default.yml configures #{badge}, which no cop defines"
        end
      end

      def test_every_cop_declares_the_required_keys
        configured_cops.each do |badge|
          settings = default_config.fetch(badge)
          REQUIRED_KEYS.each do |key|
            assert settings.key?(key), "#{badge} is missing #{key}"
          end

          assert_equal true, settings["Enabled"], "#{badge} should be enabled by default"
          assert_equal "0.1.0", settings["VersionAdded"]
          refute_empty settings["Description"].to_s.strip
        end
      end

      def test_every_cop_ships_the_case_file_include_globs
        expected = [
          "test/cases/**/*.rb",
          "spec/cases/**/*.rb",
          "test/**/*_case.rb",
          "spec/**/*_case.rb"
        ]

        configured_cops.each do |badge|
          assert_equal expected, default_config.fetch(badge).fetch("Include"), badge
        end
      end

      def test_the_department_itself_is_enabled
        assert_equal true, default_config.fetch("Constable").fetch("Enabled")
      end

      def test_inject_merges_the_defaults_into_rubocops_own_configuration
        merged = ::RuboCop::ConfigLoader.default_configuration

        cop_badges.each do |badge|
          assert merged.key?(badge), "#{badge} was not injected into RuboCop's default configuration"
          assert_equal true, merged[badge]["Enabled"]
        end
      end

      def test_include_globs_select_case_files_and_skip_ordinary_code
        cop = build_cop(::RuboCop::Cop::Constable::NoSleep)

        %w[
          test/cases/models/user_case.rb
          spec/cases/controllers/sessions_case.rb
          test/controllers/users_controller_case.rb
          spec/models/user_case.rb
        ].each { |path| assert cop.relevant_file?(path), "#{path} should be linted" }

        %w[
          app/models/user.rb
          lib/tasks/import.rake.rb
          test/support/authenticatable.rb
        ].each { |path| refute cop.relevant_file?(path), "#{path} should not be linted" }
      end

      def test_all_seven_spec_cops_exist
        assert_equal(
          %w[
            Constable/NoConditionalAssertions
            Constable/NoNetworkWithoutStub
            Constable/NoRetryHelpers
            Constable/NoSharedMutableState
            Constable/NoSleep
            Constable/NoUnfrozenTime
            Constable/UnsafeBlockVisibility
          ],
          cop_badges.sort
        )
      end

      private

      def default_config
        @default_config ||= YAML.safe_load(::RuboCop::Constable.config_default.read)
      end

      def configured_cops
        default_config.keys.select { |key| key.start_with?("Constable/") }.sort
      end

      def cop_badges
        ::RuboCop::Cop::Registry.global.cops
                                .select { |cop| cop.badge.department == :Constable }
                                .map { |cop| cop.badge.to_s }
                                .sort
      end
    end
  end
end
