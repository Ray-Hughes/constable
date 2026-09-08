# frozen_string_literal: true

module Constable
  # Decides what a given `constable test` invocation actually runs.
  #
  # The default with no arguments is deliberately *not* the whole suite: locally, the
  # interesting tests are the ones covering what you just changed, so the default is
  # git-diff scoped. CI passes --full and gets everything, every time. When git can't
  # answer -- no repo, no commits, a detached checkout -- the answer is the full suite
  # rather than a confidently empty one. Running too much is a slow day; running too
  # little is a false green.
  class Selection
    # A single resolved target: a file, optionally narrowed to one investigation by line.
    Target = Struct.new(:path, :line, :kind, keyword_init: true) do
      def native? = kind == :native
      def cold?   = kind == :cold
      def to_s    = line ? "#{path}:#{line}" : path.to_s
    end

    NATIVE_GLOBS = [
      "test/cases/**/*.rb",
      "spec/cases/**/*.rb",
      "test/**/*_case.rb",
      "spec/**/*_case.rb"
    ].freeze

    attr_reader :config, :root, :args, :reason

    def initialize(args = [], config: Constable.config, root: Constable.root,
                   full: false, unsafe_only: false, tier: nil)
      @args        = Array(args)
      @config      = config
      @root        = root.to_s
      @full        = full
      @unsafe_only = unsafe_only
      # Downcased: `--tier UNIT` used to match nothing at all and report a clean run.
      @tier        = tier.to_s.strip.downcase.to_sym unless tier.to_s.strip.empty?
      @reason      = nil
    end

    TIERS = %w[unit integration system].freeze

    def full?        = @full
    def unsafe_only? = @unsafe_only

    # => [Target]
    def targets
      @targets ||= begin
        list =
          if @args.any?
            explicit_targets
          elsif @unsafe_only
            cold_targets
          elsif @full
            all_targets
          else
            diff_targets
          end

        list = list.select(&:cold?) if @unsafe_only
        list = list.select { |t| tier_matches?(t) } if @tier
        list.uniq { |t| [t.path, t.line] }
      end
    end

    # Did the user ask for something in particular? If so, finding nothing is an error
    # rather than a clean run -- see Runner#refuse_empty_selection!.
    def explicit? = @args.any? { |arg| !arg.to_s.strip.empty? } || !@tier.nil?

    # Says which part of the request came up empty, because "0 tests" on its own does not
    # tell you whether the path was wrong, the tier was, or both.
    def empty_selection_message
      if @tier && !TIERS.include?(@tier.to_s)
        return "unknown tier #{@tier.inspect} -- expected one of #{TIERS.join(", ")}."
      end

      described = @args.reject { |arg| arg.to_s.strip.empty? }
      subject   = described.empty? ? "this run" : described.join(", ")
      suffix    = @tier ? " in the #{@tier} tier" : ""

      "no tests matched #{subject}#{suffix}. Check the path, the line number, and " \
        "whether the file is a case or a cold case."
    end

    def native_targets = targets.select(&:native?)
    def cold_targets_selected = targets.select(&:cold?)
    def empty? = targets.empty?

    # A specific investigation was named (PATH:LINE), so only that one should run.
    def line_filter_for(path)
      targets.select { |t| t.path == path && t.line }.map(&:line)
    end

    private

    # "spec/cases/sessions_case.rb:12" -- a file, or one investigation inside it.
    def explicit_targets
      @reason = "explicit paths"
      @args.flat_map do |arg|
        path, line = split_line(arg)
        absolute = absolutize(path)

        if File.directory?(absolute)
          files_under(absolute).map { |f| target_for(f, nil) }
        else
          [target_for(absolute, line)]
        end
      end.compact
    end

    def all_targets
      @reason = "full suite"
      (native_files + cold_files).map { |f| target_for(f, nil) }.compact
    end

    def cold_targets
      @reason = "cold cases only"
      cold_files.map { |f| Target.new(path: f, line: nil, kind: :cold) }
    end

    # Changed files map to their own case files plus any case file that looks like it
    # covers them (app/models/user.rb -> **/user_case.rb, **/users_*_case.rb).
    def diff_targets
      unless Diff.available?(root: @root)
        @reason = "full suite (git unavailable)"
        return all_targets
      end

      changed = Diff.changed_files(root: @root)
      if changed.empty?
        @reason = "full suite (no changes detected)"
        return all_targets
      end

      matched = changed.flat_map { |file| cases_covering(file) }.uniq
      if matched.empty?
        @reason = "full suite (no cases matched the diff)"
        return all_targets
      end

      @reason = "#{matched.size} #{matched.size == 1 ? "case" : "cases"} touched by the diff"
      matched.map { |f| target_for(f, nil) }.compact
    end

    # Maps one changed source file to the case files that plausibly exercise it. A changed
    # test file is itself a target; a changed app file is matched by name.
    def cases_covering(changed_file)
      absolute = absolutize(changed_file)
      known = native_files + cold_files
      return [absolute] if known.include?(absolute)

      stem = File.basename(changed_file, ".rb")
      return [] if stem.empty?

      singular = stem.sub(/s\z/, "")
      known.select do |case_file|
        base = File.basename(case_file, ".rb")
        base.start_with?(stem) || base.start_with?(singular) ||
          base.sub(/_(case|spec|test)\z/, "") == stem
      end
    end

    def target_for(file, line)
      return nil unless File.file?(file)

      Target.new(path: file, line: line, kind: kind_of(file))
    end

    def kind_of(file)
      return :cold if @config.cold_case?(file)
      return :cold if cold_by_content?(file)

      :native
    end

    # A file that declares itself a ColdCase is one, whatever the globs say.
    def cold_by_content?(file)
      head = File.foreach(file).first(40).join
      head.include?("Constable::ColdCase")
    rescue StandardError
      false
    end

    def native_files
      @native_files ||= glob(NATIVE_GLOBS).reject { |f| @config.cold_case?(f) }
    end

    def cold_files
      @cold_files ||= begin
        from_config = glob(@config.cold_cases)
        declared = glob(["test/**/*_spec.rb", "spec/**/*_spec.rb", "test/**/*_test.rb"])
                   .select { |f| cold_by_content?(f) }
        (from_config + declared).uniq
      end
    end

    def files_under(dir)
      Dir.glob(File.join(dir, "**", "*.rb"))
    end

    def glob(patterns)
      Array(patterns).flat_map { |p| Dir.glob(File.join(@root, p.to_s)) }
                     .select { |f| File.file?(f) }
                     .sort
                     .uniq
    end

    def tier_matches?(target)
      return true unless @tier

      @config.tier_for(target.path) == @tier
    end

    # "path/to/file.rb:12" -> ["path/to/file.rb", 12]
    def split_line(arg)
      if (match = arg.to_s.match(/\A(.*?):(\d+)\z/))
        [match[1], match[2].to_i]
      else
        [arg.to_s, nil]
      end
    end

    def absolutize(path)
      File.absolute_path?(path) ? path : File.expand_path(path, @root)
    end
  end
end
