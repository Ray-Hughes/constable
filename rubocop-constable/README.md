# rubocop-constable

The companion RuboCop extension for [Constable](https://github.com/Ray-Hughes/constable),
the opinionated Rails testing gem published as `constable-rails`.

Constable's second principle is that **nondeterminism is caught by the linter, not
discovered in CI**. This gem is that linter. Seven cops, all on by default, each one
aimed at a specific way a suite stops being trustworthy: a bare `sleep`, an unfrozen
clock, a live HTTP call, class-level shared state, an assertion hiding behind a
branch, a retry helper papering over a real failure, and an `unsafe` block that never
says why it exists.

## Installation

```ruby
# Gemfile
group :development, :test do
  gem "constable-rails"
  gem "rubocop-constable", require: false
end
```

```yaml
# .rubocop.yml
require:
  - rubocop-constable
```

That is the whole setup. Every cop arrives enabled, with `Include` globs already
pointed at case files — nothing to copy into your own config.

On RuboCop 1.72 and newer you can use the `plugins:` key instead of `require:`;
both work.

## Scope: native cases only

**Every cop here is scoped to native `Constable::Case` files.** A file whose class
inherits from `Constable::ColdCase::RSpec` or `Constable::ColdCase::Minitest` is
exempt from all of them.

That is a design decision, not an oversight. Constable's third principle is that
adoption never requires a rewrite: an existing RSpec or Minitest file becomes a cold
case with a one-line superclass swap and runs verbatim from day one. Linting those
files would punish exactly the people who took the on-ramp, and would turn a
zero-risk import into a thousand-offense wall. Cold cases already announce
themselves — the runner emits one warning per cold-case file, every run, in the
summary's own WARNINGS section — so they are visible without being blocked.

### The heuristic

For each file, in order:

1. **Cold case wins.** If any class in the file inherits from a constant with a
   `ColdCase` segment (`Constable::ColdCase::RSpec`, `Constable::ColdCase::Minitest`,
   or a project-local `ColdCase` base class), the file is exempt. This runs first, so
   a cold case is never dragged back into scope by a path glob — and a file holding
   both a cold case and a native case gets the benefit of the doubt.
2. **Native case.** If any class inherits from a constant whose last segment ends in
   `Case` — `Constable::Case` itself, or the tier base classes the install generator
   writes (`UnitCase`, `IntegrationCase`, `SystemCase`) — the file is in scope.
   Matching the `Case` suffix rather than `Constable::Case` literally is deliberate:
   the recommended pattern is subclassing a tier base class, so the literal
   superclass of a real case file usually *isn't* `Constable::Case`.
3. **Path fallback.** Otherwise, a file under one of the cop's `Include` globs is
   treated as in scope. This keeps the cops useful for a shared module living under
   `test/cases/`, or a case file whose class definition a static parser can't see.
   It is safe precisely because rule 1 already took cold cases off the table.
4. Anything else reports nothing.

The default `Include` globs are:

```yaml
Include:
  - 'test/cases/**/*.rb'
  - 'spec/cases/**/*.rb'
  - 'test/**/*_case.rb'
  - 'spec/**/*_case.rb'
```

## The escape hatch

Six of the seven cops go quiet inside an `unsafe { }` block, because that is
Constable's designed valve for the genuine edge case — and it is never silent: the
runtime emits a warning with `file:line` and the adjacent comment for every
occurrence, every run.

The seventh cop, `Constable/UnsafeBlockVisibility`, is what keeps that honest. It
does not object to `unsafe` at all; it objects only to an `unsafe` that does not say
why.

## The cops

### `Constable/NoSleep`

A bare `sleep` is the most common way a suite becomes both slow and flaky at once: it
costs seconds on every green run and is still not long enough on the loaded CI box.
`sleep(...)` and `Kernel.sleep(...)` are flagged; `some_object.sleep` is not.

```ruby
# bad
investigate("expires the session") { sleep(0.2); attest(session).to be_expired }

# good
investigate("expires the session") { travel_to(2.hours.from_now); attest(session).to be_expired }

# good -- the timeout is the subject, and it says so
unsafe { sleep(0.1) } # testing an actual timeout path, not a code smell
```

### `Constable/NoUnfrozenTime`

Reading the wall clock makes a test a function of when it runs — invisible until the
suite goes red at midnight, on the last day of a month, or in the one CI region that
isn't UTC. Flags `Time.now`, `Time.current`, `Time.zone.now`, `Date.today`,
`Date.current`, `DateTime.now` and `DateTime.current`.

Satisfied by any of: a lexically enclosing `freeze_time { }` / `travel_to(...) { }`
block; a bare `freeze_time` / `travel_to` earlier in the same `investigate`; a
`freeze_time` / `travel_to` in any `briefing` in the file (a briefing runs before
every investigation, so it covers all of them); being the argument to a freeze helper
(`travel_to(Time.now + 1.day)` is fine); or `unsafe { }`.

| Option | Default |
| --- | --- |
| `ForbiddenCalls` | `Time.now`, `Time.current`, `Time.zone.now`, `Date.today`, `Date.current`, `DateTime.now`, `DateTime.current` |
| `FreezeHelpers` | `freeze_time`, `travel_to` |

### `Constable/NoNetworkWithoutStub`

A case that talks to the real network is not a test of your code, it is a test of
somebody else's uptime. If the file never calls `stub_network!`, HTTP entry points are
flagged: `Net::HTTP`, `HTTParty`, `Faraday`, `RestClient`, `Excon`, `Typhoeus`,
`HTTPClient`, `HTTPX`, `HTTP`, `Curl`, `Patron`, `Mechanize`, `OpenURI`, `Down`, plus
`URI.open` / `URI.read` and open-uri's `open("https://...")`.

One `stub_network!` anywhere in the file — normally in a `briefing`, which runs before
every investigation — silences the cop for the whole case.

The cop matches calls made *directly* on a known entry-point constant, so a chain like
`Faraday.new(url: url).get("/profile")` reports once, at its entry point. A connection
object handed around by a `witness` is out of reach of a static check; `stub_network!`
itself catches that one at runtime.

| Option | Default |
| --- | --- |
| `StubHelpers` | `stub_network!` |
| `HttpConstants` | the list above |

### `Constable/NoSharedMutableState`

Isolation is non-negotiable in native code. A class variable or global written from
inside a case survives the investigation that wrote it, so the suite's result depends
on its order — and the failure lands on whichever test ran second, not on the one that
caused it. This is why Constable has no `before(:all)`.

Reading `@@x` or `$x` is fine. Writing is not: assignment, `||=`/`+=`, `<<`, `push`,
`merge!`, `[]=`, and anything else ending in `!` or `=`. Use `witness` for per-test
memoized data, `briefing` for per-test setup, and an ordinary instance variable for
whatever an investigation needs to remember about itself.

### `Constable/NoConditionalAssertions`

An assertion behind a branch is an assertion that might not run. The test goes green
either way, so nobody notices when the interesting branch stops being taken — the case
quietly stops testing anything while still counting itself as coverage.

Flags `if`, `unless`, modifier forms, ternaries, `case/when` and `case/in` whose
branch bodies contain `attest` or an `assert_*`/`refute_*` call. Only the outermost
conditional is reported, so a nested tree yields one offense, not five. The fix is to
split the branches into separate `investigate` blocks — or separate `docket` blocks —
so each one asserts unconditionally and each one's name says which world it describes.

| Option | Default |
| --- | --- |
| `AssertionMethods` | `attest` |
| `AssertionPrefixes` | `assert`, `refute` |

### `Constable/NoRetryHelpers`

Retrying is how a flaky test hides. It turns a test that fails some of the time into
one that passes most of the time — strictly worse, because now nobody is looking at
it.

Flags the `retry` keyword, the helper calls `wait_for`, `eventually`, `with_retries`,
`try_again`, `retry_until`, `retry_on_failure`, `poll_until`, `keep_trying`, and
`loop`/`while`/`until` bodies that poll with `sleep`. The loop heuristic is
deliberately narrow — a `while` doing real work is left alone.

Constable's real answer for genuine flakiness is **warrants**: the runner reruns a
failing test in isolation, records what it finds in the blotter, and reports it in its
own summary section. Visible and counted, rather than swallowed by a
`rescue; retry; end`.

`wait_for(timeout:, interval:)` does exist in the runtime DSL for genuinely async work
— but it is legal only inside `unsafe { }`, and raises outside it. This cop enforces
the same rule statically.

| Option | Default |
| --- | --- |
| `RetryHelpers` | the list above |

### `Constable/UnsafeBlockVisibility`

Every escape hatch is visible. This cop fails **only** when an `unsafe` block has
nothing next to it explaining why. Satisfied by a trailing comment on the same line, a
comment on the line immediately above, or a literal reason argument. That text is what
the runner quotes in the run summary:

```
⚠ spec/controllers/sessions_case.rb:44
  unsafe { sleep(0.1) } — "testing an actual timeout path, not a code smell"
```

```ruby
# bad
unsafe { sleep(0.1) }

# good
unsafe { sleep(0.1) } # testing an actual timeout path, not a code smell

# good
# testing an actual timeout path, not a code smell
unsafe do
  sleep(0.1)
end

# good
unsafe("testing an actual timeout path, not a code smell") { sleep(0.1) }
```

| Option | Default |
| --- | --- |
| `AllowReasonArgument` | `true` — set to `false` to insist on a comment |

## Autocorrection

None of these cops autocorrect. Every one of them is reporting a decision a human has
to make — which investigation to split the branch into, whether the clock or the
network is genuinely the subject, whether the retry was hiding a real bug. A machine
guessing at that would be worse than the offense.

## Development

The suite is plain Minitest, matching the rest of the Constable repo:

```
bundle install
bundle exec rake test
# or, without bundler:
ruby -Ilib -Itest test/no_sleep_test.rb
```

Each cop is exercised by building a `RuboCop::ProcessedSource` and running it through
a `Commissioner` holding just that cop; `test/integration_test.rb` runs the whole
department through a real `Team` over real files, which is what proves the `Include`
filtering and the cold-case exemption end to end.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
