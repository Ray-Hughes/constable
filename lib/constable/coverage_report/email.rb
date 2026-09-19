# frozen_string_literal: true

require "securerandom"
require "time"

module Constable
  module CoverageReport
    # SMTP, straight -- not the app's ActionMailer. A CI test environment runs with
    # `delivery_method :test` almost by definition, so going through the app's mailer would
    # hand the report to an array and report success.
    #
    #   email:
    #     to: [lead@example.com]
    #     from: constable@example.com
    #     smtp_host: smtp.example.com
    #     smtp_port: 587                         # STARTTLS when the server offers it
    #     smtp_user: constable                   # omit for an unauthenticated relay
    #     smtp_password_env: CONSTABLE_SMTP_PASSWORD
    #
    # The password is read from the environment, never the file: config.yml is committed.
    class Email
      def initialize(settings, env: ENV, smtp: nil)
        @settings = settings
        @env      = env
        @smtp     = smtp
      end

      def deliver(subject:, body:)
        recipients = Array(@settings["to"]).map(&:to_s)
        message = compose(subject: subject, body: body, recipients: recipients)
        start_smtp do |smtp|
          smtp.send_message(message, from, recipients)
        end
        recipients
      end

      def compose(subject:, body:, recipients:)
        <<~MESSAGE.gsub(/(?<!\r)\n/, "\r\n")
          From: #{from}
          To: #{recipients.join(", ")}
          Subject: #{subject}
          Date: #{Time.now.rfc2822}
          Message-ID: <#{SecureRandom.uuid}@constable>
          MIME-Version: 1.0
          Content-Type: text/plain; charset=UTF-8

          #{body}
        MESSAGE
      end

      private

      def from = @settings["from"].to_s

      def start_smtp(&)
        return @smtp.call(@settings, password, &) if @smtp

        require_smtp!
        host = @settings["smtp_host"].to_s
        port = (@settings["smtp_port"] || 587).to_i
        smtp = Net::SMTP.new(host, port)
        smtp.enable_starttls_auto if smtp.respond_to?(:enable_starttls_auto)
        user = @settings["smtp_user"]
        if user.to_s.empty?
          smtp.start(helo_domain, &)
        else
          smtp.start(helo_domain, user.to_s, password, (@settings["smtp_auth"] || "plain").to_sym, &)
        end
      end

      def password
        name = (@settings["smtp_password_env"] || "CONSTABLE_SMTP_PASSWORD").to_s
        @env[name]
      end

      def helo_domain = from.split("@", 2).last.to_s.then { |d| d.empty? ? "localhost" : d }

      def require_smtp!
        require "net/smtp"
      rescue LoadError
        raise Constable::Error,
              "Email delivery needs the net-smtp gem, which Constable depends on -- " \
              "run `bundle install` and try again."
      end
    end
  end
end
