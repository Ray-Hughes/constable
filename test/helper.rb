# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "constable"

module Constable
  # Shared harness for Constable's own suite.
  #
  # Constable cannot test itself before it works, so this repo's suite is plain Minitest.
  # Each test gets a throwaway project root so config, the blotter and the registry never
  # leak between tests -- the same isolation guarantee Constable makes to its users.
  class TestCase < Minitest::Test
    make_my_diffs_pretty! if respond_to?(:make_my_diffs_pretty!)

    attr_reader :tmp_root

    def setup
      @previous_root = Constable.instance_variable_get(:@root)
      @tmp_root = Dir.mktmpdir("constable-test")
      FileUtils.mkdir_p(File.join(@tmp_root, ".constable"))
      Constable.root = @tmp_root
      Constable.reset!
      Constable.registry.clear if Constable.registry.respond_to?(:clear)
      super
    end

    def teardown
      super
      Constable.storage.close if Constable.instance_variable_get(:@storage)
      Constable.reset!
      Constable.root = @previous_root
      FileUtils.remove_entry(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
    end

    # Writes a file under the throwaway root, creating parent directories.
    def write_file(relative_path, contents)
      path = File.join(@tmp_root, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    def write_config(yaml)
      write_file(".constable/config.yml", yaml)
      Constable.reset!
      Constable.config
    end

    # Builds an anonymous Constable::Case subclass with a stable reported name, so tests
    # can exercise the DSL without polluting the global constant namespace.
    def build_case(name = "TestSubjectCase", parent = Constable::Case, &block)
      klass = Class.new(parent)
      klass.define_singleton_method(:name) { name }
      klass.class_eval(&block) if block
      klass
    end

    def capture_stdout
      original = $stdout
      buffer = StringIO.new
      $stdout = buffer
      yield
      buffer.string
    ensure
      $stdout = original
    end

    def silence_warnings
      original = Constable.warnings.dup
      yield
    ensure
      Constable.warnings.replace(original)
    end

    # Cold-case globs live in the case_helper's Constable.cold_cases block, not in config.yml. Writes the file
    # (so anything reading it back sees it) and applies it the way the runner does.
    def link_cold_cases(engine = :rspec, *globs)
      body = globs.map { |glob| "  #{engine} #{glob.inspect}" }.join("\n")
      write_file("test/case_helper.rb",
                 "require \"constable\"\n\nConstable.cold_cases do\n#{body}\nend\n")
      Constable.configuration.cold_cases { globs.each { |glob| public_send(engine, glob) } }
      Constable.config.apply_overrides!(Constable.configuration.overrides)
      Constable.config
    end

    def with_env(values)
      previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
  end
end

require "stringio"
