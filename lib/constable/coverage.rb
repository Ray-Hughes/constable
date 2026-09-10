# frozen_string_literal: true

require "coverage"
require "set"
require "cgi"
require "rbconfig"
require "constable/diff"

module Constable
  # Coverage -- "the beat".
  #
  # ---------------------------------------------------------------------------
  # A NAMING TRAP, READ THIS FIRST
  #
  # This module is `Constable::Coverage`. Ruby's built-in line-coverage module is
  # `::Coverage`. Inside `module Constable`, a bare `Coverage` resolves to *this* module,
  # so `Coverage.start(lines: true)` written anywhere in this file would call a method on
  # ourselves and fail in a way that reads like a bug in Ruby. **Every reference to the
  # stdlib is spelled `::Coverage`, without exception.** Keep it that way.
  # ---------------------------------------------------------------------------
  #
  # We wrap Ruby's own `Coverage` module rather than SimpleCov, and that is the whole
  # trick behind coverage working uniformly here: **`::Coverage` measures the process, not
  # the test framework.** It hooks line execution in the VM. It has no idea whether the
  # line was reached by a native `investigate` block, by the real RSpec engine running a
  # cold case, or by a `require` at boot. So native cases and cold cases contribute to one
  # set of numbers automatically, with no per-engine instrumentation and nothing to keep
  # in sync when a new engine adapter appears.
  #
  # What is *not* uniform is the gate. The enforced threshold is diff-based, not blanket:
  # `coverage_threshold: 90` is checked only against lines changed versus the merge base,
  # the same git-diff philosophy the Runner uses to decide what to run locally. Legacy
  # gaps stay visible in the report without blocking the build; new code is held to the
  # bar. And cold cases, which opt out of Constable's rules everywhere else, opt out here
  # too: they contribute numbers, they are not held to the gate.
  module Coverage
    # Our own lib/, so the gem never measures itself.
    GEM_LIB = File.expand_path("..", __dir__)

    # Directory segments that are never application code.
    EXCLUDED_DIRS = %w[
      test spec features vendor tmp node_modules coverage log pkg
      .git .constable .bundle
    ].to_set.freeze

    EXCLUDED_BASENAMES = %w[
      case_helper.rb test_helper.rb spec_helper.rb rails_helper.rb
    ].to_set.freeze

    EXCLUDED_BASENAME_PATTERN = /_(?:test|spec)\.rb\z/

    # Lines a heuristic scan treats as not executable, used only for files that never got
    # loaded at all (see Report#synthesize_missing).
    NON_EXECUTABLE = /\A(?:end|else|ensure|begin|rescue.*|\}|\)|\]|__END__)\z/

    class << self
      # Begins measuring, if the run asked for it. Returns true when measurement is
      # active afterwards (whoever started it), false when coverage is switched off.
      #
      #   Coverage.start!(config: Constable.config)
      #   Coverage.start!(config: config, force: true)   # `constable beat`, ignoring the setting
      #
      # If something else -- SimpleCov in the app's own rails_helper, a CI wrapper -- has
      # already started `::Coverage`, we attach to their measurement instead of starting a
      # second one (there is only one, process-wide) and take care never to stop it out
      # from under them.
      def start!(config: Constable.config, force: false)
        return false unless force || config.coverage?
        return true if active?

        if ::Coverage.running?
          @external = true
        else
          ::Coverage.start(lines: true)
          @external = false
        end
        @active = true
      end

      # Ends measurement and returns a Report, or nil if we were never measuring.
      #
      #   report = Coverage.stop!(config: config)
      #   report = Coverage.stop!(config: config, gate: false)          # cold-only run
      #   report = Coverage.stop!(config: config, exempt: cold_files)   # per-file exemptions
      def stop!(config: Constable.config, root: Constable.root, exempt: [], gate: true,
                since: nil, changed_lines: :detect)
        raw = harvest(stop: true)
        return nil if raw.nil?

        build_report(raw, config: config, root: root, exempt: exempt, gate: gate,
                          since: since, changed_lines: changed_lines)
      end

      # A Report from the numbers so far, leaving measurement running. Useful for a
      # mid-run snapshot; harmless to call when coverage is off (returns nil).
      def peek(config: Constable.config, root: Constable.root, exempt: [], gate: true,
               since: nil, changed_lines: :detect)
        raw = harvest(stop: false)
        return nil if raw.nil?

        build_report(raw, config: config, root: root, exempt: exempt, gate: gate,
                          since: since, changed_lines: changed_lines)
      end

      # Stops measurement without producing a report -- for teardown paths that just want
      # the hook off again. Never stops a measurement somebody else started.
      def abort!
        ::Coverage.result(stop: true, clear: true) if @active && !@external && ::Coverage.running?
        true
      ensure
        @active = false
        @external = false
      end

      def active?   = @active == true
      def external? = @external == true

      # Builds a Report from a raw `::Coverage` result hash. Public because it is the
      # seam every test and every alternative front-end goes through: hand it a synthetic
      # `{ "path.rb" => [1, 0, nil] }` and you get the same Report the real thing produces.
      #
      #   raw           - `::Coverage` result: { path => [hits...] } or { path => { lines: [...] } }
      #   exempt        - paths/globs excluded from the diff gate (cold-case files)
      #   gate          - false disables the diff gate entirely (a cold-case-only run)
      #   changed_lines - :detect asks Diff; nil means "no diff info"; a Hash is used as given
      def build_report(raw, config: Constable.config, root: Constable.root, exempt: [], gate: true,
                       since: nil, changed_lines: :detect)
        root = resolve_root(root)
        files = normalize(raw, config: config, root: root)
        changed = resolve_changed_lines(changed_lines, root: root, since: since)

        Report.new(files: files, root: root, config: config, changed_lines: changed,
                   exempt: exempt, gate: gate)
      end

      # Persists one snapshot per run so `constable status` can plot a trend.
      def record!(report, run_id, storage: Constable.storage)
        return report if report.nil? || run_id.nil?

        storage.record_coverage(run_id, percent: report.percent, files: report.files.map(&:to_h))
        report
      end

      def default_html_path(root: Constable.root)
        File.join(root.to_s, ".constable", "coverage", "index.html")
      end

      # Writes the browsable report and returns the path written.
      def write_html(report, path: nil, root: Constable.root)
        path ||= default_html_path(root: root)
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, report.to_html)
        path
      end

      # Is this path application code we should be measuring? Excludes the gem itself,
      # installed gems, the stdlib, and the suite's own test/spec files -- a test file's
      # coverage of itself is noise, not information.
      def application_file?(path, root: Constable.root, config: nil)
        path = path.to_s
        return false unless path.end_with?(".rb")

        absolute = File.expand_path(path)
        relative = relative_to(absolute, root)
        return false if relative.nil?
        return false if absolute.start_with?("#{GEM_LIB}/")
        return false if absolute.include?("/gems/") || absolute.include?("/vendor/bundle/")
        return false if stdlib?(absolute)

        segments = relative.split("/")
        basename = segments.pop
        return false if segments.any? { |segment| EXCLUDED_DIRS.include?(segment) }
        return false if EXCLUDED_BASENAMES.include?(basename) || EXCLUDED_BASENAME_PATTERN.match?(basename)

        excluded = extra_excludes(config).any? do |glob|
          File.fnmatch?(glob, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB)
        end
        return false if excluded

        true
      end

      # --- internals -----------------------------------------------------------

      # `::Coverage` reports the paths Ruby actually loaded, which are symlink-resolved.
      # A root of /var/folders/... and a coverage path of /private/var/folders/... are the
      # same directory on macOS and must not be treated as different ones.
      def resolve_root(root)
        File.realpath(root.to_s)
      rescue SystemCallError
        File.expand_path(root.to_s)
      end

      # A path's location under the root, or nil when it isn't under it at all. Tries
      # both spellings of the root -- symlinked (/var/...) and resolved (/private/var/...)
      # -- because Ruby hands out one and the caller usually holds the other.
      def relative_to(path, root)
        absolute = File.expand_path(path.to_s)
        [File.expand_path(root.to_s), resolve_root(root)].uniq.each do |prefix|
          return absolute.delete_prefix("#{prefix}/") if absolute.start_with?("#{prefix}/")
        end
        nil
      end

      # The raw stdlib numbers as they stand, without ending the measurement. Workers use
      # this to send their counts home: Ruby's Coverage is per-process, so a forked worker's
      # hits exist only in that worker and would otherwise be thrown away when it exits.
      def peek_raw
        return nil unless ::Coverage.running?

        ::Coverage.peek_result
      rescue StandardError
        nil
      end

      # Sums two raw coverage results. Line arrays are added element-wise; nil means the
      # line isn't executable and stays nil, which is not the same as zero and must not
      # become it -- a nil turned into a 0 invents an uncovered line that never existed.
      def merge_raw(left, right)
        merged = (left || {}).dup

        (right || {}).each do |path, entry|
          existing = merged[path]
          merged[path] = existing.nil? ? entry : merge_entry(existing, entry)
        end

        merged
      end

      def merge_entry(left, right)
        if left.is_a?(Hash) || right.is_a?(Hash)
          lines = merge_lines(left.is_a?(Hash) ? left[:lines] : left,
                              right.is_a?(Hash) ? right[:lines] : right)
          return (left.is_a?(Hash) ? left : right).merge(lines: lines)
        end

        merge_lines(left, right)
      end

      def merge_lines(left, right)
        return right if left.nil?
        return left if right.nil?

        [left.size, right.size].max.times.map do |i|
          a = left[i]
          b = right[i]
          next nil if a.nil? && b.nil?

          a.to_i + b.to_i
        end
      end

      # Reads the numbers out of the stdlib. When someone else owns the measurement we
      # peek rather than stop, so their own report still comes out right at exit.
      def harvest(stop:)
        return nil unless active?
        return nil unless ::Coverage.running?

        if external? || !stop
          ::Coverage.peek_result
        else
          ::Coverage.result(stop: true, clear: true)
        end
      ensure
        if stop
          @active = false
          @external = false
        end
      end

      def normalize(raw, config:, root:)
        (raw || {}).filter_map do |path, entry|
          path = real_path(path)
          next unless application_file?(path, root: root, config: config)

          lines = entry.is_a?(Hash) ? (entry[:lines] || entry["lines"]) : entry
          next if lines.nil?

          FileCoverage.new(path: path, lines: lines, root: root)
        end
      end

      # `load "/var/tmp/x.rb"` is recorded by `::Coverage` under exactly the path it was
      # given, symlinks and all. Resolving each measured file once keeps every later
      # comparison -- against the root, against the diff -- an ordinary string compare.
      def real_path(path)
        File.realpath(path.to_s)
      rescue SystemCallError
        File.expand_path(path.to_s)
      end

      def resolve_changed_lines(changed_lines, root:, since:)
        case changed_lines
        when :detect then Diff.changed_lines(since: since, root: root, absolute: true)
        when nil     then nil
        else              normalize_changed_lines(changed_lines, root: root)
        end
      end

      # Accepts relative or absolute keys, Arrays or Sets of line numbers.
      def normalize_changed_lines(hash, root:)
        hash.each_with_object({}) do |(path, numbers), out|
          out[File.expand_path(path.to_s, root)] = numbers.is_a?(Set) ? numbers : Set.new(Array(numbers))
        end
      end

      def stdlib?(absolute)
        %w[rubylibdir libdir sitelibdir vendorlibdir archdir].any? do |key|
          dir = RbConfig::CONFIG[key]
          dir && !dir.empty? && absolute.start_with?("#{dir}/")
        end
      end

      # Undocumented-but-supported escape valve: `coverage_exclude:` in config.yml takes
      # a list of globs for generated or vendored code that lives inside the app tree.
      def extra_excludes(config)
        return [] unless config.respond_to?(:[])

        Array(config["coverage_exclude"]).map(&:to_s)
      end
    end

    # One file's line coverage. `lines` is `::Coverage`'s own array: an Integer hit count
    # per executable line, nil for a line that can never execute (blank, comment, `end`).
    class FileCoverage
      attr_reader :path, :lines, :root

      def initialize(path:, lines:, root: Constable.root)
        @path = path.to_s
        @lines = Array(lines)
        @root = Coverage.resolve_root(root)
        @synthesized = false
      end

      # True when this entry was inferred rather than measured -- a changed file that was
      # never loaded at all, so `::Coverage` had nothing to say about it.
      def synthesized? = @synthesized

      def synthesized! # :nodoc:
        @synthesized = true
        self
      end

      def relative_path
        @relative_path ||= Coverage.relative_to(@path, @root) || @path
      end

      # Number of executable lines.
      def relevant = @lines.count { |hits| !hits.nil? }

      # Number of executable lines that ran at least once.
      def covered = @lines.count { |hits| !hits.nil? && hits.positive? }

      def missed = relevant - covered

      # 1-based line numbers, for the report and the gate.
      def missed_lines = line_numbers { |hits| !hits.nil? && hits.zero? }
      def covered_lines = line_numbers { |hits| !hits.nil? && hits.positive? }
      def relevant_lines = line_numbers { |hits| !hits.nil? }

      # 1-based line numbers whose hit count satisfies the block.
      def line_numbers
        numbers = []
        @lines.each_with_index { |hits, index| numbers << (index + 1) if yield(hits) }
        numbers
      end

      def hits_for(number) = @lines[number - 1]
      def executable?(number) = !@lines[number - 1].nil?
      def covered?(number) = (@lines[number - 1] || 0).positive?

      # A file with no executable lines at all is vacuously complete, not a gap.
      def percent
        return 100.0 if relevant.zero?

        ((covered.to_f / relevant) * 100).round(2)
      end

      # "Unpatrolled" -- zero executed lines. Named separately from a merely thin file
      # because a 0% file is usually a file nobody remembered to test at all, and that is
      # a different problem from a file whose edges are uncovered.
      def unpatrolled? = relevant.positive? && covered.zero?

      # The file's text, for the HTML line view. Missing/unreadable files render empty
      # rather than blowing up a report someone is waiting on.
      def source_lines
        @source_lines ||= begin
          File.readlines(@path, chomp: true).map { |line| line.dup.force_encoding(Encoding::UTF_8).scrub }
        rescue SystemCallError, IOError
          []
        end
      end

      def to_h
        {
          path: relative_path, percent: percent, relevant: relevant,
          covered: covered, missed: missed, unpatrolled: unpatrolled?,
          missed_lines: missed_lines, synthesized: synthesized?
        }
      end
    end

    # The full picture for one run: overall numbers, per-file breakdown, the unpatrolled
    # list, and the diff-based gate.
    class Report
      attr_reader :files, :root, :config, :exempt

      def initialize(files:, root: Constable.root, config: Constable.config,
                     changed_lines: nil, exempt: [], gate: true)
        @root = Coverage.resolve_root(root)
        @config = config
        @changed_lines = changed_lines
        @exempt = Array(exempt).map(&:to_s)
        @gate = gate
        @files = files.sort_by(&:relative_path)
        synthesize_missing!
      end

      # --- overall -------------------------------------------------------------

      def empty? = @files.empty?
      def file(path) = @files.find { |f| f.relative_path == path.to_s || f.path == File.expand_path(path.to_s, @root) }

      def relevant = @files.sum(&:relevant)
      def covered  = @files.sum(&:covered)
      def missed   = relevant - covered

      def percent
        return 100.0 if relevant.zero?

        ((covered.to_f / relevant) * 100).round(2)
      end

      def unpatrolled = @files.select(&:unpatrolled?)

      # --- the diff gate -------------------------------------------------------

      # False when git could not tell us what changed. The gate cannot be enforced then,
      # and silently passing is the only honest answer -- we would otherwise fail builds
      # on shallow clones and source tarballs.
      def diff_available? = !@changed_lines.nil?

      # Gating is switched off wholesale for a run that carried no native cases -- a
      # `constable test --only=cold` run is all cold cases, and cold cases are exempt.
      def gate? = @gate == true

      # Files whose changed lines are held to the threshold: application files with
      # changed lines, minus anything exempt (a cold-case file, or a path the Runner
      # passed in as cold).
      def gated_files
        return [] unless diff_available?

        @files.reject { |f| exempt?(f) }.select { |f| changed_numbers(f).any? }
      end

      # Changed, executable lines under the gate.
      def diff_relevant
        gated_files.sum { |f| changed_numbers(f).count { |n| f.executable?(n) } }
      end

      def diff_covered
        gated_files.sum { |f| changed_numbers(f).count { |n| f.executable?(n) && f.covered?(n) } }
      end

      def diff_missed = diff_relevant - diff_covered

      # Percentage of changed executable lines that ran. nil when there is no diff info;
      # 100.0 when the diff touched no executable line at all (a README, a comment).
      def diff_percent
        return nil unless diff_available?
        return 100.0 if diff_relevant.zero?

        ((diff_covered.to_f / diff_relevant) * 100).round(2)
      end

      # { "app/models/user.rb" => [12, 13, 40] } -- the changed lines that never ran.
      # This is the actionable half of the gate: not "you are at 84%", but "these lines".
      def uncovered_diff_lines
        gated_files.each_with_object({}) do |file, out|
          numbers = changed_numbers(file).select { |n| file.executable?(n) && !file.covered?(n) }.sort
          out[file.relative_path] = numbers if numbers.any?
        end
      end

      def threshold = @config.respond_to?(:coverage_threshold) ? @config.coverage_threshold : 0

      # The build gate. Passes when there is nothing to judge -- no git, no changed
      # executable lines, or a run that was exempt from gating altogether.
      def meets_threshold?(config = @config)
        return true unless gate?
        return true unless diff_available?
        return true if diff_relevant.zero?

        diff_percent >= (config.respond_to?(:coverage_threshold) ? config.coverage_threshold : 0)
      end

      # nil when the gate passes; otherwise the sentence the reporter should print.
      def threshold_message(config = @config)
        return nil if meets_threshold?(config)

        limit = config.respond_to?(:coverage_threshold) ? config.coverage_threshold : 0
        "diff coverage #{format_percent(diff_percent)} of #{diff_relevant} changed " \
          "#{plural(diff_relevant, "line")} is below the #{limit}% threshold"
      end

      # --- output --------------------------------------------------------------

      # The one line the run summary gains: "◐ 92% covered (3 files unpatrolled)".
      def summary_line
        line = "◐ #{percent.round}% covered"
        count = unpatrolled.size
        return line if count.zero?

        "#{line} (#{count} #{plural(count, "file")} unpatrolled)"
      end

      # `constable beat` -- the standalone full picture. Plain text; colouring is the
      # reporter's business, not ours.
      def beat_report
        rule = "━" * 60
        out = [rule, "  THE BEAT#{" " * 12}#{headline}", rule, ""]
        out.concat(breakdown_section)
        out.concat(unpatrolled_section)
        out.concat(diff_section)
        out << rule
        out.join("\n")
      end

      def to_h
        {
          percent: percent, covered: covered, relevant: relevant,
          unpatrolled: unpatrolled.map(&:relative_path),
          diff_percent: diff_percent, diff_covered: diff_covered, diff_relevant: diff_relevant,
          uncovered_diff_lines: uncovered_diff_lines,
          meets_threshold: meets_threshold?,
          files: @files.map(&:to_h)
        }
      end

      def to_html = Html.new(self).render

      # --- internals -----------------------------------------------------------

      def changed_numbers(file)
        return [] unless @changed_lines

        Array(@changed_lines[file.path] ||
              @changed_lines[File.expand_path(file.relative_path, @root)] ||
              @changed_lines[file.relative_path])
      end

      def exempt?(file)
        relative = file.relative_path
        return true if @config.respond_to?(:cold_case?) && @config.cold_case?(relative)

        @exempt.any? do |pattern|
          pattern == relative || pattern == file.path ||
            File.fnmatch?(pattern, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB)
        end
      end

      private

      # `::Coverage` only knows about files that were *loaded*. Add a brand-new class that
      # no test ever requires and it simply will not appear in the result -- and a diff
      # gate that silently ignores the one file you just wrote is worse than no gate. So
      # for changed application files with no measurement at all, we synthesize a
      # zero-coverage entry, guessing executable lines from the source. The guess is
      # crude on purpose; a file in this state is 0% covered whichever way you count it.
      def synthesize_missing!
        return unless @changed_lines

        known = @files.to_set(&:path)
        @changed_lines.each_key do |path|
          next if known.include?(path)
          next unless File.file?(path)
          next unless Coverage.application_file?(path, root: @root, config: @config)

          @files << FileCoverage.new(path: path, lines: guess_executable(path), root: @root).synthesized!
        end
        @files.sort_by!(&:relative_path)
      end

      def guess_executable(path)
        File.readlines(path, chomp: true).map do |line|
          stripped = line.strip
          next nil if stripped.empty? || stripped.start_with?("#")
          next nil if NON_EXECUTABLE.match?(stripped)

          0
        end
      rescue SystemCallError, IOError
        []
      end

      def headline
        parts = ["#{format_percent(percent)} covered", "#{@files.size} #{plural(@files.size, "file")}"]
        parts << "#{unpatrolled.size} unpatrolled" if unpatrolled.any?
        parts << "diff #{format_percent(diff_percent)}" if diff_available? && diff_relevant.positive?
        parts.join(" · ")
      end

      def breakdown_section
        return ["  no application files measured", ""] if @files.empty?

        width = @files.map { |f| f.relative_path.length }.max
        rows = @files.sort_by { |f| [f.percent, f.relative_path] }.map do |f|
          format("  %6s  %-#{width}s  %s/%s%s", format_percent(f.percent), f.relative_path,
                 f.covered, f.relevant, f.synthesized? ? "  (never loaded)" : "")
        end
        ["  COVERAGE", "  #{"─" * 8}", *rows, ""]
      end

      def unpatrolled_section
        return [] if unpatrolled.empty?

        rows = unpatrolled.map do |f|
          "  ○ #{f.relative_path} (0 of #{f.relevant} #{plural(f.relevant, "line")})"
        end
        ["  UNPATROLLED", "  #{"─" * 11}", *rows, ""]
      end

      def diff_section
        return ["  DIFF COVERAGE", "  #{"─" * 13}", "  no diff information available", ""] unless diff_available?
        return [] if diff_relevant.zero? && uncovered_diff_lines.empty?

        verdict = meets_threshold? ? "meets" : "below"
        rows = ["  #{format_percent(diff_percent)} of #{diff_relevant} changed " \
                "#{plural(diff_relevant, "line")} covered -- #{verdict} the #{threshold}% threshold"]
        uncovered_diff_lines.each { |path, numbers| rows << "  ✗ #{path}:#{numbers.join(",")}" }
        ["  DIFF COVERAGE", "  #{"─" * 13}", *rows, ""]
      end

      def format_percent(value)
        return "n/a" if value.nil?

        value == value.round ? "#{value.round}%" : "#{format("%.1f", value)}%"
      end

      def plural(count, word) = count == 1 ? word : "#{word}s"
    end

    # The browsable report: one self-contained HTML file, no CDN, no assets directory,
    # nothing to serve. Open it from a file:// URL on a plane and it still works.
    class Html
      def initialize(report)
        @report = report
      end

      def render
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Constable — the beat</title>
          <style>#{CSS}</style>
          </head>
          <body>
          <header class="beat">
            #{header}
          </header>
          <main>
            #{diff_panel}
            #{unpatrolled_panel}
            #{table}
          </main>
          <footer>Generated by Constable — click a filename for its line-by-line view.</footer>
          <script>#{JS}</script>
          </body>
          </html>
        HTML
      end

      private

      def e(text) = CGI.escapeHTML(text.to_s)

      def header
        percent = @report.percent
        <<~HTML
          <div class="dial #{grade(percent)}">
            <span class="pct">#{percent.round}%</span>
            <span class="lbl">covered</span>
          </div>
          <div class="stats">
            <h1>The beat</h1>
            <p>
              <strong>#{@report.covered}</strong> of <strong>#{@report.relevant}</strong> relevant lines
              across <strong>#{@report.files.size}</strong> files.
              <span class="chip #{@report.unpatrolled.empty? ? "ok" : "warn"}">#{@report.unpatrolled.size} unpatrolled</span>
              #{diff_chip}
            </p>
          </div>
        HTML
      end

      def diff_chip
        return "" unless @report.diff_available?
        return %(<span class="chip ok">no changed lines</span>) if @report.diff_relevant.zero?

        state = @report.meets_threshold? ? "ok" : "bad"
        %(<span class="chip #{state}">diff #{@report.diff_percent.round}% of ) +
          %(#{@report.diff_relevant} changed lines</span>)
      end

      def diff_panel
        return "" unless @report.diff_available?

        uncovered = @report.uncovered_diff_lines
        return "" if uncovered.empty?

        rows = uncovered.map do |path, numbers|
          links = numbers.map { |n| %(<a href="#" data-goto="#{e(path)}" data-line="#{n}">#{n}</a>) }.join(", ")
          %(<li><code>#{e(path)}</code> <span class="lines">#{links}</span></li>)
        end.join("\n")

        <<~HTML
          <section class="panel #{@report.meets_threshold? ? "ok" : "bad"}">
            <h2>Changed lines not covered</h2>
            <p class="sub">Only these lines are held to the #{@report.threshold}% threshold. Legacy gaps below are visible, not blocking.</p>
            <ul class="uncovered">#{rows}</ul>
          </section>
        HTML
      end

      def unpatrolled_panel
        files = @report.unpatrolled
        return "" if files.empty?

        items = files.map do |f|
          %(<li><a href="#" data-goto="#{e(f.relative_path)}">#{e(f.relative_path)}</a> ) +
            %(<span class="sub">#{f.relevant} lines, none executed</span></li>)
        end.join("\n")

        <<~HTML
          <section class="panel warn">
            <h2>Unpatrolled</h2>
            <p class="sub">Zero executed lines. Usually a file nobody tested at all, rather than a thin one.</p>
            <ul class="uncovered">#{items}</ul>
          </section>
        HTML
      end

      def table
        rows = @report.files.each_with_index.map { |file, index| file_rows(file, index) }.join("\n")
        <<~HTML
          <table id="files">
            <thead>
              <tr>
                <th data-sort="text" class="asc">File</th>
                <th data-sort="num">Coverage</th>
                <th data-sort="num">Covered</th>
                <th data-sort="num">Relevant</th>
                <th data-sort="num">Missed</th>
              </tr>
            </thead>
            <tbody>#{rows}</tbody>
          </table>
        HTML
      end

      def file_rows(file, index)
        percent = file.percent
        note = file.synthesized? ? %( <span class="chip warn">never loaded</span>) : ""
        <<~HTML
          <tr class="file #{grade(percent)}" data-file="#{e(file.relative_path)}" data-index="#{index}">
            <td class="name"><button type="button" class="toggle" aria-expanded="false">#{e(file.relative_path)}</button>#{note}</td>
            <td data-value="#{percent}"><span class="bar"><span style="width:#{percent}%"></span></span><span class="num">#{format("%.1f", percent)}%</span></td>
            <td data-value="#{file.covered}" class="num">#{file.covered}</td>
            <td data-value="#{file.relevant}" class="num">#{file.relevant}</td>
            <td data-value="#{file.missed}" class="num">#{file.missed}</td>
          </tr>
          <tr class="source" hidden><td colspan="5">#{source_view(file)}</td></tr>
        HTML
      end

      def source_view(file)
        lines = file.source_lines
        return %(<p class="sub">Source unavailable (#{e(file.path)}).</p>) if lines.empty?

        body = lines.each_with_index.map do |text, index|
          number = index + 1
          hits = file.hits_for(number)
          state = if hits.nil? then "na"
                  elsif hits.positive? then "hit"
                  else "miss"
                  end
          count = hits.nil? ? "" : "#{hits}×"
          %(<div class="line #{state}" id="L#{e(file.relative_path)}-#{number}">) +
            %(<span class="ln">#{number}</span><span class="hits">#{count}</span><code>#{e(text)}</code></div>)
        end.join

        %(<div class="code">#{body}</div>)
      end

      def grade(percent)
        return "good" if percent >= 90
        return "ok" if percent >= 70

        percent.zero? ? "none" : "bad"
      end

      CSS = <<~CSS
        :root {
          color-scheme: light dark;
          --bg: #f6f5f2; --panel: #fffdf8; --ink: #1c1a17; --muted: #6c665c;
          --line: #e3ded3; --good: #2e7d4f; --ok: #b07d12; --bad: #b3261e; --none: #7a2f2a;
          --hit: rgba(46,125,79,.14); --miss: rgba(179,38,30,.16); --accent: #2d4f8a;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #16171a; --panel: #1e2024; --ink: #e8e6e1; --muted: #9a958c;
            --line: #2e3137; --good: #6bbd8c; --ok: #d8a93e; --bad: #ef6b62; --none: #ef8b7f;
            --hit: rgba(107,189,140,.16); --miss: rgba(239,107,98,.18); --accent: #7fa8f0;
          }
        }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--ink);
               font: 14px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif; }
        header.beat { display: flex; gap: 1.5rem; align-items: center; padding: 1.5rem 2rem;
                      border-bottom: 1px solid var(--line); background: var(--panel); }
        .dial { width: 96px; height: 96px; border-radius: 50%; display: flex; flex-direction: column;
                align-items: center; justify-content: center; border: 4px solid var(--line); flex: none; }
        .dial.good { border-color: var(--good); } .dial.ok { border-color: var(--ok); }
        .dial.bad, .dial.none { border-color: var(--bad); }
        .dial .pct { font-size: 1.6rem; font-weight: 700; }
        .dial .lbl { font-size: .7rem; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); }
        h1 { font-size: 1.25rem; margin: 0 0 .25rem; }
        h2 { font-size: 1rem; margin: 0 0 .25rem; }
        p { margin: .25rem 0; }
        .sub { color: var(--muted); font-size: .85rem; }
        .chip { display: inline-block; padding: .1rem .5rem; border-radius: 999px; font-size: .78rem;
                border: 1px solid var(--line); }
        .chip.ok { color: var(--good); border-color: var(--good); }
        .chip.warn { color: var(--ok); border-color: var(--ok); }
        .chip.bad { color: var(--bad); border-color: var(--bad); }
        main { padding: 1.5rem 2rem 3rem; }
        .panel { background: var(--panel); border: 1px solid var(--line); border-left: 3px solid var(--muted);
                 border-radius: 6px; padding: 1rem 1.25rem; margin-bottom: 1.25rem; }
        .panel.bad { border-left-color: var(--bad); }
        .panel.warn { border-left-color: var(--ok); }
        ul.uncovered { list-style: none; margin: .5rem 0 0; padding: 0; }
        ul.uncovered li { padding: .2rem 0; border-bottom: 1px dotted var(--line); }
        .lines a { color: var(--accent); text-decoration: none; margin-right: .25rem; }
        table { width: 100%; border-collapse: collapse; background: var(--panel);
                border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
        th { text-align: left; font-size: .78rem; text-transform: uppercase; letter-spacing: .06em;
             color: var(--muted); padding: .6rem .75rem; border-bottom: 1px solid var(--line);
             cursor: pointer; user-select: none; white-space: nowrap; }
        th::after { content: ""; }
        th.asc::after { content: " ▲"; } th.desc::after { content: " ▼"; }
        td { padding: .4rem .75rem; border-bottom: 1px solid var(--line); vertical-align: middle; }
        td.num, th:not(:first-child) { text-align: right; }
        tr.file.good td:first-child { border-left: 3px solid var(--good); }
        tr.file.ok td:first-child { border-left: 3px solid var(--ok); }
        tr.file.bad td:first-child, tr.file.none td:first-child { border-left: 3px solid var(--bad); }
        button.toggle { background: none; border: 0; padding: 0; color: var(--accent); cursor: pointer;
                        font: inherit; text-align: left; }
        .bar { display: inline-block; width: 90px; height: 6px; background: var(--line);
               border-radius: 3px; overflow: hidden; margin-right: .5rem; vertical-align: middle; }
        .bar > span { display: block; height: 100%; background: var(--good); }
        tr.file.ok .bar > span { background: var(--ok); }
        tr.file.bad .bar > span, tr.file.none .bar > span { background: var(--bad); }
        tr.source > td { padding: 0; background: var(--bg); }
        .code { max-height: 60vh; overflow: auto; font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
        .line { display: flex; white-space: pre; }
        .line .ln { width: 4.5rem; flex: none; text-align: right; padding-right: .75rem; color: var(--muted); }
        .line .hits { width: 4rem; flex: none; text-align: right; padding-right: 1rem; color: var(--muted); font-size: .9em; }
        .line code { white-space: pre; }
        .line.hit { background: var(--hit); }
        .line.miss { background: var(--miss); }
        .line.miss .ln { color: var(--bad); font-weight: 700; }
        .line.na { opacity: .65; }
        .line.flash { outline: 2px solid var(--accent); outline-offset: -2px; }
        footer { padding: 1rem 2rem 2rem; color: var(--muted); font-size: .8rem; }
      CSS

      JS = <<~JS
        (function () {
          var table = document.getElementById("files");
          if (!table) return;
          var body = table.tBodies[0];

          // Rows come in pairs: the file row and its (hidden) source row. Sorting moves
          // the pair, never just the header of it.
          function pairs() {
            var out = [], rows = Array.prototype.slice.call(body.rows);
            for (var i = 0; i < rows.length; i += 2) out.push([rows[i], rows[i + 1]]);
            return out;
          }

          function toggle(row) {
            var source = row.nextElementSibling;
            var button = row.querySelector(".toggle");
            var open = source.hidden;
            source.hidden = !open;
            if (button) button.setAttribute("aria-expanded", open ? "true" : "false");
            return source;
          }

          body.addEventListener("click", function (event) {
            var button = event.target.closest(".toggle");
            if (!button) return;
            event.preventDefault();
            toggle(button.closest("tr.file"));
          });

          Array.prototype.forEach.call(table.tHead.rows[0].cells, function (th, index) {
            th.addEventListener("click", function () {
              var descending = !th.classList.contains("desc");
              Array.prototype.forEach.call(table.tHead.rows[0].cells, function (other) {
                other.classList.remove("asc", "desc");
              });
              th.classList.add(descending ? "desc" : "asc");
              var numeric = th.dataset.sort === "num";
              var sorted = pairs().sort(function (a, b) {
                var x = a[0].cells[index], y = b[0].cells[index];
                if (numeric) {
                  return (parseFloat(y.dataset.value) - parseFloat(x.dataset.value)) * (descending ? 1 : -1);
                }
                return x.textContent.trim().localeCompare(y.textContent.trim()) * (descending ? -1 : 1);
              });
              sorted.forEach(function (pair) { body.appendChild(pair[0]); body.appendChild(pair[1]); });
            });
          });

          document.addEventListener("click", function (event) {
            var link = event.target.closest("[data-goto]");
            if (!link) return;
            event.preventDefault();
            var row = body.querySelector('tr.file[data-file="' + link.dataset.goto + '"]');
            if (!row) return;
            if (row.nextElementSibling.hidden) toggle(row);
            var target = link.dataset.line
              ? document.getElementById("L" + link.dataset.goto + "-" + link.dataset.line)
              : row;
            if (!target) target = row;
            target.scrollIntoView({ block: "center" });
            target.classList.add("flash");
            setTimeout(function () { target.classList.remove("flash"); }, 1600);
          });
        })();
      JS

      private_constant :CSS, :JS
    end
  end
end
