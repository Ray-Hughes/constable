# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    class NoUnfrozenTimeTest < CopTest
      COP = ::RuboCop::Cop::Constable::NoUnfrozenTime

      def test_registers_an_offense_for_time_now
        source = native_source(<<~RUBY)
          investigate "stamps the record" do
            attest(record.created_at).to eq(Time.now)
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "`Time.now` reads the wall clock")
      end

      def test_registers_an_offense_for_every_forbidden_reader
        %w[Time.now Time.current Time.zone.now Date.today Date.current DateTime.now].each do |call|
          source = native_source("investigate('x') { attest(x).to eq(#{call}) }\n")

          assert_single_offense(COP, source, line: 2, message_fragment: "`#{call}`")
        end
      end

      def test_accepts_a_reader_after_freeze_time_in_the_same_investigation
        source = native_source(<<~RUBY)
          investigate "stamps the record" do
            freeze_time
            attest(record.created_at).to eq(Time.now)
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_reader_after_travel_to_in_the_same_investigation
        source = native_source(<<~RUBY)
          investigate "stamps the record" do
            travel_to(Time.utc(2026, 1, 1))
            attest(record.created_at).to eq(Time.current)
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_rejects_a_reader_before_freeze_time_in_the_same_investigation
        source = native_source(<<~RUBY)
          investigate "stamps the record" do
            attest(record.created_at).to eq(Time.now)
            freeze_time
          end
        RUBY

        assert_single_offense(COP, source, line: 3)
      end

      def test_rejects_a_reader_frozen_only_in_a_different_investigation
        source = native_source(<<~RUBY)
          investigate "one" do
            freeze_time
          end

          investigate "two" do
            attest(record.created_at).to eq(Time.now)
          end
        RUBY

        assert_single_offense(COP, source, line: 7)
      end

      def test_accepts_a_reader_when_a_briefing_freezes_time
        source = native_source(<<~RUBY)
          briefing { freeze_time }

          investigate "stamps the record" do
            attest(record.created_at).to eq(Time.now)
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_reader_lexically_inside_a_freeze_time_block
        source = native_source(<<~RUBY)
          investigate "stamps the record" do
            freeze_time do
              attest(record.created_at).to eq(Time.now)
            end
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_reader_passed_to_a_freeze_helper
        source = native_source(<<~RUBY)
          investigate "stamps the record" do
            travel_to(Time.now + 3600)
            attest(record).to be_stamped
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_reader_inside_an_unsafe_block
        source = native_source(<<~RUBY)
          investigate "uses the real clock on purpose" do
            # the NTP drift check is genuinely about wall time
            unsafe { attest(drift_from(Time.now)).to be < 1 }
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_case_that_never_reads_the_clock
        source = native_source(<<~RUBY)
          investigate "creates a user" do
            attest(User).to exist(email: "a@b.com")
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_cold_cases_are_exempt
        assert_cold_case_exempt(COP, "investigate('x') { attest(y).to eq(Time.now) }\n")
      end
    end
  end
end
