# frozen_string_literal: true

require "json"

module Constable
  module CoverageReport
    # The two pull-request deliveries, over GitHub's REST API. Both update in place: a
    # report that posted a new comment on every push would bury the review under its own
    # history, so each run finds what the last one wrote and replaces it.
    class GitHub
      # Fences the section Constable owns inside a pull request description. Everything
      # outside them is the author's and is never touched.
      SECTION_START = "<!-- constable:coverage:start -->"
      SECTION_END   = "<!-- constable:coverage:end -->"

      # How far to look for an earlier comment. Bounded: an API answering every page with
      # the same full page would otherwise hold the build forever. Past it a new comment is
      # posted, which is the cheaper mistake.
      MAX_COMMENT_PAGES = 30

      def initialize(context:, token:, http: Http.new)
        @context = context
        @token   = token
        @http    = http
      end

      # Edits Constable's earlier comment when there is one, else posts a new one.
      # Returns the comment's URL.
      def upsert_comment(body)
        existing = find_comment
        response = if existing
                     request(:patch, "/repos/#{repo}/issues/comments/#{existing["id"]}", body: body)
                   else
                     request(:post, "/repos/#{repo}/issues/#{pr}/comments", body: body)
                   end
        response.json&.fetch("html_url", nil)
      end

      # Replaces the fenced section of the description, or appends one. Returns the
      # pull request's URL.
      def update_description(body)
        pull = request(:get, "/repos/#{repo}/pulls/#{pr}").json || {}
        updated = self.class.with_section(pull["body"].to_s, body)
        return pull["html_url"] if updated == pull["body"].to_s

        request(:patch, "/repos/#{repo}/pulls/#{pr}", body: updated).json&.fetch("html_url", nil)
      end

      def self.with_section(description, body)
        section = "#{SECTION_START}\n#{body}\n#{SECTION_END}"
        pattern = /#{Regexp.escape(SECTION_START)}.*?#{Regexp.escape(SECTION_END)}/m
        return description.sub(pattern) { section } if description.match?(pattern)
        return section if description.strip.empty?

        "#{description.rstrip}\n\n#{section}"
      end

      private

      def repo = @context.repository
      def pr   = @context.pr_number

      # Paged, because a long review thread runs past one page and the comment to update
      # is usually on the first -- but not always.
      def find_comment
        (1..MAX_COMMENT_PAGES).each do |page|
          comments = request(:get, "/repos/#{repo}/issues/#{pr}/comments?per_page=100&page=#{page}").json
          return nil unless comments.is_a?(Array) && comments.any?

          found = comments.find { |c| c["body"].to_s.start_with?(Markdown::MARKER) }
          return found if found
          return nil if comments.size < 100
        end
        nil
      end

      def request(method, path, body: nil)
        payload = body && JSON.generate(body: body)
        response = @http.call(method, "#{@context.api_url}#{path}", headers: headers, body: payload)
        return response if response.ok?

        raise Http::Failed, "GitHub #{method.to_s.upcase} #{path} answered #{response.status}: " \
                            "#{response.json&.fetch("message", nil) || response.body.to_s[0, 200]}" \
                            "#{permission_hint(response)}"
      end

      def headers
        {
          "Authorization" => "Bearer #{@token}",
          "Accept" => "application/vnd.github+json",
          "Content-Type" => "application/json",
          "User-Agent" => "constable/#{Constable::VERSION}"
        }
      end

      def permission_hint(response)
        return "" unless [401, 403, 404].include?(response.status)

        ". The token needs `pull-requests: write` (and `issues: write` for comments) -- " \
          "in GitHub Actions, add them under the workflow's `permissions:`."
      end
    end
  end
end
