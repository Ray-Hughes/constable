# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0]

Initial release.

### The case file

- `Constable::Case` with the full case-file DSL: `investigate`, `witness`, `briefing`,
  `docket`, and the `tier` macro.
- `investigate` is a registration DSL, not a method definition — every investigation runs
  in its own fresh instance, so no two tests can reach each other.
- `witness` memoizes per test, never per process.
- No `before(:all)` equivalent exists, deliberately.
- Shared behavior across files is a plain Ruby module you `include` — no shared-examples DSL.

### Rails

- A railtie registers Constable as the app's generator test framework, so
  `rails generate scaffold` writes cases rather than Minitest files. Every generator Rails
  hooks is covered, and no fixtures are generated — a `witness` replaces them.
- `Constable::RailsSupport::Integration` and `::System` give the tier base classes the
  request stack and Capybara respectively.
- `Constable::Case` answers to minitest's `setup`/`teardown` macros and lifecycle hooks, so
  the Rails ecosystem's testing modules compose with it. `briefing` remains the primary API.

### Adoption

- `Constable::ColdCase::RSpec` and `Constable::ColdCase::Minitest` run an existing spec or
  test file completely untouched, through its own real engine, feeding results into
  Constable's reporting, flake history and CI gate alongside native cases.
- Zero-file-change adoption via `cold_cases:` globs in `.constable/config.yml`.
- `constable import --from=rspec|minitest` (reopen, verbatim) and the opt-in
  `constable modernize PATH` AST rewrite into the native DSL.
- `rails generate constable:install` writes `test/case_helper.rb`, `test/support/`,
  `.constable/config.yml`, and the optional `:cold_case` Gemfile group.

### Strictness

- `unsafe { }` escape hatch — always warns, never silent, with `file:line` and the reason.
- `rubocop-constable` companion gem: `NoSleep`, `NoUnfrozenTime`, `NoNetworkWithoutStub`,
  `NoSharedMutableState`, `NoConditionalAssertions`, `NoRetryHelpers`, `UnsafeBlockVisibility`
  — scoped to native cases only; cold cases are exempt by design.

### Anti-flake

- Random order every run with a printed, replayable seed.
- Order-dependency detection in CI.
- State-leak check after each native investigation.
- Flake history keyed by a **content hash of the investigate block**, so renaming a class,
  rewording a description or moving a file carries history over untouched.
- Rename detection with `auto_relink` and `constable history relink OLD NEW`.
- Jail, parole and parole-violation tracking for legacy red suites.
- Warrants — automatic flaky detection that answers "is this failure even real."

### Speed

- Boot tiers via base classes, with path-based inference as a fallback.
- Parallel workers, load-balanced by a cached per-test duration index.
- Git-diff-based local test selection; `--full` for everything.

### Watching the suite

- `constable watchlist` — jailed, paroled and warranted tests in one view.
- `constable status` — the trend view: how much of the suite is still running as cold
  cases and whether that number is moving, the recent runs, and the ten slowest tests
  historically.

### Output

- Live glyph stream, then a summary that leads with what is most urgent: parole
  violations, failures, warnings, slowest.
- Failures carry their own context, point at the `investigate` line rather than framework
  internals, and print a ready-to-paste rerun command with the seed.
- stdout is results only; `Rails.logger` and SQL go to `log/test.log`, streamed with `--verbose`.

### Coverage

- Diff-based coverage gate — only lines changed in the current diff are held to the
  threshold. `constable beat` for the full picture, `--html` for a browsable report.

[Unreleased]: https://github.com/Ray-Hughes/constable/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Ray-Hughes/constable/releases/tag/v0.1.0
