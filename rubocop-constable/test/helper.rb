# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "rubocop-constable"

module RuboCop
  module Constable
    # Shared harness for the extension's own suite.
    #
    # RuboCop cops are conventionally exercised with RSpec's `ExpectOffense`, but
    # the Constable repo standardises on Minitest, so this runs each cop by hand:
    # build a `ProcessedSource`, hand it to a `Commissioner` holding just the cop
    # under test, and assert on the resulting offenses. No RSpec anywhere.
    class CopTest < Minitest::Test
      # A path that matches none of the cops' default `Include` globs, so the
      # scoping tests exercise the superclass heuristic rather than the path
      # fallback. Tests that want the path fallback pass their own.
      OUT_OF_INCLUDE_PATH = "app/models/user.rb"
      IN_INCLUDE_PATH = "test/cases/models/user_case.rb"

      # A native case file, as `rails generate constable:install` sets one up.
      def native_source(body, superclass: "IntegrationCase")
        <<~RUBY
          class UsersController::CreatesUserCase < #{superclass}
          #{body.gsub(/^/, "  ").gsub(/^\s+$/, "")}
          end
        RUBY
      end

      # The same body inside a cold case -- an untouched RSpec/Minitest file that
      # opted out of native rules. Every cop must stay silent here.
      def cold_case_source(body, superclass: "Constable::ColdCase::RSpec")
        <<~RUBY
          class LegacyUsersSpec < #{superclass}
          #{body.gsub(/^/, "  ").gsub(/^\s+$/, "")}
          end
        RUBY
      end

      def offenses(cop_class, source, path: OUT_OF_INCLUDE_PATH, cop_options: {})
        cop = build_cop(cop_class, cop_options)
        processed = processed_source(source, path)
        assert processed.valid_syntax?, "fixture source failed to parse:\n#{source}"

        commissioner = ::RuboCop::Cop::Commissioner.new([cop], [], raise_error: true)
        report = commissioner.investigate(processed)
        raise report.errors.values.flatten.first if report.errors.any?

        report.offenses.reject(&:disabled?).sort_by { |offense| [offense.line, offense.column] }
      end

      def messages(cop_class, source, **kwargs)
        offenses(cop_class, source, **kwargs).map(&:message)
      end

      def assert_no_offenses(cop_class, source, **kwargs)
        found = offenses(cop_class, source, **kwargs)
        assert_empty found.map { |o| "#{o.line}: #{o.message}" }
      end

      def assert_offense_count(expected, cop_class, source, **kwargs)
        found = offenses(cop_class, source, **kwargs)
        assert_equal expected, found.size, "offenses were:\n#{found.map { |o| "  #{o.line}: #{o.message}" }.join("\n")}"
        found
      end

      # Asserts the cop reports exactly one offense, on `line`, whose message
      # contains `message_fragment`.
      def assert_single_offense(cop_class, source, line:, message_fragment: nil, **kwargs)
        found = assert_offense_count(1, cop_class, source, **kwargs)
        offense = found.first
        assert_equal line, offense.line, "offense was on line #{offense.line}: #{offense.message}"
        assert_includes offense.message, message_fragment if message_fragment
        offense
      end

      # Asserts the cold-case exemption suppresses everything this cop would
      # otherwise report for the same body.
      def assert_cold_case_exempt(cop_class, body, **kwargs)
        refute_empty offenses(cop_class, native_source(body), **kwargs),
                     "fixture must offend as a native case for the exemption test to mean anything"

        %w[Constable::ColdCase::RSpec Constable::ColdCase::Minitest].each do |superclass|
          found = offenses(cop_class, cold_case_source(body, superclass: superclass), **kwargs)
          assert_empty found.map(&:message), "#{superclass} should be exempt from #{cop_class.badge}"
        end
      end

      def build_cop(cop_class, cop_options = {})
        cop_class.new(config_for(cop_class, cop_options))
      end

      def config_for(cop_class, cop_options = {})
        hash = ::RuboCop::ConfigLoader.send(:load_yaml_configuration, ::RuboCop::Constable.config_default.to_s)
        hash = hash.merge(cop_class.badge.to_s => hash.fetch(cop_class.badge.to_s, {}).merge(cop_options))
        ::RuboCop::Config.create(hash, ::RuboCop::Constable.config_default.to_s, check: false)
      end

      def processed_source(source, path)
        ::RuboCop::ProcessedSource.new(source, ruby_version, path)
      end

      def ruby_version
        ::RuboCop::TargetRuby::DEFAULT_VERSION
      end
    end
  end
end
