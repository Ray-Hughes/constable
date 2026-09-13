# frozen_string_literal: true

module Constable
  # Loading an adopted suite's support files.
  #
  # A converted file moves from RSpec's engine to Constable's, and the helpers it calls have
  # to come with it. On the suite this was written against, 32 modules live in spec/support
  # and 2 in test/support -- so a file could convert cleanly, parse, and then fail at runtime
  # on a method that was never loaded. `ama_test_start_date` is not a conversion bug; it is a
  # helper that stayed behind.
  #
  # The rule is one line long: **a file that calls `RSpec.configure` is configuring RSpec**,
  # and Constable is not RSpec. Those four were, on that suite, database cleaning, Capybara,
  # cache clearing and timezone -- every one of them a concern Constable already owns, with
  # its own transaction, its own system-tier support, its own isolation. Loading them would
  # either fail or install a second, conflicting answer.
  #
  # Everything else is a plain Ruby module and loads.
  #
  #   Constable.load_support("test/support/**/*.rb", "spec/support/**/*.rb")
  #
  # Skips are recorded rather than silent: a helper that quietly did not load is the failure
  # this exists to prevent, so `skipped` says what was left out and why.
  module SupportFiles
    CONFIGURES_RSPEC = /RSpec\.configure\b/
    CONFIGURES_MINITEST = /Minitest\.after_run\b|Minitest::Test\.(?:extend|include)\b/

    class << self
      # [[path, reason], ...] for everything deliberately not loaded.
      def skipped = (@skipped ||= [])

      # Modules the loaded files defined, in load order.
      #
      # Loading a helper is only half of it. RSpec does the other half with
      # `config.include SomeHelper`, and without an equivalent the module exists and no case
      # can call it -- which surfaces as `undefined local variable` on a method that is
      # plainly right there in the file. So the modules are reported, and the generated
      # case_helper shows where to include them.
      def defined_modules = (@defined_modules ||= [])

      def reset!
        skipped.clear
        defined_modules.clear
      end

      # Sorted, because Dir[] returns filesystem order and that differs between a laptop and
      # CI -- a support file that loads in a different order is an order dependence nobody
      # chose.
      def load(*globs, root: Constable.root)
        reset!
        expand(globs, root).each { |path| load_one(path, root) }
        warn_about_skips!
        skipped
      end

      private

      def expand(globs, root)
        globs.flatten.flat_map { |glob| Dir[File.join(root.to_s, glob)] }.uniq.sort
      end

      def load_one(path, root)
        relative = path.delete_prefix("#{root}/")
        reason = framework_config_reason(path)
        return skipped << [relative, reason] if reason

        before = module_names
        require path
        defined_modules.concat(module_names - before)
      rescue StandardError, ScriptError => e
        # Naming the file matters more than the backtrace: the failure is almost always
        # "this helper assumes something RSpec set up", and the answer is to look at it.
        raise Constable::Error,
              "#{relative} could not be loaded as a support file -- #{e.class}: #{e.message}. " \
              "It may depend on something only RSpec provides. Move what a case needs into a " \
              "plain module, or leave the specs that use it as cold cases."
      end

      # Top-level modules only -- a helper is nearly always one, and walking every namespace
      # to catch the rest would cost more than it finds.
      def module_names
        Object.constants.select do |name|
          value = Object.const_get(name)
          value.instance_of?(Module)
        rescue StandardError
          false
        end
      end

      def framework_config_reason(path)
        source = File.read(path)
        if source.match?(CONFIGURES_RSPEC)
          "configures RSpec -- Constable owns the transaction, isolation and system-tier setup itself"
        elsif source.match?(CONFIGURES_MINITEST)
          "configures Minitest directly"
        end
      rescue StandardError
        nil
      end

      # Once, with a count, not one line per file. The detail is in `skipped` for anyone who
      # needs it.
      def warn_about_skips!
        return if skipped.empty?

        Constable.warn!(
          "#{skipped.size} support file(s) were not loaded because they configure another " \
          "framework: #{skipped.map(&:first).join(", ")}. Constable provides those concerns " \
          "itself. Anything a case actually calls should live in a plain module."
        )
      end
    end
  end
end
