# frozen_string_literal: true

module Constable
  module CoverageReport
    # The report as a pull request reads it. One renderer for every delivery -- a comment,
    # the description, an email, a webhook payload -- so the numbers can never disagree
    # between two places the same team is looking.
    #
    # Laid out the way teams already read coverage comments (a summary table, then the
    # changed files), with what Constable knows beyond that: coverage of the changed lines
    # themselves, and every changed line that never ran, linked to the code.
    class Markdown
      # Opens every body Constable writes, so the next run can find and replace its own.
      MARKER = "<!-- constable:coverage -->"

      DEFAULT_TITLE = "📊 Code Coverage Report"
      FILE_LIMIT = 25
      # The line the changed-files table warns below, as the SimpleCov comments did.
      WARN_BELOW = 50

      # title/note/report_url come from `coverage_report` settings and the publish command;
      # `now` is injectable so a rendered report can be compared in a test.
      def initialize(report, context: nil, title: nil, note: nil, report_url: nil, now: Time.now)
        @report     = report
        @context    = context
        @title      = title.to_s.strip.empty? ? DEFAULT_TITLE : title.to_s.strip
        @note       = note.to_s.strip
        @report_url = report_url.to_s.strip
        @now        = now
      end

      def render
        out = [MARKER, "# #{@title}", "", run_line, ""]
        out.concat(summary_section)
        out.concat(changed_files_section)
        out.concat(uncovered_section)
        out.concat(unpatrolled_section)
        out.concat(report_section)
        out << footer
        out.join("\n")
      end

      # One line, for places that have room for no more -- a log, a Slack preview.
      def headline
        diff = @report.diff_percent
        return "Coverage: #{pct(@report.percent)}" if diff.nil?

        "Coverage: #{pct(@report.percent)} · changed lines #{pct(diff)} (#{verdict_word} #{@report.threshold}%)"
      end

      # Plain words for an email subject line, which cannot carry markdown.
      def subject
        where = @context&.label
        ["Coverage #{pct(@report.percent)}", where].compact.join(" — ")
      end

      private

      def run_line
        bits = ["Run completed on #{@now.utc.strftime("%a %b %-d %H:%M:%S UTC %Y")}"]
        bits << "commit `#{@context.sha[0, 7]}`" if @context&.sha
        bits << "[workflow run](#{@context.run_url})" if @context&.run_url
        bits.join(" · ")
      end

      def summary_section
        rows = [
          ["**Total Coverage**", "#{pct(@report.percent)} (#{of(@report.covered, @report.relevant)} lines)"],
          ["**Changed Lines**", changed_lines_value],
          ["**Files Measured**", number(@report.files.size)],
          ["**Files With No Line Run**", number(@report.unpatrolled.size)]
        ]
        ["## Coverage Summary", "", "| Metric | Value |", "|:--|:--|",
         *rows.map { |label, value| "| #{label} | #{value} |" }, ""]
      end

      def changed_lines_value
        return "n/a (the base branch is not in this clone)" unless @report.diff_available?
        return "No executable lines changed" if @report.diff_relevant.zero?

        value = "#{pct(@report.diff_percent)} (#{of(@report.diff_covered, @report.diff_relevant)})"
        return "#{value} · report only" if @report.threshold.zero?

        "#{@report.meets_threshold? ? "✅" : "⚠️"} #{value} · #{verdict_word} the #{@report.threshold}% threshold"
      end

      def verdict_word = @report.meets_threshold? ? "meets" : "below"

      def changed_files_section
        out = ["## Changed Files Coverage", ""]
        files = @report.gated_files
        return out.push("No changed application files in this diff.", "") if files.empty?

        out.push("| File | File Coverage | Changed Lines Covered | Warning (<#{WARN_BELOW}%) |",
                 "|:--|--:|--:|:--:|")
        files.first(FILE_LIMIT).each { |file| out << changed_file_row(file) }
        out << "| …and #{files.size - FILE_LIMIT} more | | | |" if files.size > FILE_LIMIT
        out << ""
      end

      def changed_file_row(file)
        executable = @report.changed_numbers(file).select { |n| file.executable?(n) }
        covered = executable.count { |n| file.covered?(n) }
        changed = executable.empty? ? "none executable" : of(covered, executable.size)
        warn = file.percent < WARN_BELOW ? "⚠️ Yes" : "No"
        "| #{file_link(file.relative_path)} | #{pct(file.percent)} | #{changed} | #{warn} |"
      end

      def uncovered_section
        return [] unless @report.diff_available?

        uncovered = @report.uncovered_diff_lines
        return ["✅ Every changed line ran.", ""] if uncovered.empty?

        count = uncovered.values.sum(&:size)
        out = ["## Changed Lines Not Run", "", "#{number(count)} changed #{count == 1 ? "line" : "lines"} " \
                                               "never ran in any test:", ""]
        uncovered.first(FILE_LIMIT).each do |path, numbers|
          out << "- `#{path}`: #{ranges(numbers).map { |a, b| range_link(path, a, b) }.join(", ")}"
        end
        extra = uncovered.size - FILE_LIMIT
        out << "- …and #{extra} more #{extra == 1 ? "file" : "files"}" if extra.positive?
        out << ""
      end

      def unpatrolled_section
        files = @report.unpatrolled.map(&:relative_path)
        return [] if files.empty?

        listed = files.first(FILE_LIMIT).map { |f| "- `#{f}`" }
        listed << "- …and #{files.size - FILE_LIMIT} more" if files.size > FILE_LIMIT
        ["<details><summary>#{files.size} #{files.size == 1 ? "file" : "files"} with no line run</summary>",
         "", *listed, "", "</details>", ""]
      end

      def report_section
        return [] if @report_url.empty? && @note.empty?

        out = ["## Coverage Report", ""]
        out.push("📥 [Download Full HTML Report](#{@report_url})", "") unless @report_url.empty?
        out.push(*@note.lines.map { |line| "> #{line.chomp}" }, "") unless @note.empty?
        out
      end

      def footer = "<sub>Constable #{Constable::VERSION}</sub>"

      # [12, 13, 14, 20] -> [[12, 14], [20, 20]]
      def ranges(numbers)
        numbers.sort.slice_when { |a, b| b != a + 1 }.map { |run| [run.first, run.last] }
      end

      def range_link(path, first, last)
        text = first == last ? first.to_s : "#{first}–#{last}"
        url = @context&.blob_url(path, first, last)
        url ? "[#{text}](#{url})" : text
      end

      def file_link(path)
        url = @context&.blob_url(path, 1)&.sub(/#L1\z/, "")
        url ? "[`#{path}`](#{url})" : "`#{path}`"
      end

      def of(part, whole) = "#{number(part)} of #{number(whole)}"
      def pct(value) = value.nil? ? "n/a" : "#{format("%.1f", value)}%"
      def number(value) = value.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end
  end
end
