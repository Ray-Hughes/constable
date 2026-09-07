# frozen_string_literal: true

module RuboCop
  module Constable
    # Merges this extension's `config/default.yml` into RuboCop's own default
    # configuration, so users get sensible defaults for every `Constable/*` cop
    # from `require: rubocop-constable` alone -- no copy-pasting of departments
    # into their `.rubocop.yml`.
    #
    # This is the standard RuboCop extension injection pattern, as used by
    # rubocop-rails, rubocop-rspec and friends.
    module Inject
      def self.defaults!
        path = ::RuboCop::Constable.config_default.to_s
        hash = ::RuboCop::ConfigLoader.send(:load_yaml_configuration, path)
        config = ::RuboCop::Config.new(hash, path).tap(&:make_excludes_absolute)
        puts "configuration from #{path}" if ::RuboCop::ConfigLoader.debug?
        config = ::RuboCop::ConfigLoader.merge_with_default(config, path)
        ::RuboCop::ConfigLoader.instance_variable_set(:@default_configuration, config)
      end
    end
  end
end
