# frozen_string_literal: true

module Constable
  # The outcome of a single test, native or cold. Everything downstream -- the reporter,
  # flake history, jail, warrants -- consumes these and nothing else.
  class Result
    STATUSES = %i[passed failed jailed skipped errored warranted parole_violation].freeze

    GLYPHS = {
      passed: "✓", # check
      failed: "✗", # ballot x
      jailed: "⛓", # chains
      skipped: "○", # hollow circle
      errored: "!",
      warranted: "⚖", # scales
      parole_violation: "⛓"
    }.freeze

    attr_reader :identity, :case_name, :description, :file, :line, :kind, :tier
    attr_accessor :status, :duration, :failure, :warnings, :retries, :jail_reason,
                  :parole_day, :times_jailed, :seed

    def initialize(identity:, case_name:, description:, file:, line:, kind: :native, tier: nil,
                   status: :passed, duration: 0.0, failure: nil, warnings: [], retries: [])
      @identity    = identity
      @case_name   = case_name
      @description = description
      @file        = file
      @line        = line
      @kind        = kind
      @tier        = tier
      @status      = status
      @duration    = duration
      @failure     = failure
      @warnings    = warnings
      @retries     = retries
    end

    def self.from_investigation(investigation, **attrs)
      new(
        identity: investigation.identity,
        case_name: investigation.case_name,
        description: investigation.full_description,
        file: investigation.relative_file,
        line: investigation.line,
        kind: investigation.kind,
        tier: investigation.tier,
        **attrs
      )
    end

    def passed?    = @status == :passed
    def failed?    = %i[failed errored].include?(@status)
    def jailed?    = %i[jailed parole_violation].include?(@status)
    def skipped?   = @status == :skipped
    def native?    = @kind == :native
    def cold?      = @kind == :cold
    def parole_violation? = @status == :parole_violation
    def warranted? = @status == :warranted

    def glyph = GLYPHS.fetch(@status, "?")
    def location = "#{@file}:#{@line}"
    def display_label = "#{@case_name} \"#{@description}\""

    # The command that reruns exactly this test, seed included, ready to paste.
    def rerun_command
      base = "constable test #{location}"
      base += " --unsafe" if cold?
      base += " --seed #{@seed}" if @seed
      base
    end

    def to_h
      {
        identity: @identity, case_name: @case_name, description: @description,
        file: @file, line: @line, kind: @kind, tier: @tier, status: @status,
        duration: @duration, failure: @failure&.to_h, warnings: @warnings,
        retries: @retries, jail_reason: @jail_reason, parole_day: @parole_day,
        times_jailed: @times_jailed, seed: @seed
      }
    end

    def self.from_h(hash)
      hash = hash.transform_keys(&:to_sym)
      result = new(
        identity: hash[:identity], case_name: hash[:case_name], description: hash[:description],
        file: hash[:file], line: hash[:line], kind: (hash[:kind] || :native).to_sym,
        tier: hash[:tier], status: (hash[:status] || :passed).to_sym,
        duration: hash[:duration].to_f, warnings: hash[:warnings] || [], retries: hash[:retries] || []
      )
      result.failure      = Failure.from_h(hash[:failure]) if hash[:failure]
      result.jail_reason  = hash[:jail_reason]
      result.parole_day   = hash[:parole_day]
      result.times_jailed = hash[:times_jailed]
      result.seed         = hash[:seed]
      result
    end
  end

  # A failure carries its own context -- the assertion's actual message plus whatever
  # the matcher thought was worth showing (a response body, a record's attributes) --
  # and points at the investigate block, never at framework internals.
  class Failure
    attr_reader :message, :context, :backtrace, :exception_class

    def initialize(message:, context: nil, backtrace: [], exception_class: nil)
      # Other engines wrap their messages in blank lines for their own reporters. Ours
      # already puts the message in a block of its own, so the padding just leaves holes.
      @message         = message.is_a?(String) ? message.strip : message
      @context         = context
      @backtrace       = Array(backtrace)
      @exception_class = exception_class
    end

    def self.from_exception(error, context: nil)
      new(
        message: error.message,
        context: context,
        backtrace: Backtrace.clean(error.backtrace),
        exception_class: error.class.name
      )
    end

    def to_h
      { message: @message, context: @context, backtrace: @backtrace, exception_class: @exception_class }
    end

    def self.from_h(hash)
      return nil if hash.nil?

      hash = hash.transform_keys(&:to_sym)
      new(message: hash[:message], context: hash[:context],
          backtrace: hash[:backtrace] || [], exception_class: hash[:exception_class])
    end
  end

  # Strips the framework out of backtraces. A developer wants their own line, not ours.
  module Backtrace
    GEM_ROOT = File.expand_path("../..", __dir__)

    module_function

    def clean(backtrace)
      lines = Array(backtrace)
      app = lines.reject { |l| l.to_s.start_with?(GEM_ROOT) || l.to_s.include?("/gems/") || l.to_s.include?("/ruby/3") }
      (app.empty? ? lines : app).first(10)
    end
  end
end
