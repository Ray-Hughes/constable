# frozen_string_literal: true

module Constable
  # Stubs and call assertions, without rspec-mocks.
  #
  # Constable shipped no mocking library, which made `allow(x).to receive(:y)` the single
  # largest reason a file could not be converted -- 4,801 occurrences on the suite this was
  # measured against, half of everything still blocked. "Use a stub object instead" is fine
  # advice for a file being written and useless for ten thousand that already exist.
  #
  # What makes this fast is what it does not do. rspec-mocks builds a proxy per object and a
  # double per method, and `verify_partial_doubles` reflects over the real method's signature
  # on every stub. This replaces the singleton method directly and puts the original on a
  # restore list. Constable already owns teardown, so nothing needs a global `after` hook to
  # put the world back.
  #
  #   investigate "retries once" do
  #     impersonate(client, :fetch, raises: Timeout::Error)
  #     impersonate(logger, :warn)
  #
  #     attest { subject.call }.to raise_error(Timeout::Error)
  #     attest(logger).to have_been_asked(:warn)
  #   end
  #
  # The verification is the cheap half of what rspec-mocks does and the half that catches
  # real bugs: stubbing a method the object does not have is a typo or a rename, and it is
  # refused rather than silently passing forever. `allow_missing: true` is the escape hatch,
  # and a decoy has nothing to verify against so it never needs one.
  module Impersonation
    NOTHING = Object.new.freeze
    private_constant :NOTHING

    # One replaced method, and what it takes to undo it.
    Restoration = Struct.new(:target, :name, :original, :owned, keyword_init: true) do
      def restore!
        singleton = target.singleton_class
        singleton.send(:remove_method, name) if singleton.method_defined?(name, false) ||
                                                singleton.private_method_defined?(name, false)
        singleton.send(:define_method, name, original) if original && !owned
      end
    end

    # Every call that reached an impersonated method, in order.
    Call = Struct.new(:name, :args, :kwargs, :block, keyword_init: true)

    class Ledger
      def initialize
        @calls = Hash.new { |hash, key| hash[key] = [] }
        @restorations = []
      end

      def record(name, call) = @calls[name.to_sym] << call
      def calls(name) = @calls[name.to_sym]
      def track(restoration) = @restorations << restoration

      # Reverse order, so a method impersonated twice comes back to what it was first.
      def restore!
        @restorations.reverse_each(&:restore!)
        @restorations.clear
        @calls.clear
      end
    end

    # A stand-in with no real object behind it -- rspec's `double`. Because nothing is being
    # replaced, there is no original to verify against and no original to restore.
    class Decoy
      attr_reader :constable_ledger, :constable_name

      def initialize(name = :decoy, **methods)
        @constable_name = name
        @constable_ledger = Ledger.new
        methods.each { |method_name, value| constable_answer(method_name, value) }
      end

      def constable_answer(name, value = NOTHING, &block)
        ledger = @constable_ledger
        define_singleton_method(name) do |*args, **kwargs, &blk|
          ledger.record(name, Call.new(name: name, args: args, kwargs: kwargs, block: blk))
          next block.call(*args, **kwargs, &blk) if block

          value unless value.equal?(NOTHING)
        end
        self
      end

      def inspect = "#<decoy #{@constable_name}>"
      alias to_s inspect
    end

    # Replace one method for the duration of this investigation.
    #
    #   impersonate(client, :fetch)                    # returns nil, records the call
    #   impersonate(client, :fetch, returns: :ok)
    #   impersonate(client, :fetch, raises: Timeout::Error)
    #   impersonate(client, :fetch) { |id| store[id] }
    def impersonate(target, name, returns: NOTHING, raises: nil, allow_missing: false, &block)
      name = name.to_sym
      verify_impersonation!(target, name) unless allow_missing || target.is_a?(Decoy)

      ledger = constable_ledger_for(target)
      track_original(target, name, ledger)

      target.define_singleton_method(name) do |*args, **kwargs, &blk|
        ledger.record(name, Call.new(name: name, args: args, kwargs: kwargs, block: blk))
        raise raises if raises
        next block.call(*args, **kwargs, &blk) if block

        returns unless returns.equal?(NOTHING)
      end
      target
    end

    # Every instance of a class, for code that builds its own collaborators. The same
    # caveat rspec attaches to `any_instance_of` applies: needing it usually means the
    # collaborator should have been passed in.
    def impersonate_any(klass, name, returns: NOTHING, raises: nil, allow_missing: false, &block)
      name = name.to_sym
      unless allow_missing || klass.method_defined?(name) || klass.private_method_defined?(name)
        raise Constable::Error, missing_method_message(klass, name, "instances of #{klass}")
      end

      ledger = constable_ledger_for(klass)
      original = klass.instance_method(name) if klass.method_defined?(name) ||
                                                klass.private_method_defined?(name)
      constable_impersonations << AnyInstance.new(klass: klass, name: name, original: original)

      klass.define_method(name) do |*args, **kwargs, &blk|
        ledger.record(name, Call.new(name: name, args: args, kwargs: kwargs, block: blk))
        raise raises if raises
        next block.call(*args, **kwargs, &blk) if block

        returns unless returns.equal?(NOTHING)
      end
      klass
    end

    AnyInstance = Struct.new(:klass, :name, :original, keyword_init: true) do
      def restore!
        klass.send(:remove_method, name) if klass.method_defined?(name, false) ||
                                            klass.private_method_defined?(name, false)
        klass.send(:define_method, name, original) if original
      end
    end

    # A stand-in object. `decoy(:client, fetch: :ok)` answers `fetch` with `:ok` and records
    # every call.
    def decoy(name = :decoy, **methods) = Decoy.new(name, **methods)

    # What reached `target`, for the matchers to read.
    def constable_calls(target, name) = constable_ledger_for(target).calls(name)

    # Undo everything this investigation replaced. Called from Case's teardown, so a test
    # never has to remember it and a failing test cannot skip it.
    def constable_restore_impersonations!
      constable_impersonations.reverse_each(&:restore!)
      constable_impersonations.clear
      constable_ledgers.each do |target, ledger|
        ledger.restore!
        singleton = target.singleton_class
        singleton.send(:remove_method, :constable_ledger) if singleton.method_defined?(:constable_ledger)
      end
      constable_ledgers.clear
    end

    private

    # Keyed by identity, not by object_id: an object_id can be recycled once its object is
    # collected, so two different targets could collide on one entry.
    def constable_ledgers = (@constable_ledgers ||= {}.compare_by_identity)
    def constable_impersonations = (@constable_impersonations ||= [])

    # The ledger hangs off the object itself, not off the test instance. `attest(client).to
    # have_been_asked(:fetch)` hands the matcher the client and nothing else, so the record
    # of what was called has to be reachable from there. Removed again on restore, so an
    # object that outlives the test carries nothing away with it.
    def constable_ledger_for(target)
      return target.constable_ledger if target.respond_to?(:constable_ledger)

      ledger = Ledger.new
      target.define_singleton_method(:constable_ledger) { ledger }
      constable_ledgers[target] = ledger
      ledger
    end

    # Stubbing a method the object does not have is a typo or a rename that outlived its
    # rename. RSpec calls this verify_partial_doubles and makes it optional; here it is the
    # default, because the version that silently passes forever has no value.
    def verify_impersonation!(target, name)
      return if target.respond_to?(name, true)

      raise Constable::Error, missing_method_message(target, name, describe_target(target))
    end

    def missing_method_message(_target, name, description)
      "#{description} does not respond to #{name.inspect}, so impersonating it would be " \
        "stubbing a method that does not exist -- which passes forever and proves nothing. " \
        "Check the spelling, or pass `allow_missing: true` if the method is defined later."
    end

    def describe_target(target)
      target.is_a?(Module) ? target.to_s : "#{target.class} instances"
    end

    def track_original(target, name, ledger)
      singleton = target.singleton_class
      owned = singleton.method_defined?(name, false) ||
              singleton.private_method_defined?(name, false)
      original = target.method(name).unbind if target.respond_to?(name, true)
      ledger.track(Restoration.new(target: target, name: name, original: original, owned: !owned))
    end
  end
end
