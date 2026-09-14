# frozen_string_literal: true

require_relative "../helper"

module Constable
  # stdout is supposed to be results only. Rails loggers were routed to log/test.log from
  # the start, but a gem that writes straight to $stderr was not -- and Faraday's "install
  # the faraday-retry gem" fires once per file that triggers it, landing in the middle of
  # the live stream:
  #
  #   Address    ✓✓✓✓✓✓✓✓✓✓✓To use retry middleware with Faraday v2.0+...
  class LogRouterTest < TestCase
    def teardown
      LogRouter.restore!
      super
    end

    # route! only takes the console when there is a Rails to route around it; our own
    # suite has none, so drive the capture directly.
    def capture_console(verbose_to: nil)
      file = StringIO.new
      original_out = $stdout
      LogRouter.send(:capture_console!, file, verbose_to)
      yield file
    ensure
      LogRouter.send(:restore_console!)
      $stdout = original_out
    end

    def test_a_stray_write_goes_to_the_log_not_the_terminal
      terminal = $stdout

      capture_console do |file|
        warn "install the faraday-retry gem"
        $stdout.puts "something a gem printed"

        assert_includes file.string, "faraday-retry"
        assert_includes file.string, "something a gem printed"
      end

      assert_same terminal, $stdout, "the terminal has to come back"
    end

    # The console is a dup of the terminal, not the terminal object itself -- redirecting
    # the descriptor is the whole point, so the reporter needs its own handle on where the
    # terminal used to be.
    def test_the_console_is_a_handle_on_the_real_terminal
      terminal = $stdout

      capture_console do
        refute_same terminal, $stdout, "everything else writes to the log"
        refute_nil LogRouter.console, "the reporter still has somewhere to write"
        refute_same $stdout, LogRouter.console
      end
    end

    def test_verbose_tees_it_back
      seen = StringIO.new

      capture_console(verbose_to: seen) do |file|
        warn "still want to see this"

        assert_includes file.string, "still want to see this"
        assert_includes seen.string, "still want to see this", "--verbose means show me"
      end
    end

    def test_restore_puts_both_streams_back
      out = $stdout
      err = $stderr

      capture_console { nil }

      assert_same out, $stdout
      assert_same err, $stderr
    end

    def test_the_console_falls_back_to_stdout_when_nothing_was_captured
      assert_same $stdout, LogRouter.console
    end

    # Something handed $stdout may ask it for a file descriptor, and a NoMethodError
    # raised from inside somebody else's gem is a bad way to find that out.
    # ---- crash visibility --------------------------------------------------------------

    # A fatal signal skips at_exit, so the descriptors are never put back and Ruby's crash
    # report ends up in log/test.log with nothing on the terminal. The marker is what turns
    # a silent exit 134 into a sentence on the next run.
    def test_a_run_that_never_restored_the_console_is_reported_next_time
      marker = LogRouter.console_mark_path(tmp_root)
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "999999\n#{tmp_root}/log/test.log\n")

      io = StringIO.new
      message = LogRouter.report_previous_crash!(io: io, root: tmp_root)

      assert_match(/ended without finishing/, message.to_s)
      assert_match(%r{log/test\.log}, io.string)
      refute_path_exists marker, "the marker has to be cleared once it has been reported"
    end

    # A second Constable running right now is not a crash.
    def test_a_marker_from_a_live_process_is_left_alone
      marker = LogRouter.console_mark_path(tmp_root)
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "#{Process.ppid}\n#{tmp_root}/log/test.log\n")

      io = StringIO.new

      assert_nil LogRouter.report_previous_crash!(io: io, root: tmp_root)
      assert_empty io.string
      assert_path_exists marker
    end

    def test_no_marker_means_nothing_is_said
      io = StringIO.new

      assert_nil LogRouter.report_previous_crash!(io: io, root: tmp_root)
      assert_empty io.string
    end

    def test_the_tee_answers_fileno
      File.open(File.join(tmp_root, "out.log"), "w") do |file|
        tee = LogRouter::Tee.new(file, StringIO.new)

        assert_equal file.fileno, tee.fileno
      end
    end

    def test_the_tee_answers_fileno_with_nil_when_no_target_has_one
      assert_nil LogRouter::Tee.new(StringIO.new).fileno
    end
  end
end
