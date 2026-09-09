# Changelog

All notable changes to `rubocop-constable` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.2]

Version bumped to track `constable-rails` 1.4.2. No cop changes.

## [1.4.1]

Version bumped to track `constable-rails` 1.4.1. No cop changes.

## [1.4.0]

Version bumped to track `constable-rails` 1.4.0. No cop changes.

## [1.3.3]

Version bumped to track `constable-rails` 1.3.3. No cop changes.

## [1.3.2]

Version bumped to track `constable-rails` 1.3.2. No cop changes.

## [1.3.1]

Version bumped to track `constable-rails` 1.3.1. No cop changes.

## [1.3.0]

Version bumped to track `constable-rails` 1.3.0. No cop changes.

## [1.2.0]

Version bumped to track `constable-rails` 1.2.0. No cop changes.

## [1.1.0]

Version bumped to track `constable-rails` 1.1.0. No cop changes.

## [1.0.0]

Version bumped to track `constable-rails` 1.0.0. The cops themselves are unchanged --
all seven were already correct, and the suite (97 runs) still passes untouched. They
were verified against a real Rails app for the first time in this cycle: all seven fire,
and cold cases are exempt as designed (27 spec files, zero offenses, while the native
probe file trips nine).

## [0.1.0]

Initial release. Seven cops, all enabled by default, all scoped to native
`Constable::Case` files:

- `Constable/NoSleep`
- `Constable/NoUnfrozenTime`
- `Constable/NoNetworkWithoutStub`
- `Constable/NoSharedMutableState`
- `Constable/NoConditionalAssertions`
- `Constable/NoRetryHelpers`
- `Constable/UnsafeBlockVisibility`

Cold cases (`Constable::ColdCase::RSpec`, `Constable::ColdCase::Minitest`) are
exempt from every one of them, by design.
