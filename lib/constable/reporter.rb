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

    DEFAULT_SLOWEST = 5

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

    def initialize(io: $stdout, config: nil, color: nil, slowest: DEFAULT_SLOWEST)
      @io      = io
      @config  = config || Constable.config
      @color   = resolve_color(color)
      @slowest = slowest.to_i
      @io.set_encoding(Encoding::UTF_8) if @io.respond_to?(:set_encoding)

      reset_stream!
      @failed_live = 0
      @warning_count = 0
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

      close_stream_line
      pending_case_names.each { |name| open_stream_line(name) && close_stream_line }
      writeln
      reset_stream!
      self
    end

    # Prints the summary. Returns the process exit status so a caller can
    # `exit reporter.finish(...)` in one line.
    def finish(results:, duration: 0.0, seed: nil, coverage: nil, suggestions: [], warnings: nil)
      results = Array(results)
      @seed   = seed if seed
      flush!

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
      section_warnings(warnings)
      section_slowest(results)
      rename_suggestions(suggestions)

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
        writeln(ENTRY_INDENT + parole_violation_sentence(result))
      end
    end

    def parole_violation_sentence(result)
      sentence = "Failed on day #{result.parole_day} of a #{@config.parole_period}-run parole — back to jail."
      sentence << " This is its #{ordinalize(result.times_jailed)} time in jail." if result.times_jailed
      sentence
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
      writeln
      failure_message(result).each_line { |line| writeln(ENTRY_INDENT + line.chomp) }
      failure_context(result)
      writeln
      writeln(ENTRY_INDENT + paint("Rerun just this test:", :dim))
      writeln(DETAIL_INDENT + result.rerun_command)
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

    def section_warnings(warnings)
      return if warnings.empty?

      section("WARNINGS")
      each_entry(warnings) do |warning|
        location = warning[:location].to_s
        message  = warning[:message].to_s
        if location.empty?
          writeln(INDENT + paint("#{GLYPHS[:warning]} #{message}", COLORS[:warning]))
        else
          writeln(INDENT + paint("#{GLYPHS[:warning]} #{location}", COLORS[:warning]))
          message.each_line { |line| writeln(ENTRY_INDENT + line.chomp) }
        end
      end
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
    def rename_suggestions(suggestions)
      suggestions = Array(suggestions).map { |s| suggestion_line(s) }.compact
      return if suggestions.empty?

      writeln
      suggestions.each { |line| writeln(INDENT + paint(line, :dim)) }
    end

    def suggestion_line(suggestion)
      return suggestion.to_s if suggestion.is_a?(String)
      return nil unless suggestion.respond_to?(:to_h)

      s = suggestion.to_h.transform_keys(&:to_sym)
      from = s[:old_label] || s[:from] || label_for(s[:old_case], s[:old_description])
      to   = s[:new_label] || s[:to]   || label_for(s[:new_case], s[:new_description])
      old_hash = s[:old_hash] || s[:old_identity]
      new_hash = s[:new_hash] || s[:new_identity]
      return nil if from.nil? || to.nil?

      "possible rename: #{from} → #{to}, " \
        "run constable history relink #{old_hash} #{new_hash} to confirm"
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

      { message: w[:message].to_s, location: w[:location], kind: (w[:kind] || :unsafe).to_sym }
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
      count.to_i == 1 ? word : "#{word}s"
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
