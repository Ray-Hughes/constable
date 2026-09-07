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
      raw  = File.exist?(path) ? (YAML.safe_load_file(path, permitted_classes: [], aliases: true) || {}) : {}
      new(raw, root: root, overrides: overrides)
    end

    def initialize(raw = {}, root: Constable.root, overrides: {})
      @root = root.to_s
      @raw  = deep_merge(DEFAULTS, stringify(raw || {}))
      @raw  = deep_merge(@raw, stringify(overrides || {}))
    end

    def cold_cases         = Array(@raw["cold_cases"])
    def warrants?          = truthy(@raw["warrants"])
    def warrant_retries    = @raw["warrant_retries"].to_i
    def auto_relink?       = truthy(@raw["auto_relink"])
    def parole_period      = @raw["parole_period"].to_i
    def coverage?          = truthy(@raw["coverage"])
    def coverage_threshold = @raw["coverage_threshold"].to_i
    def coverage_html?     = truthy(@raw["coverage_html"])
    def fail_on_warnings?  = truthy(@raw["fail_on_warnings"])
    def tiers              = @raw["tiers"] || {}
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
