<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/Ray-Hughes/constable/main/docs/assets/logo-dark.png">
  <img src="https://raw.githubusercontent.com/Ray-Hughes/constable/main/docs/assets/logo.png" alt="Constable" width="340">
</picture>

**A strict Rails testing framework where fast and non-flaky are structural, not disciplinary.**

[![Gem Version](https://badge.fury.io/rb/constable-rails.svg)](https://badge.fury.io/rb/constable-rails)
[![CI](https://github.com/Ray-Hughes/constable/actions/workflows/ci.yml/badge.svg)](https://github.com/Ray-Hughes/constable/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D)](https://www.ruby-lang.org)
[![Rails](https://img.shields.io/badge/rails-%3E%3D%207.0-D30001)](https://rubyonrails.org)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE.txt)

[Install](#installation) · [Quick start](#quick-start) · [Documentation](#documentation) · [Contributing](#contributing)

</div>

---

```ruby
class UsersController::CreatesUserCase < IntegrationCase
  witness(:valid_params) { { user: { email: "a@b.com", password: "secret123" } } }

  briefing { stub_network! }

  investigate "creates a user with valid params" do
    freeze_time

    post users_path, params: valid_params

    attest(response).to be_created
    attest(User).to exist(email: "a@b.com")
  end
end
```

Most suites are fast and reliable because a team keeps them that way by hand. Constable
makes it structural instead — isolation you cannot opt out of, nondeterminism caught by a
linter instead of by CI, and an adoption path that never asks you to rewrite anything.

> **Installed as `constable-rails`.** The name `constable` was claimed on RubyGems in 2011
> by an unrelated, long-abandoned gem. That is the only thing the suffix affects —
> everything you actually type is `constable`: the module, the CLI, the config directory,
> the generators.

## Table of contents

- [Why](#why)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Documentation](#documentation)
  - [The DSL](#the-dsl)
  - [Tiers](#tiers-are-base-classes-not-magic)
  - [Matchers](#matchers)
  - [Shared behavior](#shared-behavior-is-just-ruby)
  - [Rails generators](#rails-generators)
  - [Adopting an existing suite](#adopting-an-existing-suite)
  - [Escape hatches](#escape-hatches-always-visible)
  - [The linter](#the-linter)
  - [Jail, parole and warrants](#jail-parole-and-warrants)
  - [Identity survives renames](#identity-survives-renames)
  - [Command reference](#command-reference)
  - [Output](#output)
  - [The blotter](#the-blotter)
  - [Configuration](#configuration)
- [Contributing](#contributing)
- [Reporting a problem](#reporting-a-problem)
- [License](#license)

## Why

1. **Isolation is non-negotiable in native code.** No class-level shared state, no
   `before(:all)` equivalent. Every native test gets a clean transaction and a clean
   object graph.
2. **Nondeterminism is caught by the linter, not discovered in CI.** Bare `sleep`,
   unfrozen `Time.now`, and unstubbed network calls are lint errors before they are flakes.
3. **Adoption never requires a rewrite.** A whole existing RSpec or Minitest file runs
   completely untouched from day one. Strictness applies to new code — it is not a
   precondition for installing the gem.
4. **Every escape hatch is visible.** An `unsafe` block, a cold case, a jailed test — none
   are ever silent. They are reported every run until someone deals with them.
5. **Fast is the default, not an opt-in.** Boot tiers, parallel workers and git-diff test
   selection all ship in the base gem.

## Requirements

| | Minimum | Notes |
|---|---|---|
| **Ruby** | **3.1** | Parallel workers use `fork`, so they are unavailable on Windows and JRuby; those platforms fall back to serial automatically. |
| **Rails** | **7.0** | Tested against 7.1 and 8.1. |

Constable pulls in five gems, all of them small and already present in most Rails apps:

| Gem | Version | What needs it |
|---|---|---|
| `activesupport` | `>= 7.0` | `freeze_time` / `travel_to` delegate to it when it's there |
| `railties` | `>= 7.0` | the generators and the railtie that registers Constable as your test framework |
| `thor` | `>= 1.2` | the `constable` CLI |
| `sqlite3` | `>= 1.6` | the blotter — flake history, the jail docket, warrants |
| `parser` | `>= 3.1` | the AST rewrite behind `constable modernize` |

Your app's own database is untouched by any of this: the blotter is a separate SQLite file
Constable owns. See [The blotter](#the-blotter).

Nothing else is required. These are all optional, and only if you want the feature:

| Optional | For |
|---|---|
| `rubocop-constable` | the linter — the seven cops that catch nondeterminism at edit time |
| `rspec-rails` / `minitest` | cold cases, if you are adopting an existing suite |
| `capybara` + a driver | the `:system` tier |
| `pg` / `mysql2` | pointing the blotter at Postgres or MySQL instead of SQLite |

## Installation

```ruby
# Gemfile
group :development, :test do
  gem "constable-rails"
  gem "rubocop-constable", require: false
end
```

```console
$ bundle install
$ rails generate constable:install
```

That writes `test/case_helper.rb`, `test/support/`, `.constable/config.yml`, a `.rubocop.yml`
snippet, and a worked example case so `constable test` does something immediately.

## Quick start

```console
$ constable test              # only what your current git diff touches
$ constable test --full       # everything. this is what CI runs
$ constable test path/to/case.rb:12
```

## Documentation

### The DSL

The vocabulary is the API, not decoration.

| Constable | Replaces | Notes |
|---|---|---|
| `Constable::Case` | `describe` / `TestCase` | One file, roughly one subject under test |
| `investigate "..." do` | `it` / `def test_` | A plain string — punctuation and interpolation are fine |
| `witness(:name) { }` | `let` | Memoized **per test**, never per process |
| `briefing do ... end` | `before` / `setup` | Runs before every investigation. There is no `before(:all)` |
| `docket "..." do ... end` | nested `describe` | Grouping that introduces no shared state |
| `attest(x).to matcher` | `expect(x).to` | Sugar over `assert_*` primitives, which are always available too |

`investigate` is a **registration DSL, not a method definition.** Each block runs in its own
fresh instance, fully isolated from every other one.

```ruby
class UsersController::CreatesUserCase < IntegrationCase
  docket "as an admin" do
    briefing { sign_in(:admin) }

    investigate "creates a user with valid params" do
      post users_path, params: valid_params
      attest(response).to be_created
    end
  end

  docket "as a guest" do
    investigate "is redirected to sign in" do
      post users_path, params: valid_params
      attest(response).to redirect_to(sign_in_path)
    end
  end
end
```

### Tiers are base classes, not magic

```ruby
# test/case_helper.rb
class UnitCase < Constable::Case
  tier :unit
end

class IntegrationCase < Constable::Case
  include Constable::RailsSupport::Integration
  tier :integration
end

class SystemCase < Constable::Case
  include Constable::RailsSupport::System if defined?(Capybara)
  tier :system
end
```

Subclass whichever fits. Path-based inference (`test/cases/models/**` → `:unit`) still works
as a fallback, but ordinary inheritance is the recommended pattern — nothing to infer.

`RailsSupport::Integration` is what gives a case `get`/`post`, `response` and your app's URL
helpers; `RailsSupport::System` gives it Capybara and `driven_by`. `UnitCase` gets neither,
deliberately — that is the tier that boots without them. The installer writes all three.

Rails' testing modules expect minitest's lifecycle, so `Constable::Case` also answers to the
`setup` and `teardown` class macros. `setup` is an exact synonym for `briefing` and exists so
those modules compose — **`briefing` is still the way to write setup.**

### Matchers

```ruby
# test/support/matchers.rb
Constable::Matchers.define(:be_created) { |response| response.status == 201 }
Constable::Matchers.define(:exist) { |model_class, attrs| model_class.exists?(attrs) }
```

Built in: `eq`, `eql`, `be`, `include`, `match`, `raise_error`, `have_attributes`,
`exist`, `be_created`, `redirect_to`, `have_http_status`, `change`, `contain_exactly`,
`match_array`, `start_with`, `end_with`, `be_between`, `be_within(d).of(x)`, `satisfy`,
plus `be_a`, `be_nil`, `be_empty`, `be_truthy`, `be_falsey` and a `be_*` / `have_*`
predicate fallback. `be` also takes the operator form — `attest(count).to be > 0`.
Plain `assert_*` and `refute_*` primitives are always available alongside `attest`.

The set is deliberately smaller than RSpec's, so `constable modernize` **flags any
matcher it does not recognize** rather than converting it into a case that only fails
once you run it.

### Shared behavior is just Ruby

There is deliberately no shared-examples mechanism. Reuse across files is a module:

```ruby
# test/support/authenticatable.rb
module Authenticatable
  def sign_in(user)
    post session_path, params: { email: user.email, password: "password" }
  end
end
```

`include Authenticatable` in any case. Ruby's own composition tools are more flexible than a
parallel DSL that does the same job.

### Rails generators

`rails generate` asks whatever is registered as the app's test framework what a test file
looks like. Constable registers itself, so scaffolds produce cases rather than Minitest
files for a framework you replaced.

```console
$ rails generate scaffold Post title:string
      create  test/cases/controllers/posts_controller_case.rb
      create  test/cases/system/posts_case.rb
```

Every generator Rails hooks is covered — `model`, `controller`, `scaffold`, `integration_test`,
`system_test`, `mailer`, `job`, `helper`, `channel`, `mailbox`, `generator`, `resource` — each
writing a case that subclasses the right tier base class.

No fixtures are generated, deliberately: a `witness` builds exactly what one investigation
needs and throws it away with it. A factory gem registered as your `fixture_replacement`
still gets its turn.

### Adopting an existing suite

Nothing gets rewritten. **Cold cases** run your original file through its own real engine —
RSpec or Minitest — and feed pass/fail/timing into Constable's reporting, flake history and
CI gate alongside native cases.

**One line changes.** The file body is untouched:

```ruby
class LegacyUsersSpec < Constable::ColdCase::RSpec
  describe UsersController do
    it "creates a user" do
      post users_path, params: valid_params
      expect(response).to have_http_status(:created)
    end
  end
end
```

**Or nothing changes at all** — match the path in config:

```yaml
cold_cases:
  - spec/controllers/**/*_spec.rb
```

```console
$ constable import --from=rspec        # reopen everything, verbatim
$ constable modernize spec/controllers/users_controller_spec.rb --alongside
```

`modernize` converts `describe`/`it` → `Constable::Case`/`investigate`, `let` → `witness`,
`before` → `briefing`, `expect` → `attest`, and `def test_foo` → `investigate "foo"`. It
**flags `before(:all)` and `let!` rather than converting them** — those need a human decision —
and leaves custom matchers and `shared_examples` alone, logging everything to
`constable_modernize_report.md`. It writes nothing unless you ask it to.

Native and cold cases run side by side in one `constable test`. No big-bang cutover.

### Escape hatches, always visible

```ruby
investigate "times out after thirty seconds" do
  unsafe { sleep(0.1) } # testing an actual timeout path, not a code smell
  attest(subject).to have_timed_out
end
```

Every `unsafe` emits a warning with its `file:line` and that adjacent comment as the reason.
One warning per cold-case *file*, one per `unsafe` occurrence. Warnings never fail the build
by default — `fail_on_warnings: true` opts CI into enforcing a downward trend — but they are
never silent either.

### The linter

`rubocop-constable` is scoped to native cases only; cold cases are exempt by design.

| Cop | Catches |
|---|---|
| `NoSleep` | bare `sleep` outside `unsafe` |
| `NoUnfrozenTime` | `Time.now` / `Date.today` / `Time.current` outside `freeze_time`/`travel_to` |
| `NoNetworkWithoutStub` | HTTP calls without `stub_network!` |
| `NoSharedMutableState` | class variables and globals mutated across investigations |
| `NoConditionalAssertions` | `if`/`else` branching around assertions |
| `NoRetryHelpers` | any retry/eventually pattern |
| `UnsafeBlockVisibility` | an `unsafe` block with no comment explaining why |

### Jail, parole and warrants

A large red legacy suite has an on-ramp. Run once in jail mode for a clean baseline, then
work the docket down.

```console
$ constable test --jail          # failures get jailed instead of failing the build
$ constable jail                 # the docket: reason, file:line, date jailed
$ constable jail run             # re-run jailed tests sequentially
$ constable jail parole PATH:LINE
$ constable jail release PATH:LINE
```

Jailing isn't hiding — it swaps "blocks the build" for "tracked and skipped." Jailed tests are
always their own summary category, never folded into passed, and their `briefing`/`witness`
setup still runs so setup rot surfaces immediately.

**Parole** is "probably fixed, not fully trusted yet." A paroled test runs normally but is
watched: one failure is an immediate violation straight back to jail, and `parole_period`
consecutive clean runs (default 10) auto-releases it. `jail run` never auto-releases on a
pass — a single green run doesn't prove anything.

**Warrants** answer a different question — not "does this block the build" but "is this
failure even real." With warrants on, a failing test is rerun in isolation `warrant_retries`
times (default 5). Fails every retry, it's a genuine failure. Passes even once, it's flaky
rather than broken: a warrant is written to the blotter, never to your source, and the result
stops blocking the build while staying loudly visible.

```console
$ constable warrants
$ constable warrants release PATH:LINE
$ constable watchlist    # everything under supervision: jailed, paroled, warranted
$ constable status       # trend: native-vs-cold %, recent runs, slowest historically
```

### Identity survives renames

Each test's key is a **content hash of its `investigate` block body**, whitespace-normalized.
Class name, description and file are stored alongside purely as a display label.

- Rename the class, reword the description, move the file → hash untouched, history carries over.
- Change what the test actually *does* → hash changes, history starts fresh. Correct, not a limitation.
- Renamed *and* tweaked in one commit? Constable notices an old test vanishing as a similar
  new one appears and suggests `constable history relink OLD NEW`. Set `auto_relink: true` to
  confirm high-confidence matches automatically.

Two tests with byte-identical bodies would otherwise share a key — and bodies repeat more
than the phrase "content hash" suggests, since
`attest(build(:thing, name: nil)).not_to be_valid` is the same handful of tokens in every
model case. Constable re-keys colliding tests on their class and description once the
suite is loaded, so no two tests ever share a docket row. Rename-survival is weaker for
exactly those tests, which is the right trade: a history belonging to two tests at once is
worse than one that resets.

### Command reference

| Command | Runs |
|---|---|
| `constable test` | Everything, git-diff-scoped locally |
| `constable test --full` | The whole suite. CI always uses this |
| `constable test PATH[:LINE]` | One file, or one investigation at that line |
| `constable test --unsafe` | Cold cases only |
| `constable test --jail` | The full run, in jail mode |
| `constable jail [run\|parole\|release]` | The docket. `release --all` empties it |
| `constable warrants [release]` | Outstanding warrants |
| `constable watchlist` | Everything under supervision right now |
| `constable status` | How the suite is doing over time |
| `constable beat [--html]` | Coverage: overall %, per-file, the unpatrolled list |
| `constable history relink OLD NEW` | Carry history across a real body change |
| `constable prepare [--workers N]` | Build the per-worker test databases `worker_databases: reuse` needs |
| `constable prune [--dry-run]` | Forget docket rows and warrants for tests that no longer exist |
| `constable import --from=rspec` | Adopt an existing suite as cold cases |
| `constable modernize PATH [--cold]` | Opt-in AST rewrite into the native DSL. `--cold` moves it verbatim instead |

Flags: `--full --unsafe --jail --warrants --coverage --seed N --workers N --verbose --tier T\n--expanded --concise --output MODE --no-color`.

Order is randomized every run for native cases, with the seed printed and replayable via
`--seed`. Cold cases keep their own engine's order. Workers run in parallel by default,
load-balanced by a cached per-test duration index.

Each worker gets **its own database**, built from schema the way `rails test` does it —
or kept between runs, with `worker_databases: reuse`, which is both faster and the only
thing that works for an app whose schema cannot rebuild the database by itself (any app
with Postgres custom types: `CREATE TYPE` has no `schema.rb` representation). Prepare
those once with `constable prepare`, and again after a migration — kept databases do not
follow one on their own. Forgetting is caught rather than suffered: Constable compares
what each worker database has migrated against the real test database before it forks, and
runs serially (which uses the real one, so it is correct) rather than testing yesterday's
schema.
Sharing one would not be a speed/safety trade but a correctness bug: on SQLite the run
dissolves into `database is locked`, and on a client/server database tests quietly see
each other's rows. If your app has ActiveRecord but cannot shard, Constable runs serially
and says why — slow is a trade-off, wrong is not.

The database is not the only thing a worker needs to itself. Anything your suite keeps on
disk per process — a browser cache, a download directory, a screenshot path — needs a name
that differs per worker, or they race for it. Each worker is told which one it is:

```ruby
worker = ENV["CONSTABLE_WORKER"] ? "_w#{ENV['CONSTABLE_WORKER']}" : ""
cache  = Rails.root.join("tmp/browser_cache#{worker}")
```

Some databases cannot be given to each worker at all — Oracle and anything else Rails does
not manage (`database_tasks: false`). Constable does not try, and now says so at the start
of a parallel run, because *skipped* and *safe* are different claims:

```
⚠ vacols (database_tasks: false) cannot be given to each worker, so all of them share it.
  Tests that write to it will interfere with each other, and the failures will not look
  like a parallelism problem -- they look like rows vanishing mid-test.
```

That warning is worth taking literally. On a real app with a legacy Oracle database, a
four-worker run produced 163 failures that all passed serially; 53 of them were a bare
`VacolsRecordNotFound`, because each worker's `before(:suite)` deleted from the one shared
database while the others were midway through tests that had just written to it.

**And a harder limit, if your app talks to one through a C driver: forking may not be
possible at all.** The same app aborts roughly half its parallel runs with SIGABRT — no
output on either stream, the crash report landing inside `libclntsh`, Oracle's client
library catching a SIGSEGV in its own signal handler. It is not a Constable failure and
there is nothing Constable can do about it: a process holding OCI handles is not reliably
forkable. If you see bare exit code 134 and no output, check
`~/Library/Logs/DiagnosticReports` (or your platform's equivalent) before assuming the test
runner ate your suite, and run those specs with `worker_databases: off`.

`CONSTABLE_WORKER` is the index and `CONSTABLE_WORKERS` the count; both are unset in the
parent, so serial runs keep whatever name they had. Use `FileUtils.mkdir_p` rather than
`Dir.mkdir ... unless File.directory?` while you are there — the second is a race, and if
it runs inside `spec/support` it takes `rails_helper` down with it, which costs the loser
its database cleaning rather than just its cache directory.

### Output

stdout is reserved for results — not just Constable's own output, but the app's. Rails
loggers, SQL, request/response logging, and anything a gem prints to `$stdout` or
`$stderr` mid-run all go to `log/test.log`; `--verbose` streams it back for active
debugging.

That matters more than it sounds. A gem warning fired once per file lands in the middle of
the live stream, and you get `Address ✓✓✓✓✓✓...`
instead of a readable run. The one thing Constable deliberately does not intercept is a
write straight to file descriptor 2 — capturing that would also swallow a real crash and
break `binding.pry`, so `2>/dev/null` stays yours to decide on.

**While it runs**, the live stream has two modes. `concise` is the default: one glyph per
test, grouped into a run per case, so a thousand-test suite stays inside one screen and a
wall of green is the point.

```
  ProjectCase                       ✓✓✓✓✓✓✓✓✓✓✓✓
  BillingCase                       ✓✓⚖⛓✓
```

`expanded` trades that for a line per test — glyph, name, duration — so you can see which
test is hanging while it hangs, rather than after.

```
  ProjectCase
    ✓ validations rejects a colour outside the palette  2ms
    ✓ validations rejects a duplicate name for the same owner 12ms
    ✗ #completion_ratio is the fraction of done tasks   8ms

  BillingCase
    ⚖ charges a card                                    310ms
    ⛓ refunds a charge — assertion failed on the amount
    ✓ issues a receipt                                  1.4s
```

Set it in `.constable/config.yml` (`output: concise` or `expanded`), or per run with
`--expanded` / `--concise`. A jailed test never ran its body, so it is given no duration
rather than a dishonest `0ms`. **The summary below is identical in both modes** — the mode
only changes what you watch on the way there.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CONSTABLE            6 tests · 3 cases · 12.4s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ 2 passed   ✗ 1 failed   ⛓ 2 jailed (1 parole violation)   ◑ 1 on parole   ⚖ 1 warrant issued   ⚠ 2 warnings   ◐ 92% covered (3 files unpatrolled)

  PAROLE VIOLATED
  ───────────────
  ⛓ UsersController::CreatesUserCase
    "creates a user with valid params"
    spec/cases/users_controller/creates_user_case.rb:8
    Failed on day 3 of a 10-run parole — back to jail. This is its 2nd time in jail.

  → Somebody trusted this test again and it let them down,
    so it is back on the docket. Fix it before the next
    constable jail parole — a second violation is the signal
    that the test, not the flake, is the problem.

  FAILURES
  ────────
  ✗ SessionsCase
    "expires after inactivity"
    spec/cases/sessions_case.rb:12

    Expected response to be :created, got :unprocessable_entity

    Response body:
      { "errors": ["Email has already been taken"] }

    Rerun just this test:
      constable test spec/cases/sessions_case.rb:12 --seed 8841

  WARRANTS
  ────────
  ⚖ BillingCase
    "charges a card"
    spec/cases/sessions_case.rb:12
    Failed, then passed 4 of 5 retries run in isolation.

  → A warrant is "not reproducible", not "not a problem" —
    it stops blocking the build and stays visible until
    someone deals with it. Fixed the flake? constable
    warrants release PATH:LINE

  JAILED
  ──────
  ⛓ BillingCase
    "refunds a charge"
    spec/cases/sessions_case.rb:12
    Assertion failed on the amount.

  → Jailed means skipped and tracked, not passing. Think one
    is fixed? constable jail parole PATH:LINE runs it for
    real again — 10 clean runs and it releases itself.

  ON PAROLE
  ─────────
  ◑ SessionsCase
    "signs a user in"
    spec/cases/sessions_case.rb:12
    Day 4 of 10 — 6 clean runs to go.

  → A paroled test runs for real and is watched: one failure
    sends it straight back to jail. constable watchlist
    shows everything under supervision.

  WARNINGS
  ────────
  ⚠ spec/legacy/old_users_spec.rb
    running as a cold case (Constable::ColdCase::RSpec) — 12
    tests not yet under native rules

  ⚠ spec/controllers/sessions_case.rb:44
    unsafe { sleep(0.1) } — "testing an actual timeout path,
    not a code smell"

  SLOWEST
  ────────
  3.2s  UsersController::CreatesUserCase "creates a user with valid params"
  1.1s  SessionsCase "times out after thirty seconds"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Sections print worst-to-least-urgent: parole violations, failures, warrants, jailed, on
parole, warnings, slowest. A section only appears when it has something to say.

Each supervision section ends with one line saying what to do next, because "2 jailed" is
a fact and `constable jail parole PATH:LINE` is an action. Failures don't get a hint —
they already end with the exact command to rerun them.

### The blotter

Flake history, the jail docket and warrants live in a store Constable owns entirely — by
default a self-contained `.constable/constable.sqlite3` in WAL mode. Never your app's
database: native cases roll back their transaction and would roll this data back with it,
`:unit`-tier runs skip booting the DB stack for speed, and the workload is a handful of
tables that doesn't need a client-server database.

Teams who need one queryable store across many CI machines can point it elsewhere — always a
separate connection from the app's own:

```yaml
storage:
  adapter: postgres
  url: postgres://user:pass@host/constable_metadata
```

### Configuration

Settings can be written in Ruby, in `test/case_helper.rb` — the same place RSpec puts
`RSpec.configure` — or in `.constable/config.yml`, or on the command line. The most
specific wins:

```
a CLI flag              --workers 4, --expanded      one run
Constable.configure     test/case_helper.rb          code you deliberately ran
.constable/config.yml   the project's declared default
Constable's defaults
```

Every key below can be set in either place. Put settings that differ per machine or per
branch in the YAML, where they are obvious and greppable; put settings that have to be
*computed* in Ruby, because YAML cannot:

```ruby
# test/case_helper.rb
Constable.configure do |c|
  c.parallel_workers = ENV.fetch("CI_WORKERS", 4).to_i
  c.coverage         = ENV["CI"] == "true"
  c.output           = :expanded
end
```

Not `config/initializers/`, which is where a runtime gem like Devise goes. Initializers
run on **every** boot including production, where a test-only gem is not in the bundle, so
an initializer calling `Constable.configure` takes the app down. It is the same reason
RSpec, SimpleCov, WebMock and Capybara all configure from the test helper.

`config.yml` is optional, and one setting is the reason it exists: **`storage` can only be
set there.** The blotter is opened before `case_helper.rb` loads, so that `constable jail`,
`warrants`, `watchlist` and `status` can read the docket without booting the app — a
broken app should not stop you reading the docket. Setting it in Ruby raises rather than
being quietly ignored.

Beyond that it is a preference. A settings file is greppable and diffable without running
anything, which suits values that differ per project or per branch; Ruby suits anything
computed.

`config.yml` doubles as the reference, so re-run
`rails generate constable:install --skip` after an upgrade: it appends any settings your
file does not mention and leaves your own values and comments alone. (`--skip` so the
other generated files, which you have probably edited, are left as they are.)

```yaml
# .constable/config.yml
cold_cases:
  - spec/controllers/**/*_spec.rb

storage:
  adapter: sqlite                # sqlite (default) | postgres | mysql
  path: .constable/constable.sqlite3

warrants: false                  # opt-in flaky detector
warrant_retries: 5
auto_relink: false

parole_period: 10                # consecutive clean runs to auto-release

coverage: false
coverage_threshold: 90           # diff-based — only lines changed in the current diff
coverage_html: false

fail_on_warnings: false
output: concise                  # live stream detail: concise | expanded
parallel_workers: auto

tiers:                           # fallback inference; base classes are primary
  unit: "test/cases/models/**/*"
  integration: "test/cases/controllers/**/*"
  system: "test/cases/system/**/*"
```

## Contributing

Bug reports and pull requests are welcome at
<https://github.com/Ray-Hughes/constable>.

```console
$ git clone git@github.com:Ray-Hughes/constable.git
$ cd constable
$ bin/setup
$ bundle exec rake test      # the framework's own suite
$ bundle exec rake cops      # the RuboCop extension's suite
$ bundle exec rubocop        # lint
```

The repo holds two gems: `constable-rails` at the root, and `rubocop-constable` in its own
directory with its own gemspec and suite. `docs/ARCHITECTURE.md` is the interface contract
between components and is worth reading before a substantial change; `docs/SPEC.md` is the
product spec.

A few house rules, so a change lands cleanly:

- **Constable's own suite is Minitest**, not Constable — it cannot test itself before it
  works. Add tests under `test/unit/` or `test/integration/`.
- **New behavior needs a test that would fail without it.** Several of the nastiest bugs in
  this gem were invisible to unit tests and only appeared when the real binary ran against a
  real Rails app; an integration test is often the honest one.
- **Keep `rake test` and `rubocop` green.** CI runs both on Ruby 3.1, 3.2 and 3.3.
- Comments explain *why*, not *what*.

## Reporting a problem

Please open a [GitHub issue](https://github.com/Ray-Hughes/constable/issues). Include:

- what you ran, and the full summary block it printed
- the seed, so the order is replayable (`constable test --seed N`)
- your Ruby and Rails versions, and whether the case is native or a cold case

If a test behaves differently alone than in a full run, say so explicitly — that is an
order-dependency bug and Constable has machinery specifically for it.

## License

[MIT](LICENSE.txt).
