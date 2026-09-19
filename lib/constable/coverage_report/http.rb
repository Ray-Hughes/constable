# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Constable
  module CoverageReport
    # JSON over HTTPS with the standard library, so publishing adds no HTTP gem to anyone's
    # bundle. Anything answering `call(method, url, headers:, body:)` with a Response can
    # stand in for it, which is how the tests run without a network.
    class Http
      Response = Struct.new(:status, :body, :headers, keyword_init: true) do
        def ok? = status.between?(200, 299)

        def json
          body.to_s.empty? ? nil : JSON.parse(body)
        rescue JSON::ParserError
          nil
        end
      end

      class Failed < Constable::Error; end

      TIMEOUT = 30

      def call(method, url, headers: {}, body: nil)
        uri = URI(url)
        request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
        headers.each { |name, value| request[name] = value }
        request.body = body if body

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          http.request(request)
        end
        Response.new(status: response.code.to_i, body: response.body, headers: response.to_hash)
      rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise Failed, "#{method.to_s.upcase} #{uri&.host}: #{e.class}: #{e.message}"
      end
    end
  end
end
