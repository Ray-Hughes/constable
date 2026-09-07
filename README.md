# Constable

**An opinionated, strict Rails testing framework where fast and non-flaky are structural, not disciplinary.**

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

> **Installed as `constable-rails`.** The name `constable` was claimed on RubyGems in 2011 by
> an unrelated, long-abandoned gem. That's the *only* thing the suffix affects — everything
> you actually type is `constable`: the module, the CLI, the config directory, the generator.

---

## Why

Most suites are fast and reliable because a team keeps them that way by hand. Constable
makes it structural instead. Five ideas hold the whole thing up:

1. **Isolation is non-negotiable in native code.** No class-level shared state, no
   `before(:all)` equivalent. Every native test gets a clean transaction and a clean object graph.
2. **Nondeterminism is caught by the linter, not discovered in CI.** Bare `sleep`, unfrozen
   `Time.now`, and unstubbed network calls are lint errors before they're flakes.
3. **Adoption never requires a rewrite.** A whole existing RSpec or Minitest file runs
   completely untouched from day one. Strictness applies to new code — it isn't a
   precondition for installing the gem.
4. **Every escape hatch is visible.** An `unsafe` block, a cold case, a jailed test — none of
   them are ever silent. They're reported every run until someone deals with them.
5. **Fast is the default, not an opt-in.** Boot tiers, parallel workers and git-diff test
   selection all ship in the base gem.

## Install

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

That writes `test/case_helper.rb`, `test/support/`, and `.constable/config.yml`.

## The DSL

The vocabulary is the API, not decoration.

| Constable | Replaces | Notes |
|---|---|---|
| `Constable::Case` | `describe` / `TestCase` | One file, roughly one subject under test |
| `investigate "..." do` | `it` / `def test_` | A plain string description — punctuation and interpolation are fine |
| `witness(:name) { }` | `let` | Memoized **per test**, never per process |
| `briefing do ... end` | `before` / `setup` | Runs before every investigation. There is no `before(:all)` |
| `docket "..." do ... end` | nested `describe` | Grouping sugar that introduces no shared state |
| `attest(x).to matcher` | `expect(x).to` | Sugar over `assert_*` primitives that are always available too |

`investigate` is a **registration DSL, not a method definition.** Each block runs in its own
fresh instance, fully isolated from every other one.

### Dockets

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

`include Authenticatable` in any case. Ruby's own composition tools are more flexible than
a parallel DSL that does the same job.

### Tiering is base classes, not magic

```ruby
# test/case_helper.rb
class UnitCase < Constable::Case
  tier :unit
end

class IntegrationCase < Constable::Case
  tier :integration
end

class SystemCase < Constable::Case
  include Capybara::DSL
  tier :system
end
```

Subclass whichever fits. Path-based inference (`test/cases/models/**` → `:unit`) still works
as a fallback, but ordinary inheritance is the recommended pattern — nothing to infer.

### Custom matchers

```ruby
# test/support/matchers.rb
Constable::Matchers.define(:be_created) { |response| response.status == 201 }
Constable::Matchers.define(:exist) { |model_class, attrs| model_class.exists?(attrs) }
```

## Adopting an existing suite

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
# .constable/config.yml
cold_cases:
  - spec/controllers/**/*_spec.rb
```

```console
$ constable import --from=rspec     # reopen everything, verbatim
$ constable modernize spec/controllers/users_controller_spec.rb   # opt-in AST rewrite
```

`modernize` converts `describe`/`it` → `Constable::Case`/`investigate`, `let` → `witness`,
`before` → `briefing`, and `def test_foo` → `investigate "foo"`. It **flags `before(:all)`
rather than converting it** — that needs a human decision — and leaves custom matchers and
`shared_examples` alone, logging them to `constable_modernize_report.md`.

Native and cold cases run side by side in one `constable test`. No big-bang cutover.

## Escape hatches, always visible

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

## The linter

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

## Jail, parole and warrants

A large red legacy suite has an on-ramp. Run once in jail mode for a clean baseline, then
work the docket down.

```console
$ constable test --jail          # failures get jailed instead of failing the build
$ constable jail                 # the docket: reason, file:line, date jailed
$ constable jail run             # re-run jailed tests sequentially
$ constable jail parole PATH:LINE
$ constable jail release PATH:LINE
```

Jailing isn't hiding — it swaps "blocks the build" for "tracked and skipped," and jailed
tests are always their own summary category, never folded into passed. Their `briefing` and
`witness` setup still runs, so setup rot surfaces immediately.

**Parole** is "probably fixed, not fully trusted yet." A paroled test runs normally but is
watched: one failure is an immediate violation straight back to jail, and
`parole_period` consecutive clean runs (default 10) auto-releases it. `jail run` never
auto-releases on a pass — a single green run doesn't prove anything.

**Warrants** answer a different question — not "does this block the build" but "is this
failure even real." With warrants on, a failing test is rerun in isolation
`warrant_retries` times (default 5). Fails every retry, it's a genuine failure. Passes even
once, it's flaky rather than broken: a warrant is written to the blotter, never to your
source, and the result stops blocking the build while staying loudly visible.

```console
$ constable warrants
$ constable warrants release PATH:LINE
$ constable watchlist    # everything under supervision: jailed, paroled, warranted
$ constable status       # trend view: native-vs-cold %, flake trend, slowest 10
```

## Identity survives renames

Each test's key is a **content hash of its `investigate` block body**, whitespace-normalized.
The class name, description and file are stored alongside purely as a display label.

- Rename the class, reword the description, move the file → hash untouched, history carries over.
- Change what the test actually *does* → hash changes, history starts fresh. Correct, not a limitation.
- Renamed *and* tweaked in the same commit? Constable notices an old test vanishing as a
  similar new one appears and suggests `constable history relink OLD NEW`. Set
  `auto_relink: true` to confirm high-confidence matches automatically.

## Running tests

| Command | Runs |
|---|---|
| `constable test` | Everything, git-diff-scoped locally |
| `constable test --full` | The whole suite. CI always uses this |
| `constable test PATH[:LINE]` | One file, or one investigation at that line |
| `constable test --unsafe` | Cold cases only |
| `constable test --jail` | The full run, in jail mode |
| `constable beat [--html]` | Coverage: overall %, per-file, the unpatrolled list |

Order is randomized every run for native cases, with the seed printed and replayable via
`--seed`. Cold cases keep their own engine's order. Workers run in parallel by default,
load-balanced by a cached per-test duration index.

## Output

stdout is reserved for results. `Rails.logger`, SQL and request/response logging go to
`log/test.log`; `--verbose` streams it back for active debugging.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CONSTABLE            482 tests · 3 cases · 12.4s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ 478 passed   ✗ 2 failed   ⛓ 2 jailed (1 parole violation)   ◑ 1 on parole   ⚖ 1 warrant issued   ⚠ 3 warnings   ◐ 92% covered

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
```

Sections print worst-to-least-urgent: parole violations, then failures, then warnings, then
the slowest list. Failures carry their own context and point at your `investigate` line, not
at framework internals.

## The blotter

Flake history, the jail docket and warrants live in a store Constable owns entirely — by
default a self-contained `.constable/constable.sqlite3` in WAL mode. Never your app's
database, for three reasons: native cases roll back their transaction and would roll this
data back with it; `:unit`-tier runs skip booting the DB stack for speed; and the workload
is a handful of tables that doesn't need a client-server database.

Teams who genuinely need one queryable store across many CI machines can point it elsewhere —
always a separate connection from the app's own:

```yaml
storage:
  adapter: postgres
  url: postgres://user:pass@host/constable_metadata
```

## Configuration

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
parallel_workers: auto

tiers:                           # fallback inference; base classes are primary
  unit: "test/cases/models/**/*"
  integration: "test/cases/controllers/**/*"
  system: "test/cases/system/**/*"
```

## Development

```console
$ bin/setup
$ bundle exec rake test      # Constable's own suite (Minitest — it can't test itself yet)
$ bundle exec rake cops      # the rubocop-constable extension's suite
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
