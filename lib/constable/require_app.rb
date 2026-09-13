# frozen_string_literal: true

module Constable
  # `require_app "services/thing"` -- a file in this app, named from the app root.
  #
  # A ported spec often carries `require_relative "../../app/services/thing"`, and a port
  # moves the file, so the path is wrong by however many directories it moved. Repointing it
  # gives `"../../../../app/services/thing"`: correct, unreadable, and wrong again on the
  # next move.
  #
  # `require Rails.root.join("app/services/thing").to_s` is right and survives moving, and is
  # a mouthful to type and to read. This is that, spelled shorter.
  #
  #   require_app "services/thing"        # app/services/thing.rb
  #   require_app "app/services/thing"    # the same -- an app/ prefix is optional
  #   require_app "lib/tasks/thing"       # anything else is taken from the root as written
  #
  # Worth knowing before reaching for it: in a Rails app, most of these are unnecessary.
  # Zeitwerk autoloads `app/`, so the constant resolves without any require at all -- that
  # was verified on a real suite, where removing two of them changed nothing. It earns its
  # place for the paths Zeitwerk does not own: a non-standard directory, a file whose name
  # does not match its constant, or an app with eager loading off in test.
  module RequireApp
    def require_app(path)
      Kernel.require(Constable::RequireApp.resolve(path))
    end

    # "services/thing" -> "<root>/app/services/thing.rb", when that exists.
    def self.resolve(path)
      name = path.to_s.delete_suffix(".rb")
      root = defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : Constable.root

      candidates = ["#{name}.rb"]
      candidates.unshift("app/#{name}.rb") unless name.start_with?("app/")

      found = candidates.find { |candidate| File.file?(File.join(root, candidate)) }
      return File.join(root, found) if found

      raise Constable::Error,
            "require_app(#{path.inspect}) found nothing. Looked for " \
            "#{candidates.join(" and ")} under #{root}. Paths are named from the app root, " \
            "and the app/ prefix is optional."
    end
  end
end

# On Object rather than only inside a case: these requires sit at the top of a file, outside
# any class body, which is where `require_relative` was.
Object.include(Constable::RequireApp)
