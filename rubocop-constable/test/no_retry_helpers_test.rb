# frozen_string_literal: true

require "helper"

module RuboCop
  module Constable
    class NoRetryHelpersTest < CopTest
      COP = ::RuboCop::Cop::Constable::NoRetryHelpers

      def test_registers_an_offense_for_the_retry_keyword
        source = native_source(<<~RUBY)
          investigate "finishes the job" do
            begin
              attest(job).to be_finished
            rescue Constable::AssertionFailed
              retry
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 6, message_fragment: "`retry` turns a failing investigation")
      end

      def test_registers_an_offense_for_each_retry_helper
        %w[wait_for eventually with_retries try_again retry_until poll_until keep_trying].each do |helper|
          source = native_source("investigate('x') { #{helper} { done? } }\n")

          assert_single_offense(COP, source, line: 2, message_fragment: "`#{helper}` is a retry helper")
        end
      end

      def test_registers_an_offense_for_a_sleep_polling_until_loop
        source = native_source(<<~RUBY)
          investigate "finishes the job" do
            until job.reload.finished?
              sleep 0.1
            end
            attest(job).to be_finished
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "`until` polls with `sleep`")
      end

      def test_registers_an_offense_for_a_sleep_polling_while_loop
        source = native_source(<<~RUBY)
          investigate "x" do
            while job.pending?
              sleep 0.1
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "`while` polls with `sleep`")
      end

      def test_registers_an_offense_for_a_kernel_loop_that_polls
        source = native_source(<<~RUBY)
          investigate "x" do
            loop do
              break if job.reload.finished?
              sleep 0.1
            end
          end
        RUBY

        assert_single_offense(COP, source, line: 3, message_fragment: "`loop` polls with `sleep`")
      end

      def test_accepts_a_loop_that_does_real_work
        source = native_source(<<~RUBY)
          investigate "imports every row" do
            while (row = reader.next_row)
              importer.call(row)
            end
            attest(Import.count).to eq(3)
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_case_that_asserts_on_the_completed_state
        source = native_source(<<~RUBY)
          investigate "finishes the job" do
            perform_enqueued_jobs
            attest(job.reload).to be_finished
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_wait_for_inside_an_unsafe_block
        source = native_source(<<~RUBY)
          investigate "renders the toast" do
            # the browser drives this repaint on its own schedule
            unsafe { wait_for(timeout: 2, interval: 0.05) { page.has_content?("Done") } }
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_retry_inside_an_unsafe_block
        source = native_source(<<~RUBY)
          investigate "x" do
            unsafe do
              # the driver's first CDP connect races with the browser boot
              begin
                connect!
              rescue Selenium::WebDriver::Error::WebDriverError
                retry
              end
            end
          end
        RUBY

        assert_no_offenses(COP, source)
      end

      def test_accepts_a_wait_for_call_on_an_explicit_receiver
        source = native_source("investigate('x') { queue.wait_for(:drain) }\n")

        assert_no_offenses(COP, source)
      end

      def test_cold_cases_are_exempt
        assert_cold_case_exempt(COP, "it('x') { eventually { attest(page).to have_content('Done') } }\n")
      end
    end
  end
end
