# frozen_string_literal: true

require "helper"

module Constable
  # `constable test --watch`: a save runs the tests that cover the saved file. Driven here
  # with a fake runner and a sleeper that makes the edits, so nothing waits and nothing forks.
  class WatcherTest < TestCase
    def setup
      super
      @model = write_file("app/models/user.rb", "class User; end\n")
      @case  = write_file("test/cases/models/user_case.rb", "class UserCase < Constable::Case\nend\n")
      write_file("test/cases/models/order_case.rb", "class OrderCase < Constable::Case\nend\n")
      @ran = []
    end

    def watcher(edits: [])
      selection = Selection.new([], config: Constable.config, root: tmp_root)
      sleeper = lambda do |_seconds|
        edit = edits.shift
        edit&.call
      end
      Watcher.new(selection: selection, root: tmp_root, io: StringIO.new, interval: 0,
                  runner: ->(files) { @ran << files }, sleeper: sleeper)
    end

    # Content changes and a new mtime, the way an editor's save lands.
    def save(path, contents = "# saved\n")
      lambda do
        File.write(path, contents)
        File.utime(Time.now + 5, Time.now + 5, path)
      end
    end

    def test_saving_app_code_runs_the_case_that_covers_it
      ran = watcher(edits: [save(@model)]).tick

      assert_equal [File.join(tmp_root, "test/cases/models/user_case.rb")], ran
      assert_equal [["test/cases/models/user_case.rb"]], @ran, "paths are handed on relative to the root"
    end

    def test_saving_a_case_runs_that_case
      watcher(edits: [save(@case, "class UserCase < Constable::Case\n  # edited\nend\n")]).tick

      assert_equal [["test/cases/models/user_case.rb"]], @ran
    end

    def test_nothing_saved_runs_nothing
      assert_empty watcher.tick
      assert_empty @ran
    end

    def test_a_save_no_test_covers_says_so_and_runs_nothing
      unrelated = write_file("app/services/billing_gateway.rb", "class BillingGateway; end\n")
      io = StringIO.new
      w = watcher(edits: [save(unrelated)])
      w.instance_variable_set(:@io, io)

      assert_empty w.tick
      assert_includes io.string, "app/services/billing_gateway.rb changed -- no tests cover it."
      assert_empty @ran
    end

    # Formatters and editors often write a file more than once per save.
    def test_a_burst_of_writes_is_one_run
      other = write_file("app/models/order.rb", "class Order; end\n")

      watcher(edits: [save(@model), save(other)]).tick

      assert_equal 1, @ran.size
      assert_equal %w[test/cases/models/order_case.rb test/cases/models/user_case.rb], @ran.first
    end

    def test_each_run_is_a_fresh_process_with_the_forwarded_options
      w = watcher
      w.forwarded = ["--only", "native"]

      assert_equal [Gem.ruby, "-S", "constable", "test", "a_case.rb", "--only", "native"], w.command(["a_case.rb"])
    end
  end
end
