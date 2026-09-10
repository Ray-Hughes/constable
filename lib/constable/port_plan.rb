# frozen_string_literal: true

module Constable
  # What `constable modernize --port` would do, before it does any of it.
  #
  # `modernize` already writes nothing without a write flag, so a dry run was always
  # available -- but "writes nothing" is not a plan. A plan answers the questions someone
  # actually has before moving four hundred files: where does each one land, how many
  # convert versus move verbatim, what is standing in the way, and how long will the result
  # take to run.
  #
  # The runtime estimate is the one number here that is not free. It comes from the blotter:
  # Constable already records an average duration per test to balance parallel workers, and
  # joining that to each test's current file says what these files cost today. It is an
  # estimate of the *tests*, not of the port, and it says so -- a suite that has never been
  # run has no answer and gets none invented for it.
  class PortPlan
    Entry = Struct.new(:source, :destination, :form, :flags, :tests, :seconds, keyword_init: true)

    def initialize(results, storage:, root:, delete: false, base: nil)
      @results = results
      @storage = storage
      @root = root.to_s
      @delete = delete
      @base = base
    end

    attr_reader :delete, :base

    def entries
      @entries ||= @results.map do |result|
        source = result.relative_path
        timing = timings[source] || {}
        Entry.new(
          source: source,
          destination: destination_for(result),
          form: result.flagged? ? :cold : :native,
          flags: Array(result.flags).size,
          tests: timing[:tests],
          seconds: timing[:seconds]
        )
      end
    end

    def native = entries.count { |e| e.form == :native }
    def cold   = entries.count { |e| e.form == :cold }

    def measured = entries.select(&:tests)
    def unmeasured = entries.reject(&:tests)

    def total_tests   = measured.sum { |e| e.tests.to_i }
    def total_seconds = measured.sum { |e| e.seconds.to_f }

    # What this suite spends per test outside the test body, measured from its own largest
    # recorded run. nil when nothing has been measured here -- the caller says so rather
    # than inventing a number.
    def overhead
      return @overhead if defined?(@overhead)

      @overhead = begin
        @storage.overhead_per_test
      rescue StandardError
        nil
      end
    end

    def projected_seconds
      return nil unless overhead

      total_seconds + (overhead[:seconds] * total_tests)
    end

    # Why each file that cannot convert cannot convert, most common first.
    def blockers
      @results.flat_map { |r| Array(r.flags) }
              .group_by { |f| f[:kind] }
              .transform_values(&:size)
              .sort_by { |_, n| -n }
    end

    private

    def timings
      @timings ||= @storage.average_seconds_by_file
    rescue StandardError
      {}
    end

    def destination_for(result)
      Constable::Importer::Modernizer.port_path(result.path, @root).delete_prefix("#{@root}/")
    end
  end
end
