# frozen_string_literal: true

module Constable
  # The base class for a case file -- one file, roughly one subject under test.
  #
  #   class UsersController::CreatesUserCase < IntegrationCase
  #     witness(:valid_params) { { user: { email: "a@b.com" } } }
  #     briefing { stub_network! }
  #
  #     investigate "creates a user with valid params" do
  #       post users_path, params: valid_params
  #       attest(response).to be_created
  #     end
  #   end
  #
  # `investigate` is a registration DSL, not a method definition. Every investigation is
  # run in its own fresh instance of the owning class, which is the whole reason there is
  # no `before(:all)` equivalent here and never will be: class-level shared state is the
  # thing this framework exists to make impossible.
  class Case
    # The runtime DSL (freeze_time, stub_network!, unsafe, assertion primitives) and the
    # `attest` expectation sugar are separate components. They're mixed in here so every
    # investigation body has them. The rescue exists only so a Case remains loadable --
    # and its registration DSL testable -- in a checkout where those files haven't landed
    # yet; once they exist this is an ordinary include.
    begin
      include Constable::DSL
    rescue LoadError, NameError # :nocov:
      nil
    end

    begin
      include Constable::Matchers::Expectations
    rescue LoadError, NameError # :nocov:
      nil
    end

    class << self
      # Every subclass -- a tier base class, a real case, a docket -- starts with its own
      # empty ledger. Only real cases go on the registry's top-level list; a docket is
      # reachable through the class that opened it.
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@constable_docket, @constable_defining_docket == true)
        Constable.registry.register(subclass)
      end

      # Registers a test. The description is a plain string, so punctuation and
      # interpolation are fine -- nothing here is translated into a method name.
      def investigate(description, &block)
        raise ArgumentError, "investigate(#{description.inspect}) requires a block" unless block

        file, line = block.source_location
        investigation = Investigation.new(
          case_class: self,
          description: description.to_s,
          block: block,
          file: file,
          line: line,
          docket_path: docket_path.dup,
          tier: tier_for(file)
        )
        constable_children << investigation
        investigation
      end

      # A fixture/helper, memoized **per-test**. The memo lives on the fresh instance the
      # investigation runs in, never on the class and never on the process -- per-process
      # caching would leak state between tests, which defeats the entire point.
      def witness(name, &block)
        raise ArgumentError, "witness(#{name.inspect}) requires a block" unless block

        name = name.to_sym
        own_witnesses[name] = block
        define_method(name) do
          constable_witnesses.fetch(name) { constable_witnesses[name] = instance_exec(&block) }
        end
        name
      end

      # Setup, run before every investigation in this case. Multiple are allowed and a
      # parent's briefings always run before a child's.
      def briefing(&block)
        raise ArgumentError, "briefing requires a block" unless block

        own_briefings << block
        block
      end

      # In-file grouping. A docket is an anonymous subclass with the description pushed
      # onto its docket path -- so witnesses and briefings declared inside it are scoped
      # to it, and nothing is shared with its siblings. Nests arbitrarily deep.
      def docket(description, &block)
        raise ArgumentError, "docket(#{description.inspect}) requires a block" unless block

        previous = @constable_defining_docket
        @constable_defining_docket = true
        subclass = Class.new(self)
        @constable_defining_docket = previous

        subclass.instance_variable_set(:@constable_docket_path, docket_path + [description.to_s])
        subclass.instance_variable_set(:@constable_docket_description, description.to_s)
        constable_children << subclass
        subclass.class_eval(&block)
        subclass
      end

      # :unit / :integration / :system. Reads as an inherited value, so a tier base class
      # (`class UnitCase < Constable::Case; tier :unit; end`) hands its tier to every case
      # that subclasses it.
      def tier(value = nil)
        return self.tier = value unless value.nil?

        return @constable_tier if defined?(@constable_tier) && @constable_tier

        superclass.respond_to?(:tier) ? superclass.tier : nil
      end

      def tier=(value)
        @constable_tier = value&.to_sym
      end

      # Every investigation belonging to this class and to its dockets, flattened, in
      # declaration order.
      def investigations
        constable_children.flat_map do |child|
          child.is_a?(Investigation) ? [child] : child.investigations
        end
      end

      def own_investigations = constable_children.grep(Investigation)
      def dockets            = constable_children.grep(Class)

      # Briefings run outermost-first: Constable::Case, then the tier base class, then the
      # case, then each docket in turn.
      def briefings
        constable_lineage.flat_map(&:own_briefings)
      end

      def witnesses
        constable_lineage.each_with_object({}) { |klass, out| out.merge!(klass.own_witnesses) }
      end

      def witness_names = witnesses.keys

      def own_briefings  = (@constable_own_briefings ||= [])
      def own_witnesses  = (@constable_own_witnesses ||= {})

      # ["as an admin", "with a locked account"] -- the enclosing docket descriptions.
      def docket_path
        @constable_docket_path ||= (superclass.respond_to?(:docket_path) ? superclass.docket_path.dup : [])
      end

      def docket_description
        defined?(@constable_docket_description) ? @constable_docket_description : nil
      end

      # True for the anonymous subclasses `docket` creates. They're deliberately kept off
      # the registry's top-level list.
      def docket?
        defined?(@constable_docket) && @constable_docket == true
      end

      # The nearest named, non-docket ancestor -- so an anonymous docket still reports as
      # "UsersController::CreatesUserCase".
      def constable_display_name
        klass = self
        while klass && klass != Constable::Case
          return klass.name if !klass.docket? && klass.name

          klass = klass.superclass
        end
        "AnonymousCase"
      end

      # Runner entry point. Builds the fresh instance, runs every inherited briefing in
      # order, and executes the investigation body in that same instance.
      def run(investigation, instance: nil)
        (instance || new).run_investigation(investigation)
      end

      # A fresh instance, bound to nothing. One per investigation, always.
      def constable_instance_for(investigation)
        new.tap { |instance| instance.constable_investigation = investigation }
      end

      private

      # Self last: the outermost class briefs first.
      def constable_lineage
        chain = []
        klass = self
        while klass && klass <= Constable::Case
          chain.unshift(klass)
          klass = klass.superclass
        end
        chain
      end

      def constable_children = (@constable_children ||= [])

      # An explicit `tier` macro always wins; path convention is only the fallback for a
      # case that never declared one.
      def tier_for(file)
        tier || (file && Constable.config.tier_for(file))
      rescue StandardError
        tier
      end
    end

    # The investigation currently being run in this instance. The runtime DSL uses it to
    # point warnings and failures at the user's own file:line.
    attr_accessor :constable_investigation

    # The full path the Runner takes for one test: fresh instance, briefings, body.
    def run_investigation(investigation)
      run_setup(investigation)
      run_body(investigation)
    end

    # Setup only. A jailed test still gets this -- its briefings and witnesses run, just
    # not its body -- so setup rot surfaces immediately instead of at the next jail run.
    def run_setup(investigation = nil)
      @constable_investigation = investigation if investigation
      clear_witnesses!
      self.class.briefings.each { |briefing| instance_exec(&briefing) }
      self
    end

    def run_body(investigation)
      @constable_investigation = investigation
      instance_exec(&investigation.block)
    end

    # Per-test memo store for `witness`. Fresh instance, fresh hash, no exceptions.
    def constable_witnesses
      @constable_witnesses ||= {}
    end

    def clear_witnesses!
      @constable_witnesses = {}
    end

    def constable_display_name = self.class.constable_display_name
  end
end
