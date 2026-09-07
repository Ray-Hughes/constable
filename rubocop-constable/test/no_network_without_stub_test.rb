# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    class NoNetworkWithoutStubTest < CopTest
      COP = ::RuboCop::Cop::Constable::NoNetworkWithoutStub

      def test_registers_an_offense_for_net_http
        source = native_source(<<~RUBY)
          investigate "fetches the profile" do
            attest(Net::HTTP.get(uri)).to include("ok")
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "`Net::HTTP.get` reaches the real network")
      end

      def test_registers_an_offense_for_each_http_library
        {
          "HTTParty.get(url)" => "HTTParty.get",
          "Faraday.new(url: url)" => "Faraday.new",
          "RestClient.post(url, {})" => "RestClient.post",
          "Excon.get(url)" => "Excon.get",
          "Typhoeus::Request.get(url)" => "Typhoeus::Request.get",
          "HTTP.get(url)" => "HTTP.get",
          "URI.open(url)" => "URI.open",
          "Net::HTTP::Get.new(uri)" => "Net::HTTP::Get.new"
        }.each do |call, expected|
          source = native_source("investigate('x') { #{call} }\n")

          assert_single_offense(COP, source, line: 2, message_fragment: "`#{expected}`")
        end
      end

      def test_registers_an_offense_for_open_uri_kernel_open
        source = native_source(%(investigate('x') { open("https://example.com").read }\n))

        assert_single_offense(COP, source, line: 2, message_fragment: "`open`")
      end

      def test_reports_a_chain_once_at_its_entry_point
        source = native_source("investigate('x') { Faraday.new(url: url).get('/profile') }\n")

        assert_single_offense(COP, source, line: 2, message_fragment: "`Faraday.new`")
      end

      def test_accepts_the_whole_file_when_a_briefing_stubs_the_network
        source = native_source(<<~RUBY)
          briefing do
            stub_network!
          end

          investigate "fetches the profile" do
            attest(Net::HTTP.get(uri)).to include("ok")
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_stub_declared_inside_the_investigation
        source = native_source(<<~RUBY)
          investigate "fetches the profile" do
            stub_network!
            attest(Net::HTTP.get(uri)).to include("ok")
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_case_that_never_touches_the_network
        source = native_source(<<~RUBY)
          investigate "parses the url" do
            attest(URI.parse("https://example.com").host).to eq("example.com")
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_network_call_inside_an_unsafe_block
        source = native_source(<<~RUBY)
          investigate "smoke-tests the real endpoint" do
            # deliberately hits staging; this case is the canary, not a unit test
            unsafe { attest(Net::HTTP.get(uri)).to include("ok") }
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_cold_cases_are_exempt
        assert_cold_case_exempt(COP, "investigate('x') { Net::HTTP.get(uri) }\n")
      end
    end
  end
end
