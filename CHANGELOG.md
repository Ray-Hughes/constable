# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0]

Adoption at scale. Everything here came from installing 1.2.0 into a 1,277-spec-file
Postgres app.

### `worker_databases: reuse`

Per-worker databases have been rebuilt from schema on every run since 1.0.0, which is
what Rails does for `rails test`. It is correct by construction — no drift is possible —
and it is useless for an app whose schema **cannot** rebuild the database by itself. Any
app with Postgres custom types is in that position: `CREATE TYPE` has no `schema.rb`
representation, so a from-scratch load fails on a schema that references a type it never
defines.

```yaml
worker_databases: schema   # schema (default) | reuse | off
```

`reuse` connects to `<database>_<index>` when it is already there and builds it from
schema only when it is not — checking each database separately, which matters for a
multi-database app where one may be prepared and another not. "Already there" means
present *and* holding tables: an empty database is not a prepared one, and running a
suite against no tables is the worst available outcome.

It is also just faster for everyone. A 3,000-line schema is no longer reloaded once per
worker per run.

`off` skips sharding entirely — an explicit serial run, no attempt and no warning.

New command, for the one-time setup `reuse` needs:

```console
$ constable prepare              # build <database>_0 .. _<N-1>, once
$ constable prepare --workers 8
```

### Hundreds of cold cases no longer bury the summary

Every cold-case file warns, once per run, so that "12 tests not yet under native rules"
is never something the suite quietly forgets to mention. At 1,277 files that is four
thousand lines of the same sentence, and the warnings that actually need a decision — an
`unsafe` block, a jailed test — are lost inside it.

Past ten files they collapse into one line that keeps the numbers, which are the part
that is supposed to shrink:

```
⚠ 1277 files running as cold cases, 18432 tests — not yet under native rules.
  `constable test --unsafe` runs just these.
```

Fewer than ten are still listed individually, and nothing else is ever collapsed.


## [1.2.0]

Two bugs found installing 1.1.0 into a large real Postgres app (~3,000-line schema,
custom types, a factory directory). Both are the same shape as the ones 1.0.0 fixed:
Constable was confidently wrong and said nothing useful about it.

### A factory named `*_case.rb` was loaded as a test

`spec/**/*_case.rb` is a generous net, and a real app has things in it that merely share
the suffix. Caseflow has a FactoryBot factory at `spec/factories/distributed_case.rb`.
Constable loaded it as a case file, FactoryBot raised `DuplicateDefinitionError` because
the factory was already registered, and the run reported a failing test in a file that
contains no tests:

```
✗ spec/factories/distributed_case.rb
  "could not be loaded"
  FactoryBot::DuplicateDefinitionError: Factory already registered: distributed_case
```

A filename is not evidence. A file outside the conventional `test/cases/` and
`spec/cases/` directories now has to look like a case before it is loaded — a class
declaration, or the DSL. Files under those directories are still taken at their word,
since that is what they are for and an empty one there is a case somebody is part-way
through writing.

### An app that cannot be sharded now runs anyway

Per-worker databases (1.0.0) are built by loading `schema.rb` into `<database>_<index>`.
Not every app can do that: one with Postgres custom types, functions or triggers cannot
rebuild itself from `schema.rb` at all, which is exactly why such apps keep a
`structure.sql`. Rails' own `parallelize` fails the same way.

Constable handled it about as badly as possible. Each worker raised, printing a full
stack trace — four workers, four traces, several hundred lines — and the parent then
reported a run that had never happened:

```
CONSTABLE            1 test · 1 case · 10.8s
✓ 0 passed   ✗ 1 failed
```

A worker that cannot build its database now reports that home rather than raising. If no
worker got started, nothing has run yet, so the parent simply runs the suite serially and
says why in one sentence — including the real error and how to skip the attempt
(`parallel_workers: 1`). The rule from 1.0.0 is unchanged: a worker never falls back to
sharing the parent's database, because that is the corruption this whole mechanism
exists to prevent.


## [1.1.0]

Three things that were documented and did not work, plus the command for a docket
that has gone stale.

### `Constable.configure` actually configures things now

The generated `test/case_helper.rb` told you to write `c.parallel_workers = 4`, explained
when you would want to, and then **nothing in the codebase ever read it**. Four accessors,
all inert.

They work now, and every setting `.constable/config.yml` understands is settable in Ruby
alongside them — `cold_cases`, `storage`, `warrants`, `warrant_retries`, `auto_relink`,
`parole_period`, `coverage`, `coverage_threshold`, `coverage_html`, `fail_on_warnings`,
`parallel_workers`, `output`, `tiers`. A test asserts the two halves stay in step, so a
setting cannot be added to one and forgotten in the other.

Precedence, and the reasoning:

```
a CLI flag              --workers 4, --expanded      one run, most specific
Constable.configure     test/case_helper.rb          code you deliberately ran
.constable/config.yml   the project's declared default
Constable's defaults
```

Which to use? A setting that differs per machine or per branch belongs in the YAML, where
it is obvious and greppable. A setting that has to be *computed* belongs in Ruby, because
YAML cannot do this:

```ruby
Constable.configure do |c|
  c.parallel_workers = ENV.fetch("CI_WORKERS", 4).to_i
  c.coverage         = ENV["CI"] == "true"
end
```

Values set in Ruby go through the same clamping as values set in the file, so a typo is no
more dangerous in one than the other.

**`storage` is the one exception, and it now says so.** The blotter is opened before
`case_helper.rb` loads, so that `constable jail`, `warrants`, `watchlist` and `status` can
read the docket without booting the app — a broken app should not stop you reading the
docket. Setting it in Ruby would have been silently ignored, which is the exact failure
this release exists to stop, so it raises and explains why.

The docs now lead with Ruby. The generated `case_helper.rb` lists **every** setting at its
default in one compact block — a test asserts the list stays complete, and that it never
offers `storage`. The long-form explanation of each stays in `config.yml`, so the two files
are a reference and a place to write code rather than two competing references.

Neither is `config/initializers/`, and the reason is concrete: initializers run on every
boot including production, where a test-only gem is not in the bundle, so an initializer
calling `Constable.configure` takes the app down with a NoMethodError. Same reason RSpec,
SimpleCov, WebMock and Capybara all configure from the test helper.

### `.constable/config.yml` is now genuinely optional

You can delete it. `rails generate constable:install --skip-config` never writes it.

The one thing keeping it mandatory was `storage`, which cannot be set in Ruby for the
ordering reason above. It now reads from the environment as well, which is the right shape
for CI anyway, where the value is a secret and differs per machine:

```
CONSTABLE_STORAGE_URL=postgres://user:pass@host/constable_metadata
CONSTABLE_STORAGE_PATH=/var/lib/constable/blotter.sqlite3
CONSTABLE_STORAGE_ADAPTER=postgres
```

An adapter is inferred from the URL scheme when it is not given, and an empty variable
means unset rather than "connect to the empty string". The `.constable/` **directory**
still exists to hold the blotter — deliberately not `tmp/`, which `rails tmp:clear` and
most deploys would wipe, taking weeks of flake history with it.

One bug found while checking this end to end, in the override layer added above: settings
were applied *after* the selection had already been asked for its targets, so
`c.cold_cases` in Ruby was silently ignored and a suite of 192 ran 35. Overrides are now
applied between requiring the helper and asking the selection anything.

### Settings added after you install are no longer invisible

`.constable/config.yml` doubles as the reference — every key at its default, with the
reasoning above it — which only works if it stays current. A gem upgrade cannot rewrite it
without clobbering your settings, and Thor's only other answer is to skip the file, so
**`output` shipped in 1.0.0 and never appeared in any existing config.** The first anyone
knew was running `bundle update` and finding the setting missing.

`rails generate constable:install` now appends only the settings your file does not
mention, each with its explanation, under a header saying where they came from. Your
values and your own comments are never touched. Re-run it after any upgrade.

### `constable prune`

A test's key is a content hash of its body, so editing a jailed test gives it a new
identity and leaves the old row behind — pointing at a `file:line` that may now hold
something else. That is identity working as designed, and it was the one known limitation
left open in 1.0.0. This is the broom:

```console
$ constable prune --dry-run   # list what would go
$ constable prune             # forget it
```

It loads the whole suite first, because which tests still exist is only knowable once
every case file has been read, and it is deliberately conservative in two directions:

- **A known identity is never pruned**, even when the file recorded beside it is gone. The
  path is a display label; the identity is the truth. A test that moved file has an
  out-of-date label, not a missing test.
- **A cold case is never pruned while its file exists.** Cold-case tests cannot be
  enumerated without running their own engine, so their absence says nothing.

Flake history is left alone either way — only the docket and outstanding warrants are
touched.


## [1.0.0]

The first release anybody should install.

0.1.0 shipped the ideas; running it against a real Rails app for the first time found
that several of them did not survive contact. Four bugs made the documented adoption
path impossible to follow, three commands raised `NoMethodError` the moment they were
run, and three separate ways of mistyping a command produced a **green build that ran no
tests at all**. Those are all fixed, with tests, and the suite has grown from 738 runs to
888.

The API has not changed. Every 0.1.0 case file, config key and command still works.

### The adoption path now actually works

These four were found by installing 0.1.0 into a Rails app with a 188-example RSpec
suite and following the README from the top.

- **`rails generate constable:install` no longer breaks the Gemfile.** It appended a
  `:cold_case` group declaring `rspec-rails` without checking whether the app already
  had it. Any app adopting Constable *from RSpec* — which is the entire target audience
  — was left with a Gemfile Bundler refused to parse: *"You cannot specify the same gem
  twice with different version requirements."* The installer now adds only the engines
  the repo has files for, and only ones the Gemfile does not already declare.

- **Cold cases run `before(:suite)` and `after(:suite)` hooks.** `ColdCase::RSpec` drove
  example groups directly and skipped RSpec's `with_suite_hooks`, so the hooks never
  fired. That is where `webmock/rspec` calls `WebMock.enable!`, where VCR and
  DatabaseCleaner install themselves, and where SimpleCov starts. It failed *open*: a
  spec that stubbed HTTP opened a real socket instead of erroring. Each hook now runs
  exactly once per run — after a file has loaded, since a legacy file's own
  `require "rails_helper"` is what registers them.

- **Parallel workers get their own database.** Constable forks its own workers and so
  never picked up the per-worker databases Rails builds for `rails test`. Every worker
  opened the same one. On SQLite a suite that passed 188/0 serially collapsed into 130
  `database is locked` failures. On a client/server database it would have been quieter
  and worse. A worker that cannot build its own database now raises rather than falling
  back to the shared one, and an app that cannot shard runs serially with a warning.

- **An outage no longer jails healthy tests.** Flake history reads "passed last run,
  failed this run" as evidence about a test, so that one broken parallel run put 29
  healthy tests on the docket marked *"passed, then failed with no code change"*. A run
  where a quarter of the suite fails with the identical error is now recognised as one
  broken run: the failures still stand and the build still goes red, but nothing moves
  through the jail or parole state machine and nothing is written to flake history.

- **`constable:install` writes the blotter into `.gitignore`.** It is this machine's
  flake history and docket. Committing it hands CI somebody else's docket and conflicts
  on every run.

- **FactoryBot is wired into the tier base classes,** and `test/support/**` loads
  *before* them. `create(:user)` is what a converted spec is full of, and the generated
  `case_helper.rb` both omitted the include and told you to `include Authenticatable` in
  a class defined thirty lines above the file that defines it.

### Commands that had never been run

There was no test file for the CLI at all. All three of these are in the published
command reference and all three raised `NoMethodError` on their first line:

- `constable jail parole PATH:LINE`
- `constable jail release PATH:LINE`
- `constable warrants release PATH:LINE` — twice over: after fixing the first bug it
  went on to call a second method that does not exist either.

Ambiguous targets are also refused rather than guessed at. `constable jail parole
test/cases/reports_case.rb`, with three tests from that file on the docket, paroled one
of them — not the first by line, whichever row the database happened to return. It now
prints the candidates and exits.

### Three ways to get a green build that ran nothing

Each of these printed `0 passed, 0 failed` and exited **0**, so a typo in a CI script
went green having tested nothing. The most expensive kind of bug a test runner can have,
because it stays invisible for months.

- `constable test test/cases/typo_case.rb` — no such file.
- `constable test users_case.rb:999` — worse than nothing. `PATH:LINE` picks the
  investigation declared nearest above the line so you can point anywhere inside a
  block; unbounded, a line past the end of the file ran the **last** investigation in
  it. Not the test you asked for, not an error, green either way.
- `constable test --tier nonsense` — and `--tier UNIT`, which matched nothing because
  tiers were case-sensitive.

### Correctness

- **Two tests no longer share one identity.** A test's key is a content hash of its
  body, which is what lets history survive a rename — but two tests with byte-identical
  bodies got the same key, in different classes, with different descriptions. The
  blotter treated them as one test: jail either and both went, and their flake histories
  merged. This is routine rather than exotic; the model generator writes an identical
  first investigation into every file it touches.

- **A witness can no longer replace the framework.** `witness` defines a real instance
  method, so `witness(:class)` quietly replaced `Object#class` and every later failure
  message reported the wrong thing. `witness(:attest)` was worse: it disabled assertions
  outright, so the tests passed by doing nothing.

- **`be(nil)` asserted the opposite of what it said.** `[nil].any?` is false — `Array#any?`
  without a block tests the truthiness of the elements, not presence — so it fell through
  to the truthiness branch.

- **`match_array` was aliased to `contain_exactly`,** but RSpec's takes one array where
  `contain_exactly` takes varargs, so `match_array([1, 2])` asserted the collection held
  a single element which was itself `[1, 2]`.

### Matchers

`constable modernize` rewrote any matcher name straight into an `attest` call, so a spec
using one Constable did not implement converted cleanly and then died at runtime.

- Added: `contain_exactly`, `match_array`, `be` (identity, truthiness, and the
  `be >= 0` operator form), `be_within(d).of(x)`, `start_with`, `end_with`,
  `be_between`, `satisfy`.
- `modernize` now **flags any matcher it does not recognize** instead of converting it.
- `have_http_status` resolves names through `Rack::Utils` and knows
  `:unprocessable_content` — the Rack 3.1 name for 422, and the one Rails 8.1 tells you
  to use while Constable accepted only the deprecated spelling.
- Helper specs are flagged. They converted reporting *"21 converted, 0 flagged"* and
  then failed every example with `undefined local variable or method 'helper'`.

### Output

- **An `expanded` mode.** `output: concise | expanded` in `.constable/config.yml`, or
  `--expanded` / `--concise` for one run. Concise is unchanged and still the default.
  Expanded prints a line per test — glyph, description, duration — so you can see which
  test is hanging while it hangs. Per-test durations are in milliseconds; the run-scale
  format rendered every fast test as `0.0s`.
- **Sections for the supervision states.** Jailed tests, warrants and tests on parole
  were counted in the headline and then never mentioned again, so "2 jailed" was a
  number with nothing behind it. `WARRANTS`, `JAILED` and `ON PAROLE` now print like
  `FAILURES` does.
- **Each one ends with what to do next.** "2 jailed" is a fact;
  `constable jail parole PATH:LINE` is an action. Parole shows its progress toward
  release.
- Parole entries carry their `file:line` — the one thing their own hint asked you to
  pass — and warning text wraps to the 60-column frame instead of spilling out of it.

### Messages instead of stack traces

- A YAML typo in `config.yml` raised a raw `Psych::SyntaxError`; a file that parsed but
  was not a mapping raised *"no implicit conversion of Array into Hash"* from inside the
  merge. Both now name the file and the problem.
- A corrupt blotter raised *"file is not a database: PRAGMA journal_mode = WAL"*. It now
  says what the file holds — flake history, the docket, warrants, never a test — and
  that deleting it is safe.
- `coverage_threshold` is clamped to a percentage, negative `warrant_retries` means off,
  and `parole_period` clamps in one place. `Jail` already refused a period of zero, but
  the reporter read the raw value and would print *"Day 1 of 0 — 0 clean runs to go"*
  while the docket waited for ten.

### Also

- A new logo, with a dark variant, and a `<picture>` element so GitHub picks.


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

[Unreleased]: https://github.com/Ray-Hughes/constable/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/Ray-Hughes/constable/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/Ray-Hughes/constable/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Ray-Hughes/constable/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Ray-Hughes/constable/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/Ray-Hughes/constable/releases/tag/v0.1.0
