# Constable

A build spec for an opinionated, strict Rails testing gem.

> Published on RubyGems as **`constable-rails`** (the name `constable` was taken in 2011).
> This is *only* the package name. Everything inside the gem is `constable`:
> module `Constable`, CLI `constable`, `require "constable"`, `.constable/config.yml`,
> `rails generate constable:install`. Nothing internal is renamed.

## What this is

Constable replaces RSpec/Minitest for Rails apps that want tests to be fast and non-flaky by construction, not by discipline. It leans fully into a sheriff/case-file motif for its DSL and vocabulary — this isn't decorative, the vocabulary is the API. Existing RSpec/Minitest suites can adopt it with a one-line change per file and zero rewriting; strictness applies to new code, not as a precondition for installing the gem.

## Core philosophy

1. **Isolation is non-negotiable in native code.** No class-level shared state, no `before(:all)` equivalent. Every native test gets a clean transaction and a clean object graph.
2. **Nondeterminism is caught by the linter, not discovered in CI.** Bare `sleep`, unfrozen `Time.now`/`Date.today`, and unstubbed network calls are lint errors in native code.
3. **Adoption never requires a rewrite.** A whole existing RSpec/Minitest file can run completely untouched from day one.
4. **Every escape hatch is visible.** Nothing that bends the rules — an unsafe block, a cold case, a jailed test — is ever silent. It's reported, every run, until someone deals with it.
5. **Fast is the default, not an opt-in.** Minimal boot tiers, parallel workers, and git-diff-based local test selection all ship in the base gem.

## The DSL — case-file motif

```ruby
class UsersController::CreatesUserCase < Constable::Case
  witness(:valid_params) { { user: { email: "a@b.com", password: "secret123" } } }

  briefing do
    stub_network!
  end

  investigate "creates a user with valid params" do
    freeze_time

    post users_path, params: valid_params

    attest(response).to be_created
    attest(User).to exist(email: "a@b.com")
  end
end
```

- **`Constable::Case`** — base class for a case file (one file, roughly one subject under test).
- **`investigate "description" do ... end`** — declares a test. The description is a plain string (not a method name translated from `snake_case`), so punctuation and interpolation are fine. This is a registration DSL, not literal method definitions — each `investigate` block runs in its own fresh instance, fully isolated from every other one.
- **`witness(:name) { ... }`** — a fixture/helper, memoized **per-test** (never per-process — per-process caching would leak state between tests, which defeats the entire point). Replaces `let`.
- **`briefing do ... end`** — setup, run before every `investigate` in the case. Replaces `before`/`setup`. No `before(:all)` equivalent exists.
- **`attest(actual).to matcher`** — optional fluent assertion sugar (`be_created`, `exist(...)`, etc.), built over plain `assert_*` primitives that are always available too. Custom matchers are defined with `Constable::Matchers.define(:matcher_name) { |actual, *args| ... }`.
- **`docket "context description" do ... end`** — optional in-file grouping/scoping sugar (the RSpec-nested-`describe` equivalent). Introduces no shared state; each nested `investigate` is still fully isolated.

```ruby
class UsersController::CreatesUserCase < Constable::Case
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

Grouping/shared behavior across *files* is just Ruby — a plain module you `include`, not a framework-specific shared-examples mechanism. This is deliberate: more flexibility comes from reusing Ruby's own composition tools instead of inventing a parallel DSL for the same job.

**Tiering is base classes, not magic.** Rather than only inferring `:unit`/`:integration`/`:system` from file path, the test helper defines one base class per tier, pre-wired with whatever that tier needs:

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

> **Correction against the original draft.** This section first showed `IntegrationCase` as
> nothing but `tier :integration`, and `SystemCase` as `include Capybara::DSL`. Neither
> works: with only a tier, a case has no `get`/`post`, no `response` and none of the app's
> URL helpers, so the headline example at the top of this spec — `post users_path` then
> `attest(response)` — could not run at all, and every scaffold-generated controller case
> failed on an undefined URL helper.
>
> `Constable::RailsSupport::Integration` and `::System` carry that behavior. They exist
> because Rails' own testing modules cannot be mixed into a plain class: they expect
> minitest's contract — the `setup`/`teardown` class macros in both block and symbol form,
> and the `before_setup`/`after_setup`/`before_teardown`/`after_teardown` instance hooks.
> `Constable::Case` provides that contract, with `setup` as an exact synonym for `briefing`,
> documented as a compatibility shim rather than a second way to write setup. `UnitCase`
> takes neither module, which is what lets the `:unit` tier boot without the request stack.

Real cases subclass whichever fits (`class UsersController::CreatesUserCase < IntegrationCase`). File-path convention (`test/cases/models/**` → `:unit`, etc.) is still used as a fallback/default when a case doesn't inherit from one of these, but explicit base classes are the recommended pattern since they're just ordinary Rails-idiomatic inheritance, no inference required.

## Test helper (the RSpec `spec_helper`/`rails_helper` equivalent)

`rails generate constable:install` creates:

- **`test/case_helper.rb`** — requires the gem, loads the Rails test environment, defines the per-tier base classes above, requires support files (`Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }`), and is where `Constable.configure` lives for anything not covered by `.constable/config.yml` (matchers, tier base-class wiring, one-time global setup like Capybara driver config).
- **`test/support/`** — a directory for shared modules (the shared-behavior story) and custom matcher definitions, auto-required by `case_helper.rb`, same role RSpec's `support/**/*.rb` plays.
- **`.constable/config.yml`** — everything that's a *setting* rather than *code* (full reference below).

```ruby
# test/support/matchers.rb
Constable::Matchers.define(:be_created) do |response|
  response.status == 201
end

Constable::Matchers.define(:exist) do |model_class, attrs|
  model_class.exists?(attrs)
end
```

```ruby
# test/support/authenticatable.rb — shared behavior, just a module
module Authenticatable
  def sign_in(user)
    post session_path, params: { email: user.email, password: "password" }
  end
end
```

Every `Constable::Case` subclass can `include Authenticatable` directly — no shared-examples DSL needed.

## Rails generator integration

`rails generate scaffold Post title:string` does not know what a test file looks like. It
asks whatever generator is registered as the app's **test framework**, and unless something
says otherwise that is always `test_unit`. Without this, an app could install Constable,
write its whole suite in cases, and still have every `rails generate` quietly drop Minitest
files into `test/` — for the one framework the app deliberately replaced.

A railtie closes the gap, the same way `rspec-rails` does:

```ruby
config.app_generators do |g|
  g.test_framework :constable, fixture: false
  g.integration_tool :constable
  g.system_tests     :constable
end
```

Rails resolves `integration_tool` and `system_tests` separately from `test_framework` — its
own `test_unit` railtie claims all three — so claiming only the first would leave
`rails generate integration_test` and `rails generate system_test` still writing Minitest.

**`fixture: false` is not an oversight.** Constable has no fixtures: a `witness` builds
exactly what one investigation needs and throws it away with it, which is the same reason
there is no `before(:all)`. Generating a `fixtures.yml` alongside a case would hand the
suite the shared mutable state the framework exists to prevent. A factory gem registered as
the `fixture_replacement` still gets its turn, via `hook_for` — factories are a witness's
business, not a fixture's.

The railtie is **loaded conditionally**, never unconditionally: `require "constable"` has to
keep working in a process with no Rails app at all, which is the whole premise of the
`:unit` tier.

### The generators

Every generator Rails hooks is implemented, so no `rails generate` command silently falls
back to Minitest. Each writes a case that subclasses the appropriate **tier base class**
from `case_helper.rb` and uses the real DSL — `investigate`, `witness`, `briefing`, `attest`
— never `it`/`let`/`before`/`expect`.

| Command | Namespace | Writes |
|---|---|---|
| `rails g model Post` | `constable:model` | `test/cases/models/post_case.rb` |
| `rails g controller Posts index` | `constable:controller` | `test/cases/controllers/posts_controller_case.rb` |
| `rails g scaffold Post` | `constable:scaffold` | a controller case + a system case |
| `rails g integration_test Checkout` | `constable:integration` | `test/cases/controllers/checkout_case.rb` |
| `rails g system_test Posts` | `constable:system` | `test/cases/system/posts_case.rb` |
| `rails g mailer User welcome` | `constable:mailer` | `test/cases/mailers/user_mailer_case.rb` + a preview |
| `rails g job Cleanup` | `constable:job` | `test/cases/jobs/cleanup_job_case.rb` |
| `rails g helper Posts` | `constable:helper` | `test/cases/helpers/posts_helper_case.rb` |
| `rails g channel Chat` | `constable:channel` | `test/cases/channels/chat_channel_case.rb` |
| `rails g mailbox Inbound` | `constable:mailbox` | `test/cases/mailboxes/inbound_mailbox_case.rb` |
| `rails g generator Awesome` | `constable:generator` | `test/cases/generators/awesome_generator_case.rb` |
| `rails g resource Post` | `constable:resource` | delegates, like Rails' own |

Scaffold generates an API-only controller case when the app is `--api`, and skips the
system case when there are no views to drive.

Generated cases are honest starting points, in the spirit of Rails' own scaffolded tests.
Where Rails would emit an empty or pending test, Constable emits an `investigate` with a
real body or an explicit comment naming what to assert — never something that passes
vacuously while looking like a test.

## The unsafe escape hatch (two tiers)

**Tier 1 — cold cases (the import story).** A whole file keeps its original RSpec or Minitest syntax completely untouched — reopened as-is. Change one line (the superclass) or add a config path match:

```ruby
# spec/controllers/users_controller_spec.rb — literally unchanged
class LegacyUsersSpec < Constable::ColdCase::RSpec
  describe UsersController do
    it "creates a user" do
      post users_path, params: valid_params
      expect(response).to have_http_status(:created)
    end
  end
end
```

```yaml
# .constable/config.yml — or don't touch the file at all
cold_cases:
  - spec/controllers/**/*_spec.rb
```

`Constable::ColdCase::RSpec` / `Constable::ColdCase::Minitest` run the file through the real RSpec/Minitest engine and feed pass/fail/timing into Constable's own reporting, flake history, and CI gate alongside native cases. RSpec/Minitest themselves are only needed when cold cases exist, so the installer puts them in an optional Gemfile group:

```ruby
group :cold_case do
  gem "rspec-rails"
  gem "minitest"
end
```

Delete the group once a suite is fully modernized and both dependencies drop out.

**Tier 2 — off the record (an edge-case valve, not a migration tool).** Inside an otherwise-native, otherwise-strict `Constable::Case`, a single investigation can suppress specific guards for one call:

```ruby
investigate "times out after thirty seconds" do
  unsafe { sleep(0.1) } # testing an actual timeout path, not a code smell
  attest(subject).to have_timed_out
end
```

Every unsafe usage emits a warning, always — one per cold-case file (not per test), one per `unsafe { }` occurrence, with file:line. Warnings never fail the build by default (`fail_on_warnings: true` opts a CI run into enforcing a downward trend), but they're never silent — always shown in the run summary's own section.

## Import command

```
rails generate constable:install
constable import --from=rspec       # or --from=minitest
```

Default mode is **reopen** (verbatim): files become `Constable::ColdCase::*` subclasses (superclass swap, or a zero-file-change config path match) and run immediately. No AST rewriting, no risk of a broken conversion.

A separate, opt-in **modernize** mode does the AST rewrite into the native DSL, file by file:

```
constable modernize spec/controllers/users_controller_spec.rb
```

| Source | Converts to |
|---|---|
| `describe X do ... it "does thing" do` | `class XCase < Constable::Case` + `investigate "does thing" do` |
| `let(:x) { }` | `witness(:x) { }` |
| `before { }` | `briefing do ... end` |
| `before(:all)` | flagged, not auto-converted — needs a human decision |
| Minitest `def test_foo` | `investigate "foo" do ... end` |
| Custom matchers / `shared_examples` | left untouched, logged in `constable_modernize_report.md` |

Native cases and cold cases run side by side in the same `constable test` invocation — no big-bang cutover.

## Built-in linter

Shipped as a Rubocop extension (`rubocop-constable`), scoped to native `Constable::Case` files only — `ColdCase::*` files are exempt by design:

- `NoSleep` — bare `sleep` outside an `unsafe` block.
- `NoUnfrozenTime` — `Time.now`/`Date.today`/`Time.current` outside `freeze_time`/`travel_to`.
- `NoNetworkWithoutStub` — HTTP calls without `stub_network!`.
- `NoSharedMutableState` — class variables/globals mutated across investigations.
- `NoConditionalAssertions` — `if/else` branching around `attest`/`assert_*` calls.
- `NoRetryHelpers` — any retry/eventually pattern.
- `UnsafeBlockVisibility` — fails only if an `unsafe` block has no adjacent comment explaining why.

## Anti-flake mechanisms

- Random order every run for native cases (seed printed, replayable via `--seed`); cold cases keep whatever order their own engine uses.
- Order-dependency detection: new/changed native investigations run once isolated and once in full-suite context in CI; a mismatch fails with "ORDER DEPENDENT TEST."
- State-leak check after each native investigation (ObjectSpace/global diff).
- **Flake history**: every test's pass/fail result is recorded (native and cold cases alike). A test that flips result without a code change is auto-jailed.

## Speed mechanisms

- Boot tiers (`:unit`/`:integration`/`:system`) via base classes as shown above, with file-path/superclass convention as a fallback.
- Parallel workers by default, load-balanced by a cached per-test duration index — across native and cold cases in the same run.
- Git-diff-based local runs (`constable test` with no args); `constable test --full` for everything, always used in CI.
- `witness` encourages `build_stubbed`-style reuse over redundant `create` calls.

## Persistence — the blotter

All operational data (flake history, jail/parole state, warrants) lives in one self-contained store Constable owns entirely — **not** the app's real database, and not necessarily whatever adapter the app uses either:

1. **The transaction conflict.** Native cases wrap each test in a rolled-back transaction. Writing this data through the app's own DB connection would roll it back along with everything else.
2. **Zero-dependency by default.** `:unit`-tier runs are supposed to skip booting the Rails/DB stack for speed; requiring a live Postgres/MySQL server to record "did this test pass" would undo that.
3. **The workload doesn't need a client-server database.** A handful of tables, ~one row per test per run, a dozen-ish parallel workers — SQLite in WAL mode handles this comfortably.

Default storage adapter is a self-contained `.constable/constable.sqlite3` — but the storage layer is a pluggable interface (`Constable::Storage::Adapter`), so a team that genuinely needs one queryable store shared across many CI machines (a cross-repo flaky-test dashboard — a different problem than local bookkeeping) can point it at Postgres or MySQL instead, always as a **separate database/connection from the app's own**, never sharing the app's transactional test connection:

```yaml
# .constable/config.yml
storage:
  adapter: sqlite              # sqlite (default) | postgres | mysql
  path: .constable/constable.sqlite3   # sqlite only
  # url: postgres://user:pass@host/constable_metadata   # postgres/mysql only
```

Tables: `flake_history`, `jail_docket`, `warrants`.

**Identity survives renames.** Each test's key is a **content hash of the `investigate` block's body** (whitespace-normalized), with class name and description stored alongside purely as a display label:

- Rename the class, reword the description, move the file — body untouched, hash untouched, full history carries over automatically.
- Change what the test actually does — hash changes, history starts fresh. Correct, not a limitation.
- A rename often ships with a small logic tweak in the same commit, which would otherwise reset history unnecessarily. Constable detects the pattern (an old test vanishing the same run a similar new one appears) and compares bodies for similarity:
  - `auto_relink: true` (default **false**) — relink automatically on a high-confidence match.
  - Default (off, or low confidence either way) — surfaced as a suggestion in the run summary: `possible rename: OldCase#old description → NewCase#new description, run constable history relink OLD_HASH NEW_HASH to confirm`.
  - `constable history relink OLD_HASH NEW_HASH` — the manual command, for confirming a detected match or for a deliberate rewrite where history should be kept despite a real logic change.

## Run modes & jail

| Command | Runs |
|---|---|
| `constable test` | Everything — native + cold cases (git-diff-scoped locally, `--full` for the whole suite; CI always uses `--full`) |
| `constable test PATH[:LINE]` | One file, or one specific `investigate` at that line |
| `constable test --unsafe` | Every cold case only |
| `constable test PATH:LINE --unsafe` | One specific cold case only |
| `constable test --jail` | The full run, in **jail mode** |

**Jail mode.** Any test that fails during a `--jail` run gets jailed instead of failing the build — recorded with a reason, file:line, and timestamp, still reported clearly (jailing isn't hiding, it's swapping "blocks the build" for "tracked and skipped"). The practical on-ramp for a large, currently-red legacy suite: run once in `--jail` for a clean baseline, then work the docket down. Outside `--jail`, a failure is just a failure.

Jailed tests are skipped automatically in every normal run afterward (their `briefing`/`witness` setup still runs — just not the `investigate` body — so setup rot surfaces immediately rather than only at the next `jail run`). They're always counted in the summary as their own category, never folded into "passed."

| Command | Effect |
|---|---|
| `constable jail` | Lists every jailed test — reason, file:line, date jailed |
| `constable jail run` | Re-runs every jailed test **sequentially** (clean per-test attribution) |
| `constable jail run --full` | Re-runs the whole docket in one parallelized batch (faster, coarser attribution) |
| `constable jail run PATH:LINE` | Re-runs one specific jailed test |
| `constable jail parole PATH:LINE` | Moves a jailed test to **parole** |
| `constable jail release PATH:LINE` | Fully releases a test, no supervision |

`jail run` never auto-releases or auto-paroles on a pass — a single green run doesn't prove anything. It flags candidates; a human acts.

**Parole — "probably fixed, not fully trusted yet."** A paroled test runs normally again (not skipped), but is watched:

- **Fails even once** → immediate violation, straight back to jail. No leniency — parole exists precisely because the test wasn't trusted.
- **Clean for `parole_period` consecutive runs** (default 10) → auto-released, fully, no human step.

**Parole violations are reported distinctly from ordinary jailings** — someone deliberately trusted this test again, so it's more urgent news than a plain new failure. It gets a `PAROLE VIOLATED` section, printed before the regular `FAILURES` section, and the summary's headline count splits it out: `⛓ 2 jailed (1 parole violation)`. The docket tracks a running `parole_violations` count per test, so a repeat offender says so explicitly ("this is its 2nd time in jail").

A test lands in jail three ways: a flake-history flip, a `--jail`-mode failure, or a parole violation. All three land in the same docket.

## Warrants — automatic flaky detection

Opt-in (`warrants: true` in config, or `constable test --warrants` for one run). A detection mechanism, distinct from jail: jail answers "does this block the build," warrants answers "is this failure even real."

**Issuing a warrant.** The moment a test fails on its normal attempt with warrants on, Constable reruns that single test, in isolation, `warrant_retries` more times (default 5):

- **Fails every retry** → genuine failure, no warrant. Handled exactly like any other failure (including jail, if `--jail` is also active).
- **Passes at least once** → flaky, not broken. A warrant entry is written to the blotter (never to source). That run's result doesn't block the build, but is called out in its own summary section.

**Living under a warrant.** Once warranted, a test always gets the full retry treatment on every future run — not just after a fresh failure, and regardless of whether `--warrants` is passed that run. The blotter entry carries the standing rule.

- **All retries pass** → warrant cleared, entry removed. Reported as cleared.
- **At least one fails** → warrant stays; result reported as "still under warrant," non-blocking.
- Manual clear: `constable warrants release PATH:LINE`.

`constable warrants` lists the current table directly — no source-editing companion command exists (same design as jail: one source of truth, nothing to drift out of sync).

## Coverage — "the beat"

Built on Ruby's `Coverage` module, tracked across native and cold cases alike (`Coverage` operates at the process level regardless of which engine ran the test).

- `coverage: true` in config, or `constable test --coverage` for one run.
- Summary gets one more line: `◐ 92% covered (3 files unpatrolled)` — "unpatrolled" = zero executed lines, named explicitly since a 0% file is usually a missed file, not a thin one.
- **The enforced threshold is diff-based, not blanket.** `coverage_threshold: 90` is checked only against lines changed in the current diff, matching the git-diff philosophy used for local test selection elsewhere — legacy gaps stay visible without blocking the build; new code is held to the bar.
- `constable beat` — standalone command for the full picture: overall %, per-file breakdown, the unpatrolled list, `--html` for a browsable report.
- Cold cases contribute coverage numbers but aren't held to the diff-coverage gate, consistent with their opt-out status everywhere else.

## Watching the suite — `watchlist` and `status`

Two different questions, two different commands:

- **`constable watchlist`** — everything currently under supervision, in one view: jailed tests, paroled tests (with their clean-run count), and warranted tests. The single place to see "what's not fully trusted right now" without checking three separate commands. `constable jail` and `constable warrants` still exist as focused views scoped to just one of those categories.
- **`constable status`** — a longer-running trend view: native-vs-cold-case percentage over time, flake history trend, slowest 10 tests historically. Answers "how's the suite doing," not "what's flagged right now."

## CLI / reporting

**Where output goes.** `Rails.logger`, `ActiveRecord`/SQL logging, and request/response logging route to `log/test.log` only — never to stdout, which is reserved for results. `constable test --verbose` streams `test.log` to stdout for active debugging.

**While running**, stdout shows one compact glyph per test as it completes:

```
UsersController::CreatesUserCase  ✓✓✓✗✓
SessionsCase                       ✓✓⛓✓
```

**The final summary is the actual deliverable:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CONSTABLE            482 tests · 3 cases · 12.4s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ 478 passed   ✗ 2 failed   ⛓ 2 jailed (1 parole violation)   ◑ 1 on parole   ⚖ 1 warrant issued   ⚠ 3 warnings   ◐ 92% covered

  PAROLE VIOLATED
  ───────────────
  ⛓ UsersController::CreatesUserCase
    "creates a user with valid params"
    Failed on day 3 of a 10-run parole — back to jail. This is its 2nd time in jail.

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

  WARNINGS
  ────────
  ⚠ spec/legacy/old_users_spec.rb
    running as a cold case (Constable::ColdCase::RSpec) — 12 tests not yet under native rules

  ⚠ spec/controllers/sessions_case.rb:44
    unsafe { sleep(0.1) } — "testing an actual timeout path, not a code smell"

  SLOWEST
  ────────
  3.2s  UsersController::CreatesUserCase "creates a user with valid params"
  1.1s  SessionsCase "times out after thirty seconds"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Failure messages are specific, not generic: the assertion's own context (response body, record attributes), file:line at the `investigate` block itself (not framework internals), and a ready-to-paste rerun command with the exact seed. Sections print worst-to-least-urgent: parole violations, then failures, then warnings, then the slowest list.

## Configuration reference

```yaml
# .constable/config.yml
cold_cases:                     # glob paths to run as cold cases (unmodified RSpec/Minitest)
  - spec/controllers/**/*_spec.rb

storage:
  adapter: sqlite                # sqlite (default) | postgres | mysql
  path: .constable/constable.sqlite3
  # url: postgres://user:pass@host/constable_metadata

warrants: false                  # opt-in flaky detector
warrant_retries: 5               # reruns before declaring a warrant/real failure
auto_relink: false               # auto-confirm high-confidence rename detection

parole_period: 10                # consecutive clean runs to auto-release from parole

coverage: false                  # record coverage during test runs
coverage_threshold: 90           # diff-based — only lines changed in the current diff
coverage_html: false             # generate a browsable report by default

fail_on_warnings: false          # CI: fail the build if warning count doesn't trend down

parallel_workers: auto           # or an explicit integer

tiers:                           # fallback path-based tier inference (base classes are primary)
  unit: "test/cases/models/**/*"
  integration: "test/cases/controllers/**/*"
  system: "test/cases/system/**/*"
```

## Gem layout

```
lib/constable/
  case.rb                 # base class, investigate/witness/briefing/docket DSL, tier macro
  runner.rb               # order randomization, isolation, flake history
  dsl.rb                  # freeze_time / stub_network! / wait_for / unsafe
  matchers.rb             # attest(...).to ... + Constable::Matchers.define
  reporter.rb             # stdout glyph stream + final summary formatting
  jail.rb                 # jail docket, --jail mode, jail run (sequential/--full), parole
  warrants.rb             # warrants table, retry logic
  coverage.rb             # Coverage module wrapper, diff-coverage gate, beat report
  storage/
    adapter.rb             # pluggable interface
    sqlite_adapter.rb       # default
    postgres_adapter.rb     # optional, separate connection from the app's own
    mysql_adapter.rb        # optional, separate connection from the app's own
  cold_case/
    rspec.rb                # adapter running real RSpec engine, results merged in
    minitest.rb             # adapter running real Minitest engine, results merged in
  linter/                  # rubocop-constable cops
  importer/
    reopener.rb              # default: superclass swap / config path match
    modernizer.rb             # opt-in: AST rewrite to native DSL
lib/constable/railtie.rb    # registers Constable as the app's test framework
lib/generators/constable/
  install_generator.rb      # writes case_helper.rb, support/, .constable/config.yml
  import_generator.rb
  base.rb                   # shared tier/superclass/path resolution
  model/ controller/ scaffold/ integration/ system/ mailer/ job/
  helper/ channel/ mailbox/ generator/ resource/
                            # one per generator Rails hooks, each with its templates
```

## Suggested build phasing

1. **Phase 0 (MVP)**: `Constable::Case` + `investigate`/`witness`/`briefing` runner, transactional isolation, `ColdCase::RSpec`/`ColdCase::Minitest` adapters, `rubocop-constable` core cops, SQLite storage adapter, the case-helper/install generator, and the redesigned stdout/test.log output.
2. **Phase 1**: `modernize` AST rewrite tool, flake history, jail (including parole), watchlist command.
3. **Phase 2**: Warrants, boot tiers, parallel execution, git-diff test selection.
4. **Phase 3**: Coverage ("the beat"), `constable status` trend dashboard, pluggable Postgres/MySQL storage adapters, editor plugin hooks.

Rails generator integration belongs in Phase 0 alongside the install generator: without it
a freshly installed Constable app still gets Minitest files from `rails generate`, which
undercuts the install before the developer has written a line.
