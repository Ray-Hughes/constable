# frozen_string_literal: true

require_relative "../helper"
require "constable/coverage"
require "open3"

module Constable
  # Most of these drive Coverage from a synthetic `::Coverage` result hash rather than a
  # real measurement run: the arithmetic, the gate and the rendering are the interesting
  # parts, and a hash of hit counts is exactly what the stdlib hands us anyway. The
  # lifecycle tests at the bottom do exercise the real `::Coverage` module.
  #
  # Note the spelling throughout: `Coverage` here is Constable's, `::Coverage` is Ruby's.
  class CoverageTest < TestCase
    def teardown
      Coverage.abort!
      ::Coverage.result(stop: true, clear: true) if ::Coverage.running?
      super
    end

    # --- report arithmetic -------------------------------------------------------

    def test_percent_counts_only_executable_lines
      report = build("app/models/user.rb" => [1, 0, nil, 3, nil])

      assert_in_delta 66.67, report.percent
      assert_equal 2, report.covered
      assert_equal 3, report.relevant
      assert_equal 1, report.missed
    end

    def test_percent_across_several_files
      report = build(
        "app/models/user.rb" => [1, 1, 1, 1],
        "app/models/order.rb" => [0, 0, 0, 0]
      )

      assert_in_delta 50.0, report.percent
      assert_equal 2, report.files.size
    end

    def test_a_file_with_no_executable_lines_is_vacuously_complete
      report = build("app/models/blank.rb" => [nil, nil])

      assert_in_delta 100.0, report.percent
      assert_in_delta 100.0, report.file("app/models/blank.rb").percent
      assert_empty report.unpatrolled, "a file of comments is not a missed file"
    end

    def test_an_entirely_empty_report_is_one_hundred_percent
      report = build({})

      assert_predicate report, :empty?
      assert_in_delta 100.0, report.percent
      assert_equal "◐ 100% covered", report.summary_line
    end

    def test_per_file_breakdown
      report = build("app/models/user.rb" => [1, 0, nil, 0, 5])
      file = report.file("app/models/user.rb")

      assert_equal "app/models/user.rb", file.relative_path
      assert_equal 4, file.relevant
      assert_equal 2, file.covered
      assert_equal 2, file.missed
      assert_equal [2, 4], file.missed_lines
      assert_equal [1, 5], file.covered_lines
      assert_in_delta 50.0, file.percent
      assert file.executable?(1)
      refute file.executable?(3)
      assert file.covered?(5)
      refute file.covered?(2)
      assert_equal 5, file.hits_for(5)
    end

    def test_files_are_sorted_by_path
      report = build(
        "app/models/user.rb" => [1],
        "app/jobs/purge_job.rb" => [1],
        "lib/thing.rb" => [1]
      )

      assert_equal %w[app/jobs/purge_job.rb app/models/user.rb lib/thing.rb],
                   report.files.map(&:relative_path)
    end

    def test_the_hash_shaped_coverage_result_is_accepted_too
      # `::Coverage.start(lines: true)` returns { path => { lines: [...] } }; a bare
      # `::Coverage.start` returns { path => [...] }. Somebody else may have started it.
      report = build("app/models/user.rb" => { lines: [1, 0] })

      assert_in_delta 50.0, report.percent
    end

    # --- unpatrolled -------------------------------------------------------------

    def test_unpatrolled_files_are_those_with_zero_executed_lines
      report = build(
        "app/models/user.rb" => [1, 1],
        "app/jobs/purge_job.rb" => [0, 0, nil],
        "app/models/order.rb" => [0, 1]
      )

      assert_equal ["app/jobs/purge_job.rb"], report.unpatrolled.map(&:relative_path)
      assert_predicate report.file("app/jobs/purge_job.rb"), :unpatrolled?
      refute_predicate report.file("app/models/order.rb"), :unpatrolled?
    end

    def test_the_summary_line_names_the_unpatrolled_count
      report = build(
        "app/a.rb" => [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
        "app/b.rb" => [0],
        "app/c.rb" => [0]
      )

      assert_equal "◐ 86% covered (2 files unpatrolled)", report.summary_line
    end

    def test_the_summary_line_says_file_singular_for_one
      report = build("app/a.rb" => [1], "app/b.rb" => [0])

      assert_equal "◐ 50% covered (1 file unpatrolled)", report.summary_line
    end

    # --- what counts as application code -----------------------------------------

    def test_the_gem_its_dependencies_and_the_stdlib_are_filtered_out
      report = build(
        "app/models/user.rb" => [1],
        "#{Coverage::GEM_LIB}/constable/runner.rb" => [1],
        "/usr/local/lib/ruby/gems/3.2.0/gems/rack/lib/rack.rb" => [1],
        RbConfig::CONFIG["rubylibdir"] ? File.join(RbConfig::CONFIG["rubylibdir"], "set.rb") : "/x/set.rb" => [1]
      )

      assert_equal ["app/models/user.rb"], report.files.map(&:relative_path)
    end

    def test_the_suites_own_files_are_filtered_out
      report = build(
        "app/models/user.rb" => [1],
        "test/cases/models/user_case.rb" => [1],
        "spec/models/user_spec.rb" => [1],
        "test/case_helper.rb" => [1],
        "lib/tasks/user_test.rb" => [1],
        "vendor/bundle/thing.rb" => [1]
      )

      assert_equal ["app/models/user.rb"], report.files.map(&:relative_path)
    end

    def test_files_outside_the_root_and_non_ruby_files_are_filtered_out
      report = build(
        "app/models/user.rb" => [1],
        "/somewhere/else/thing.rb" => [1],
        "app/views/users/index.html.erb" => [1]
      )

      assert_equal ["app/models/user.rb"], report.files.map(&:relative_path)
    end

    def test_coverage_exclude_globs_from_config_are_honoured
      config = config_with("coverage_exclude" => ["app/generated/**/*.rb"])
      report = build({ "app/models/user.rb" => [1], "app/generated/schema.rb" => [0] }, config: config)

      assert_equal ["app/models/user.rb"], report.files.map(&:relative_path)
    end

    # --- the diff gate -----------------------------------------------------------

    def test_the_gate_passes_when_changed_lines_are_covered
      report = build(
        { "app/models/user.rb" => [1, 1, 0, 0] },
        changed_lines: { "app/models/user.rb" => [1, 2] }
      )

      assert_equal 2, report.diff_relevant
      assert_equal 2, report.diff_covered
      assert_in_delta 100.0, report.diff_percent
      assert report.meets_threshold?
      assert_nil report.threshold_message
      assert_empty report.uncovered_diff_lines
    end

    def test_the_gate_fails_when_changed_lines_are_not_covered
      report = build(
        { "app/models/user.rb" => [1, 0, 0, 1] },
        changed_lines: { "app/models/user.rb" => [1, 2, 3, 4] }
      )

      assert_in_delta 50.0, report.diff_percent
      refute report.meets_threshold?
      assert_equal({ "app/models/user.rb" => [2, 3] }, report.uncovered_diff_lines)
      assert_match(/below the 90% threshold/, report.threshold_message)
    end

    def test_the_gate_ignores_legacy_gaps_outside_the_diff
      # 25% overall, but every line the diff touched is covered. Legacy gaps stay visible
      # in the report; they do not block the build.
      report = build(
        { "app/models/user.rb" => [1, 0, 0, 0] },
        changed_lines: { "app/models/user.rb" => [1] }
      )

      assert_in_delta 25.0, report.percent
      assert_in_delta 100.0, report.diff_percent
      assert report.meets_threshold?
    end

    def test_changed_lines_that_are_not_executable_do_not_count
      report = build(
        { "app/models/user.rb" => [1, nil, nil] },
        changed_lines: { "app/models/user.rb" => [2, 3] }
      )

      assert_equal 0, report.diff_relevant
      assert_in_delta 100.0, report.diff_percent
      assert report.meets_threshold?, "a comment-only diff cannot fail a coverage gate"
    end

    def test_the_threshold_comes_from_config
      report = build(
        { "app/models/user.rb" => [1, 1, 1, 0] },
        changed_lines: { "app/models/user.rb" => [1, 2, 3, 4] },
        config: config_with("coverage_threshold" => 70)
      )

      assert_in_delta 75.0, report.diff_percent
      assert report.meets_threshold?
      refute report.meets_threshold?(config_with("coverage_threshold" => 80))
    end

    def test_without_diff_information_the_gate_cannot_be_enforced
      report = build({ "app/models/user.rb" => [0, 0] }, changed_lines: nil)

      refute_predicate report, :diff_available?
      assert_nil report.diff_percent
      assert report.meets_threshold?, "no git means no gate -- never fail a build on a tarball checkout"
      assert_match(/no diff information/, report.beat_report)
    end

    def test_a_changed_file_that_was_never_loaded_is_held_to_the_gate_anyway
      # The blind spot worth caring about: `::Coverage` never mentions a file nothing
      # required, so a brand-new untested class would otherwise sail through the gate.
      write_file("app/models/order.rb", <<~RUBY)
        # frozen_string_literal: true
        class Order
          def total
            1
          end
        end
      RUBY

      report = build(
        { "app/models/user.rb" => [1, 1] },
        changed_lines: { "app/models/user.rb" => [1], "app/models/order.rb" => [1, 2, 3, 4, 5, 6] }
      )

      order = report.file("app/models/order.rb")

      assert order, "the never-loaded file must still appear in the report"
      assert_predicate order, :synthesized?
      assert_predicate order, :unpatrolled?
      refute report.meets_threshold?
      assert_includes report.uncovered_diff_lines.keys, "app/models/order.rb"
    end

    def test_a_changed_file_that_is_not_application_code_is_not_synthesized
      write_file("test/cases/models/order_case.rb", "investigate('x') { }\n")

      report = build({ "app/models/user.rb" => [1] },
                     changed_lines: { "test/cases/models/order_case.rb" => [1] })

      assert_equal ["app/models/user.rb"], report.files.map(&:relative_path)
    end

    # --- cold-case exemption -----------------------------------------------------

    def test_cold_cases_contribute_numbers_but_a_cold_only_run_is_not_gated
      report = build(
        { "app/models/user.rb" => [1, 0, 0, 0] },
        changed_lines: { "app/models/user.rb" => [1, 2, 3, 4] },
        gate: false
      )

      refute_predicate report, :gate?
      assert_in_delta 25.0, report.percent, 0.01
      assert_in_delta 25.0, report.diff_percent, 0.01
      assert report.meets_threshold?, "cold cases contribute coverage but are exempt from the gate"
    end

    def test_files_matched_by_the_cold_cases_config_are_exempt_from_the_gate
      config = config_with("cold_cases" => ["app/legacy/**/*.rb"])
      report = build(
        { "app/legacy/importer.rb" => [0, 0], "app/models/user.rb" => [1, 1] },
        changed_lines: { "app/legacy/importer.rb" => [1, 2], "app/models/user.rb" => [1, 2] },
        config: config
      )

      assert_equal ["app/models/user.rb"], report.gated_files.map(&:relative_path)
      assert_in_delta 100.0, report.diff_percent
      assert report.meets_threshold?
      assert_equal 0.0, report.file("app/legacy/importer.rb").percent,
                   "the numbers are still reported, only the gate is waived"
    end

    def test_explicitly_exempt_paths_are_excluded_from_the_gate
      report = build(
        { "app/legacy/importer.rb" => [0, 0] },
        changed_lines: { "app/legacy/importer.rb" => [1, 2] },
        exempt: ["app/legacy/importer.rb"]
      )

      assert_empty report.gated_files
      assert_equal 0, report.diff_relevant
      assert report.meets_threshold?
    end

    def test_exempt_accepts_globs
      report = build(
        { "app/legacy/importer.rb" => [0, 0] },
        changed_lines: { "app/legacy/importer.rb" => [1, 2] },
        exempt: ["app/legacy/**/*.rb"]
      )

      assert_empty report.gated_files
      assert report.meets_threshold?
    end

    # --- beat report -------------------------------------------------------------

    def test_the_beat_report_covers_overall_per_file_and_unpatrolled
      report = build(
        { "app/models/user.rb" => [1, 1, 0, 1], "app/jobs/purge_job.rb" => [0, 0] },
        changed_lines: { "app/models/user.rb" => [3] }
      )
      text = report.beat_report

      assert_includes text, "THE BEAT"
      assert_includes text, "COVERAGE"
      assert_includes text, "app/models/user.rb"
      assert_includes text, "UNPATROLLED"
      assert_includes text, "app/jobs/purge_job.rb"
      assert_includes text, "DIFF COVERAGE"
      assert_includes text, "app/models/user.rb:3"
    end

    def test_to_h_is_a_flat_serialisable_snapshot
      report = build(
        { "app/models/user.rb" => [1, 0] },
        changed_lines: { "app/models/user.rb" => [2] }
      )
      hash = report.to_h

      assert_in_delta 50.0, hash[:percent]
      assert_equal 1, hash[:covered]
      assert_equal 2, hash[:relevant]
      assert_equal({ "app/models/user.rb" => [2] }, hash[:uncovered_diff_lines])
      refute hash[:meets_threshold]
      assert_equal "app/models/user.rb", hash[:files].first[:path]
    end

    # --- persistence -------------------------------------------------------------

    def test_a_snapshot_is_recorded_through_the_storage_adapter
      storage = RecordingStorage.new
      report = build("app/models/user.rb" => [1, 0])

      Coverage.record!(report, 42, storage: storage)

      snapshot = storage.snapshots.fetch(0)

      assert_equal 42, snapshot[:run_id]
      assert_in_delta 50.0, snapshot[:percent]
      assert_equal "app/models/user.rb", snapshot[:files].first[:path]
      assert_equal 1, snapshot[:files].first[:covered]
    end

    def test_recording_a_nil_report_or_run_is_a_no_op
      storage = RecordingStorage.new

      Coverage.record!(nil, 1, storage: storage)
      Coverage.record!(build("app/a.rb" => [1]), nil, storage: storage)

      assert_empty storage.snapshots
    end

    # --- HTML --------------------------------------------------------------------

    def test_the_html_report_is_a_self_contained_document
      write_file("app/models/user.rb", "class User\n  def name = \"x\"\nend\n")
      report = build("app/models/user.rb" => [1, 0, nil])
      html = report.to_html

      assert_match(/\A<!doctype html>/, html)
      assert_includes html, "<title>Constable — the beat</title>"
      assert_includes html, "</html>"
      assert_includes html, "prefers-color-scheme"
      refute_match(%r{<(?:script|link|img)[^>]+(?:src|href)=["']https?://}, html,
                   "the report must not depend on a CDN")
      refute_includes html, "//cdn"
    end

    def test_the_html_report_carries_the_summary_the_table_and_the_source_view
      write_file("app/models/user.rb", "class User\n  def name = \"x\"\nend\n")
      write_file("app/jobs/purge_job.rb", "class PurgeJob\nend\n")
      report = build(
        { "app/models/user.rb" => [1, 0, nil], "app/jobs/purge_job.rb" => [0, nil] },
        changed_lines: { "app/models/user.rb" => [2] }
      )
      html = report.to_html

      assert_includes html, "50%"
      assert_includes html, "unpatrolled"
      assert_includes html, %(data-file="app/models/user.rb")
      assert_includes html, %(data-sort="num")
      assert_includes html, "Changed lines not covered"
      assert_includes html, %(<span class="ln">2</span>)
      assert_includes html, %(class="line hit")
      assert_includes html, %(class="line miss")
      assert_includes html, %(class="line na")
    end

    def test_the_html_report_escapes_source_text
      write_file("app/models/user.rb", "TAG = \"<script>alert(1)</script>\"\n")
      report = build("app/models/user.rb" => [1])
      html = report.to_html

      refute_includes html, "<script>alert(1)</script>"
      assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    def test_the_html_report_survives_a_source_file_it_cannot_read
      report = build("app/models/ghost.rb" => [1, 0])

      assert_includes report.to_html, "Source unavailable"
    end

    def test_write_html_creates_the_file_and_returns_its_path
      report = build("app/models/user.rb" => [1])

      path = Coverage.write_html(report, root: tmp_root)

      assert_equal Coverage.default_html_path(root: tmp_root), path
      assert_path_exists path
      assert_includes File.read(path), "<!doctype html>"
    end

    def test_write_html_accepts_an_explicit_path
      report = build("app/models/user.rb" => [1])
      target = File.join(tmp_root, "reports", "beat.html")

      assert_equal target, Coverage.write_html(report, path: target)
      assert_path_exists target
    end

    # --- lifecycle over the real ::Coverage module -------------------------------

    def test_start_is_a_no_op_when_coverage_is_switched_off
      refute Coverage.start!(config: config_with("coverage" => false))
      refute_predicate Coverage, :active?
      assert_nil Coverage.stop!(config: config_with("coverage" => false))
    end

    def test_start_and_stop_measure_a_file_that_is_loaded_in_between
      skip("::Coverage is already running in this process") if ::Coverage.running?

      path = write_file("app/models/counter.rb", <<~RUBY)
        module CoverageProbe
          def self.touched
            :yes
          end

          def self.never_called
            :no
          end
        end
      RUBY

      assert Coverage.start!(config: config_with("coverage" => true))
      assert_predicate Coverage, :active?

      load path
      CoverageProbe.touched

      report = Coverage.stop!(config: config_with("coverage" => true), changed_lines: nil)

      refute_predicate Coverage, :active?
      refute ::Coverage.running?, "we started it, so we must stop it"

      file = report.file("app/models/counter.rb")

      assert file, "the loaded application file should be measured"
      assert_includes file.covered_lines, 3
      assert_includes file.missed_lines, 7
    ensure
      Object.send(:remove_const, :CoverageProbe) if defined?(CoverageProbe)
    end

    def test_measurement_started_elsewhere_is_joined_and_never_stopped
      skip("::Coverage is already running in this process") if ::Coverage.running?

      ::Coverage.start(lines: true)

      assert Coverage.start!(config: config_with("coverage" => true))
      assert_predicate Coverage, :external?

      report = Coverage.stop!(config: config_with("coverage" => true), changed_lines: nil)

      assert report, "we still produce our own report"
      assert ::Coverage.running?, "somebody else's measurement must survive our stop"
    ensure
      ::Coverage.result(stop: true, clear: true) if ::Coverage.running?
    end

    # The whole chain at once: a real git working tree, a real ::Coverage measurement, and
    # the gate deciding from what it finds rather than from a hand-fed hash.
    def test_the_gate_detects_the_diff_from_a_real_repository
      skip("git is not available on this machine") unless git_available?
      skip("::Coverage is already running in this process") if ::Coverage.running?

      run_git("init", "--quiet")
      run_git("config", "user.email", "constable@example.test")
      run_git("config", "user.name", "Constable")
      path = write_file("app/models/probe.rb", <<~RUBY)
        module GitProbe
          def self.walked
            :yes
          end
        end
      RUBY
      run_git("add", "-A")
      run_git("commit", "--quiet", "--no-gpg-sign", "-m", "first")

      write_file("app/models/probe.rb", <<~RUBY)
        module GitProbe
          def self.walked
            :yes
          end

          def self.unwalked
            :no
          end
        end
      RUBY

      Coverage.start!(config: config_with("coverage" => true), force: true)
      load path
      GitProbe.walked
      report = Coverage.stop!(config: config_with("coverage" => true), root: tmp_root)

      assert_predicate report, :diff_available?
      assert_equal({ "app/models/probe.rb" => [7] }, report.uncovered_diff_lines,
                   "only the body of the new, never-called method is an uncovered changed line")
      refute report.meets_threshold?
    ensure
      Object.send(:remove_const, :GitProbe) if defined?(GitProbe)
    end

    def test_stop_without_a_start_returns_nothing
      assert_nil Coverage.stop!(config: config_with("coverage" => true))
    end

    def test_abort_leaves_the_module_idle
      skip("::Coverage is already running in this process") if ::Coverage.running?

      Coverage.start!(config: config_with("coverage" => true))
      Coverage.abort!

      refute_predicate Coverage, :active?
      refute ::Coverage.running?
    end

    # --- helpers -----------------------------------------------------------------

    private

    # Storage is a pluggable interface and its implementations are somebody else's file;
    # all Coverage needs from it is record_coverage.
    class RecordingStorage
      attr_reader :snapshots

      def initialize
        @snapshots = []
      end

      def record_coverage(run_id, percent:, files:)
        @snapshots << { run_id: run_id, percent: percent, files: files }
      end
    end

    # The realpath of the throwaway root: on macOS /var/folders/... resolves to
    # /private/var/folders/..., and ::Coverage always reports the resolved spelling.
    def root
      @root ||= File.realpath(tmp_root)
    end

    def git_available?
      _out, _err, status = Open3.capture3("git", "--version")
      status.success?
    rescue StandardError
      false
    end

    def run_git(*args)
      out, err, status = Open3.capture3("git", *args, chdir: tmp_root)
      flunk("git #{args.join(" ")} failed: #{err}") unless status.success?
      out
    end

    def config_with(overrides = {})
      Config.new({ "coverage" => true, "coverage_threshold" => 90 }.merge(overrides), root: root)
    end

    # Turns a hash of repo-relative paths into the absolute-path hash ::Coverage produces,
    # then into a Report.
    # Options travel in a plain positional hash rather than as keywords: `build("a.rb" =>
    # [1])` would otherwise be swallowed as keyword arguments by any method that takes
    # them, which is a genuinely confusing five minutes to debug.
    def build(raw, options = {})
      absolute = raw.each_with_object({}) do |(path, lines), out|
        out[File.absolute_path?(path) ? path : File.join(root, path)] = lines
      end

      Coverage.build_report(absolute,
                            config: options[:config] || config_with,
                            root: root,
                            exempt: options[:exempt] || [],
                            gate: options.fetch(:gate, true),
                            changed_lines: options.fetch(:changed_lines, nil))
    end
  end
end
