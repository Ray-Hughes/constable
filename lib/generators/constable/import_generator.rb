# frozen_string_literal: true

require "rails/generators/base"
require "constable"

module Constable
  module Generators
    # `rails generate constable:import --from=rspec`
    #
    # A thin front door onto Constable::Importer, for people who reach for
    # `rails generate` before `constable import`. The two are the same operation;
    # this one exists so the install step and the import step are spelled the
    # same way.
    #
    # The default strategy is "reopen": files become Constable::ColdCase::*
    # subclasses (a superclass swap, or a zero-file-change glob in config) and run
    # immediately, verbatim, through their own engine. Nothing is rewritten and
    # nothing can be broken by a bad conversion. The AST rewrite into the native
    # DSL is a separate, opt-in step -- `constable modernize PATH` -- taken one
    # file at a time once the suite is already green under Constable.
    class ImportGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      SOURCES    = %w[rspec minitest].freeze
      STRATEGIES = %w[reopen modernize].freeze

      desc <<~DESC
        Imports an existing RSpec or Minitest suite as cold cases. The default "reopen"
        strategy changes no test code: files run verbatim through their own engine, with
        pass/fail/timing merged into Constable's reporting, flake history and CI gate.

        Run with --dry-run first to see exactly which files would be touched.
      DESC

      class_option :from, type: :string, default: "rspec",
                          desc: "Which suite to import: #{SOURCES.join(" | ")}"
      class_option :strategy, type: :string, default: "reopen",
                              desc: "#{STRATEGIES.join(" | ")} -- reopen is verbatim, modernize rewrites"
      class_option :dry_run, type: :boolean, default: false,
                             desc: "Report what would happen without writing anything"

      def import
        validate_options!
        report(invoke_importer)
      end

      private

      def validate_options!
        unless SOURCES.include?(options[:from])
          raise Thor::Error, "--from must be one of #{SOURCES.join(", ")} (got #{options[:from].inspect})"
        end

        return if STRATEGIES.include?(options[:strategy])

        raise Thor::Error, "--strategy must be one of #{STRATEGIES.join(", ")} (got #{options[:strategy].inspect})"
      end

      def importer_arguments
        {
          from: options[:from].to_sym,
          config: Constable.config,
          dry_run: options[:dry_run],
          strategy: options[:strategy].to_sym
        }
      end

      # The importer is built independently of this generator, so the call site
      # checks the contract instead of assuming it. A signature that has drifted
      # should read as "the importer changed shape, here is how" -- not as an
      # ArgumentError from three frames down with no indication of whose fault
      # it is.
      def invoke_importer
        importer = load_importer!
        assert_signature!(importer)
        importer.run(**importer_arguments)
      rescue ArgumentError => e
        raise Thor::Error, <<~MSG.chomp
          Constable::Importer.run rejected the arguments this generator passes
          (#{importer_arguments.keys.map(&:inspect).join(", ")}): #{e.message}

          The generator and the importer have drifted apart. Fix the call in
          lib/generators/constable/import_generator.rb to match Importer.run.
        MSG
      end

      def load_importer!
        importer = Constable::Importer
        return importer if importer.respond_to?(:run)

        raise Thor::Error, "Constable::Importer does not respond to .run -- this build of the gem is incomplete."
      rescue LoadError, NameError => e
        raise Thor::Error, "Constable::Importer could not be loaded (#{e.class}: #{e.message})."
      end

      def assert_signature!(importer)
        parameters = importer.method(:run).parameters
        return if parameters.any? { |type, _| type == :keyrest } # **opts swallows anything

        accepted = parameters.filter_map { |type, name| name if %i[key keyreq].include?(type) }
        missing  = importer_arguments.keys - accepted
        required = parameters.filter_map { |type, name| name if type == :keyreq }
        unfilled = required - importer_arguments.keys

        return if missing.empty? && unfilled.empty?

        lines = ["Constable::Importer.run has a different signature than this generator expects.",
                 "  generator passes: #{importer_arguments.keys.map(&:inspect).join(", ")}",
                 "  importer accepts: #{accepted.map(&:inspect).join(", ")}"]
        lines << "  not accepted:     #{missing.map(&:inspect).join(", ")}" unless missing.empty?
        lines << "  required, unset:  #{unfilled.map(&:inspect).join(", ")}" unless unfilled.empty?
        lines << "Fix the call in lib/generators/constable/import_generator.rb to match Importer.run."

        raise Thor::Error, lines.join("\n")
      end

      # The importer owns the detail of what it did; this only makes sure the run
      # says something, since a generator that prints nothing reads as a generator
      # that did nothing.
      def report(result)
        return if options[:quiet]

        say ""
        if options[:dry_run]
          say "  Dry run -- nothing was written.", :yellow
        else
          say "  Imported #{options[:from]} as cold cases (strategy: #{options[:strategy]}).", :green
        end
        say "  #{result}" if result.is_a?(String) && !result.empty?
        say ""
        say "  Every cold-case file is reported as a warning on every run -- one per file,"
        say "  not one per test -- until it is either modernized or deliberately kept."
        say ""
      end
    end
  end
end
