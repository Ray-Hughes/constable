# frozen_string_literal: true

# The gem is published as "constable-rails" because the name "constable" was claimed on
# RubyGems in 2011 by an unrelated, long-abandoned gem.
#
# Bundler.require requires each gem by its *gem* name, so an app writing the ordinary
#
#   gem "constable-rails"
#
# gets `require "constable-rails"` and nothing else. Without this file that raises
# LoadError, and Bundler's only fallback is "constable/rails", which does not exist
# either -- so the gem would never be loaded into the app at all. Everything would still
# appear to work, because the `constable` executable requires "constable" itself, right
# up until the moment something needed the Railtie: `rails generate scaffold` would
# quietly keep emitting Minitest files, for the framework the app had just replaced.
require "constable"
