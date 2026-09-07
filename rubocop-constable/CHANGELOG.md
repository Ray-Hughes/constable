# Changelog

All notable changes to `rubocop-constable` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - unreleased

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
