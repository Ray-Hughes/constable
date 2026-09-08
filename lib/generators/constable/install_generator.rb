# frozen_string_literal: true

# Rails generator machinery is required *here*, not from lib/constable.rb.
# `require "constable"` has to work in a process with no Rails app at all --
# that is the entire point of the :unit tier -- so railties is only ever pulled
# in by the two files that genuinely cannot exist without it.
require "rails/generators/base"
require "constable"

module Constable
  module Generators
    # `rails generate constable:install`
    #
    # Writes the six things a Constable suite needs to run, and nothing else:
    #
    #   test/case_helper.rb          the boot file + per-tier base classes
    #   test/support/matchers.rb     custom matcher examples
    #   test/support/authenticatable.rb  the "shared behavior is a module" example
    #   test/cases/example_case.rb   a worked case so `constable test` does something
    #   .constable/config.yml        every setting, at its default, as a reference
    #   .rubocop.yml                 the linter, merged into yours if you have one
    #   .gitignore                   two lines, so the blotter stays local
    #
    # Plus the optional :cold_case Gemfile group, but only when there is actually
    # an RSpec or Minitest suite in the repo to import. Installing the gem into a
    # greenfield app shouldn't add two dependencies for a migration that will
    # never happen.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc <<~DESC
        Sets up Constable: test/case_helper.rb with the per-tier base classes, test/support/
        with matcher and shared-module examples, an example case, the full .constable/config.yml
        reference, a .rubocop.yml wired to rubocop-constable, and -- only when this repo already
        has RSpec or Minitest files to import -- the optional :cold_case Gemfile group.

        --force, --pretend, --quiet and --skip come from Rails and behave as they do everywhere.
      DESC

      class_option :skip_gemfile, type: :boolean, default: false,
                                  desc: "Don't append the optional :cold_case group to the Gemfile"
      class_option :skip_rubocop, type: :boolean, default: false,
                                  desc: "Don't create or modify .rubocop.yml"
      class_option :skip_example, type: :boolean, default: false,
                                  desc: "Don't write the example case under test/cases/"
      class_option :skip_support, type: :boolean, default: false,
                                  desc: "Don't write the example files under test/support/"
      class_option :skip_config, type: :boolean, default: false,
                                 desc: "Don't write .constable/config.yml -- configure in Ruby instead"

      COLD_CASE_HEADER = <<~RUBY
        # Cold cases: your existing RSpec/Minitest files, run verbatim through their own
        # real engine, with results merged into Constable's reporting and CI gate. These
        # gems are needed only for as long as cold cases exist -- delete the group once
        # the suite is fully modernized and the dependencies drop out with it.
      RUBY

      # Only the engines this repo actually has files for, and only ones the Gemfile does
      # not already declare. An app adopting Constable *from RSpec* -- which is most of
      # them -- already has rspec-rails, and declaring it twice is not a style question:
      # Bundler refuses to parse the file at all, so the install leaves the app unbootable.
      COLD_CASE_GEMS = { rspec: "rspec-rails", minitest: "minitest" }.freeze

      # Per engine, so a repo with only RSpec files does not get minitest added to its
      # Gemfile for a migration it is never going to do.
      LEGACY_GLOBS = { rspec: "spec/**/*_spec.rb", minitest: "test/**/*_test.rb" }.freeze

      # The blotter is machine state: this laptop's flake history and jail docket. Sharing
      # it through git would hand CI somebody else's docket and conflict on every run.
      GITIGNORE_ENTRY = <<~TEXT
        # Constable's blotter -- flake history, the jail docket, warrants. Local state:
        # each machine keeps its own, and CI starts clean.
        /.constable/*.sqlite3
        /.constable/*.sqlite3-*
      TEXT

      NEW_SETTINGS_HEADER = <<~TEXT
        # ---------------------------------------------------------------------------
        # Added by `rails generate constable:install` on a later upgrade. These settings
        # did not exist when this file was written; each is shown at its default, so
        # deleting any of them changes nothing.
        # ---------------------------------------------------------------------------

      TEXT

      RUBOCOP_EXTENSION = "rubocop-constable"

      def create_case_helper
        template "case_helper.rb.tt", "test/case_helper.rb"
      end

      def create_support_files
        return if options[:skip_support]

        template "matchers.rb.tt", "test/support/matchers.rb"
        template "authenticatable.rb.tt", "test/support/authenticatable.rb"
      end

      # The config file doubles as the reference -- every key at its default, with the
      # reasoning above it -- which only works if it stays current. A gem upgrade cannot
      # rewrite it (that would clobber your settings) and Thor's only other answer is to
      # skip the file entirely, so before 1.1.0 a setting added after you installed was
      # invisible: `output` shipped in 1.0.0 and never appeared in an existing config.
      #
      # So: create it if it is missing, and otherwise append only the settings it does not
      # already mention. Your edits and comments are never touched.
      def create_config
        if options[:skip_config]
          say_status :skip, ".constable/config.yml (configure in test/case_helper.rb instead)", :blue
          return
        end

        path = File.join(destination_root, ".constable/config.yml")
        return template("config.yml.tt", ".constable/config.yml") unless File.exist?(path)

        missing = missing_config_blocks(File.read(path))
        if missing.empty?
          say_status :identical, ".constable/config.yml (every setting is documented)", :blue
          return
        end

        names = missing.flat_map { |block| config_keys_in(block) }
        say_status :append, ".constable/config.yml (#{names.join(", ")})", :green
        append_to_file ".constable/config.yml", "\n#{NEW_SETTINGS_HEADER}#{missing.join("\n\n")}\n"
      end

      def create_example_case
        return if options[:skip_example]

        template "example_case.rb.tt", "test/cases/example_case.rb"
      end

      # The :cold_case group is appended only when there is something to import,
      # and only once no matter how many times the generator runs. Re-running an
      # installer is normal (a new option, a regenerated helper) and must never
      # leave a Gemfile with the same group in it twice.
      def add_cold_case_gemfile_group
        return if options[:skip_gemfile]

        unless File.exist?(File.join(destination_root, "Gemfile"))
          say_status :skip, "Gemfile not found -- add the :cold_case group by hand before importing", :yellow
          return
        end

        unless legacy_suite_present?
          say_status :skip, "Gemfile (no RSpec or Minitest files here to import as cold cases)", :blue
          return
        end

        if gemfile_contents.match?(/^\s*group\s+:cold_case\b/)
          say_status :identical, "Gemfile (:cold_case group already present)", :blue
          return
        end

        gems = cold_case_gems_to_add
        if gems.empty?
          say_status :skip, "Gemfile (every cold-case engine is already declared)", :blue
          return
        end

        append_to_file "Gemfile", "\n#{cold_case_group(gems)}"
      end

      # The blotter must not be committed. Appended rather than templated, because an app
      # always has a .gitignore already and ours is two lines of it.
      def ignore_the_blotter
        path = File.join(destination_root, ".gitignore")

        unless File.exist?(path)
          create_file ".gitignore", GITIGNORE_ENTRY
          return
        end

        if File.read(path).include?("/.constable/*.sqlite3")
          say_status :identical, ".gitignore (blotter already ignored)", :blue
          return
        end

        append_to_file ".gitignore", "\n#{GITIGNORE_ENTRY}"
      end

      # An app that already lints has opinions in .rubocop.yml worth more than
      # ours. Merge into it; never clobber it.
      def configure_rubocop
        return if options[:skip_rubocop]

        path = File.join(destination_root, ".rubocop.yml")
        return template("rubocop.yml.tt", ".rubocop.yml") unless File.exist?(path)

        existing = File.read(path)
        if existing.include?(RUBOCOP_EXTENSION)
          say_status :identical, ".rubocop.yml (already requires #{RUBOCOP_EXTENSION})", :blue
          return
        end

        create_file ".rubocop.yml", merge_rubocop(existing), force: true
      end

      def print_next_steps
        return if options[:quiet]

        say ""
        say "  Constable is installed.", :green
        say ""
        say "    constable test          run everything changed since the merge-base"
        say "    constable test --full   run the whole suite (this is what CI does)"
        say ""
        say "  test/case_helper.rb is worth reading before you write a case -- it explains"
        say "  the tier base classes, and the two things Constable deliberately doesn't have."
        say ""
      end

      private

      # An engine earns a line only if this repo has files for it and the Gemfile does not
      # already declare it.
      def cold_case_gems_to_add
        COLD_CASE_GEMS.filter_map do |engine, gem_name|
          next unless legacy_files?(engine)
          next if gem_declared?(gem_name)

          gem_name
        end
      end

      def cold_case_group(gems)
        lines = gems.map { |gem_name| %(  gem "#{gem_name}") }
        "#{COLD_CASE_HEADER}group :cold_case do\n#{lines.join("\n")}\nend\n"
      end

      # Matches `gem "rspec-rails"` and `gem 'rspec-rails', "~> 8.0"` alike, and ignores a
      # commented-out line, which is a suggestion rather than a declaration.
      def gem_declared?(gem_name)
        gemfile_contents.each_line.any? do |line|
          stripped = line.strip
          next false if stripped.start_with?("#")

          stripped.match?(/\Agem\s+["']#{Regexp.escape(gem_name)}["']/)
        end
      end

      # Blocks in the shipped reference whose settings the existing file never mentions.
      # A "block" is a run of lines between blank ones: the comment and the setting it
      # explains travel together, because a bare key with no reasoning is not a reference.
      def missing_config_blocks(existing)
        present = config_keys_in(existing)

        reference_blocks.select do |block|
          keys = config_keys_in(block)
          keys.any? && (keys - present) == keys
        end
      end

      def reference_blocks
        File.read(find_in_source_paths("config.yml.tt")).split(/\n{2,}/).map(&:rstrip).reject(&:empty?)
      end

      # Top-level YAML keys only, ignoring comments and nested ones -- a commented-out
      # example is a suggestion, not a declaration.
      def config_keys_in(text)
        text.lines.filter_map do |line|
          match = line.match(/\A([a-z][a-z0-9_]*):/)
          match && match[1]
        end.uniq
      end

      def gemfile_contents
        File.read(File.join(destination_root, "Gemfile"))
      end

      # "Is there anything here to import?" -- any RSpec or Minitest file at all.
      # Native Constable cases are named *_case.rb, so the example this generator
      # just wrote can never be mistaken for a legacy suite.
      def legacy_suite_present?
        Dir.glob(File.join(destination_root, "{spec,test}/**/*_{spec,test}.rb")).any?
      end

      def legacy_files?(engine)
        Dir.glob(File.join(destination_root, LEGACY_GLOBS.fetch(engine))).any?
      end

      # A textual merge, not a YAML round trip: parsing and re-emitting someone's
      # .rubocop.yml would silently eat every comment in it, and comments in a
      # lint config are usually the reason a rule is there at all.
      def merge_rubocop(existing)
        lines = existing.lines

        # `require:` heading an indented list -- append one more item to the end
        # of it, so load order for everything already there is unchanged.
        index = lines.index { |line| line.match?(/\Arequire:[ \t]*(#.*)?$/) }
        if index
          last   = index
          indent = "  "
          ((index + 1)...lines.length).each do |i|
            item = lines[i].match(/\A([ \t]+)-[ \t]/)
            break unless item || lines[i].match?(/\A[ \t]*#/)
            next unless item

            last   = i
            indent = item[1]
          end
          lines.insert(last + 1, "#{indent}- #{RUBOCOP_EXTENSION}\n")
          return lines.join
        end

        # `require: some-extension` on one line -- promote it to a list of both.
        index = lines.index { |line| line.match?(/\Arequire:[ \t]*[^\s#]/) }
        if index
          current = lines[index].sub(/\Arequire:[ \t]*/, "").sub(/[ \t]*#.*\z/m, "").strip
          lines[index] = "require:\n  - #{current}\n  - #{RUBOCOP_EXTENSION}\n"
          return lines.join
        end

        # No `require:` at all -- append the whole snippet, existing file intact.
        "#{existing.chomp}\n\n#{File.read(File.join(self.class.source_root, "rubocop.yml.tt"))}"
      end
    end
  end
end
