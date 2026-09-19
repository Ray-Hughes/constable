# frozen_string_literal: true

module Constable
  module CoverageReport
    # The `coverage_report:` block of .constable/config.yml, read and checked.
    #
    # Checked up front, and loudly. A typo in `deliver:` that quietly published nothing
    # would look exactly like a quiet week: nobody notices a report that never arrives.
    class Settings
      DELIVERIES = %w[pr_comment pr_description email custom].freeze
      HOSTS      = %w[github].freeze
      CIS        = %w[github_actions].freeze

      attr_reader :raw

      def initialize(raw)
        @raw = raw.is_a?(Hash) ? raw : {}
      end

      def self.from(config) = new(config["coverage_report"])

      def deliveries = Array(@raw["deliver"]).map { |d| d.to_s.strip }.reject(&:empty?)
      def enabled?   = deliveries.any?
      def host       = (@raw["host"] || "github").to_s
      def ci         = (@raw["ci"] || "github_actions").to_s
      def token_env  = (@raw["token_env"] || "GITHUB_TOKEN").to_s
      def email      = @raw["email"].is_a?(Hash) ? @raw["email"] : {}
      def custom     = @raw["custom"].is_a?(Hash) ? @raw["custom"] : {}
      # Heading and closing note for the rendered report; both optional.
      def title      = @raw["title"]
      def note       = @raw["note"]

      def pr_delivery? = deliveries.intersect?(%w[pr_comment pr_description])

      # Every problem at once, so fixing the file is one edit rather than one per run.
      def problems
        out = []
        unknown = deliveries - DELIVERIES
        unless unknown.empty?
          out << "deliver: #{unknown.join(", ")} #{unknown.one? ? "is" : "are"} not a delivery. " \
                 "Choose from #{DELIVERIES.join(", ")}."
        end
        out << "host: #{host} is not supported yet (supported: #{HOSTS.join(", ")})." unless HOSTS.include?(host)
        out << "ci: #{ci} is not supported yet (supported: #{CIS.join(", ")})." unless CIS.include?(ci)

        if deliveries.include?("email")
          out << "email.to needs at least one address." if Array(email["to"]).empty?
          out << "email.from is required." if email["from"].to_s.strip.empty?
          out << "email.smtp_host is required." if email["smtp_host"].to_s.strip.empty?
        end
        out
      end

      def validate!
        return self if problems.empty?

        raise Constable::ConfigurationError,
              "coverage_report in #{Config::CONFIG_PATH} has #{problems.one? ? "a problem" : "problems"}:\n  " +
              problems.join("\n  ")
      end
    end
  end
end
