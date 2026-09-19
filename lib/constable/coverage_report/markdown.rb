# frozen_string_literal: true

module Constable
  module CoverageReport
    # The report as a pull request reads it. One renderer for every delivery -- a comment,
    # the description, an email, a webhook payload -- so the numbers can never disagree
    # between two places the same team is looking.
    #
    # Leads with what a reviewer can act on: the changed lines that never ran, each a link
    # to the code. The whole-suite percentage is context, not the point.
    class Markdown
      # Opens every body Constable writes, so the next run can find and replace its own.
      MARKER = "<!-- constable:coverage -->"

      FILE_LIMIT = 25

      def initialize(report, context: nil)
        @report  = report
        @context = context
      end

      def render
        out = [MARKER, "### #{headline}", "", table, ""]
        out.concat(uncovered_section)
        out.concat(unpatrolled_section)
        out << footer
        out.join("\n")
      end

      def headline
        diff = @report.diff_percent
        return "Coverage: #{pct(@report.percent)}" if diff.nil?

        verdict = @report.meets_threshold? ? "meets" : "below"
        "Coverage: #{pct(@report.percent)} · changed lines #{pct(diff)} (#{verdict} #{@report.threshold}%)"
      end

      # Plain words for an email subject line, which cannot carry markdown.
      def subject
        where = @context&.label
        ["Coverage #{pct(@report.percent)}", where].compact.join(" — ")
      end

      private

      def table
        rows = ["|  | Covered | Relevant | % |", "|---|---:|---:|---:|",
                row("Whole suite", @report.covered, @report.relevant, @report.percent)]
        if @report.diff_available?
          rows << row("Changed lines", @report.diff_covered, @report.diff_relevant, @report.diff_percent)
        end
        rows.join("\n")
      end

      def row(label, covered, relevant, percent)
        "| #{label} | #{number(covered)} | #{number(relevant)} | #{pct(percent)} |"
      end

      def uncovered_section
        return [] unless @report.diff_available?

        uncovered = @report.uncovered_diff_lines
        return ["Every changed line ran.", ""] if uncovered.empty?

        count = uncovered.values.sum(&:size)
        out = ["**#{number(count)} changed #{count == 1 ? "line" : "lines"} never ran**", ""]
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

      def footer
        bits = ["Constable #{Constable::VERSION}"]
        bits << "commit #{@context.sha[0, 7]}" if @context&.sha
        bits << "[run](#{@context.run_url})" if @context&.run_url
        "<sub>#{bits.join(" · ")}</sub>"
      end

      # [12, 13, 14, 20] -> [[12, 14], [20, 20]]
      def ranges(numbers)
        numbers.sort.slice_when { |a, b| b != a + 1 }.map { |run| [run.first, run.last] }
      end

      def range_link(path, first, last)
        text = first == last ? first.to_s : "#{first}–#{last}"
        url = @context&.blob_url(path, first, last)
        url ? "[#{text}](#{url})" : text
      end

      def pct(value) = value.nil? ? "n/a" : "#{format("%.1f", value)}%"
      def number(value) = value.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end
  end
end
