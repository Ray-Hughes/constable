# frozen_string_literal: true

require "yaml"
require "etc"

module Constable
  # Settings, as opposed to code. Everything here comes from .constable/config.yml
  # and may be overridden per-run by CLI flags. Code-level configuration (matchers,
  # tier base classes, one-time global setup) lives in test/case_helper.rb instead.
  class Config
    DEFAULTS = {
      "cold_cases" => [],
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
      "tiers" => {
        "unit" => "test/cases/models/**/*",
        "integration" => "test/cases/controllers/**/*",
        "system" => "test/cases/system/**/*"
      }
    }.freeze

    CONFIG_PATH = ".constable/config.yml"

    attr_reader :root, :raw

    def self.load(root: Constable.root, overrides: {})
      path = File.join(root.to_s, CONFIG_PATH)
      new(read_file(path), root: root, overrides: overrides)
    end

    # A typo in config.yml used to surface as a raw Psych::SyntaxError, or -- for a file
    # that parsed but wasn't a mapping -- as "no implicit conversion of Array into Hash"
    # from somewhere deep in the merge. Neither says which file to open.
    def self.read_file(path)
      return {} unless File.exist?(path)

      loaded = YAML.safe_load_file(path, permitted_classes: [], aliases: true)
      return {} if loaded.nil?

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

    def cold_cases         = Array(@raw["cold_cases"])
    def warrants?          = truthy(@raw["warrants"])
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
    OUTPUT_MODES = %i[concise expanded].freeze

    def output_mode
      mode = @raw["output"].to_s.strip.downcase.to_sym
      OUTPUT_MODES.include?(mode) ? mode : :concise
    end

    def expanded_output? = output_mode == :expanded
    def storage            = @raw["storage"] || {}

    def storage_adapter = (storage["adapter"] || "sqlite").to_s
    def storage_url     = storage["url"]

    def storage_path
      path = storage["path"] || DEFAULTS["storage"]["path"]
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

    def cold_case?(path)
      relative = path.to_s.delete_prefix("#{@root}/")
      cold_cases.any? do |glob|
        File.fnmatch?(glob.to_s, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
          File.fnmatch?(glob.to_s, path.to_s, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
    end

    def [](key) = @raw[key.to_s]
    def to_h    = @raw.dup

    private

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
