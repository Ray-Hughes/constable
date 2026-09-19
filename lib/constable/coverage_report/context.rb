# frozen_string_literal: true

require "json"

module Constable
  module CoverageReport
    # Where this run is: which repository, which pull request, which commit. Read from the
    # CI's own environment, so nothing has to be passed on the command line.
    #
    # GitHub Actions only, for now. GitHub Enterprise needs nothing extra: Actions sets
    # GITHUB_API_URL and GITHUB_SERVER_URL to the enterprise host (https://va.ghe.com/api/v3,
    # say), and everything here goes through those.
    class Context
      attr_reader :repository, :pr_number, :sha, :base_ref, :branch, :api_url, :server_url, :run_url

      def self.detect(env: ENV)
        return nil unless env["GITHUB_ACTIONS"] == "true"

        event = read_event(env["GITHUB_EVENT_PATH"])
        pull  = event["pull_request"] || {}
        server = env.fetch("GITHUB_SERVER_URL", "https://github.com")
        repo   = env["GITHUB_REPOSITORY"]

        new(
          repository: repo,
          # A pull_request event carries its number. CONSTABLE_PR_NUMBER covers the rest --
          # a workflow_run, or a publish job that only has the number passed to it.
          pr_number: (env["CONSTABLE_PR_NUMBER"] || pull["number"])&.to_i,
          # GITHUB_SHA is the throwaway merge commit on a pull_request event. Links into the
          # code have to point at the branch's own head, which is what reviewers see.
          sha: pull.dig("head", "sha") || env["GITHUB_SHA"],
          base_ref: env["GITHUB_BASE_REF"].to_s.empty? ? nil : env["GITHUB_BASE_REF"],
          branch: env["GITHUB_HEAD_REF"].to_s.empty? ? env["GITHUB_REF_NAME"] : env["GITHUB_HEAD_REF"],
          api_url: env.fetch("GITHUB_API_URL", "https://api.github.com"),
          server_url: server,
          run_url: repo && env["GITHUB_RUN_ID"] ? "#{server}/#{repo}/actions/runs/#{env["GITHUB_RUN_ID"]}" : nil
        )
      end

      def self.read_event(path)
        return {} if path.to_s.empty? || !File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        {}
      end

      def initialize(repository:, pr_number: nil, sha: nil, base_ref: nil, branch: nil,
                     api_url: "https://api.github.com", server_url: "https://github.com", run_url: nil)
        @repository = repository
        @pr_number  = pr_number&.positive? ? pr_number : nil
        @sha        = sha
        @base_ref   = base_ref
        @branch     = branch
        @api_url    = api_url.to_s.chomp("/")
        @server_url = server_url.to_s.chomp("/")
        @run_url    = run_url
      end

      def pull_request? = !@pr_number.nil?

      # A link to lines of a file at this run's commit, or nil when there is no commit to
      # point at.
      def blob_url(path, first, last = first)
        return nil unless @repository && @sha

        anchor = first == last ? "L#{first}" : "L#{first}-L#{last}"
        "#{@server_url}/#{@repository}/blob/#{@sha}/#{path}##{anchor}"
      end

      def label
        return "#{@repository} ##{@pr_number}" if pull_request?

        [@repository, @branch].compact.join(" @ ")
      end
    end
  end
end
