# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate channel Room`.
    #
    #   test/cases/channels/room_channel_case.rb   class RoomChannelCase < IntegrationCase
    class ChannelGenerator < Base
      check_class_collision suffix: "ChannelCase"

      strips_suffix(/_channel\z/i)

      def create_case_file
        template "channel_case.rb.tt", case_path("channels", class_path, "#{file_name}_channel_case.rb")
      end
    end
  end
end
