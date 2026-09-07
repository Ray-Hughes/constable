# frozen_string_literal: true

# The entry point users name in `.rubocop.yml`:
#
#   require:
#     - rubocop-constable
#
require "yaml"
require "rubocop"

require_relative "rubocop/constable"
require_relative "rubocop/constable/version"
require_relative "rubocop/constable/inject"

RuboCop::Constable::Inject.defaults!

require_relative "rubocop/cop/constable_cops"
