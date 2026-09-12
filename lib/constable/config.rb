# frozen_string_literal: true

require "erb"
require "yaml"
require "etc"

module Constable
  # Settings, as opposed to code. Everything here comes from .constable/config.yml
  # and may be overridden per-run by CLI flags. Code-level configuration (matchers,
  # tier base classes, one-time global setup) lives in test/case_helper.rb instead.
  class Config
    DEFAULTS = {
      "timeout" => 0,
      "heartbeat" => 0,
      "slowest" => 5,
      "storage" => { "adapter" => "sqlite", "path" => ".constable/constable.sqlite3", "url" => nil },
      "warrants" => false,
      "warrant_retries" => 5,
      "auto_relink" => false,
      "parole_period" => 10,
      "coverage" => false,
      "coverage_threshold" => 90,
      "coverage_html" => false,
      "fail_on_warnings" => false,
      "output" => "concise",
      "parallel_workers" => "auto",
      "worker_databases" => "schema",
      "jail_flakes" => false,
      # Defaults for `constable modernize`. A port is the same command run over and over
      # against different directories, and repeating four flags each time is how one gets
      # left off -- `--delete` without `--base` ports a whole directory into classes that
      # inherit none of the app's tier setup.
      "modernize" => {
        "base" => nil,
        "port" => false,
        "delete" => false,
        "batch" => nil
      },
      "tiers" => {
        "unit" => "test/cases/models/**/*",
        "integration" => "test/cases/controllers/**/*",
        "system" => "test/cases/system/**/*"
      }
    }.freeze

    CONFIG_PATH = ".constable/config.yml"

    # Your own preferences, layered over the project's.
    #
    # .constable/config.yml is a team agreement: how many workers CI gets, what the coverage
    # gate is, whether flakes are jailed. Answers that have to be the same for everyone or
    # they are not answers. But some of what a test run does is nobody else's business --
    # whether the output is expanded, whether it is coloured, how often it says how long it
    # has been going. Editing a shared file to change those means either committing a
    # preference for the whole team or carrying a dirty file forever.
    #
    # So there is a second file, gitignored, holding only the settings where one developer
    # differing from another costs nothing. `constable config` writes it.
    #
    # The list is deliberately short and deliberately closed. A setting that changes what
    # PASSES is not a preference, and letting it be overridden here would mean a suite that
    # is green on one machine and red on another, with the difference in a file nobody else
    # can see. Those raise rather than being quietly applied.
    PREFERENCES_PATH = ".constable/preferences.yml"

    PREFERENCE_KEYS = %w[output heartbeat color slowest].freeze

    # Settings for `constable modernize`, so a port can be configured once and run as
    # `constable modernize PATH`. A flag on the command line always wins over the file --
    # the file says what this project does by default, the flag says what this invocation
    # does instead.
    def modernize_base    = @raw.dig("modernize", "base")
    def modernize_port?   = truthy(@raw.dig("modernize", "port"))
    def modernize_delete? = truthy(@raw.dig("modernize", "delete"))

    def modernize_batch
      value = @raw.dig("modernize", "batch").to_i
      value.positive? ? value : nil
    end

    attr_reader :root, :raw

    def self.load(root: Constable.root, overrides: {})
      path = File.join(root.to_s, CONFIG_PATH)
      raw = read_file(path)
      raw = deep_merge_hashes(raw, preferences(root))
      new(raw, root: root, overrides: overrides)
    end

    # Read, filtered to what a preference is allowed to be, and loudly refused otherwise.
    # Silently dropping the rest would leave someone staring at a setting they wrote that
    # does nothing.
    def self.preferences(root)
      path = File.join(root.to_s, PREFERENCES_PATH)
      raw = read_file(path)
      return {} if raw.empty?

      unknown = raw.keys.map(&:to_s) - PREFERENCE_KEYS
      unless unknown.empty?
        raise Constable::ConfigurationError,
              "#{PREFERENCES_PATH} sets #{unknown.sort.join(", ")}, which #{unknown.one? ? "is" : "are"} " \
              "not #{unknown.one? ? "a preference" : "preferences"}. That file holds only settings where " \
              "one developer differing from another costs nothing: #{PREFERENCE_KEYS.join(", ")}. " \
              "Anything that changes what passes belongs in #{CONFIG_PATH}, where the rest of the team " \
              "can see it."
      end
      raw
    end

    def self.deep_merge_hashes(base, other)
      base.merge(other) do |_key, a, b|
        a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge_hashes(a, b) : b
      end
    end

    # A typo in config.yml used to surface as a raw Psych::SyntaxError, or -- for a file
    # that parsed but wasn't a mapping -- as "no implicit conversion of Array into Hash"
    # from somewhere deep in the merge. Neither says which file to open.
    def self.read_file(path)
      return {} unless File.exist?(path)

      # ERB first, exactly as Rails does for database.yml. It is what replaces setting a
      # value in Ruby: `parallel_workers: <%= ENV.fetch("CI_WORKERS", 4) %>` computes at
      # load time without needing a second home for settings.
      loaded = YAML.safe_load(ERB.new(File.read(path)).result, permitted_classes: [], aliases: true)
      return {} if loaded.nil?

      if loaded.is_a?(Hash) && loaded.key?("cold_cases")
        raise Constable::ConfigurationError,
              "#{CONFIG_PATH} sets cold_cases, which moved to the Constable.cold_cases block " \
              "in test/case_helper.rb:\n\n    " \
              "Constable.cold_cases do\n      " \
              "rspec \"spec/**/*_spec.rb\"\n    " \
              "end\n\n" \
              "Delete the cold_cases key here and run `constable import --from=rspec` " \
              "(or --from=minitest) to write that file. It lives in the test tree so that " \
              "linking a legacy suite is visible rather than buried in a config key."
      end

      unless loaded.is_a?(Hash)
        raise Constable::Error,
              "#{CONFIG_PATH} must be a mapping of settings, but it parsed as " \
              "#{loaded.class.name.downcase}. Check the indentation."
      end

      loaded
    rescue Psych::SyntaxError => e
      raise Constable::Error, "#{CONFIG_PATH} is not valid YAML: #{e.problem} at line #{e.line}."
    end

    def initialize(raw = {}, root: Constable.root, overrides: {})
      @root = root.to_s
      @raw  = deep_merge(DEFAULTS, stringify(raw || {}))
      @raw  = deep_merge(@raw, stringify(overrides || {}))
    end

    # Merges values set in Ruby (Constable.configure) over the ones read from the file.
    # Called once, after case_helper.rb has been loaded -- which is the first moment those
    # values exist.
    def apply_overrides!(overrides)
      return self if overrides.nil? || overrides.empty?

      @raw = deep_merge(@raw, stringify(overrides))
      self
    end

    def cold_cases         = Array(@raw["cold_cases"])
    def warrants?          = truthy(@raw["warrants"])

    # Should a test that passed last run and failed this one be put on the docket by
    # itself? Off by default, and the reason is what jailing *does*: a jailed test is
    # skipped on every later run. Turning that on automatically means a suite quietly
    # stops running tests nobody chose to stop running.
    #
    # Observed on a real suite: a first `constable test` put 29 tests on a docket the user
    # had never asked for, and every one of them was skipped from then on. A suite with
    # order-dependent tests -- which is most large suites, and exactly the kind Constable
    # is pitched at -- trips this constantly.
    #
    # `constable test --jail` still jails failures, because that is a thing you asked for.
    def jail_flakes?       = truthy(@raw["jail_flakes"])
    # Negative retries are a typo for "off", not an instruction to count backwards.
    def warrant_retries    = [@raw["warrant_retries"].to_i, 0].max
    def auto_relink?       = truthy(@raw["auto_relink"])

    # Clamped here rather than at each call site: Jail already refused a period of zero
    # ("release on sight" is not parole), but the reporter read the raw value and would
    # cheerfully print "Day 1 of 0 -- 0 clean runs to go" while the docket waited for 10.
    def parole_period
      period = @raw["parole_period"].to_i
      period.positive? ? period : DEFAULTS["parole_period"]
    end

    def coverage?          = truthy(@raw["coverage"])
    # Clamped: a threshold above 100 is a build that can never go green, and a negative
    # one is a gate that can never fail. Both are typos rather than intentions.
    def coverage_threshold = @raw["coverage_threshold"].to_i.clamp(0, 100)
    def coverage_html?     = truthy(@raw["coverage_html"])
    def fail_on_warnings?  = truthy(@raw["fail_on_warnings"])
    def tiers              = @raw["tiers"] || {}

    # How much the live stream says while the suite runs.
    #
    #   concise   one glyph per test, grouped into a run per case. The default: a
    #             1,000-test suite stays inside one screen.
    #   expanded  a line per test -- glyph, name, duration. Slower to read in bulk,
    #             but you can see which test is hanging without waiting for the summary.
    #
    # The summary itself is identical either way. This only affects the live stream.
    # How a parallel worker gets a database of its own.
    #
    #   schema  rebuild `<database>_<index>` from schema on every run. What Rails does for
    #           `rails test`, and correct by construction: no drift is possible.
    #   reuse   connect to `<database>_<index>` when it already exists, and build it from
    #           schema only when it does not. Faster -- a large schema is not reloaded on
    #           every run -- and the only option that works for an app whose schema cannot
    #           rebuild the database by itself, which is any app with Postgres custom
    #           types. The cost is that keeping those databases current is now yours.
    #   off     do not shard, so do not fork. An explicit serial run, with no attempt and
    #           no warning.
    WORKER_DATABASE_MODES = %i[schema reuse off].freeze

    # `off` is a YAML 1.1 boolean, so `worker_databases: off` arrives here as `false`
    # rather than the string -- as do `no` and `false`. All three mean the same thing to
    # anyone writing them, so read them that way instead of falling through to :schema.
    def worker_databases
      raw = @raw["worker_databases"]
      return :off if raw == false

      mode = raw.to_s.strip.downcase.to_sym
      WORKER_DATABASE_MODES.include?(mode) ? mode : :schema
    end

    OUTPUT_MODES = %i[concise expanded].freeze

    def output_mode
      mode = @raw["output"].to_s.strip.downcase.to_sym
      OUTPUT_MODES.include?(mode) ? mode : :concise
    end

    def expanded_output? = output_mode == :expanded

    # Readable under its own key as well, so `constable config` can print every preference
    # without a table mapping key names to differently named readers.
    def output = output_mode
    def storage = @raw["storage"] || {}

    # Storage is the one setting that cannot be written in Ruby -- the blotter is opened
    # before test/case_helper.rb loads, so `constable jail` and `constable status` can read
    # the docket without booting the app. That would leave .constable/config.yml mandatory
    # for anyone not on the default SQLite, so the environment can say it instead:
    #
    #   CONSTABLE_STORAGE_URL=postgres://user:pass@host/constable_metadata
    #   CONSTABLE_STORAGE_PATH=/var/lib/constable/blotter.sqlite3
    #
    # Which is also the right shape for CI, where the value is a secret and differs per
    # machine. The environment wins over the file, as an environment usually should.
    def storage_url = env_or("CONSTABLE_STORAGE_URL", storage["url"])

    def storage_adapter
      explicit = env_or("CONSTABLE_STORAGE_ADAPTER", storage["adapter"])
      return explicit.to_s if explicit

      # A URL with no adapter names its own: postgres://... can only mean postgres.
      scheme = storage_url.to_s[%r{\A([a-z][a-z0-9+.-]*)://}, 1]
      return "postgres" if %w[postgres postgresql].include?(scheme)
      return "mysql" if %w[mysql mysql2].include?(scheme)

      "sqlite"
    end

    def storage_path
      path = env_or("CONSTABLE_STORAGE_PATH", storage["path"]) ||
             DEFAULTS["storage"]["path"]
      File.absolute_path?(path) ? path : File.join(@root, path)
    end

    # "auto" resolves to the machine's processor count, minus a little headroom so a
    # developer's laptop stays usable while the suite runs.
    def parallel_workers
      value = @raw["parallel_workers"]
      return [value.to_i, 1].max unless value.nil? || value.to_s == "auto"

      [Etc.nprocessors - 1, 1].max
    end

    # Path-based tier inference. This is the *fallback* -- an explicit `tier :unit`
    # macro or a tiered base class always wins.
    def tier_for(path)
      relative = path.to_s.delete_prefix("#{@root}/")
      tiers.each do |tier, glob|
        next unless glob
        return tier.to_sym if File.fnmatch?(glob.to_s, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
                              File.fnmatch?(glob.to_s, path.to_s, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
      nil
    end

    # Colour, when it is set explicitly. nil means "decide from the terminal", which is the
    # right default and what NO_COLOR and a non-tty already answer.
    def color
      return nil unless @raw.key?("color")

      truthy(@raw["color"])
    end

    # How many rows the SLOWEST section shows.
    def slowest
      count = @raw.fetch("slowest", 5).to_i
      count.negative? ? 0 : count
    end

    # Seconds between "still going" lines during a run. 0 is off.
    def heartbeat
      seconds = @raw["heartbeat"].to_i
      seconds.positive? ? seconds : 0
    end

    # Seconds before a single file is declared hung and failed. 0 is off, which is the
    # default: killing a test mid-flight is a real intervention and should be asked for.
    def timeout
      seconds = @raw["timeout"].to_i
      seconds.positive? ? seconds : 0
    end

    def cold_case_except = Array(@raw["cold_case_except"])

    def cold_case_excluded?(path)
      return false if cold_case_except.empty?

      relative = path.to_s.delete_prefix("#{@root}/")
      cold_case_except.any? do |glob|
        File.fnmatch?(glob.to_s, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
          File.fnmatch?(glob.to_s, path.to_s, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
    end

    def cold_case?(path)
      return false if cold_case_excluded?(path)

      relative = path.to_s.delete_prefix("#{@root}/")
      cold_cases.any? do |glob|
        File.fnmatch?(glob.to_s, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
          File.fnmatch?(glob.to_s, path.to_s, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
    end

    def [](key) = @raw[key.to_s]
    def to_h    = @raw.dup

    private

    # An empty environment variable is not a value. `CONSTABLE_STORAGE_URL=` in a CI
    # config means "unset", not "connect to the empty string".
    def env_or(name, fallback)
      value = ENV.fetch(name, nil)
      value.nil? || value.strip.empty? ? fallback : value.strip
    end

    def truthy(value)
      return false if value.nil? || value == false
      return false if value.to_s.strip.downcase == "false"

      true
    end

    def stringify(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v.is_a?(Hash) ? stringify(v) : v }
    end

    def deep_merge(base, other)
      base.merge(other) do |_key, old, new|
        if old.is_a?(Hash) && new.is_a?(Hash)
          deep_merge(old, new)
        elsif new.nil?
          old
        else
          new
        end
      end
    end
  end
end
