# frozen_string_literal: true

require "helper"
require "json"

module Constable
  # Publishing coverage: where the report goes, what it says, and that one broken
  # destination never takes the others down with it. No network: GitHub, SMTP and the
  # webhook are all stood in for by fakes that record what they were asked.
  class CoverageReportTest < TestCase
    # Answers GitHub API calls from a table and records every request.
    class FakeHttp
      attr_reader :requests

      def initialize(&responder)
        @requests = []
        @responder = responder
      end

      def call(method, url, headers: {}, body: nil)
        @requests << { method: method, url: url, headers: headers, body: body && JSON.parse(body) }
        status, payload = @responder.call(method, url, body && JSON.parse(body))
        CoverageReport::Http::Response.new(status: status, body: payload.nil? ? "" : JSON.generate(payload))
      end
    end

    # Net::SMTP's shape, recording what would have been sent.
    class FakeSmtp
      attr_reader :sent, :password

      def initialize
        @sent = []
      end

      def call(_settings, password)
        @password = password
        yield self
      end

      def send_message(message, from, to)
        @sent << { message: message, from: from, to: to }
      end
    end

    def setup
      super
      @model = write_file("app/models/user.rb", "class User\n  def a = 1\n  def b = 2\n  def c = 3\n  def d = 4\nend\n")
      @idle  = write_file("app/models/idle.rb", "class Idle\n  def x = 1\nend\n")
    end

    # user.rb: lines 2-5 executable, 4 and 5 never ran. idle.rb: nothing ran at all.
    def report(changed: { "app/models/user.rb" => [2, 4, 5] })
      raw = {
        File.realpath(@model) => [1, 1, 1, 0, 0, nil],
        File.realpath(@idle) => [0, 0, nil]
      }
      Coverage.build_report(raw, config: Constable.config, root: tmp_root, changed_lines: changed)
    end

    def context(**overrides)
      CoverageReport::Context.new(repository: "acme/app", pr_number: 7, sha: "abc1234def", base_ref: "staging",
                                  api_url: "https://ghe.example.com/api/v3", server_url: "https://ghe.example.com",
                                  run_url: "https://ghe.example.com/acme/app/actions/runs/9", **overrides)
    end

    def settings(raw)
      CoverageReport::Settings.new(raw)
    end

    # --- settings ------------------------------------------------------------------

    def test_nothing_is_delivered_until_deliver_names_something
      refute_predicate settings({}), :enabled?
      assert_predicate settings("deliver" => ["pr_comment"]), :enabled?
    end

    def test_every_problem_is_named_at_once
      problems = settings("deliver" => %w[pr_comment slack email], "host" => "gitlab", "email" => {}).problems

      assert(problems.any? { |p| p.include?("slack is not a delivery") })
      assert(problems.any? { |p| p.include?("host: gitlab is not supported") })
      assert(problems.any? { |p| p.include?("email.to") })
      assert(problems.any? { |p| p.include?("email.smtp_host") })
    end

    def test_publishing_with_a_bad_setting_raises_rather_than_quietly_skipping
      assert_raises(ConfigurationError) do
        CoverageReport.publish(report, settings: settings("deliver" => ["slack"]), context: context)
      end
    end

    def test_config_defaults_publish_nothing
      refute_predicate CoverageReport::Settings.from(Constable.config), :enabled?
    end

    # --- context -------------------------------------------------------------------

    def test_context_reads_a_pull_request_run_on_github_enterprise
      event = write_file("event.json", JSON.generate(pull_request: { number: 42, head: { sha: "feedbeef" } }))
      env = {
        "GITHUB_ACTIONS" => "true", "GITHUB_REPOSITORY" => "software/caseflow",
        "GITHUB_EVENT_PATH" => event, "GITHUB_SHA" => "mergecommit",
        "GITHUB_BASE_REF" => "staging", "GITHUB_HEAD_REF" => "feature",
        "GITHUB_API_URL" => "https://va.ghe.com/api/v3", "GITHUB_SERVER_URL" => "https://va.ghe.com",
        "GITHUB_RUN_ID" => "55"
      }

      found = CoverageReport::Context.detect(env: env)

      assert_equal 42, found.pr_number
      assert_equal "feedbeef", found.sha, "links point at the branch head, not the merge commit"
      assert_equal "staging", found.base_ref
      assert_equal "https://va.ghe.com/api/v3", found.api_url
      assert_equal "https://va.ghe.com/software/caseflow/actions/runs/55", found.run_url
    end

    def test_no_context_outside_github_actions
      assert_nil CoverageReport::Context.detect(env: {})
    end

    def test_a_pr_number_can_be_handed_to_a_run_that_is_not_a_pull_request_event
      found = CoverageReport::Context.detect(env: { "GITHUB_ACTIONS" => "true", "GITHUB_REPOSITORY" => "a/b",
                                                    "CONSTABLE_PR_NUMBER" => "12" })

      assert_equal 12, found.pr_number
    end

    # --- markdown ------------------------------------------------------------------

    def test_the_summary_table_reads_like_a_coverage_comment
      body = CoverageReport::Markdown.new(report, context: context, now: Time.utc(2026, 9, 19, 7, 38, 53)).render

      assert body.start_with?(CoverageReport::Markdown::MARKER)
      assert_includes body, "# 📊 Code Coverage Report"
      assert_includes body, "Run completed on Sat Sep 19 07:38:53 UTC 2026 · commit `abc1234` · " \
                            "[workflow run](https://ghe.example.com/acme/app/actions/runs/9)"
      assert_includes body, "| Metric | Value |"
      assert_includes body, "| **Total Coverage** | 42.9% (3 of 7 lines) |"
      assert_includes body, "| **Changed Lines** | ⚠️ 33.3% (1 of 3) · below the 90% threshold |"
      assert_includes body, "| **Files Measured** | 2 |"
      assert_includes body, "| **Files With No Line Run** | 1 |"
    end

    def test_changed_files_get_a_row_each_with_the_low_coverage_warning
      body = CoverageReport::Markdown.new(report, context: context).render

      assert_includes body, "| File | File Coverage | Changed Lines Covered | Warning (<50%) |"
      link = "[`app/models/user.rb`](https://ghe.example.com/acme/app/blob/abc1234def/app/models/user.rb)"
      assert_includes body, "| #{link} | 60.0% | 1 of 3 | No |"

      sparse = Coverage.build_report({ File.realpath(@model) => [1, 1, 0, 0, 0, nil] },
                                     config: Constable.config, root: tmp_root,
                                     changed_lines: { "app/models/user.rb" => [2] })
      assert_includes CoverageReport::Markdown.new(sparse).render, "| 40.0% | 1 of 1 | ⚠️ Yes |"
    end

    def test_the_changed_lines_that_never_ran_are_linked_to_the_code
      body = CoverageReport::Markdown.new(report, context: context).render

      assert_includes body, "## Changed Lines Not Run"
      assert_includes body, "2 changed lines never ran in any test:"
      assert_includes body, "[4–5](https://ghe.example.com/acme/app/blob/abc1234def/app/models/user.rb#L4-L5)"
    end

    def test_a_file_with_no_line_run_is_listed_but_folded_away
      body = CoverageReport::Markdown.new(report, context: context).render

      assert_includes body, "<details><summary>1 file with no line run</summary>"
      assert_includes body, "`app/models/idle.rb`"
    end

    def test_title_note_and_report_link_come_from_settings_and_the_publish_step
      configured = settings("title" => "📊 Backend Coverage Report", "note" => "Frontend is in its own comment.")
      body = CoverageReport.markdown_for(report, settings: configured, context: context,
                                                 report_url: "https://ghe.example.com/art/1").render

      assert_includes body, "# 📊 Backend Coverage Report"
      assert_includes body, "## Coverage Report"
      assert_includes body, "📥 [Download Full HTML Report](https://ghe.example.com/art/1)"
      assert_includes body, "> Frontend is in its own comment."
    end

    def test_a_threshold_of_zero_reports_without_a_verdict
      write_config("coverage_threshold: 0\n")
      zero = Coverage.build_report({ File.realpath(@model) => [1, 1, 1, 0, 0, nil] },
                                   config: Constable.config, root: tmp_root,
                                   changed_lines: { "app/models/user.rb" => [2, 4, 5] })

      assert_includes CoverageReport::Markdown.new(zero).render,
                      "| **Changed Lines** | 33.3% (1 of 3) · report only |"
    end

    def test_no_diff_says_so_instead_of_a_changed_lines_section
      body = CoverageReport::Markdown.new(report(changed: nil), context: nil).render

      assert_includes body, "| **Changed Lines** | n/a (the base branch is not in this clone) |"
      assert_includes body, "No changed application files in this diff."
      refute_includes body, "## Changed Lines Not Run"
    end

    def test_every_changed_line_covered_says_so
      body = CoverageReport::Markdown.new(report(changed: { "app/models/user.rb" => [2, 3] })).render

      assert_includes body, "✅ Every changed line ran."
    end

    # --- GitHub --------------------------------------------------------------------

    def test_a_first_run_posts_a_comment
      http = FakeHttp.new do |method, url, _body|
        next [200, []] if method == :get

        created = { "html_url" => "https://ghe.example.com/c/1" }
        next [201, created] if method == :post && url.end_with?("/issues/7/comments")

        [500, nil]
      end

      deliveries = CoverageReport.publish(report, settings: settings("deliver" => ["pr_comment"]), context: context,
                                                  env: { "GITHUB_TOKEN" => "t" }, http: http)

      assert_equal [:sent], deliveries.map(&:status)
      post = http.requests.find { |r| r[:method] == :post }
      assert post[:body]["body"].start_with?(CoverageReport::Markdown::MARKER)
      assert_equal "Bearer t", post[:headers]["Authorization"]
      assert post[:url].start_with?("https://ghe.example.com/api/v3/repos/acme/app/")
    end

    # Found on the second page, because a long review thread pushes it there.
    def test_a_later_run_edits_its_own_comment_instead_of_adding_another
      first_page = Array.new(100) { |i| { "id" => i, "body" => "a human comment" } }
      http = FakeHttp.new do |method, url, _body|
        if method == :get
          next [200, first_page] if url.match?(/[?&]page=1\z/)

          next [200, [{ "id" => 555, "body" => "#{CoverageReport::Markdown::MARKER}\nold" }]]
        end
        next [200, { "html_url" => "https://ghe.example.com/c/555" }] if method == :patch

        [500, nil]
      end

      CoverageReport.publish(report, settings: settings("deliver" => ["pr_comment"]), context: context,
                                     env: { "GITHUB_TOKEN" => "t" }, http: http)

      refute(http.requests.any? { |r| r[:method] == :post }, "a second comment was posted")
      assert(http.requests.any? { |r| r[:method] == :patch && r[:url].end_with?("/issues/comments/555") })
    end

    def test_the_comment_search_gives_up_rather_than_paging_forever
      full_page = Array.new(100) { |i| { "id" => i, "body" => "a human comment" } }
      http = FakeHttp.new { |method, _url, _body| method == :get ? [200, full_page] : [201, { "html_url" => "u" }] }

      CoverageReport.publish(report, settings: settings("deliver" => ["pr_comment"]), context: context,
                                     env: { "GITHUB_TOKEN" => "t" }, http: http)

      assert_equal(CoverageReport::GitHub::MAX_COMMENT_PAGES, http.requests.count { |r| r[:method] == :get })
      assert(http.requests.any? { |r| r[:method] == :post })
    end

    def test_the_description_keeps_the_authors_text_and_replaces_only_its_own_section
      old = "Author's summary.\n\n#{CoverageReport::GitHub::SECTION_START}\nstale\n" \
            "#{CoverageReport::GitHub::SECTION_END}\n\nMore from the author."

      updated = CoverageReport::GitHub.with_section(old, "fresh")

      assert_includes updated, "Author's summary."
      assert_includes updated, "More from the author."
      assert_includes updated, "fresh"
      refute_includes updated, "stale"
    end

    def test_the_description_gains_a_section_when_it_has_none
      assert_equal "Summary.\n\n#{CoverageReport::GitHub::SECTION_START}\nnew\n#{CoverageReport::GitHub::SECTION_END}",
                   CoverageReport::GitHub.with_section("Summary.\n", "new")
    end

    def test_pr_description_delivery_patches_the_pull_request
      http = FakeHttp.new do |method, _url, _body|
        next [200, { "body" => "Summary.", "html_url" => "https://ghe.example.com/pull/7" }] if method == :get

        [200, { "html_url" => "https://ghe.example.com/pull/7" }]
      end

      deliveries = CoverageReport.publish(report, settings: settings("deliver" => ["pr_description"]),
                                                  context: context, env: { "GITHUB_TOKEN" => "t" }, http: http)

      assert_equal [:sent], deliveries.map(&:status)
      patch = http.requests.find { |r| r[:method] == :patch }
      assert patch[:body]["body"].start_with?("Summary.")
      assert_includes patch[:body]["body"], CoverageReport::GitHub::SECTION_START
    end

    def test_a_refused_token_says_what_permission_is_missing
      http = FakeHttp.new { [403, { "message" => "Resource not accessible by integration" }] }

      delivery = CoverageReport.publish(report, settings: settings("deliver" => ["pr_comment"]), context: context,
                                                env: { "GITHUB_TOKEN" => "t" }, http: http).first

      assert_predicate delivery, :failed?
      assert_includes delivery.detail, "Resource not accessible"
      assert_includes delivery.detail, "pull-requests: write"
    end

    def test_pr_deliveries_are_skipped_out_loud_without_a_pull_request_or_token
      publish = lambda do |ctx, env|
        CoverageReport.publish(report, settings: settings("deliver" => %w[pr_comment pr_description]),
                                       context: ctx, env: env, http: FakeHttp.new { [500, nil] })
      end

      assert_equal ["not running in GitHub Actions"] * 2, publish.call(nil, {}).map(&:detail)
      assert_equal ["this run is not for a pull request"] * 2,
                   publish.call(context(pr_number: nil), { "GITHUB_TOKEN" => "t" }).map(&:detail)
      assert_equal ["GITHUB_TOKEN is not set"] * 2, publish.call(context, {}).map(&:detail)
    end

    # --- email ---------------------------------------------------------------------

    EMAIL = { "to" => ["lead@example.com"], "from" => "constable@example.com", "smtp_host" => "smtp.example.com",
              "smtp_password_env" => "SMTP_PW" }.freeze

    def test_email_sends_the_report_with_the_password_from_the_environment
      smtp = FakeSmtp.new

      delivery = CoverageReport.publish(report, settings: settings("deliver" => ["email"], "email" => EMAIL),
                                                context: context, env: { "SMTP_PW" => "s3cret" }, smtp: smtp).first

      assert_predicate delivery, :sent?
      assert_equal "s3cret", smtp.password
      sent = smtp.sent.first
      assert_equal ["lead@example.com"], sent[:to]
      assert_includes sent[:message], "Subject: Coverage "
      assert_includes sent[:message], "acme/app #7"
      assert_includes sent[:message], "changed lines never ran"
      assert(sent[:message].lines.all? { |line| line.end_with?("\r\n") }, "SMTP needs CRLF line endings")
    end

    # One broken destination must not cost the others.
    def test_a_failing_delivery_does_not_stop_the_rest
      broken_smtp = ->(*) { raise Errno::ECONNREFUSED, "smtp.example.com" }
      http = FakeHttp.new do |method, _url, _body|
        method == :get ? [200, []] : [201, { "html_url" => "u" }]
      end

      both = settings("deliver" => %w[email pr_comment], "email" => EMAIL)
      deliveries = CoverageReport.publish(report, settings: both, context: context, env: { "GITHUB_TOKEN" => "t" },
                                                  http: http, smtp: broken_smtp)

      assert_equal %i[failed sent], deliveries.map(&:status)
      assert_includes deliveries.first.detail, "Connection refused"
    end

    # --- custom (webhook) ------------------------------------------------------------

    def test_the_webhook_gets_the_summary_signed_with_the_secret
      http = FakeHttp.new { [204, nil] }
      env = { "HOOK" => "https://hooks.example.com/coverage", "HOOK_SECRET" => "shh" }

      delivery = CoverageReport.publish(report, settings: settings("deliver" => ["custom"],
                                                                   "custom" => { "webhook_url_env" => "HOOK",
                                                                                 "secret_env" => "HOOK_SECRET" }),
                                                context: context, env: env, http: http).first

      assert_predicate delivery, :sent?
      request = http.requests.first
      assert_equal "https://hooks.example.com/coverage", request[:url]
      assert_equal 7, request[:body]["pull_request"]
      assert_equal({ "app/models/user.rb" => [4, 5] }, request[:body]["coverage"]["uncovered_diff_lines"])
      refute request[:body]["coverage"].key?("files"), "per-file line arrays stay out of the payload"
      expected = OpenSSL::HMAC.hexdigest("SHA256", "shh", JSON.generate(request[:body]))
      assert_equal "sha256=#{expected}", request[:headers]["X-Constable-Signature"]
    end

    def test_the_webhook_without_a_url_fails_and_names_the_variable
      delivery = CoverageReport.publish(report, settings: settings("deliver" => ["custom"]), context: context,
                                                env: {}, http: FakeHttp.new { [204, nil] }).first

      assert_predicate delivery, :failed?
      assert_includes delivery.detail, "CONSTABLE_COVERAGE_WEBHOOK_URL"
    end

    def test_custom_delivery_asks_the_tier_first
      assert Tier.paid?(:custom_delivery)
      Tier.stub(:allows?, false) do
        delivery = CoverageReport.publish(report, settings: settings("deliver" => ["custom"]), context: context,
                                                  env: { "CONSTABLE_COVERAGE_WEBHOOK_URL" => "https://x" },
                                                  http: FakeHttp.new { [204, nil] }).first

        assert_predicate delivery, :failed?
        assert_includes delivery.detail, "paid tier"
      end
    end

    # --- shards --------------------------------------------------------------------

    def test_shards_merge_back_into_one_measurement
      model = File.realpath(@model)
      first  = CoverageReport.save_shard({ model => [1, 0, 0, nil] }, shard: Shard.new(index: 1, total: 2),
                                                                      gate: false, root: File.realpath(tmp_root))
      second = CoverageReport.save_shard({ model => [0, 2, 0, nil], "/elsewhere/gem.rb" => [1] },
                                         shard: Shard.new(index: 2, total: 2), gate: true,
                                         root: File.realpath(tmp_root))

      saved = JSON.parse(File.read(first))
      assert_equal ["app/models/user.rb"], saved["files"].keys, "paths are stored relative to the root"

      raw, gate = CoverageReport.load_shards([first, second], root: File.realpath(tmp_root))

      assert_equal [1, 2, 0, nil], raw[model]
      assert_equal 1, raw.size, "a file outside the root is not the app's"
      assert gate
    end

    def test_no_shard_files_is_an_error_not_an_empty_report
      error = assert_raises(Constable::Error) { CoverageReport.load_shards([]) }

      assert_includes error.message, "shard-*.json"
    end

    # A shard has a fraction of the picture, so it saves rather than publishes -- even with
    # every delivery configured.
    def test_a_sharded_run_saves_its_coverage_instead_of_publishing
      write_config("coverage_report:\n  deliver: [pr_comment]\n")
      runner = Struct.new(:coverage_report, :coverage_raw, :coverage_gate, :shard, keyword_init: true)
                     .new(coverage_report: report, coverage_raw: { File.realpath(@model) => [1, 0, nil] },
                          coverage_gate: true, shard: Shard.new(index: 2, total: 3))

      Constable.stub(:root, File.realpath(tmp_root)) do
        capture_stdout { CLI.new.publish_coverage(runner, Constable.config) }
      end

      saved = File.join(tmp_root, ".constable/coverage/shard-2-of-3.json")
      assert_path_exists saved
      assert_equal({ "app/models/user.rb" => [1, 0, nil] }, JSON.parse(File.read(saved))["files"])
    end

    def test_publish_dry_run_prints_the_merged_report
      CoverageReport.save_shard({ File.realpath(@model) => [1, 1, 1, 0, 0, nil] },
                                shard: Shard.new(index: 1, total: 1), gate: true, root: File.realpath(tmp_root))

      output = capture_stdout do
        Dir.chdir(tmp_root) { CLI::CoverageCommand.new([], { "dry-run" => true }).publish }
      end

      assert_includes output, CoverageReport::Markdown::MARKER
      assert_includes output, "# 📊 Code Coverage Report"
    end

    # The CI publish job writes the full report first, uploads it, then links to it.
    def test_publish_writes_the_html_report_and_links_to_it
      CoverageReport.save_shard({ File.realpath(@model) => [1, 1, 1, 0, 0, nil] },
                                shard: Shard.new(index: 1, total: 1), gate: true, root: File.realpath(tmp_root))
      html = File.join(tmp_root, "coverage-html/index.html")
      options = { "dry-run" => true, "html" => html, "report-url" => "https://x/art/5" }

      output = capture_stdout { Dir.chdir(tmp_root) { CLI::CoverageCommand.new([], options).publish } }

      assert_path_exists html
      assert_includes File.read(html), "<!doctype html>"
      assert_includes output, "📥 [Download Full HTML Report](https://x/art/5)"
    end
  end
end
