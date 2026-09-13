# frozen_string_literal: true

require_relative "../helper"

module Constable
  # A ported spec carries `require_relative "../../app/services/thing"`, and a port moves the
  # file -- so the path is wrong by however many directories it moved, and repointing it
  # gives "../../../../app/services/thing": correct, unreadable, wrong again on the next move.
  class RequireAppTest < TestCase
    def test_the_app_prefix_is_optional
      write_file("app/services/thing.rb", "module Thing; end\n")

      assert_equal File.join(tmp_root, "app/services/thing.rb"),
                   RequireApp.resolve("services/thing")
      assert_equal File.join(tmp_root, "app/services/thing.rb"),
                   RequireApp.resolve("app/services/thing")
    end

    def test_a_rb_suffix_is_optional
      write_file("app/services/thing.rb", "module Thing; end\n")

      assert_equal File.join(tmp_root, "app/services/thing.rb"),
                   RequireApp.resolve("services/thing.rb")
    end

    # Anything outside app/ is taken from the root as written -- a rubocop cop, a rake task,
    # a directory Zeitwerk does not own.
    def test_a_path_outside_app_is_taken_from_the_root
      write_file(".rubocop/custom_cop/thing.rb", "module Thing; end\n")

      assert_equal File.join(tmp_root, ".rubocop/custom_cop/thing.rb"),
                   RequireApp.resolve(".rubocop/custom_cop/thing")
    end

    # The failure has to say where it looked. "cannot load such file" plus a path nobody
    # wrote is the error this helper exists to stop producing.
    def test_a_missing_file_says_where_it_looked
      error = assert_raises(Constable::Error) { RequireApp.resolve("services/nope") }

      assert_match(%r{require_app\("services/nope"\)}, error.message)
      assert_match(%r{app/services/nope\.rb}, error.message)
      assert_match(/named from the app root/, error.message)
    end

    def test_it_actually_loads_the_file
      write_file("app/services/loaded_thing.rb", "LOADED_THING = :yes\n")
      Object.new.send(:require_app, "services/loaded_thing")

      assert_equal :yes, Object.const_get(:LOADED_THING)
    ensure
      Object.send(:remove_const, :LOADED_THING) if Object.const_defined?(:LOADED_THING)
    end
  end
end
