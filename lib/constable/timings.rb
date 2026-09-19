# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module Constable
  # Recorded durations as a file that can travel between CI machines.
  #
  # `--shard-by-time` balances a CI matrix by how long things took, and it is only correct
  # when every machine computes the same partition -- so every machine has to read the
  # same numbers. A blotter cannot promise that: each shard writes to its own, and one
  # restored from a cache is whatever the cache held when that machine asked. A timings
  # file can: one job merges what every shard measured, and every shard of the next run
  # reads that one file.
  #
  #   { "format": 1,
  #     "files": { "test/cases/models/user_case.rb": 12.4 },   # cold cases: seconds per file
  #     "tests": { "<identity>": 0.8 },                         # native: seconds per test
  #     "partition": { "shard": "3/12", "fingerprint": "..." } }
  module Timings
    FORMAT = 1

    module_function

    # What this machine's blotter knows, ready to write.
    def export(storage, partition: nil)
      files = storage.average_seconds_by_file.transform_values { |row| row[:seconds].to_f.round(3) }
      tests = storage.duration_index.transform_values { |seconds| seconds.to_f.round(3) }
      out = { "format" => FORMAT, "files" => files.sort.to_h, "tests" => tests.sort.to_h }
      out["partition"] = partition if partition
      out
    end

    def write(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(data))
      path
    end

    # { files: {...}, tests: {...} }, or nil when there is no usable file -- which the caller
    # must treat the same way on every machine, or the partitions diverge.
    def load(path)
      return nil if path.nil? || !File.file?(path)

      data = JSON.parse(File.read(path))
      return nil unless data.is_a?(Hash) && data["format"] == FORMAT

      { files: data["files"].to_h.transform_values(&:to_f), tests: data["tests"].to_h.transform_values(&:to_f) }
    rescue JSON::ParserError
      nil
    end

    # One file from many. Each shard measured a different slice, so the keys barely overlap;
    # where they do, the later file wins. Partitions are collected so a merge can check that
    # the shards agreed on how the suite was divided.
    def merge(paths)
      paths.each_with_object({ "format" => FORMAT, "files" => {}, "tests" => {}, "partitions" => [] }) do |path, out|
        data = JSON.parse(File.read(path))
        raise Constable::Error, "#{path} is not a timings file this Constable can read" unless data["format"] == FORMAT

        out["files"].merge!(data["files"].to_h)
        out["tests"].merge!(data["tests"].to_h)
        out["partitions"] << data["partition"] if data["partition"]
      end
    end

    # The shards of one matrix that disagree about the partition, by total. Empty when they
    # all agree. A disagreement means some tests may have run twice and others not at all.
    def disagreements(partitions)
      partitions.group_by { |p| p["shard"].to_s.split("/").last }
                .select { |_total, group| group.map { |p| p["fingerprint"] }.uniq.size > 1 }
    end

    # Identical on every machine that divides the same items by the same weights, and on no
    # machine that does not -- printed by each shard so they can be compared.
    # Labels relative to the root, so two machines that checked out to different paths still
    # compare equal when they divided the suite the same way.
    def fingerprint(items, weights)
      root = "#{Constable.root}/"
      lines = items.map do |item|
        "#{item.label.to_s.delete_prefix(root)}\t#{format("%.3f", weights.fetch(item, 0.0))}"
      end
      Digest::SHA256.hexdigest(lines.sort.join("\n"))[0, 12]
    end
  end
end
