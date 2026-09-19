# frozen_string_literal: true

require "helper"
require "json"

module Constable
  # A timings file is how a CI matrix balances by time without its shards disagreeing:
  # one file, merged from what every shard measured, read by every shard of the next run.
  class TimingsTest < TestCase
    Item = Struct.new(:label)

    def write_timings(name, files: {}, tests: {}, partition: nil)
      data = { "format" => Timings::FORMAT, "files" => files, "tests" => tests }
      data["partition"] = partition if partition
      Timings.write(File.join(tmp_root, name), data)
    end

    def test_a_timings_file_round_trips
      path = write_timings("t.json", files: { "spec/a_spec.rb" => 12.5 }, tests: { "abc" => 0.25 })

      assert_equal({ files: { "spec/a_spec.rb" => 12.5 }, tests: { "abc" => 0.25 } }, Timings.load(path))
    end

    # Every shard must read the same thing. A missing or unreadable file is "no timings",
    # never a partial read one machine sees and another does not.
    def test_a_missing_or_foreign_file_is_no_timings
      assert_nil Timings.load(nil)
      assert_nil Timings.load(File.join(tmp_root, "missing.json"))
      assert_nil Timings.load(write_file("bad.json", "{not json"))
      assert_nil Timings.load(write_file("old.json", JSON.generate("format" => 99)))
    end

    def test_merge_unions_every_shard_and_collects_partitions
      a = write_timings("a.json", files: { "a" => 1.0 }, partition: { "shard" => "1/2", "fingerprint" => "x" })
      b = write_timings("b.json", files: { "b" => 2.0 }, partition: { "shard" => "2/2", "fingerprint" => "x" })

      merged = Timings.merge([a, b])

      assert_equal({ "a" => 1.0, "b" => 2.0 }, merged["files"])
      assert_equal 2, merged["partitions"].size
      assert_empty Timings.disagreements(merged["partitions"])
    end

    def test_shards_that_divided_the_suite_differently_are_named
      partitions = [{ "shard" => "1/2", "fingerprint" => "x" }, { "shard" => "2/2", "fingerprint" => "y" },
                    { "shard" => "1/4", "fingerprint" => "z" }, { "shard" => "2/4", "fingerprint" => "z" }]

      assert_equal ["2"], Timings.disagreements(partitions).keys
    end

    def test_the_fingerprint_follows_items_and_weights_not_their_order
      a = Item.new("a")
      b = Item.new("b")

      assert_equal Timings.fingerprint([a, b], { a => 1.0 }), Timings.fingerprint([b, a], { a => 1.0 })
      refute_equal Timings.fingerprint([a, b], { a => 1.0 }), Timings.fingerprint([a, b], { a => 2.0 })
      refute_equal Timings.fingerprint([a, b], {}), Timings.fingerprint([a], {})
    end

    def test_merge_command_writes_one_file_and_refuses_a_disagreeing_matrix
      a = write_timings("a.json", files: { "a" => 1.0 }, partition: { "shard" => "1/2", "fingerprint" => "x" })
      b = write_timings("b.json", files: { "b" => 2.0 }, partition: { "shard" => "2/2", "fingerprint" => "x" })
      out = File.join(tmp_root, "merged.json")

      capture_stdout { CLI::TimingsCommand.new.merge(out, a, b) }
      assert_equal({ "a" => 1.0, "b" => 2.0 }, JSON.parse(File.read(out))["files"])

      c = write_timings("c.json", files: { "c" => 3.0 }, partition: { "shard" => "2/2", "fingerprint" => "y" })
      error = assert_raises(Constable::Error) { capture_stdout { CLI::TimingsCommand.new.merge(out, a, c) } }
      assert_includes error.message, "did not divide the suite the same way"
      assert_path_exists out, "the merged file is still written, so the next run is not left without one"
    end

    # The guarantee the whole feature rests on: shards reading one timings file divide the
    # suite identically -- same fingerprint, and between them every file exactly once.
    def test_shards_reading_one_timings_file_partition_identically_and_completely
      write_config("storage:\n  adapter: sqlite\n  path: .constable/constable.sqlite3\n")
      names = %w[alpha bravo charlie delta echo foxtrot]
      names.each do |name|
        body = "  describe(#{name.inspect}) { it(\"runs\") {} }"
        write_file("spec/#{name}_spec.rb", "class Legacy#{name.capitalize}Spec < Constable::ColdCase::RSpec\n#{body}\nend\n")
      end
      timings = write_timings("timings.json", files: { "spec/alpha_spec.rb" => 100.0, "spec/bravo_spec.rb" => 90.0 })

      runs = (1..3).map do |index|
        runner = Runner.new(selection: Selection.new([], config: Constable.config, root: tmp_root, full: true),
                            config: Constable.config, storage: Constable.storage,
                            reporter: Reporter.new(io: StringIO.new, config: Constable.config, color: false),
                            shard: Shard.new(index: index, total: 3), shard_by_time: true, timings: timings)
        runner.call
        [runner.partition_fingerprint, runner.results.map(&:file).uniq]
      end

      assert_equal 1, runs.map(&:first).uniq.size, "every shard must compute the same partition"
      files = runs.flat_map(&:last)
      assert_equal names.map { |n| "spec/#{n}_spec.rb" }.sort, files.sort, "every file exactly once"
      long = %w[spec/alpha_spec.rb spec/bravo_spec.rb]
      heavy = runs.map(&:last).select { |slice| slice.intersect?(long) }
      assert_equal 2, heavy.size, "the two long files were given to different shards"
    end
  end
end
