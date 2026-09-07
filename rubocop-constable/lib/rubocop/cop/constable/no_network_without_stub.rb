# frozen_string_literal: true

module RuboCop
  module Cop
    module Constable
      # A case that talks to the real network is not a test of your code, it is a
      # test of somebody else's uptime. It fails on a plane, on a flaky DNS
      # resolver, and on the day the third party rate-limits CI -- none of which
      # are your bug.
      #
      # Constable ships `stub_network!`, which installs a guard that raises on any
      # real outbound connection. Call it in a `briefing` and every investigation in
      # the case is covered; this cop then goes quiet for the whole file. If the
      # outbound call itself is the subject, `unsafe { }` says so on the record.
      #
      # @example
      #   # bad
      #   investigate "fetches the profile" do
      #     attest(Net::HTTP.get(uri)).to include("ok")
      #   end
      #
      #   # good
      #   briefing { stub_network! }
      #
      #   investigate "fetches the profile" do
      #     attest(Net::HTTP.get(uri)).to include("ok")
      #   end
      class NoNetworkWithoutStub < Base
        include CaseScope
        include Helpers

        MSG = "`%<call>s` reaches the real network, and this case never calls " \
              "`stub_network!`. A test that depends on somebody else's uptime is " \
              "not testing your code -- add `briefing { stub_network! }`, or use " \
              "`unsafe { }` if the live call is the subject."

        DEFAULT_HTTP_CONSTANTS = %w[
          Net::HTTP
          Net::HTTPS
          HTTParty
          Faraday
          RestClient
          Excon
          Typhoeus
          HTTPClient
          HTTPX
          HTTP
          Curl
          Patron
          Mechanize
          OpenURI
          Down
        ].freeze

        DEFAULT_STUB_HELPERS = %w[stub_network!].freeze

        # `URI` is a perfectly innocent constant right up until you `.open` it.
        URI_NETWORK_METHODS = %i[open read].freeze
        URL_LITERAL = %r{\Ahttps?://}i.freeze

        def on_new_investigation
          @network_stubbed = nil
          super
        end

        def on_send(node)
          return unless constable_case_file?
          return if network_stubbed?
          return unless (call = network_call_name(node))
          return if inside_unsafe_block?(node)

          add_offense(node, message: format(MSG, call: call))
        end
        alias on_csend on_send

        private

        # The stub is a file-level fact: `stub_network!` in a `briefing` runs before
        # every investigation, so one call anywhere covers the case.
        def network_stubbed?
          return @network_stubbed unless @network_stubbed.nil?

          ast = processed_source&.ast
          @network_stubbed =
            !ast.nil? && ast.each_node(:send, :csend).any? do |send_node|
              send_node.receiver.nil? && stub_helpers.include?(send_node.method_name.to_s)
            end
        end

        # Matches only calls made *directly* on a known entry-point constant. That
        # is deliberate: it flags the innermost link of a chain exactly once, so
        # `Faraday.new.get(url)` reports on `Faraday.new` rather than twice, and
        # `Net::HTTP.get(uri).to_s` never reports a nonsense `Net::HTTP.to_s`.
        # Calls on an object handed around by a `witness` are out of reach of a
        # static check and are left to `stub_network!` itself to catch at runtime.
        def network_call_name(node)
          receiver = node.receiver

          if receiver.nil?
            # open-uri patches Kernel#open; `open("https://...")` is a live request.
            return "open" if node.method_name == :open && url_literal_argument?(node)

            return nil
          end

          return nil unless receiver.const_type?

          root = constant_string(receiver)
          return nil if root.nil?

          if root == "URI"
            return nil unless URI_NETWORK_METHODS.include?(node.method_name)

            return "URI.#{node.method_name}"
          end

          return nil unless http_constant?(root)

          "#{root}.#{node.method_name}"
        end

        def http_constant?(root)
          http_constants.any? { |name| root == name || root.start_with?("#{name}::") }
        end

        def url_literal_argument?(node)
          first = node.first_argument
          return false unless first.respond_to?(:str_type?) && (first.str_type? || first.dstr_type?)

          URL_LITERAL.match?(first.source.delete_prefix('"').delete_prefix("'"))
        end

        def http_constants
          @http_constants ||= Array(cop_config.fetch("HttpConstants", DEFAULT_HTTP_CONSTANTS)).map(&:to_s)
        end

        def stub_helpers
          @stub_helpers ||= Array(cop_config.fetch("StubHelpers", DEFAULT_STUB_HELPERS)).map(&:to_s)
        end
      end
    end
  end
end
