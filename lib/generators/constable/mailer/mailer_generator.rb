# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate mailer Notifier welcome`.
    #
    #   test/cases/mailers/notifier_mailer_case.rb        class NotifierMailerCase < IntegrationCase
    #   test/mailers/previews/notifier_mailer_preview.rb  the /rails/mailers preview
    class MailerGenerator < Base
      argument :actions, type: :array, default: [], banner: "method method"

      def check_class_collision
        class_collisions "#{class_name}MailerCase", "#{class_name}MailerPreview"
      end

      def create_case_file
        template "mailer_case.rb.tt", case_path("mailers", class_path, "#{file_name}_mailer_case.rb")
      end

      # A preview is a development tool, not a case, and ActionMailer looks for it under
      # test/mailers/previews by default. Moving it somewhere more Constable-shaped would
      # buy nothing and break /rails/mailers, so it stays exactly where Rails put it.
      def create_preview_file
        template "preview.rb.tt", File.join("test/mailers/previews", class_path, "#{file_name}_mailer_preview.rb")
      end

      private

      def file_name
        @_file_name ||= super.sub(/_mailer\z/i, "")
      end
    end
  end
end
