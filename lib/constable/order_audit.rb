# frozen_string_literal: true

module Constable
  # Catches the test that only passes because something else ran first.
  #
  # A new or changed investigation is run twice in CI: once completely alone, in its own
  # forked process before the suite has touched anything, and once in ordinary full-suite
  # context. The two answers should agree. When they don't, the test is depending on state
  # it never set up, and that is a failure now rather than a mystery three months from now
  # when someone reorders a file.
  #
  # Only new and changed investigations are audited, because identity is a content hash:
  # an unchanged body keeps its hash, and a body that already passed this audit does not
  # need to pay for it on every future run.
  class OrderAudit
    MESSAGE = "ORDER DEPENDENT TEST"

    attr_reader :config, :storage

    def initialize(config: Constable.config, storage: Constable.storage, enabled: nil)
      @config  = config
      @storage = storage
      @enabled = enabled.nil? ? ci? : enabled
      @isolated = {}
    end

    def enabled? = @enabled && Process.respond_to?(:fork)

    def ci? = !ENV["CI"].to_s.empty?

    # Investigations whose content hash the blotter has never seen -- new tests, or tests
    # whose body actually changed.
    def candidates(investigations)
      return [] unless enabled?

      known = begin
        @storage.known_identities.map { |entry| entry[:identity] }
      rescue StandardError
        []
      end
      investigations.reject { |inv| known.include?(inv.identity) }
    end

    # The "alone" half of the audit. Runs before the suite so each child inherits a process
    # that has not yet run a single test.
    def record_isolated!(investigations)
      candidates(investigations).each do |investigation|
        @isolated[investigation.identity] = run_alone(investigation)
      end
      @isolated
    end

    # The "in context" half. Returns the results rewritten to failures where the two
    # answers disagree.
    def audit(results)
      return results if @isolated.empty?

      results.map do |result|
        expected = @isolated[result.identity]
        next result if expected.nil?
        next result if expected == simple_status(result)

        order_dependent(result, expected)
      end
    end

    def order_dependent?(result)
      expected = @isolated[result.identity]
      !expected.nil? && expected != simple_status(result)
    end

    private

    def simple_status(result)
      result.passed? ? :passed : :failed
    end

    def order_dependent(result, isolated_status)
      in_suite = simple_status(result)
      result.status = :failed
      result.failure = Failure.new(
        message: "#{MESSAGE}: passed #{describe(isolated_status)} but #{describe(in_suite)} " \
                 "in full-suite context. This investigation depends on state another test " \
                 "leaves behind rather than on its own briefing.",
        context: "alone: #{isolated_status}\nin suite: #{in_suite}",
        backtrace: []
      )
      result
    end

    def describe(status)
      status == :passed ? "alone" : "failed alone"
    end

    # Forks a child that runs exactly one investigation and reports back a single byte.
    # A crash in the child is a failure, not a hang in the parent.
    def run_alone(investigation)
      reader, writer = IO.pipe

      pid = fork do
        reader.close
        instance = Case.constable_instance_for(investigation)
        status =
          begin
            Isolation.with_rollback(investigation.tier) { instance.run_investigation(investigation) }
            "P"
          rescue StandardError
            "F"
          ensure
            instance._constable_dsl_teardown if instance.respond_to?(:_constable_dsl_teardown)
          end
        writer.write(status)
        writer.close
        exit!(0)
      end

      writer.close
      byte = reader.read
      reader.close
      Process.waitpid(pid)

      byte == "P" ? :passed : :failed
    rescue StandardError
      nil
    end
  end
end
