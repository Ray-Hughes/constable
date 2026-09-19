# frozen_string_literal: true

require "fileutils"
require "json"

module Constable
  # Publishing the coverage report to where the team already looks: the pull request, an
  # inbox, or somewhere of their own. Configured in .constable/config.yml:
  #
  #   coverage: true
  #   coverage_report:
  #     host: github            # github.com and GitHub Enterprise
  #     ci: github_actions
  #     deliver: [pr_comment]   # any of: pr_comment, pr_description, email, custom
  #
  # Measuring is unchanged -- this only decides where the numbers go.
  #
  # A sharded run has a sixth of the picture on each machine, and six partial reports on a
  # pull request are worse than none. So a shard saves its raw measurement instead
  # (.constable/coverage/shard-3-of-6.json), and one job after the matrix merges them and
  # publishes once: `constable coverage publish`.
  module CoverageReport
    autoload :Context,  "constable/coverage_report/context"
    autoload :Email,    "constable/coverage_report/email"
    autoload :GitHub,   "constable/coverage_report/github"
    autoload :Http,     "constable/coverage_report/http"
    autoload :Markdown, "constable/coverage_report/markdown"
    autoload :Settings, "constable/coverage_report/settings"
    autoload :Webhook,  "constable/coverage_report/webhook"

    SHARD_DIR = ".constable/coverage"
    SHARD_FORMAT = 1

    # What happened to one delivery. `skipped` is not a failure -- a PR comment on a push
    # to main has no pull request to go on -- but it is always said, never silent.
    Delivery = Struct.new(:name, :status, :detail, keyword_init: true) do
      def sent?    = status == :sent
      def failed?  = status == :failed
      def skipped? = status == :skipped
      def to_s     = "#{name}: #{status}#{" -- #{detail}" if detail}"
    end

    module_function

    # Sends `report` everywhere the settings say. Never raises for a delivery that fails:
    # each outcome comes back as a Delivery, so one broken SMTP server does not stop the
    # pull request comment.
    def publish(report, settings:, context:, env: ENV, http: Http.new, smtp: nil)
      settings.validate!
      markdown = Markdown.new(report, context: context)
      body = markdown.render

      settings.deliveries.map do |name|
        deliver(name, report: report, markdown: markdown, body: body, settings: settings,
                      context: context, env: env, http: http, smtp: smtp)
      end
    end

    def deliver(name, report:, markdown:, body:, settings:, context:, env:, http:, smtp:)
      if %w[pr_comment pr_description].include?(name) && (reason = pr_unavailable(context, settings, env))
        return Delivery.new(name: name, status: :skipped, detail: reason)
      end

      detail = case name
               when "pr_comment", "pr_description"
                 github = GitHub.new(context: context, token: env[settings.token_env], http: http)
                 name == "pr_comment" ? github.upsert_comment(body) : github.update_description(body)
               when "email"
                 recipients = Email.new(settings.email, env: env, smtp: smtp)
                                   .deliver(subject: markdown.subject, body: body)
                 "sent to #{recipients.join(", ")}"
               when "custom"
                 Webhook.new(settings.custom, env: env, http: http)
                        .deliver(report: report, markdown: body, context: context)
               end
      Delivery.new(name: name, status: :sent, detail: detail)
    rescue Constable::Error, StandardError => e
      Delivery.new(name: name, status: :failed, detail: e.message)
    end

    def pr_unavailable(context, settings, env)
      return "not running in GitHub Actions" unless context
      return "this run is not for a pull request" unless context.pull_request?
      return "#{settings.token_env} is not set" if env[settings.token_env].to_s.empty?

      nil
    end

    # --- shards ------------------------------------------------------------------

    def shard_path(shard, root: Constable.root)
      File.join(root.to_s, SHARD_DIR, "shard-#{shard.index}-of-#{shard.total}.json")
    end

    # Paths are stored relative to the root. Every CI machine checks out to the same
    # directory today, but nothing promises that, and an absolute path from one runner
    # would match no file on another.
    def save_shard(raw, shard:, gate:, root: Constable.root)
      root = root.to_s
      files = (raw || {}).each_with_object({}) do |(path, entry), out|
        absolute = File.expand_path(path.to_s)
        next unless absolute.start_with?("#{root}/")

        lines = entry.is_a?(Hash) ? (entry[:lines] || entry["lines"]) : entry
        out[absolute.delete_prefix("#{root}/")] = lines if lines
      end

      path = shard_path(shard, root: root)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(format: SHARD_FORMAT, shard: shard.to_s, gate: gate, files: files))
      path
    end

    # Merges saved shards back into one raw measurement. Returns [raw, gate].
    def load_shards(paths, root: Constable.root)
      raise Constable::Error, "no coverage files to publish -- expected #{SHARD_DIR}/shard-*.json" if paths.empty?

      raw = {}
      gate = false
      paths.each do |path|
        data = JSON.parse(File.read(path))
        unless data["format"] == SHARD_FORMAT
          raise Constable::Error, "#{path} is not a coverage file this version of Constable can read"
        end

        gate ||= data["gate"] == true
        shard = data["files"].to_h { |relative, lines| [File.join(root.to_s, relative), lines] }
        raw = Coverage.merge_raw(raw, shard)
      end
      [raw, gate]
    rescue JSON::ParserError => e
      raise Constable::Error, "a coverage file is not valid JSON: #{e.message}"
    end

    # The report to publish, built from raw measurement. Rebuilt rather than reusing the
    # run's own: a run measures changed lines from origin/main, and a pull request is
    # measured from its own base -- `staging`, on plenty of repositories. `base` overrides.
    def build(raw, config:, gate:, context:, base: nil, root: Constable.root)
      since = base ? Diff.merge_base(base, root: root) : diff_base(context, root: root)
      options = since ? { since: since } : {}
      Coverage.build_report(raw, config: config, root: root, gate: gate, **options)
    end

    # The revision a pull request's changed lines are measured from: where it branched off
    # its base. nil falls back to Diff's own default (origin/main and friends), which is
    # wrong for any repository whose pull requests target something else.
    def diff_base(context, root: Constable.root)
      return nil unless context&.base_ref

      Diff.merge_base("origin/#{context.base_ref}", root: root) || Diff.merge_base(context.base_ref, root: root)
    end
  end
end
