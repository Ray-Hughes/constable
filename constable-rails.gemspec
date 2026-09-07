# frozen_string_literal: true

require_relative "lib/constable/version"

Gem::Specification.new do |spec|
  spec.name    = "constable-rails"
  spec.version = Constable::VERSION
  spec.authors = ["Ray Hughes"]
  spec.email   = ["r.hughes2136@gmail.com"]

  spec.summary     = "An opinionated, strict Rails testing framework where fast and non-flaky are structural, not disciplinary."
  spec.description = <<~DESC
    Constable replaces RSpec/Minitest for Rails apps that want tests to be fast and
    non-flaky by construction. Every test is isolated by default, nondeterminism is a
    lint error rather than a CI surprise, and every escape hatch is reported until
    someone deals with it. Existing RSpec and Minitest suites adopt it with a one-line
    change per file and zero rewriting -- cold cases run verbatim through their original
    engine while native cases run under strict rules, side by side in one run.

    Ships with a case-file DSL (investigate/witness/briefing/docket), transactional
    isolation, flake history with rename-surviving content-hash identity, a jail and
    parole docket for legacy red suites, warrants for automatic flake detection, diff-based
    coverage, parallel workers, git-diff test selection, and a RuboCop extension.

    The gem is published as "constable-rails"; everything inside it -- the module, the
    CLI, the config directory -- is simply "constable".
  DESC

  spec.homepage = "https://github.com/Ray-Hughes/constable"
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]       = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"]     = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/generators/constable/templates/**/*",
    "exe/*",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]

  spec.bindir      = "exe"
  spec.executables = ["constable"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.0"
  spec.add_dependency "railties",      ">= 7.0"
  spec.add_dependency "thor",          ">= 1.2"
  spec.add_dependency "sqlite3",       ">= 1.6"
  spec.add_dependency "parser",        ">= 3.1"
end
