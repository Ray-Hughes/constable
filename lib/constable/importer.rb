# frozen_string_literal: true

module Constable
  # Adoption, in two modes with very different risk profiles.
  #
  # **Reopen** is the default and it is verbatim. A file's body is never read, parsed or
  # rewritten -- it is either wrapped in `class Legacy... < Constable::ColdCase::RSpec`
  # (one line above, one line below, original bytes in between) or, better still, matched
  # by a glob in `.constable/config.yml` so no file is touched at all. The reason this is
  # the default and not the fallback: an AST rewrite can silently change what a test
  # asserts and still parse, compile and pass. A superclass swap cannot. The worst case
  # for reopen is a file that runs exactly as it did yesterday.
  #
  # **Modernize** is the opt-in AST rewrite into the native DSL, one file at a time, and
  # it is deliberately partial. Anything it cannot convert with certainty is *flagged* --
  # written into `constable_modernize_report.md` for a human, never guessed at. It writes
  # nothing by default.
  module Importer
    autoload :Modernizer, "constable/importer/modernizer"
    autoload :Reopener,   "constable/importer/reopener"

    module_function

    # The `constable import --from=rspec` entry point.
    #
    #   from:     :rspec | :minitest
    #   config:   a Constable::Config (used for its root and existing cold_cases globs)
    #   root:     project root; defaults to the config's root
    #   paths:    explicit files/dirs/globs to import; nil discovers them for the engine
    #   strategy: :auto (default) | :config | :superclass
    #   dry_run:  true reports exactly what would change and writes nothing
    #
    # Returns a Reopener::Result describing every glob added, every file rewritten and
    # every file deliberately skipped.
    def run(from:, config: Constable.config, root: nil, paths: nil, strategy: :auto, dry_run: false)
      Reopener.new(from: from, config: config, root: root, paths: paths,
                   strategy: strategy, dry_run: dry_run).call
    end

    # Same as #run but guaranteed not to touch anything -- the "show me first" call.
    def plan(from:, config: Constable.config, root: nil, paths: nil, strategy: :auto)
      run(from: from, config: config, root: root, paths: paths, strategy: strategy, dry_run: true)
    end

    # The `constable modernize PATH` entry point. Dry run unless `write:` says otherwise;
    # see Modernizer::WRITE_MODES.
    def modernize(paths, config: Constable.config, root: nil, write: :none, report: true, base: nil,
                  delete_original: false)
      Modernizer.run(paths, config: config, root: root, write: write, report: report, base: base,
                            delete_original: delete_original)
    end
  end
end
