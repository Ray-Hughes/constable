# frozen_string_literal: true

require "json"
require "openssl"

module Constable
  module CoverageReport
    # `deliver: [custom]` -- the report as JSON to a URL of the team's choosing, for
    # anything the built-in deliveries do not cover: a Slack workflow, a dashboard, a
    # service of their own. Part of the paid tier (see Constable::Tier).
    #
    #   custom:
    #     webhook_url_env: CONSTABLE_COVERAGE_WEBHOOK_URL
    #     secret_env: CONSTABLE_COVERAGE_WEBHOOK_SECRET   # optional
    #
    # Both are environment variable *names*: a webhook URL is a credential in all but name,
    # and config.yml is committed. With a secret set, the body is signed the way GitHub
    # signs its own webhooks -- X-Constable-Signature: sha256=<hex HMAC of the body> -- so
    # the receiver can tell the report came from this pipeline.
    class Webhook
      def initialize(settings, env: ENV, http: Http.new)
        @settings = settings
        @env      = env
        @http     = http
      end

      def url
        name = (@settings["webhook_url_env"] || "CONSTABLE_COVERAGE_WEBHOOK_URL").to_s
        @env[name].to_s.strip.then { |value| value.empty? ? nil : value }
      end

      def deliver(report:, markdown:, context:)
        Tier.check!(:custom_delivery)
        target = url
        unless target
          raise Constable::Error, "custom delivery has no URL: set " \
                                  "#{@settings["webhook_url_env"] || "CONSTABLE_COVERAGE_WEBHOOK_URL"}"
        end

        body = JSON.generate(self.class.payload(report: report, markdown: markdown, context: context))
        response = @http.call(:post, target, headers: headers(body), body: body)
        raise Http::Failed, "the webhook answered #{response.status}" unless response.ok?

        target
      end

      # Everything but per-file line arrays, which on a large app run to megabytes and are
      # not what a receiver wants. The uncovered changed lines are the actionable part and
      # stay in.
      def self.payload(report:, markdown:, context:)
        summary = report.to_h.except(:files)
        {
          event: "coverage_report",
          constable_version: Constable::VERSION,
          repository: context&.repository,
          pull_request: context&.pr_number,
          sha: context&.sha,
          branch: context&.branch,
          run_url: context&.run_url,
          coverage: summary,
          markdown: markdown
        }
      end

      private

      def headers(body)
        out = { "Content-Type" => "application/json", "User-Agent" => "constable/#{Constable::VERSION}" }
        secret_name = (@settings["secret_env"] || "CONSTABLE_COVERAGE_WEBHOOK_SECRET").to_s
        secret = @env[secret_name].to_s
        out["X-Constable-Signature"] = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}" unless secret.empty?
        out
      end
    end
  end
end
