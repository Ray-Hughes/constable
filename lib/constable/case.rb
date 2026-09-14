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
    # Names a witness may not take, because Case itself needs them.
    #
    # On the class rather than inside `class << self`, so `constable modernize` can read it
    # as `Case::RESERVED_WITNESS_NAMES` without booting anything -- catching `let(:hash)`
    # while it is still a decision, rather than writing a file that raises on load.
    #
    # Deliberately a list rather than `method_defined?`: a blanket check would reject
    # ordinary names a tier happens to define (`response` on an integration case), and
    # shadowing those is a legitimate, if unusual, thing to want.
    # `transactional` reads as a getter with no argument and a setter with one, and `false`
    # is a meaningful argument -- so "no argument" needs a value `false` is not.
    UNSET = Object.new.freeze

    RESERVED_WITNESS_NAMES = %i[
      class send __send__ __id__ object_id method methods freeze frozen? dup clone
      hash inspect to_s instance_variable_get instance_variable_set instance_variables
      attest unsafe witness briefing investigate docket tier setup teardown
      assert refute flunk skip pass freeze_time travel_to travel_back
    ].freeze

    # The runtime DSL (freeze_time, stub_network!, unsafe, assertion primitives) and the
    # `attest` expectation sugar live in their own components, mixed in here so every
    # investigation body has both without asking.
    extend Constable::SharedFixtures::ClassMethods
    include Constable::Impersonation
    include Constable::DSL
    include Constable::Matchers::Expectations

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

        # Where the block was written -- except inside a procedure, where that is the
        # procedure's file and the test belongs to the case that follows it. A case selected
        # by path has to contain the tests it declares, however they got there.
        file, line = block.source_location
        file = Constable::Procedure.following_from || file
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
        guard_witness_name!(name)
        own_witnesses[name] = block
        define_method(name) do
          constable_witnesses.fetch(name) { constable_witnesses[name] = instance_exec(&block) }
        end
        name
      end

      # Adopt one or more procedures -- shared behaviour declared elsewhere.
      #
      #   class ColocatedTaskCase < UnitCase
      #     follows TaskProcedure, AssignableProcedure
      #   end
      #
      # Evaluated in this class, so what a procedure declares is indistinguishable from
      # what the case declares itself -- and a witness the case defines afterwards wins,
      # which is what makes a procedure worth following rather than copying.
      def follows(*procedures)
        procedures.flatten.each do |procedure|
          unless procedure.respond_to?(:apply_to)
            raise ArgumentError,
                  "follows expects a Constable.procedure, got #{procedure.inspect}. " \
                  "Procedures are constants, so a typo here is a NameError rather than a " \
                  "lookup that fails at run time."
          end

          # Attributed to the file that said `follows`, so `constable test <that file>`
          # runs what the procedure declared. Not an instance variable on this class: a
          # `docket` inside the procedure builds a subclass, and subclasses do not inherit
          # instance variables, so the nested investigations would slip back to the
          # procedure's own file. The failure still points at the procedure's line, which
          # is where the code to fix actually is.
          Constable::Procedure.following(self) { procedure.apply_to(self) }
        end
        self
      end

      # Setup, run before every investigation in this case. Multiple are allowed and a
      # parent's briefings always run before a child's.
      def briefing(&block)
        raise ArgumentError, "briefing requires a block" unless block

        own_briefings << block
        block
      end

      # --- Minitest lifecycle compatibility -----------------------------------
      #
      # `briefing` is how a person writes setup in Constable. `setup` exists because
      # Rails' testing modules -- ActionDispatch::IntegrationTest::Behavior and friends --
      # are written against Minitest's contract and call these macros on the class they
      # are included into. Answering that contract is what lets a case get `post
      # users_path` and `response` for free instead of a reimplementation of them.
      #
      # It is a synonym, not a second mechanism: a `setup` block is appended to exactly
      # the same list `briefing` appends to, so ordering is one rule rather than two --
      # parents before children, declaration order preserved within a class.

      # setup { ... } and setup :method_name, :other_method are both legal, because both
      # forms appear in Rails' own modules.
      def setup(*method_names, &block)
        method_names.each { |name| own_briefings << proc { send(name) } }
        own_briefings << block if block
        self
      end

      # Cleanup, run after the investigation body in reverse declaration order -- a
      # child's teardowns before its parent's -- and run whether or not the body raised.
      def teardown(*method_names, &block)
        method_names.each { |name| own_teardowns << proc { send(name) } }
        own_teardowns << block if block
        self
      end

      # Innermost-first: the mirror image of #briefings.
      def teardowns
        constable_lineage.flat_map(&:own_teardowns).reverse
      end

      def own_teardowns = (@constable_own_teardowns ||= [])

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

      # Whether Constable wraps this case's investigations in a transaction it rolls back.
      # True unless a case says otherwise, and inherited the way `tier` is.
      #
      # The one situation that needs otherwise is a suite whose own cleanup is truncation.
      # A rollback and a truncation are not interchangeable: Postgres sequences are not
      # transactional, so a rolled-back test leaves the next one's ids where it found them,
      # while a truncation resets them. A suite written against truncation -- Capybara suites
      # usually are, because a browser talks to a server that cannot see an open transaction
      # -- has tests that quietly depend on that, and they fail against a rollback for
      # reasons that have nothing to do with the code under test.
      #
      #   class SystemCase < Constable::Case
      #     transactional false
      #     briefing { DatabaseCleaner.start }
      #     teardown { DatabaseCleaner.clean }
      #   end
      #
      # Turning it off means the cleanup is now yours. Constable says so once per run rather
      # than letting a suite discover it as cross-test contamination.
      def transactional(value = UNSET)
        return self.transactional = value unless value.equal?(UNSET)

        return @constable_transactional if defined?(@constable_transactional) && !@constable_transactional.nil?

        superclass.respond_to?(:transactional) ? superclass.transactional : true
      end

      def transactional=(value)
        @constable_transactional = value
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

      # Names a witness may not take.
      #
      # `witness` defines a real instance method, so `witness(:class) { ... }` quietly
      # replaces Object#class on the case and every later `attest` failure reports the
      # wrong thing. Worse, `witness(:attest)` disables assertions outright -- the tests
      # then pass by doing nothing, which is the one failure mode a testing framework
      # must never have.
      #
      # Deliberately a list rather than `method_defined?`: a blanket check would reject
      # ordinary names a tier happens to define (`response` on an integration case), and
      # shadowing those is a legitimate, if unusual, thing to want.
      def guard_witness_name!(name)
        if RESERVED_WITNESS_NAMES.include?(name)
          raise ArgumentError,
                "witness(:#{name}) would replace Constable::Case##{name}, which the " \
                "framework needs. Pick another name."
        end

        return unless name.to_s.start_with?("constable_")

        raise ArgumentError,
              "witness(:#{name}) is in Constable's own namespace. Names beginning " \
              "`constable_` belong to the framework."
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

      # The class this case is about, inferred from its name the way RSpec infers it from
      # `describe SomeClass`. `CacheManagerCase` is about `CacheManager`. nil when the name
      # does not resolve, which is the ordinary case for a case about behaviour rather than
      # about one class.
      def constable_described_class
        return @constable_described_class if defined?(@constable_described_class)

        name = constable_display_name.to_s.sub(/(?:Case|Spec|Test)\z/, "")
        @constable_described_class =
          begin
            name.empty? ? nil : Object.const_get(name)
          rescue NameError
            nil
          end
      end

      # Runner entry point. Builds the fresh instance, runs every inherited briefing in
      # order, and executes the investigation body in that same instance.
      #
      # The instance is always of `investigation.case_class` -- a docket's investigation
      # belongs to the docket subclass, and running it anywhere else would quietly skip
      # that docket's witnesses and briefings. So `Constable::Case.run(inv)` is enough;
      # the receiver doesn't have to be the right class.
      def run(investigation, instance: nil)
        (instance || constable_instance_for(investigation)).run_investigation(investigation)
      end

      # A fresh instance, bound to nothing but this investigation. One per investigation,
      # always.
      def constable_instance_for(investigation)
        investigation.case_class.new.tap { |instance| instance.constable_investigation = investigation }
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

    # Whatever the investigation raised, readable while teardown is running and nil when
    # it passed. Rails' system-test screenshot helper asks a test whether it failed; this
    # is how a case can answer without Minitest's result object.
    attr_reader :constable_failure

    # The full path the Runner takes for one test: fresh instance, before_setup,
    # briefings, body, teardowns, after_teardown.
    def run_investigation(investigation)
      failure = nil
      value = nil
      begin
        run_setup(investigation)
        value = run_body(investigation)
      rescue StandardError => e
        failure = e
      ensure
        @constable_failure = failure
        # A raise from teardown must never replace the investigation's own failure. The
        # first thing that went wrong is the thing worth reporting; the rest is fallout.
        teardown_failure = run_teardown
        failure ||= teardown_failure
      end

      raise failure if failure

      value
    end

    # Setup only. A jailed test still gets this -- its briefings and witnesses run, just
    # not its body -- so setup rot surfaces immediately instead of at the next jail run.
    def run_setup(investigation = nil)
      @constable_investigation = investigation if investigation
      clear_witnesses!
      before_setup
      self.class.briefings.each { |briefing| instance_exec(&briefing) }
      after_setup
      self
    end

    def run_body(investigation)
      @constable_investigation = investigation
      instance_exec(&investigation.block)
    end

    # Returns the first exception raised rather than raising it, so the caller stays in
    # charge of which failure the run reports. Every teardown runs even if an earlier one
    # blew up -- half-released state is worse than a noisy log.
    def run_teardown
      errors = []
      constable_swallow(errors) { before_teardown }
      self.class.teardowns.each { |block| constable_swallow(errors) { instance_exec(&block) } }
      constable_swallow(errors) { after_teardown }
      # After the user's teardowns, so one of them can still assert on what was called; and
      # unconditionally, so a failing test cannot leave a method replaced for the next one.
      constable_swallow(errors) { constable_restore_impersonations! }
      errors.first
    end

    # The four hooks Minitest's contract requires. They are no-ops here on purpose: this
    # is the bottom of the chain, and the Rails modules a tier base class mixes in sit
    # above it, each calling super until it lands here.
    def before_setup    = (super if defined?(super))
    def after_setup     = (super if defined?(super))
    def before_teardown = (super if defined?(super))
    def after_teardown  = (super if defined?(super))

    # Minitest names a test by the method that defines it. Constable's descriptions are
    # plain strings, so this is the closest honest answer -- and it is what Rails uses to
    # name a failure screenshot, which is the only place it shows up.
    def method_name
      slug = constable_investigation&.full_description.to_s.gsub(/[^A-Za-z0-9]+/, "_")
      slug = slug.gsub(/\A_+|_+\z/, "").downcase
      slug.empty? ? "investigation" : slug[0, 120]
    end

    # Per-test memo store for `witness`. Fresh instance, fresh hash, no exceptions.
    def constable_witnesses
      @constable_witnesses ||= {}
    end

    def clear_witnesses!
      @constable_witnesses = {}
    end

    def constable_display_name = self.class.constable_display_name

    # RSpec's implicit subject, for the same reason RSpec has one: a spec that says
    # `subject.call` never declared a subject, because `describe CacheManager` already said
    # what it was. A converted file would otherwise die on `undefined local variable or
    # method 'subject'` -- and `attest(subject)`, which is what `is_expected` converts to,
    # needs it to exist at all.
    #
    # Memoized per example, like RSpec's: two mentions in one investigation are one object.
    # A case that declares `witness(:subject) { ... }` defines its own method on the
    # subclass, which wins over this one, so an explicit subject is untouched.
    def subject
      return @constable_subject if defined?(@constable_subject)

      @constable_subject = constable_implicit_subject
    end

    private

    def constable_implicit_subject
      described = self.class.constable_described_class
      unless described.is_a?(Class)
        raise Constable::Error,
              "#{constable_display_name} used `subject` without declaring one, and its name " \
              "does not resolve to a class, so there is nothing to build. Declare it with " \
              "`witness(:subject) { ... }`, or name the thing you are asserting on directly."
      end

      described.new
    end

    def constable_swallow(errors)
      yield
    rescue StandardError => e
      errors << e
    end
  end
end
