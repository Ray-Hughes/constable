# Releasing

Two gems ship from this repo, separately:

| Gem | Directory | Purpose |
|---|---|---|
| `constable-rails` | repo root | The framework. `require "constable"`, the `constable` CLI. |
| `rubocop-constable` | `rubocop-constable/` | The RuboCop extension. Optional, `require: false`. |

The published package is `constable-rails` because `constable` was claimed on RubyGems
in 2011 by an unrelated, long-abandoned gem. Nothing inside either gem is renamed: the
module is `Constable`, the CLI is `constable`, the config directory is `.constable/`.

## Before a release

```console
$ bundle exec rake test          # the framework's own suite
$ bundle exec rake cops          # the RuboCop extension's suite
$ bundle exec rubocop            # both, lint clean
```

Then bump `Constable::VERSION` in `lib/constable/version.rb` (and
`RuboCop::Constable::VERSION` in `rubocop-constable/lib/rubocop/constable/version.rb` if
that gem changed), and move the `Unreleased` section of `CHANGELOG.md` down to the new
version number.

## Authenticating with RubyGems

Publishing needs an API key with **push** scope. Either sign in once:

```console
$ gem signin
```

or create a key at <https://rubygems.org/settings/edit> and write it yourself:

```console
$ mkdir -p ~/.gem
$ printf -- "---\n:rubygems_api_key: <YOUR_KEY>\n" > ~/.gem/credentials
$ chmod 600 ~/.gem/credentials
```

The gemspec sets `rubygems_mfa_required`, so the account needs MFA enabled for gem
signing. That is deliberate — the whole point of this gem is that a test suite is
something you trust.

## Publishing

```console
$ gem build constable-rails.gemspec
$ gem push constable-rails-0.1.0.gem

$ cd rubocop-constable
$ gem build rubocop-constable.gemspec
$ gem push rubocop-constable-0.1.0.gem
```

`gem build` warns about the open-ended runtime dependencies. Leave them alone: a
`~> 7.0` pin would lock out Rails 8, which this gem is tested against, and `~> 1.6`
would lock out sqlite3 2.x, which is the current release. The lower bounds are the part
that matters.

## Tagging

```console
$ git tag -a v0.1.0 -m "constable-rails 0.1.0"
$ git push origin v0.1.0
```

## Yanking

A pushed version cannot be replaced, only yanked — and the version number is burned
either way:

```console
$ gem yank constable-rails -v 0.1.0
```
