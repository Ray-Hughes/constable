# frozen_string_literal: true

require_relative "lib/rubocop/constable/version"

Gem::Specification.new do |spec|
  spec.name    = "rubocop-constable"
  spec.version = RuboCop::Constable::VERSION
  spec.authors = ["Ray Hughes"]
  spec.email   = ["raymond.hughes@live.com"]

  spec.summary     = "RuboCop cops that catch test nondeterminism before CI does."
  spec.description = <<~DESC
    The companion RuboCop extension for Constable, the opinionated Rails testing gem.

    Constable's second principle is that nondeterminism is caught by the linter, not
    discovered in CI. These seven cops are that linter: bare `sleep`, unfrozen
    `Time.now`, unstubbed HTTP, class-level shared state, assertions hidden behind a
    branch, retry and eventually helpers, and an `unsafe` block that never says why.

    Every cop is scoped to native `Constable::Case` files. Cold cases -- untouched
    RSpec or Minitest files running through `Constable::ColdCase::*` -- are exempt by
    design, because the whole point of the adoption story is that taking the on-ramp
    costs nothing.

    Install it alongside `constable-rails` and add `require: rubocop-constable` to
    `.rubocop.yml`.
  DESC

  spec.homepage = "https://github.com/Ray-Hughes/constable"
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = "#{spec.homepage}/tree/main/rubocop-constable"
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/rubocop-constable/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]       = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"]     = "#{spec.homepage}/blob/main/rubocop-constable/README.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "config/*.yml",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]

  spec.require_paths = ["lib"]

  spec.add_dependency "rubocop", ">= 1.50"
end
