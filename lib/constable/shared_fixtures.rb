# frozen_string_literal: true

module Constable
  # `witness_all` -- a fixture built once for a whole case instead of once per test.
  #
  # Constable's position on this has been that there is no before(:all), and the reason is
  # in every generated case_helper: state built once and handed to many tests is fast right
  # up until one test mutates it, and then you have an order-dependent failure that appears
  # on one machine and is reproducible from nothing written down.
  #
  # That reason still holds, and this is not before(:all). Two differences carry it:
  #
  #   1. The records live in a transaction opened before the case and rolled back after it,
  #      with each investigation in a nested transaction of its own. Nothing a test writes
  #      to the database reaches the next one -- that is test-prof's before_all, which this
  #      delegates to rather than reimplementing.
  #
  #   2. What a rollback cannot undo is a mutation to the Ruby object itself, because every
  #      test is handed the same instance. That is the real hazard, and it is why every
  #      witness_all is re-read from the database before each investigation by default. The
  #      saving is the INSERT, which is the expensive half; the SELECT that makes it safe is
  #      cheap by comparison.
  #
  # So the measured shape is: `let!` converted naively to a lazy `let` on caseflow's
  # user_spec broke 13 of 152 tests and saved 5%, because the tests that skip the fixture
  # are exactly the ones that need it to exist. witness_all keeps it existing and stops
  # paying to build it.
  #
  #   class UserCase < UnitCase
  #     witness_all(:org) { create(:organization) }   # one INSERT for the whole case
  #
  #     investigate "belongs to the org" do
  #       attest(org.users).to include(user)
  #     end
  #   end
  #
  # `reload: false` opts out of the re-read for a fixture nothing mutates, and is worth
  # measuring before assuming it helps.
  module SharedFixtures
    class MissingDependency < Constable::Error
      MESSAGE = "witness_all needs the test-prof gem, which provides the transaction " \
                "handling it depends on. Add `gem \"test-prof\"` to your test group. " \
                "Constable does not vendor it: before_all is subtle enough that a second " \
                "implementation of it would be a liability rather than a convenience."
      def initialize(message = MESSAGE) = super
    end

    def self.available?
      return @available if defined?(@available)

      @available = begin
        require "test_prof/before_all"
        true
      rescue LoadError
        false
      end
    end

    # Whether there is a database to open a transaction against. Same question
    # Isolation#transactional? asks, and the same answer when there isn't: do the work, skip
    # the transaction. A case with no database still runs; its fixture is simply built once
    # and not rolled back, because there is nothing to roll back.
    def self.transactional?
      return false unless defined?(::ActiveRecord::Base)

      ::ActiveRecord::Base.connected? || ::ActiveRecord::Base.connection.present?
    rescue StandardError
      false
    end

    # test-prof needs to be told what to open a transaction on. It ships one adapter and it
    # is the one every Rails app wants, so asking each user to wire it up would be a step
    # that can only be done one way.
    def self.install_adapter!
      return false unless available? && transactional?
      return true if @adapter_installed

      require "test_prof/before_all/adapters/active_record"
      TestProf::BeforeAll.adapter = TestProf::BeforeAll::Adapters::ActiveRecord
      @adapter_installed = true
    rescue LoadError, StandardError
      false
    end

    # Reset between suites so a process that loads test-prof late is not stuck with a
    # cached "no".
    def self.reset! = remove_instance_variable(:@available) if defined?(@available)

    module ClassMethods
      # Built once per case, re-read per investigation.
      def witness_all(name, reload: true, &block)
        raise ArgumentError, "witness_all(#{name.inspect}) requires a block" unless block
        raise MissingDependency unless SharedFixtures.available?

        name = name.to_sym
        guard_witness_name!(name) if respond_to?(:guard_witness_name!, true)
        SharedFixtures.install_adapter!
        own_shared_fixtures[name] = { block: block, reload: reload }

        define_method(name) do
          constable_witnesses.fetch(name) do
            constable_witnesses[name] = self.class.constable_shared_value(name, self)
          end
        end
        name
      end

      def own_shared_fixtures = (@constable_own_shared_fixtures ||= {})

      # constable_lineage is private on Case, so ask for it that way -- `respond_to?` without
      # the second argument says no, and the whole chain silently collapses to [self], which
      # loses every fixture a parent case declared.
      def shared_fixtures
        lineage = respond_to?(:constable_lineage, true) ? send(:constable_lineage) : [self]
        lineage.each_with_object({}) { |klass, out| out.merge!(klass.own_shared_fixtures) }
      end

      def shared_fixtures? = !shared_fixtures.empty?

      # Opened before the first investigation of the case, rolled back after the last, so
      # the rows exist for every test in it and for nothing after it.
      #
      # `begin_transaction` yields, and the setup has to happen inside that yield -- so
      # every fixture in the case is built here, in one pass, rather than lazily on first
      # reference. That is the point anyway: the whole saving is doing these INSERTs once.
      def constable_open_shared_scope!(context = nil)
        return if @constable_shared_open || !shared_fixtures?

        @constable_shared_open = true
        @constable_shared_values = {}
        builder = context || constable_shared_context
        build = lambda do
          shared_fixtures.each do |name, definition|
            @constable_shared_values[name] = builder.instance_exec(&definition[:block])
          end
        end

        if SharedFixtures.install_adapter!
          TestProf::BeforeAll.begin_transaction(&build)
        else
          @constable_shared_untransacted = true
          build.call
        end
      end

      # The fixtures are built before any investigation has an instance of its own, so they
      # need something to run against. A bare instance of the case gives them the same
      # helpers an investigation has -- factories, matchers, anything the tier mixes in.
      def constable_shared_context
        allocate.tap do |instance|
          instance.instance_variable_set(:@constable_witnesses, {})
        end
      end

      def constable_close_shared_scope!
        return unless @constable_shared_open

        @constable_shared_open = false
        @constable_shared_values = nil
        untransacted = @constable_shared_untransacted
        @constable_shared_untransacted = nil
        TestProf::BeforeAll.rollback_transaction unless untransacted
      end

      # The value itself is built once. `reload` decides what each investigation is handed:
      # a fresh read of the same row, or the very object the block returned.
      def constable_shared_value(name, context)
        constable_open_shared_scope!(context)
        definition = shared_fixtures.fetch(name)
        store = (@constable_shared_values ||= {})
        value = store.fetch(name) { store[name] = context.instance_exec(&definition[:block]) }
        definition[:reload] ? constable_reread(value) : value
      end

      # A mutated in-memory object is the one thing the transaction cannot protect against,
      # so the record is read again. Anything that is not a persisted record is handed back
      # untouched -- there is nothing to re-read.
      def constable_reread(value)
        return value.map { |item| constable_reread(item) } if value.is_a?(Array)
        return value unless value.respond_to?(:reload) && value.respond_to?(:persisted?)
        return value unless value.persisted?

        begin
          value.reload
        rescue StandardError
          value
        end
      end
    end
  end
end
