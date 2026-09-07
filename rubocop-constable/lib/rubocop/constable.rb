# frozen_string_literal: true

require "pathname"

module RuboCop
  # RuboCop cops for Constable, the opinionated Rails testing gem.
  #
  # Constable's promise is that fast and non-flaky are structural properties of a
  # suite, not a matter of discipline. These cops are the half of that promise that
  # runs before the suite does: nondeterminism is caught by the linter, not
  # discovered in CI.
  module Constable
    PROJECT_ROOT = Pathname.new(__dir__).parent.parent.expand_path.freeze
    CONFIG_DEFAULT = PROJECT_ROOT.join("config", "default.yml").freeze
    CONFIG = YAML.safe_load(CONFIG_DEFAULT.read, permitted_classes: [Regexp, Symbol]).freeze

    private_constant :CONFIG_DEFAULT, :PROJECT_ROOT

    class << self
      # @return [Pathname] the gem's own root, used to locate config/default.yml.
      def project_root
        PROJECT_ROOT
      end

      # @return [Pathname] path to the shipped default configuration.
      def config_default
        CONFIG_DEFAULT
      end
    end
  end
end
