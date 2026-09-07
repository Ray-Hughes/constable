# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate mailbox Forwards`.
    #
    #   test/cases/mailboxes/forwards_mailbox_case.rb   class ForwardsMailboxCase < IntegrationCase
    class MailboxGenerator < Base
      check_class_collision suffix: "MailboxCase"

      strips_suffix(/_mailbox\z/i)

      def create_case_file
        template "mailbox_case.rb.tt", case_path("mailboxes", class_path, "#{file_name}_mailbox_case.rb")
      end
    end
  end
end
