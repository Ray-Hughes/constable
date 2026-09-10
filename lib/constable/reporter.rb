# frozen_string_literal: true

require "constable/result"
require "constable/log_router"

module Constable
  # The face of the product. Two jobs, and nothing else on stdout:
  #
  #   1. While the suite runs, one compact glyph per finished test, grouped by case.
  #   2. When it finishes, the summary -- which is the actual deliverable. Everything a
  #      developer needs to act on is in it: what broke, where, why, and the exact command
  #      to rerun it. Sections print worst-to-least-urgent, and nothing that bends the
  #      rules (a jailed test, a warrant, an unsafe block) is ever silently dropped.
  #
  # Logs do not belong here -- Rails.logger, SQL and request logging go to log/test.log
  # via Constable::LogRouter. stdout is results only.
  #
  # The Runner drives it:
  #
  #   reporter = Constable::Reporter.new(io: $stdout, config: Constable.config)
  #   reporter.start(total: 482, seed: 8841)
  #   reporter.record(result)                       # one glyph, live
  #   reporter.finish(results: all, duration: 12.4, seed: 8841, coverage: cov)
  #   exit reporter.exit_status
  class Reporter
    # The summary's frame. 60 columns wide, as published in the spec.
    RULE_WIDTH = 60
    HEAVY_RULE = ("━" * RULE_WIDTH).freeze

    INDENT        = "  "
    ENTRY_INDENT  = "    "
    DETAIL_INDENT = "      "

    # "  CONSTABLE" padded so the run stats always start in the same column.
    LABEL         = "CONSTABLE"
    LABEL_WIDTH   = 21

    # The live stream pads case names into a column so the glyph runs line up.
    STREAM_NAME_WIDTH = 34
    STREAM_GAP        = 2

    # How many glyphs may pile up behind the currently-streaming case before we give
    # up waiting for it and start that case's own line. Parallel workers interleave;
    # without a limit a quiet case could hold the buffer forever.
    STREAM_FLUSH_THRESHOLD = 12

    # How many cold-case files are listed one by one before they are summarised instead.
    # A suite part-way through adoption has hundreds -- one real app had 1,277 -- and
    # printing every one buries the warnings that actually need a decision under four
    # thousand lines that say the same thing.
    COLD_CASE_LIST_LIMIT = 10

    # How many rename suggestions are listed before the rest are counted instead. A real
    # suite produced two hundred, several hundred lines of output, unlabelled.
    RENAME_LIST_LIMIT = 8

    DEFAULT_SLOWEST = 5

    # Column the expanded stream right-aligns durations into. Descriptions are never
    # truncated to fit it -- a clipped test name is not something you can grep for --
    # so a long one simply pushes its own stamp out past the column.
    EXPANDED_STAMP_COLUMN = 56

    # Result::GLYPHS covers statuses. These four are summary vocabulary, not statuses:
    # supervision and coverage are properties of a test, not outcomes of one.
    GLYPHS = Result::GLYPHS.merge(
      parole: "◑",
      warrant: "⚖",
      warning: "⚠",
      coverage: "◐"
    ).freeze

    STYLES = {
      reset: 0,
      bold: 1,
      dim: 2,
      red: 31,
      green: 32,
      yellow: 33,
      blue: 34,
      magenta: 35,
      cyan: 36
    }.freeze

    COLORS = {
      passed: :green,
      failed: :red,
      errored: :red,
      parole_violation: :red,
      jailed: :yellow,
      warranted: :yellow,
      warning: :yellow,
      skipped: :dim,
      parole: :cyan,
      coverage: :cyan
    }.freeze

    # The spec prints SLOWEST's rule one character longer than its title. Reproduced
    # verbatim so our output matches the published example character for character;
    # drop the entry to make every underline title-width.
    UNDERLINE_WIDTHS = { "SLOWEST" => 8 }.freeze

    # Wide (East Asian / emoji) code points occupy two columns; combining marks occupy
    # none. Padding by byte length or even by character count would misalign the glyph
    # column the moment a name or a glyph stops being plain ASCII.
    WIDE_RANGES = [
      0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF, 0x4E00..0x9FFF,
      0xA000..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF, 0xFE10..0xFE19, 0xFE30..0xFE6F,
      0xFF00..0xFF60, 0xFFE0..0xFFE6, 0x1F300..0x1F64F, 0x1F680..0x1F6FF,
      0x1F900..0x1F9FF, 0x20000..0x3FFFD
    ].freeze

    attr_reader :io, :config, :seed, :total

    def initialize(io: $stdout, config: nil, color: nil, slowest: DEFAULT_SLOWEST, mode: nil,
                   show: nil)
      @io      = io
      # Sections the caller asked to expand. A flag rather than a keypress, so the same
      # command prints the same thing in a CI log as it does on a terminal.
      @show    = Array(show).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:empty?)
      @config  = config || Constable.config
      @color   = resolve_color(color)
      @slowest = slowest.to_i
      # Resolved lazily: the reporter is built before case_helper.rb has run, so reading
      # the config now would miss anything Constable.configure sets.
      @requested_mode = mode
      @io.set_encoding(Encoding::UTF_8) if @io.respond_to?(:set_encoding)

      reset_stream!
      @failed_live = 0
      @warning_count = 0
      @history = {}
      @finished = false
    end

    # --- lifecycle -----------------------------------------------------------------

    # Announces the run. The seed is always printed: every summary that mentions a
    # failure hands back a rerun command, and the command is only replayable with it.
    def start(total: nil, seed: nil)
      @total = total
      @seed  = seed
      return self if total.nil? && seed.nil?

      bits = []
      bits << "#{total} #{pluralize(total, "test")}" if total
      bits << "seed #{seed}" if seed
      writeln(paint("#{LABEL.downcase} · #{bits.join(" · ")}", :dim))
      writeln
      self
    end

    # One glyph, live, as each test completes. Safe to call from the parent process
    # only -- workers ship results home and the parent reports them.
    def record(result)
      return self if result.nil?

      @failed_live += 1 if result.failed?
      stream(result)
      self
    end

    # Ends the live stream, emitting any case whose glyphs are still buffered.
    def flush!
      return self unless streaming?

      # The expanded stream never buffers -- every line was written as it happened, so
      # there is nothing left to emit, only a blank line before the summary.
      if expanded?
        reset_stream!
        writeln
        return self
      end

      close_stream_line
      pending_case_names.each { |name| open_stream_line(name) && close_stream_line }
      writeln
      reset_stream!
      self
    end

    # Prints the summary. Returns the process exit status so a caller can
    # `exit reporter.finish(...)` in one line.
    def finish(results:, duration: 0.0, seed: nil, coverage: nil, suggestions: [], warnings: nil,
               history: {})
      results = Array(results)
      @seed   = seed if seed
      flush!

      @history      = history || {}
      counts        = tally(results)
      @failed_live  = counts[:failed]
      warnings      = normalize_warnings(warnings)
      @warning_count = warnings.size
      coverage      = normalize_coverage(coverage)
      @finished     = true

      writeln(paint(HEAVY_RULE, :dim))
      writeln(header_line(results, duration))
      writeln(paint(HEAVY_RULE, :dim))
      writeln(headline(counts, warnings.size, coverage))

      section_parole_violations(results)
      section_failures(results)
      section_warrants(results)
      section_jailed(results)
      section_parole(results)
      section_warnings(warnings)
      section_slowest(results)
      rename_suggestions(suggestions)

      # Last, deliberately.
      #
      # The counts are printed at the top as well, and after a long run the top has
      # scrolled away -- so the number someone actually goes looking for is the one they
      # have to scroll back for. Recommendations sit above it because they are what to do
      # next, and the summary is what just happened.
      section_recommendations(results, counts)
      section_summary(counts, duration)

      writeln(paint(HEAVY_RULE, :dim))
      exit_status
    end

    # --- queries -------------------------------------------------------------------

    # 0 clean, 1 something the build should care about. Jailed tests, warrants and
    # warnings are deliberately non-blocking -- unless a CI run opted into
    # fail_on_warnings, which is the whole point of that setting.
    def exit_status
      return 1 if @failed_live.positive?
      return 1 if @config.fail_on_warnings? && @warning_count.positive?

      0
    end

    def success? = exit_status.zero?
    def failed?  = !success?
    def color?   = @color
    def finished? = @finished
    def mode      = @mode ||= resolve_mode(@requested_mode)
    def expanded? = mode == :expanded

    private

    # --- live glyph stream ---------------------------------------------------------

    def reset_stream!
      @stream_case    = nil
      @stream_pending = {}
      @stream_open    = false
    end

    def streaming? = @stream_open || @stream_pending.any?

    def pending_case_names
      @stream_pending.reject { |_name, glyphs| glyphs.empty? }.keys
    end

    def stream(result)
      return stream_expanded(result) if expanded?

      name = result.case_name.to_s
      name = "(anonymous)" if name.empty?
      glyph = paint(result.glyph, COLORS[result.status])

      if @stream_open && @stream_case == name
        write(glyph)
        return
      end

      (@stream_pending[name] ||= +"") << glyph
      return open_stream_line(name) unless @stream_open

      promote_stream_line if buffered_glyph_count >= STREAM_FLUSH_THRESHOLD
    end

    # Glyphs waiting behind the case that currently owns the line.
    def buffered_glyph_count
      @stream_pending.sum { |_name, glyphs| count_glyphs(glyphs) }
    end

    # Ends the current line and hands it to whichever case has waited longest with
    # the most to say. A case that has already had a line simply gets another one --
    # repeating the name is honest, silently appending to a stale line is not.
    def promote_stream_line
      close_stream_line
      busiest = @stream_pending.max_by { |_name, glyphs| count_glyphs(glyphs) }
      open_stream_line(busiest.first) if busiest
    end

    def open_stream_line(name)
      glyphs = @stream_pending.delete(name).to_s
      return false if glyphs.empty?

      write(paint(pad(name, STREAM_NAME_WIDTH - STREAM_GAP), :dim))
      write(" " * STREAM_GAP)
      write(glyphs)
      @stream_case = name
      @stream_open = true
    end

    def close_stream_line
      return false unless @stream_open

      writeln
      @stream_case = nil
      @stream_open = false
      true
    end

    # Glyphs may carry escape codes; count only the visible ones.
    def count_glyphs(string) = strip_ansi(string).length

    # --- expanded stream -----------------------------------------------------------
    #
    # One line per test instead of one glyph. The trade is deliberate: concise keeps a
    # thousand-test suite on one screen, expanded tells you which test is hanging while
    # it hangs, without waiting for the summary.
    #
    # Workers interleave, so a case can come back after another has spoken. It gets a
    # second header rather than having its later tests silently appended under the
    # wrong one -- the same honesty rule the concise stream follows.
    def stream_expanded(result)
      name = result.case_name.to_s
      name = "(anonymous)" if name.empty?

      if @stream_case != name
        writeln if @stream_case
        writeln(INDENT + paint(name, :bold))
        @stream_case = name
        @stream_open = true
      end

      writeln(expanded_line(result))
    end

    def expanded_line(result)
      glyph = paint(result.glyph, COLORS[result.status])
      line  = "#{ENTRY_INDENT}#{glyph} #{expanded_description(result)}"

      stamp = expanded_duration(result)
      return line if stamp.nil?

      # Pad to a column so the durations line up, but never truncate a description --
      # a clipped test name is not something you can grep for.
      visible = strip_ansi(line).length
      gap = [EXPANDED_STAMP_COLUMN - visible, 1].max
      "#{line}#{" " * gap}#{paint(stamp, :dim)}"
    end

    def expanded_description(result)
      description = result.description.to_s
      description = "(no description)" if description.empty?
      # A jailed test never ran its body, so say why rather than implying it passed.
      return "#{description} #{paint("— #{result.jail_reason}", :dim)}" if jail_reason_worth_showing?(result)

      description
    end

    def jail_reason_worth_showing?(result)
      result.status == :jailed && !result.jail_reason.to_s.strip.empty?
    end

    # Only real, measured time. A jailed test never ran, and "0ms" would be a claim
    # about a body that was skipped.
    def expanded_duration(result)
      return nil if result.status == :jailed
      return nil unless result.duration.to_f.positive?

      format_test_duration(result.duration)
    end

    # The summary's durations are run-scale, where "12.4s" is the useful unit. One test
    # is usually sub-second, and "0.0s" against every line says nothing at all -- so the
    # expanded stream counts milliseconds until a test is slow enough for seconds to mean
    # something.
    def format_test_duration(seconds)
      seconds = seconds.to_f
      return format_duration(seconds) if seconds >= 1

      milliseconds = (seconds * 1000).round
      milliseconds.zero? ? "<1ms" : "#{milliseconds}ms"
    end

    # --- header and headline -------------------------------------------------------

    def header_line(results, duration)
      stats = [
        "#{results.size} #{pluralize(results.size, "test")}",
        "#{case_count(results)} #{pluralize(case_count(results), "case")}",
        format_duration(duration)
      ].join(" · ")

      INDENT + paint(pad(LABEL, LABEL_WIDTH), :bold) + stats
    end

    def case_count(results) = results.map(&:case_name).uniq.size

    # Zero-valued categories are omitted rather than printed as 0 -- except passed and
    # failed, which are the two numbers a reader looks for first and so always show.
    def headline(counts, warning_count, coverage)
      parts = []
      parts << count_part(:passed, counts[:passed], "passed", always: true)
      parts << count_part(:failed, counts[:failed], "failed", always: true)
      parts << jailed_part(counts)
      parts << count_part(:skipped, counts[:skipped], "skipped")
      parts << count_part(:parole, counts[:on_parole], "on parole")
      parts << warrant_part(counts[:warranted])
      parts << count_part(:warning, warning_count, "warning", plural: true)
      parts << coverage_part(coverage)

      INDENT + parts.compact.join("   ")
    end

    def count_part(key, count, label, always: false, plural: false)
      count = count.to_i
      return nil if count.zero? && !always

      label = pluralize(count, label) if plural
      paint("#{GLYPHS[key]} #{count} #{label}", COLORS[key])
    end

    # Parole violations are more urgent news than a plain jailing -- somebody deliberately
    # trusted this test again -- so the headline splits them back out of the total.
    def jailed_part(counts)
      jailed = counts[:jailed].to_i
      return nil if jailed.zero?

      violations = counts[:parole_violations].to_i
      text = "#{GLYPHS[:jailed]} #{jailed} jailed"
      text += " (#{violations} #{pluralize(violations, "parole violation")})" if violations.positive?
      paint(text, COLORS[:jailed])
    end

    def warrant_part(count)
      count = count.to_i
      return nil if count.zero?

      paint("#{GLYPHS[:warrant]} #{count} #{pluralize(count, "warrant")} issued", COLORS[:warranted])
    end

    def coverage_part(coverage)
      return nil if coverage.nil?

      text = "#{GLYPHS[:coverage]} #{format_percent(coverage[:percent])}% covered"
      # A 0% file is usually a missed file, not a thin one, so it gets named out loud.
      if coverage[:unpatrolled].to_i.positive?
        text += " (#{coverage[:unpatrolled]} #{pluralize(coverage[:unpatrolled], "file")} unpatrolled)"
      end
      paint(text, COLORS[:coverage])
    end

    def tally(results)
      {
        passed: results.count(&:passed?),
        failed: results.count(&:failed?),
        jailed: results.count(&:jailed?),
        parole_violations: results.count(&:parole_violation?),
        on_parole: results.count { |r| r.parole_day && !r.parole_violation? },
        warranted: results.count(&:warranted?),
        skipped: results.count(&:skipped?)
      }
    end

    # --- sections ------------------------------------------------------------------

    def section(title)
      writeln
      writeln(INDENT + paint(title, :bold))
      writeln(INDENT + paint("─" * (UNDERLINE_WIDTHS[title] || title.length), :dim))
    end

    def section_parole_violations(results)
      violations = results.select(&:parole_violation?)
      return if violations.empty?

      section("PAROLE VIOLATED")
      each_entry(violations) do |result|
        writeln(INDENT + paint("#{GLYPHS[:parole_violation]} #{result.case_name}", COLORS[:parole_violation]))
        writeln(ENTRY_INDENT + paint(%("#{result.description}"), :dim))
        writeln(ENTRY_INDENT + paint(result.location, :dim))
        writeln(ENTRY_INDENT + parole_violation_sentence(result))
      end
      hint("Somebody trusted this test again and it let them down, so it is back on the " \
           "docket. Fix it before the next constable jail parole — a second violation " \
           "is the signal that the test, not the flake, is the problem.")
    end

    def parole_violation_sentence(result)
      sentence = "Failed on day #{result.parole_day} of a #{@config.parole_period}-run parole — back to jail."
      sentence << " This is its #{ordinalize(result.times_jailed)} time in jail." if result.times_jailed
      sentence
    end

    # A section says what happened; a hint says what to do about it. One dim sentence,
    # and only where there is a real next step -- a tip printed on every run stops being
    # read on the second one.
    def hint(text)
      writeln
      lines = wrap(text, width: RULE_WIDTH - INDENT.length - 2, indent: "  ")
      writeln(INDENT + paint("→ #{lines.first}", :dim))
      lines.drop(1).each { |line| writeln(INDENT + paint(line, :dim)) }
    end

    # Every test currently under a warrant: it failed, then passed when rerun in
    # isolation, so it is flaky rather than broken. Loud, but not build-blocking.
    def section_warrants(results)
      warranted = results.select(&:warranted?)
      return if warranted.empty?

      section("WARRANTS")
      each_entry(warranted) do |result|
        writeln(INDENT + paint("#{GLYPHS[:warrant]} #{result.case_name}", COLORS[:warranted]))
        writeln(ENTRY_INDENT + paint(%("#{result.description}"), :dim))
        writeln(ENTRY_INDENT + paint(result.location, :dim))
        writeln(ENTRY_INDENT + warrant_sentence(result))
      end
      hint("A warrant is \"not reproducible\", not \"not a problem\" — it stops blocking the " \
           "build and stays visible until someone deals with it. " \
           "Fixed the flake? constable warrants release PATH:LINE")
    end

    def warrant_sentence(result)
      statuses = Array(result.retries).map(&:to_sym)
      return "Failed once, then passed on retry." if statuses.empty?

      passed = statuses.count(:passed)
      "Failed, then passed #{passed} of #{statuses.size} #{pluralize(statuses.size, "retry")} " \
        "run in isolation."
    end

    # The docket. These never ran their bodies, so they are neither passing nor failing --
    # which is exactly why they get their own category rather than being folded into
    # either one.
    def section_jailed(results)
      jailed = results.select { |result| result.status == :jailed }
      return if jailed.empty?

      section("JAILED")
      each_entry(jailed) do |result|
        writeln(INDENT + paint("#{GLYPHS[:jailed]} #{result.case_name}", COLORS[:jailed]))
        writeln(ENTRY_INDENT + paint(%("#{result.description}"), :dim))
        writeln(ENTRY_INDENT + paint(result.location, :dim))
        writeln(ENTRY_INDENT + jailed_sentence(result))
      end
      hint("Jailed means skipped and tracked, not passing. Think one is fixed? " \
           "constable jail parole PATH:LINE runs it for real again — " \
           "#{@config.parole_period} clean runs and it releases itself.")
    end

    def jailed_sentence(result)
      reason   = result.jail_reason.to_s.strip
      sentence = reason.empty? ? "Body skipped; setup still ran." : "#{reason.capitalize}."
      sentence += " Its #{ordinalize(result.times_jailed)} time in jail." if result.times_jailed.to_i > 1
      sentence
    end

    # Out on parole and behaving. Worth naming every run, because the count only means
    # something if you can see it moving.
    def section_parole(results)
      paroled = results.select { |result| result.parole_day && !result.parole_violation? }
      return if paroled.empty?

      section("ON PAROLE")
      each_entry(paroled) do |result|
        writeln(INDENT + paint("#{GLYPHS[:parole]} #{result.case_name}", COLORS[:parole]))
        writeln(ENTRY_INDENT + paint(%("#{result.description}"), :dim))
        writeln(ENTRY_INDENT + paint(result.location, :dim))
        writeln(ENTRY_INDENT + parole_progress_sentence(result))
      end
      hint("A paroled test runs for real and is watched: one failure sends it straight " \
           "back to jail. constable watchlist shows everything under supervision.")
    end

    def parole_progress_sentence(result)
      day       = result.parole_day.to_i
      period    = @config.parole_period
      remaining = [period - day, 0].max
      return "Day #{day} of #{period} — releases after this run." if remaining.zero?

      "Day #{day} of #{period} — #{remaining} #{pluralize(remaining, "clean run")} to go."
    end

    def section_failures(results)
      failures = results.select(&:failed?)
      return if failures.empty?

      section("FAILURES")
      each_entry(failures) { |result| failure_entry(result) }
    end

    def failure_entry(result)
      writeln(INDENT + paint("#{GLYPHS[:failed]} #{result.case_name}", COLORS[:failed]))
      writeln(ENTRY_INDENT + paint(%("#{result.description}"), :dim))
      writeln(ENTRY_INDENT + paint(result.location, :dim))

      # Where it broke, which is rarely where the test is. The backtrace has already had
      # the framework stripped out of it, so the first frame left is the application's own
      # -- and printing it saves opening the file to find out.
      app = app_frame(result)
      writeln(ENTRY_INDENT + paint("broke at #{app}", :dim)) if app

      metrics = failure_metrics(result)
      writeln(ENTRY_INDENT + paint(metrics, :dim)) unless metrics.empty?

      writeln
      failure_message(result).each_line { |line| writeln(ENTRY_INDENT + line.chomp) }
      failure_context(result)
      writeln
      writeln(ENTRY_INDENT + paint("Rerun just this test:", :dim))
      writeln(DETAIL_INDENT + result.rerun_command)
    end

    # The first backtrace frame that is not the test file itself.
    def app_frame(result)
      frames = Array(result.failure&.backtrace)
      return nil if frames.empty?

      own = File.basename(result.file.to_s)
      frame = frames.find { |line| !line.to_s.include?(own) } || frames.first
      frame.to_s.split(":in ").first
    end

    # How long it took, and how often this exact test has failed before.
    #
    # The second is the one that changes what you do: a first failure is news about the
    # change you just made, a test that has failed four of the last twelve runs is news
    # about the test. Identity is a hash of the body, so this survives renames and does
    # not survive a rewrite -- which is the correct behaviour for both.
    # Only what earns its line. "<1ms" under a failure tells nobody anything, so a
    # duration appears once it is slow enough to be part of the story; history appears
    # whenever there is any.
    def noteworthy_failure_seconds = 0.05

    def failure_metrics(result)
      parts = []
      parts << format_test_duration(result.duration) if result.duration.to_f >= noteworthy_failure_seconds
      seen = @history[result.identity]
      parts << "failed #{seen[:failures]} of the last #{seen[:runs]} runs" if seen && seen[:runs].to_i > 1
      parts.join("  ·  ")
    end

    def failure_message(result)
      failure = result.failure
      return "(no failure message recorded)" if failure.nil?

      message = failure.message.to_s
      message = "#{failure.exception_class}: #{message}" if result.status == :errored && failure.exception_class
      message.empty? ? "(no failure message recorded)" : message
    end

    # The matcher's own context -- a response body, a record's attributes. Printed
    # verbatim, keeping whatever relative indentation the matcher chose.
    def failure_context(result)
      context = result.failure&.context
      return if context.nil?

      lines = context_lines(context)
      return if lines.empty?

      writeln
      lines.each { |line| writeln(line.empty? ? "" : ENTRY_INDENT + line) }
    end

    def context_lines(context)
      lines = case context
              when String then context.rstrip.lines.map { |line| line.chomp.rstrip }
              when Hash   then context.map { |key, value| "#{key}: #{value}" }
              when Array  then context.map(&:to_s)
              else [context.to_s]
              end
      lines.all?(&:empty?) ? [] : lines
    end

    # Collapsed once there are more than a handful, because a wall of warnings between
    # the failures and the summary is how both get skipped. `--show warnings` opens it;
    # nothing is hidden that a flag will not print, and the count is always visible.
    def warning_collapse_threshold = 5

    def section_warnings(warnings)
      warnings = collapse_cold_cases(warnings)
      return if warnings.empty?

      if collapse_section?(:warnings, warnings.size)
        section("WARNINGS")
        writeln(INDENT + paint("#{warnings.size} warnings — open with --show warnings",
                               COLORS[:warning]))
        writeln
        return
      end

      section("WARNINGS")
      each_entry(warnings) do |warning|
        location = warning[:location].to_s
        message  = warning[:message].to_s
        if location.empty?
          writeln(INDENT + paint("#{GLYPHS[:warning]} #{message}", COLORS[:warning]))
        else
          writeln(INDENT + paint("#{GLYPHS[:warning]} #{location}", COLORS[:warning]))
          warning_message_lines(message).each { |line| writeln(ENTRY_INDENT + line) }
        end
      end
    end

    # Cold cases are a fact about the suite, not a list of problems: every one says the
    # same sentence about a different file. Past the limit they become one line that
    # still carries the number -- which is the part that is supposed to shrink over time,
    # and the reason the warning exists at all.
    def collapse_cold_cases(warnings)
      cold, rest = warnings.partition { |w| w[:kind] == :cold_case }
      return warnings if cold.size <= COLD_CASE_LIST_LIMIT

      tests = cold.sum { |w| w[:tests].to_i }
      total = tests.positive? ? ", #{tests} #{pluralize(tests, "test")}" : ""

      [{
        kind: :cold_case,
        location: nil,
        message: "#{cold.size} files running as cold cases#{total} — not yet under " \
                 "native rules. `constable test --unsafe` runs just these."
      }] + rest
    end

    # A warning carries the author's own words -- an unsafe block's reason, a cold case's
    # count -- and those are easily ninety columns. Wrapped to the frame, but respecting
    # any line breaks the message already chose.
    def warning_message_lines(message)
      message.to_s.lines.flat_map do |line|
        text = line.chomp
        text.empty? ? [""] : wrap(text, width: RULE_WIDTH - ENTRY_INDENT.length, indent: "")
      end
    end

    # --- the last two sections ------------------------------------------------------

    # What to do next, before what just happened.
    #
    # Everything here is tied to something in this run or in the blotter -- a repeated
    # failure, a file that owns the clock, a docket that has stopped moving. Nothing is
    # printed on a hunch, for the same reason `constable insights` prints nothing on a
    # hunch: advice that is wrong once is advice nobody reads twice.
    def section_recommendations(results, counts)
      lines = recommendations(results, counts)
      return if lines.empty?

      section("RECOMMENDATIONS")
      lines.each do |headline, detail|
        writeln(INDENT + headline)
        next unless detail

        # The frame is sixty columns and everything obeys it, including advice.
        detail.to_s.split("\n").each do |paragraph|
          wrap(paragraph, width: RULE_WIDTH - ENTRY_INDENT.length, indent: "")
            .each { |line| writeln(ENTRY_INDENT + paint(line, :dim)) }
        end
      end
    end

    def recommendations(results, counts)
      lines = []
      lines << repeat_failure_recommendation(results)
      lines << jail_recommendation(counts)
      lines << warning_recommendation
      lines.compact
    end

    # A test that keeps failing across runs is the jail's whole purpose: it swaps "blocks
    # the build" for "tracked and skipped", and the history says which tests qualify
    # rather than someone deciding at 5pm.
    def repeat_failure_recommendation(results)
      repeats = results.select(&:failed?).select do |result|
        seen = @history[result.identity]
        seen && seen[:failures].to_i >= 3 && seen[:runs].to_i >= 5
      end
      return nil if repeats.empty?

      [paint("#{repeats.size} failing #{repeats.size == 1 ? "test has" : "tests have"} " \
             "failed repeatedly before", COLORS[:failed]),
       "Jail them to stop blocking the build while they are worked on:\n" \
       "#{repeats.first(3).map { |r| "constable jail #{r.location}" }.join("\n")}"]
    end

    def jail_recommendation(counts)
      return nil unless counts[:jailed].to_i.positive?

      [paint("#{counts[:jailed]} jailed #{counts[:jailed] == 1 ? "test" : "tests"} did not run",
             COLORS[:jailed]),
       "`constable jail run` reruns them in isolation; `constable jail list` says why each is there."]
    end

    def warning_recommendation
      return nil unless @warning_count.to_i > warning_collapse_threshold
      return nil if show?(:warnings)

      [paint("#{@warning_count} warnings were not shown", COLORS[:warning]),
       "`--show warnings` prints them. They do not fail the build unless " \
       "`fail_on_warnings` is set."]
    end

    # The counts, last, where they are still on screen when the run ends.
    # No trailing blank: the closing rule follows immediately, exactly as it does after
    # SLOWEST when that is the last section.
    def section_summary(counts, duration)
      section("SUMMARY")
      writeln(INDENT + summary_counts(counts))
      summary_detail(duration).each { |line| writeln(INDENT + paint(line, :dim)) }
    end

    def summary_counts(counts)
      total = counts.values_at(:passed, :failed, :jailed, :skipped, :warranted).sum(&:to_i)
      parts = [paint("#{total} #{total == 1 ? "test" : "tests"}", :bold)]
      parts << paint("#{counts[:passed]} passed", COLORS[:passed]) if counts[:passed].to_i.positive?
      parts << paint("#{counts[:failed]} failed", COLORS[:failed]) if counts[:failed].to_i.positive?
      parts << paint("#{counts[:skipped]} skipped", :dim) if counts[:skipped].to_i.positive?
      parts << paint("#{counts[:jailed]} jailed", COLORS[:jailed]) if counts[:jailed].to_i.positive?
      parts << paint("#{counts[:warranted]} warranted", COLORS[:warranted]) if counts[:warranted].to_i.positive?
      parts.join("   ")
    end

    def summary_detail(duration)
      bits = ["#{format_duration(duration)} total"]
      bits << "seed #{@seed}" if @seed
      bits << "#{@warning_count} warnings" if @warning_count.to_i.positive?
      wrap(bits.join("  ·  "), width: RULE_WIDTH - INDENT.length, indent: "")
    end

    # Which sections the caller asked to expand. CI-friendly on purpose: a flag, not a
    # keypress, so the same command prints the same thing in a log as on a terminal.
    def show?(name)
      @show.include?(name.to_s)
    end

    def collapse_section?(name, size)
      size > warning_collapse_threshold && !show?(name)
    end

    def section_slowest(results)
      # A jailed test never ran its body, so it has no honest duration. A parole
      # violation did run -- and failing slowly is still worth seeing.
      timed = results.reject { |r| r.skipped? || r.status == :jailed }
                     .select { |r| r.duration.to_f.positive? }
                     .sort_by { |r| -r.duration.to_f }
                     .first(@slowest)
      return if timed.empty?

      section("SLOWEST")
      width = timed.map { |r| format_duration(r.duration).length }.max
      timed.each do |result|
        stamp = format_duration(result.duration).rjust(width)
        writeln("#{INDENT}#{paint(stamp, :dim)}  #{result.case_name} #{paint(%("#{result.description}"), :dim)}")
      end
    end

    # Rename detection is the Runner's job; the reporter only says it out loud. Never
    # its own section -- it is a suggestion, not a finding.
    # Renames get a section of their own, a cap, and one line each.
    #
    # They used to be dumped unlabelled after SLOWEST, one long line per suggestion,
    # every line carrying both full test descriptions and two hashes. A real suite
    # produced two hundred of them and several hundred lines of output -- read as a wall
    # of text with no heading, and buried the sections above it. A suggestion nobody can
    # read is not a suggestion.
    def rename_suggestions(suggestions)
      suggestions = Array(suggestions).map { |s| suggestion(s) }.compact
      return if suggestions.empty?

      section("RENAMED?")
      shown = suggestions.first(RENAME_LIST_LIMIT)

      each_entry(shown) do |item|
        writeln(INDENT + paint(item[:from].to_s, :dim))
        writeln(ENTRY_INDENT + paint("→ #{item[:to]}", :dim))
        writeln(ENTRY_INDENT + paint("constable history relink #{item[:old_hash]} #{item[:new_hash]}", :dim))
      end

      remaining = suggestions.size - shown.size
      hint(if remaining.positive?
             "...and #{remaining} more. A test's history is keyed on its body, so a test " \
               "that was reworded and edited in one commit looks like a new one. Relink the " \
               "ones you recognise; ignore the rest and they age out."
           else
             "A test's history is keyed on its body, so one that was reworded and edited " \
               "in the same commit looks like a new test. Relink it to carry the history over."
           end)
    end

    def suggestion(raw)
      return { from: raw.to_s, to: nil, old_hash: nil, new_hash: nil } if raw.is_a?(String)
      return nil unless raw.respond_to?(:to_h)

      s = raw.to_h.transform_keys(&:to_sym)
      from = s[:old_label] || s[:from] || label_for(s[:old_case], s[:old_description])
      to   = s[:new_label] || s[:to]   || label_for(s[:new_case], s[:new_description])
      return nil if from.nil? || to.nil?

      { from: truncate_label(from), to: truncate_label(to),
        old_hash: s[:old_hash] || s[:old_identity], new_hash: s[:new_hash] || s[:new_identity] }
    end

    # A description built by RSpec from a matcher carries the whole inspected object --
    # ids, timestamps, every column of a record. Printed in full it is unreadable, and it
    # is the same test either way.
    def truncate_label(label)
      text = label.to_s.tr("\n", " ").squeeze(" ")
      return text if text.length <= RULE_WIDTH - INDENT.length

      "#{text[0, RULE_WIDTH - INDENT.length - 1]}…"
    end

    def label_for(case_name, description)
      return nil if case_name.nil? && description.nil?

      "#{case_name}##{description}"
    end

    def each_entry(entries)
      entries.each_with_index do |entry, index|
        writeln if index.positive?
        yield entry
      end
    end

    # --- warnings and coverage input -----------------------------------------------

    # Warnings arrive from two directions: Constable.warn! in this process, and results
    # shipped back by workers that warned in theirs. Same warning from four workers is
    # still one warning, so they collapse on message+location.
    def normalize_warnings(explicit)
      raw = explicit || Constable.warnings
      Array(raw).filter_map { |w| normalize_warning(w) }
                .uniq { |w| [w[:message], w[:location]] }
    end

    def normalize_warning(warning)
      return { message: warning.to_s, location: nil, kind: :unsafe } if warning.is_a?(String)
      return nil unless warning.respond_to?(:to_h)

      w = warning.to_h.transform_keys(&:to_sym)
      return nil if w[:message].nil?

      # `tests` rides along so cold cases can be totalled when there are too many to list.
      # Normalizing is about the three fields the reporter needs, not about discarding
      # everything a warning chose to carry.
      { message: w[:message].to_s, location: w[:location], kind: (w[:kind] || :unsafe).to_sym,
        tests: w[:tests] }.compact
    end

    def normalize_coverage(coverage)
      return nil if coverage.nil?
      return { percent: coverage.to_f, unpatrolled: 0 } if coverage.is_a?(Numeric)

      c = coverage.respond_to?(:to_h) ? coverage.to_h.transform_keys(&:to_sym) : {}
      c = coverage_from_object(coverage) if c.empty?
      percent = c[:percent] || c[:percentage] || c[:covered]
      return nil if percent.nil?

      { percent: percent.to_f, unpatrolled: unpatrolled_count(c) }
    end

    def coverage_from_object(coverage)
      {
        percent: (coverage.percent if coverage.respond_to?(:percent)),
        unpatrolled: (coverage.unpatrolled if coverage.respond_to?(:unpatrolled))
      }
    end

    def unpatrolled_count(hash)
      value = hash[:unpatrolled] || hash[:unpatrolled_files] || hash[:unpatrolled_count] || 0
      value.is_a?(Integer) ? value : Array(value).size
    end

    # --- formatting ----------------------------------------------------------------

    # 1st, 2nd, 3rd, 4th -- and 11th/12th/13th, which is where naive versions break.
    def ordinalize(number)
      n = number.to_i
      suffix = if (11..13).cover?(n.abs % 100)
                 "th"
               else
                 { 1 => "st", 2 => "nd", 3 => "rd" }.fetch(n.abs % 10, "th")
               end
      "#{n}#{suffix}"
    end

    def pluralize(count, word)
      return word if count.to_i == 1
      # "retry" -> "retries". Only the consonant-y rule earns a special case; every other
      # word this reporter pluralizes takes a plain "s".
      return "#{word[0..-2]}ies" if word.end_with?("y") && !"aeiou".include?(word[-2].to_s)

      "#{word}s"
    end

    # Hints are prose, and prose that runs past the frame reads as a mistake. Wrapped to
    # the same 60 columns the rules use, with continuation lines aligned under the arrow.
    def wrap(text, width:, indent:)
      words = text.split
      lines = [+""]
      words.each do |word|
        candidate = lines.last.empty? ? word : "#{lines.last} #{word}"
        if candidate.length <= width || lines.last.empty?
          lines[-1] = candidate
        else
          lines << +word
        end
      end
      lines.each_with_index.map { |line, i| i.zero? ? line : indent + line }
    end

    def format_duration(seconds)
      seconds = seconds.to_f
      return format("%.1fs", seconds) if seconds < 60

      minutes, rest = seconds.divmod(60)
      format("%dm %.1fs", minutes, rest)
    end

    def format_percent(percent)
      rounded = percent.round(1)
      rounded == rounded.round ? rounded.round.to_s : format("%.1f", rounded)
    end

    # --- colour --------------------------------------------------------------------

    # Colour is a nicety; correctness is not. NO_COLOR, a pipe, a dumb terminal or an
    # explicit --no-color all fall back to plain text with identical layout.
    # An explicit argument (the --expanded / --concise flags) beats the config file, which
    # beats the default. An unrecognized value falls back rather than raising: a typo in
    # config.yml should not stop a suite from running.
    def resolve_mode(mode)
      configured = @config.respond_to?(:output_mode) ? @config.output_mode : :concise
      return configured if mode.nil?

      mode = mode.to_s.strip.downcase.to_sym
      Config::OUTPUT_MODES.include?(mode) ? mode : configured
    end

    def resolve_color(color)
      return !!color unless color.nil?
      return false if ENV["NO_COLOR"] && !ENV["NO_COLOR"].empty?
      return false if ENV["TERM"].to_s == "dumb"
      return false unless @io.respond_to?(:tty?) && @io.tty?

      true
    end

    def paint(text, *styles)
      styles = styles.flatten.compact
      return text if !@color || styles.empty?

      codes = styles.filter_map { |style| STYLES[style] }
      return text if codes.empty?

      "\e[#{codes.join(";")}m#{text}\e[0m"
    end

    def strip_ansi(text) = text.to_s.gsub(/\e\[[0-9;]*m/, "")

    # --- width-aware padding -------------------------------------------------------

    def display_width(string)
      strip_ansi(string).each_char.sum { |char| char_width(char) }
    end

    def char_width(char)
      return 0 if char.match?(/\p{Mn}|\p{Me}|\p{Cf}/)

      code = char.ord
      WIDE_RANGES.any? { |range| range.cover?(code) } ? 2 : 1
    end

    def pad(string, width)
      padding = width - display_width(string)
      padding.positive? ? string + (" " * padding) : string
    end

    # --- output --------------------------------------------------------------------

    def write(text)
      @io.write(text)
      @io.flush if @io.respond_to?(:flush)
      text
    end

    def writeln(text = "")
      write("#{text}\n")
    end
  end
end
