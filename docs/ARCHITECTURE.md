# Constable — internal architecture contract

**Read this before writing any code.** `docs/SPEC.md` is the product spec (what to build).
This file is the interface contract (how the pieces fit) so components written
independently compose without rework. Foundation files below already exist and are
committed — treat their signatures as fixed. If you genuinely must change one, say so
explicitly in your final report rather than editing it silently.

Ruby >= 3.1. Frozen string literals everywhere. No `require` of Rails at load time —
Constable must boot for `:unit` tier without a Rails app present.

## Naming

Published as the gem `constable-rails`. **Nothing inside is renamed.** Module `Constable`,
CLI `constable`, `require "constable"`, `.constable/`, `constable:install`.

## Foundation (already written — do not rewrite)

### `Constable` (`lib/constable.rb`)
- `Constable.root` → String. Rails.root when booted, else nearest dir with `.constable`/`Gemfile`/`.git`.
- `Constable.config` → `Constable::Config` (memoized).
- `Constable.configure { |c| ... }` → `Constable::Configuration` (code-level config; `before_suite`/`after_suite` hooks).
- `Constable.storage` → a `Storage::Adapter`, built from config and `setup!` already called.
- `Constable.registry` → `Constable::Registry`.
- `Constable.warn!(message, location:, kind:)` and `Constable.warnings` → `[{message:, location:, kind:}]`.
- `Constable.reset!` — clears memoized config/storage/registry/warnings (tests use this).
- Errors: `Constable::Error`, `Constable::ConfigurationError`, `Constable::AssertionFailed` (has `#context`).
- Autoload map is already declared. **Adding a new top-level class means adding an `autoload` line.**

### `Constable::Config` (`lib/constable/config.rb`)
Reads `.constable/config.yml`, merged over `DEFAULTS`, then over `overrides:` (CLI flags win).
Predicate readers: `cold_cases`, `warrants?`, `warrant_retries`, `auto_relink?`, `parole_period`,
`coverage?`, `coverage_threshold`, `coverage_html?`, `fail_on_warnings?`, `parallel_workers`
(resolves `"auto"` → `nprocessors - 1`), `storage_adapter`, `storage_path`, `storage_url`,
`tiers`, `tier_for(path)` → Symbol|nil, `cold_case?(path)` → Boolean.

### `Constable::Identity` (`lib/constable/identity.rb`)
- `Identity.for_block(block)` → 16-char hex. Content hash of the block body: comments,
  indentation and line breaks normalized away via `Ripper.lex`; source obtained from
  `RubyVM::AbstractSyntaxTree.of(block, keep_script_lines: true).source` with a
  line-balancing fallback.
- `Identity.for_source(string)`, `Identity.for_cold_case(file, description)`, `Identity.digest(str)`.

### `Constable::Investigation` (`lib/constable/investigation.rb`)
Constructed with `case_class:, description:, block:, file:, line:, docket_path: [], tier: nil`.
Exposes `#identity`, `#case_name`, `#full_description` (docket path prepended),
`#location` ("file:line", repo-relative), `#relative_file`, `#kind` (`:native`),
`#display_label`, `#to_h`. `#tier` is writable.

### `Constable::Result` / `Constable::Failure` / `Constable::Backtrace` (`lib/constable/result.rb`)
`Result::STATUSES = %i[passed failed jailed skipped errored warranted parole_violation]`.
`Result.from_investigation(inv, status:, duration:, ...)`. Accessors: `status`, `duration`,
`failure`, `warnings`, `retries`, `jail_reason`, `parole_day`, `times_jailed`, `seed`, `coverage`.
Predicates: `passed? failed? jailed? skipped? native? cold? parole_violation? warranted?`.
`#glyph`, `#location`, `#display_label`, `#rerun_command` (includes `--seed`, and `--only=cold` when cold).
`#to_h` / `Result.from_h` — **these two must stay symmetric; workers ship results over a pipe as hashes.**
`Failure.from_exception(err, context:)`; `Failure` carries `message`, `context`, `backtrace`, `exception_class`.
`Backtrace.clean(bt)` drops gem/stdlib frames so a failure points at the user's `investigate` line.

### `Constable::Storage::Adapter` (`lib/constable/storage/adapter.rb`)
Abstract. `Adapter.build(config)` dispatches on `config.storage_adapter` to
`SqliteAdapter` / `PostgresAdapter` / `MysqlAdapter`. Full method list is in the file —
implement every one. Core tables per spec: `flake_history`, `jail_docket`, `warrants`;
supporting: `runs`, `durations`, `coverage_snapshots`.

**Concurrency rule: only the parent process writes to storage.** Workers send results back
over a pipe; the parent persists. No adapter needs cross-process write locking.

## Components to build, and who owns what

Each component below is owned by exactly one implementer. Do not edit files outside
your own list. Anything shared goes through the foundation above.

### A. Case DSL — `lib/constable/case.rb`, `lib/constable/registry.rb`
`Constable::Case` is the user-facing base class.

Class methods:
- `investigate(description, &block)` — registers an `Investigation`. Captures
  `block.source_location` for `file`/`line`. **Not** a method definition.
- `witness(name, &block)` — per-test memoized helper. Defines an instance method that
  memoizes into an instance-level hash. Never memoize at class or process level.
- `briefing(&block)` — before-each. Multiple allowed; parents run before children.
- `docket(description, &block)` — creates an **anonymous subclass** of the current class,
  `class_eval`s the block into it, and pushes `description` onto that subclass's
  `docket_path`. Investigations, witnesses and briefings declared inside are scoped to it.
  Introduces no shared state.
- `tier(sym)` — sets `:unit`/`:integration`/`:system`; inherited by subclasses.
- `investigations` — every Investigation for this class *and* its docket subclasses, flattened.
- `constable_display_name` — the nearest **named** ancestor's name, so an anonymous docket
  subclass still reports as `UsersController::CreatesUserCase`.
- Inheritance: witnesses/briefings/tier inherit from the superclass. A tier base class
  (`class UnitCase < Constable::Case; tier :unit; end`) must pass its tier down.

Instance side: `include Constable::DSL` and `include Constable::Matchers::Expectations`.
One fresh instance per investigation, always.

`Constable::Registry` tracks every `Case` subclass as it's defined (`inherited` hook),
excluding anonymous docket subclasses from the top-level list, and can return all
investigations across all loaded cases. `Registry#clear` for test isolation.

`Constable::Case` also carries a **minitest compatibility layer**, because Rails' testing
modules cannot be mixed into a plain class without it: the `setup`/`teardown` class macros
(variadic — both `setup { }` and `setup :method_name`) and the `before_setup`, `after_setup`,
`before_teardown`, `after_teardown` instance hooks, plus `method_name`. `setup` is an exact
synonym for `briefing`; it exists so the ecosystem composes, not as a second public API.
`run_teardown` returns its error rather than raising, so a failing teardown can never mask
the failure the developer is looking for.

### A2. Rails support — `lib/constable/rails_support.rb`
`RailsSupport::Integration` includes `ActionDispatch::IntegrationTest::Behavior` (request
helpers, `response`, URL helpers). `RailsSupport::System` provides Capybara plus `driven_by`
/`served_by`. Both load Rails lazily and raise `ConfigurationError` with an actionable
message when the relevant piece is absent — **`require "constable"` must keep working in a
process with no Rails at all**, which is the `:unit` tier's whole premise and is asserted by
a subprocess test.

### B. Runtime DSL — `lib/constable/dsl.rb`
Instance methods available inside `investigate`/`briefing`:
- `freeze_time(time = Time.now, &blk)` — freezes `Time.now`/`Date.today`/`Time.current`.
  Delegates to ActiveSupport's `travel_to` when available, else a self-contained stub.
  Must auto-unfreeze at end of test.
- `travel_to(time, &blk)`, `travel_back`.
- `stub_network!` — installs a Net::HTTP (and, if loaded, a `WebMock`-style) block that
  raises on any real outbound connection. Idempotent; auto-removed at end of test.
- `wait_for(timeout:, interval:) { ... }` — bounded polling for genuinely async things.
  **Only legal inside `unsafe`** — outside it, raise `Constable::Error` telling the user why.
- `unsafe(reason = nil) { ... }` — suppresses guards for one call and **always** emits a
  warning via `Constable.warn!` with `file:line` and the adjacent comment/reason. Never silent.
- Assertion primitives that always exist alongside `attest`: `assert`, `refute`,
  `assert_equal`, `assert_nil`, `assert_empty`, `assert_includes`, `assert_raises`,
  `assert_predicate`, `assert_match`, `assert_difference`, `assert_no_difference`.
  All raise `Constable::AssertionFailed` with a specific message and, where available, `context:`.

### C. Matchers — `lib/constable/matchers.rb`
- `Constable::Matchers.define(:name) { |actual, *args| ... }` — truthy return passes.
  A block may instead return `[bool, message, context]` for a richer failure.
- `attest(actual)` → an expectation object supporting `.to matcher` and `.not_to matcher`.
- `be_*` predicate fallback: `be_created` → `actual.created?` when no matcher is registered;
  `be_a(Klass)`, `be_nil`, `be_empty`, `be_truthy`, `be_falsey` built in.
- Built-ins to register: `eq`, `eql`, `include`, `match`, `raise_error`, `have_attributes`,
  `exist`, `be_created`, `redirect_to`, `have_http_status`, `change`.
- Failure messages must name both sides and attach `context` (response body, record attrs).
- `Matchers::Expectations` is the module mixed into `Case` providing `attest`.

### D. Storage implementations — `lib/constable/storage.rb`, `sqlite_adapter.rb`, `postgres_adapter.rb`, `mysql_adapter.rb`
SQLite is the default: `.constable/constable.sqlite3`, **WAL mode**, `busy_timeout`.
Creates its own directory. Postgres/MySQL adapters `require` their driver lazily and
raise a clear message if missing, and must use a connection **separate from the app's**.
Schema is created idempotently on `setup!` with a `schema_version` row for migrations.

### E. Runner — `lib/constable/runner.rb`, `lib/constable/selection.rb`
- Loads `test/case_helper.rb` if present, then the case files in scope.
- Builds the work list: native `Investigation`s + cold-case files.
- **Order**: shuffle native investigations with a seed (`--seed` replays; seed always printed).
  Cold cases keep their own engine's order.
- **Isolation per native investigation**: fresh instance; wrap in an ActiveRecord
  transaction rolled back afterwards when AR is loaded and the tier isn't `:unit`;
  run all inherited briefings; clear witness memoization; restore any DSL global state.
- **State-leak check** after each native investigation: diff global variables, ENV,
  class-variable count and `ObjectSpace` counts of user classes; warn on leak.
- **Order-dependency detection**: in CI (`ENV["CI"]`), new/changed native investigations run
  once isolated and once in full-suite context; a mismatch fails with `ORDER DEPENDENT TEST`.
- **Jail integration**: a jailed test still runs its `briefing`/`witness` setup — just not the
  `investigate` body — so setup rot surfaces immediately. Reported as `:jailed`, never as passed.
- **Warrant integration**: delegates to `Constable::Warrants` (see G).
- **Parallel workers**: `fork`-based, `parallel_workers` from config, load-balanced with the
  cached duration index (longest first). Workers write results to a pipe as `Result#to_h`;
  the parent is the sole storage writer. `--workers 1` / non-fork platforms fall back to serial.
- **A case is the unit of work**, not an individual test. `Runner#balance` groups items by
  case class (or by file, for a cold case) before balancing. Two reasons, both load-bearing:
  the live stream groups by case, so scattering one case's tests across the schedule gives it
  several separate lines and makes the output unreadable; and `witness_all` opens a
  transaction spanning the case, which is no use to another process. Balancing is bounded by
  the largest case rather than the largest test.
- **Timeouts**: `Runner#run_item` wraps each item in `Timeout.timeout` when `timeout` is
  non-zero, so a hung test becomes a named failure instead of a parked run. The engine
  usually catches the interrupt first, which is better — it lands on the exact test — so
  `#explain_timeouts` rewrites whatever message the engine produced.
- `Constable::Selection` — resolves what to run: `PATH`, `PATH:LINE`, `--full`, `--only`
  (`native`/`cold`/`rspec`/`minitest`), tier filter, and the **git-diff default** (changed
  files vs merge-base, mapped to their case files; falls back to full when git is unavailable
  or nothing matched).

### E2. Shared fixtures — `lib/constable/shared_fixtures.rb`
`witness_all` — one fixture per case rather than per test. Extends `Constable::Case` as
`SharedFixtures::ClassMethods`.
- Delegates transaction handling to `TestProf::BeforeAll`, which is an optional dependency;
  `witness_all` raises a message naming the gem when it is absent. A second implementation of
  `before_all` would be a liability rather than a convenience.
- `constable_open_shared_scope!` builds **every** fixture in the case in one pass, because
  `begin_transaction` yields and the setup has to happen inside that yield.
- Each investigation re-reads its record (`constable_reread`) unless `reload: false`. The
  transaction protects the database; it cannot undo a mutation to the shared Ruby object.
- Without a database it degrades to building once and not rolling back, mirroring
  `Isolation#transactional?`.

### E3. Impersonation — `lib/constable/impersonation.rb`
Stubs and call assertions, so rspec-mocks is not a reason a file cannot convert.
- `impersonate` replaces the singleton method directly and puts the original on a restore
  list. No proxy object, no per-stub signature reflection — that is the speed story.
- The ledger of calls is attached to the **target**, not the test instance, because
  `attest(client).to have_been_asked(:fetch)` hands the matcher only the client. Removed
  again on restore, so an object outliving the test carries nothing away.
- Verification (the object must respond to the method) is the default rather than optional:
  a stub of a method that does not exist passes forever and proves nothing.
- `Case#run_teardown` calls `constable_restore_impersonations!` after the user's teardowns
  and unconditionally, so a failing test cannot leave a method replaced.
- Matcher: `have_been_asked`, with an `AskedDeferred` that overrides `#invoke` to pass itself
  so `.with(...)` / `.times(n)` reach the matcher block.

### F. Jail — `lib/constable/jail.rb`
Docket state machine over storage: `jailed` ⇄ `parole` → released.
- Enters jail three ways: flake-history flip, a `--jail`-mode failure, a parole violation.
- `parole` → runs normally but watched. Any failure = immediate violation, straight back to
  jail, `parole_violations += 1`, `times_jailed += 1`. `parole_period` (default 10)
  consecutive clean runs → auto-release, no human step.
- `jail run` never auto-releases or auto-paroles on a pass; it flags candidates only.
- Parole violations are a distinct status (`:parole_violation`) so the reporter can print
  them above ordinary failures.

### G. Warrants — `lib/constable/warrants.rb`
- Opt-in via `warrants: true` or `--warrants`; **an existing warrant applies on every run
  regardless of the flag** — the blotter entry carries the standing rule.
- On failure with warrants active: rerun that single test in isolation `warrant_retries`
  more times (default 5). Fails every retry → genuine failure. Passes at least once →
  write a warrant, mark `:warranted`, non-blocking, own summary section.
- Living under a warrant: full retry treatment every run. All pass → warrant cleared
  (reported as cleared). Any fail → "still under warrant", non-blocking.
- Never writes to source files. `constable warrants release PATH:LINE` clears manually.

### H. Cold cases — `lib/constable/cold_case.rb`, `cold_case/rspec.rb`, `cold_case/minitest.rb`
`Constable::ColdCase::RSpec` and `::Minitest` are base classes whose subclass body is the
**original, unmodified** spec/test file content. Running one drives the *real* engine
(RSpec::Core / Minitest) in-process, captures per-example pass/fail/timing, and converts each
into a `Constable::Result` with `kind: :cold` and `Identity.for_cold_case(file, description)`.
Also supports zero-file-change adoption: a file matched by a glob declared in
`test/cold_cases.rb` is wrapped
automatically without touching it. Emits exactly **one warning per cold-case file**, not per test.
`require` RSpec/Minitest lazily with a clear message pointing at the `:cold_case` Gemfile group.

### I. Reporter — `lib/constable/reporter.rb`
- Live: one glyph per test as it completes, grouped by case name, streamed to stdout.
- Final summary exactly as laid out in SPEC.md: rule lines, headline counts
  (`⛓ 2 jailed (1 parole violation)`), then sections worst-to-least-urgent —
  `PAROLE VIOLATED`, `FAILURES`, `WARNINGS`, `SLOWEST`. Coverage adds `◐ 92% covered`.
- Failure blocks show message, `context` (response body / record attrs), `file:line` at the
  investigate block, and the ready-to-paste rerun command with the seed.
- Also emits rename suggestions (`possible rename: ... run constable history relink ...`).
- **stdout is results only.** `Rails.logger`, ActiveRecord SQL and request/response logging
  route to `log/test.log`; `--verbose` tees that file to stdout.
- Must degrade gracefully with `--no-color` / non-TTY / `NO_COLOR`.

### J. Coverage — `lib/constable/coverage.rb`
Wraps Ruby's `Coverage` module (process-level, so it spans native and cold alike).
Diff-based gate: only lines changed vs the merge-base are held to `coverage_threshold`.
Cold cases contribute numbers but are exempt from the gate. Reports "unpatrolled" files
(zero executed lines). `constable beat` prints overall %, per-file breakdown, unpatrolled
list; `--html` writes a browsable report.

### K. CLI + generators — `lib/constable/cli.rb`, `exe/constable`, `lib/generators/constable/*`
Thor-based. Commands, exactly as SPEC.md's tables specify:
`test [PATH[:LINE]] [--full --only MODE --jail --warrants --coverage --seed N --workers N --verbose --tier T --no-color]`,
`jail`, `jail run [PATH:LINE] [--full]`, `jail parole PATH:LINE`, `jail release PATH:LINE`,
`warrants`, `warrants release PATH:LINE`, `watchlist`, `status`, `beat [--html]`,
`history relink OLD NEW`, `import --from=rspec|minitest`, `modernize PATH`, `version`.
Exit codes: 0 clean, 1 failures, 2 usage error.
Generators: `constable:install` writes `test/case_helper.rb`, `test/support/`,
`.constable/config.yml`, `.rubocop.yml` snippet and the `:cold_case` Gemfile group;
`constable:import` wraps the importer.

### L. Importer — `lib/constable/importer.rb`, `importer/reopener.rb`, `importer/modernizer.rb`
- **Reopener (default, verbatim)**: superclass swap or config path match. No AST rewriting.
- **Modernizer (opt-in)**: `parser`-gem AST rewrite per SPEC.md's conversion table.
  `before(:all)` is flagged, never auto-converted. Custom matchers / `shared_examples` are
  left untouched and logged to `.constable/docs/modernize-report.md`.

### M. RuboCop extension — `rubocop-constable/` (its own gemspec, own publish)
Cops: `NoSleep`, `NoUnfrozenTime`, `NoNetworkWithoutStub`, `NoSharedMutableState`,
`NoConditionalAssertions`, `NoRetryHelpers`, `UnsafeBlockVisibility`.
**Scoped to native `Constable::Case` files only** — a file whose class inherits from
`Constable::ColdCase::*` is exempt by design. `config/default.yml` + `lib/rubocop-constable.rb`
entry point so users add `require: rubocop-constable` to `.rubocop.yml`.

## Configuration layering

Three sources, resolved in this order, each with a reason it exists separately:

1. `.constable/config.yml` — every setting. ERB-processed before YAML, as Rails does for
   `database.yml`, so a computed value needs no second home. Assigning any of these through
   `Constable.configure` raises and names the file.
2. `.constable/preferences.yml` — gitignored, per developer, merged over the above. The key
   list is **closed** (`output`, `heartbeat`, `color`, `slowest`) and anything else raises.
   A setting that changes what passes cannot live in a file nobody else can see.
3. `Constable.cold_cases` in `test/case_helper.rb` — the cold-case globs, reaching the config
   through `Configuration#overrides`, applied by `Runner#load_suite!` after the helper loads
   and before `Selection` is asked for targets.

`Constable.configure` is for **code**: `before_suite`, `after_suite`, matchers.

## Testing convention for this repo

Our own suite is **Minitest** (`test/**/*_test.rb`, run by `rake test`) — Constable cannot
test itself before it works. `test/helper.rb` requires the gem and gives each test a temp
root via `Constable.root=` + `Constable.reset!`. Integration tests build tiny fixture case
files under a temp dir and run the real Runner over them. Aim for meaningful coverage of
every component you own, including failure paths.
