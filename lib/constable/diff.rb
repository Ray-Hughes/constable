# frozen_string_literal: true

require "open3"
require "set"

module Constable
  # The git helper -- "what changed on this beat".
  #
  # Two consumers, one implementation:
  #
  #   * the Runner's git-diff test selection ("run the cases for the files I touched"),
  #   * the diff-based coverage gate ("hold the lines I touched to the threshold").
  #
  # Both ask the same question -- what is different between this working tree and the
  # point where this branch left the mainline -- so both ask it here, and neither has to
  # know how git spells the answer.
  #
  # Everything degrades to "no diff info" rather than raising: git may not be installed,
  # the directory may not be a repository, the repository may have no commits yet, or the
  # whole thing may be running from a tarball in CI. In every one of those cases
  # `available?` is false, `changed_files` is `[]` and `changed_lines` is `{}` -- callers
  # fall back to running everything, which is always the safe direction.
  module Diff
    # Candidate mainlines, tried in order. `origin/*` first: on a CI checkout the local
    # `main` may not exist at all, and where it does it can be stale.
    DEFAULT_BASES = %w[origin/main origin/master origin/HEAD main master].freeze

    # git's well-known empty tree. Diffing against it makes a repository's very first
    # commit read as "every line is new", which is exactly right -- on a one-commit
    # repository there is no earlier state for any of it to be older than.
    EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    HUNK_HEADER = /\A@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/
    NEW_FILE_HEADER = %r{\A\+\+\+ (?:b/)?(.+)\z}

    module_function

    # True when git can actually answer questions here: the binary exists, this is a
    # repository, and it has at least one commit to compare against.
    def available?(root: Constable.root)
      !head_sha(root: root).nil?
    end

    # The absolute path of the repository's top level, or nil when there isn't one.
    # Paths from `changed_files`/`changed_lines` are relative to *this*, not to
    # `Constable.root` -- the two are usually the same directory, but an engine or a
    # monorepo package can sit below the repository root.
    def git_root(root: Constable.root)
      out = git("rev-parse", "--show-toplevel", root: root)
      out && !out.strip.empty? ? File.realpath(out.strip) : nil
    rescue Errno::ENOENT
      nil
    end

    # Every file that differs from the merge base and still exists on disk, plus every
    # untracked file. Deletions are dropped: there is nothing left to test or cover.
    #
    #   Diff.changed_files                      #=> ["app/models/user.rb", "test/cases/user_case.rb"]
    #   Diff.changed_files(absolute: true)      #=> ["/repo/app/models/user.rb", ...]
    #   Diff.changed_files(since: "main")       # explicit base instead of the detected one
    #
    # Returns [] when git can't answer.
    def changed_files(since: nil, root: Constable.root, absolute: false)
      base = resolve_base(since: since, root: root)
      return [] unless base

      tracked = git("diff", "--name-only", "--diff-filter=d", base, "--", root: root).to_s.lines
      files = (tracked.map(&:chomp) + untracked_files(root: root)).map { |p| unquote(p) }
      files = files.uniq.reject(&:empty?)
      absolute ? files.map { |p| File.expand_path(p, git_root(root: root) || root) } : files
    end

    # The changed *line numbers* per file, as a Set of integers keyed by path:
    #
    #   Diff.changed_lines                  #=> { "app/models/user.rb" => #<Set: {12, 13, 40}> }
    #   Diff.changed_lines(absolute: true)  #=> { "/repo/app/models/user.rb" => ... }
    #
    # Only lines that exist in the *new* state are reported -- an added or modified line
    # has a number in the file you can go and look at; a deleted line does not. Untracked
    # files count as changed in their entirety, since none of their lines existed before.
    #
    # Returns {} when git can't answer.
    def changed_lines(since: nil, root: Constable.root, absolute: false)
      base = resolve_base(since: since, root: root)
      return {} unless base

      out = git("diff", "--unified=0", "--no-color", "--no-ext-diff", "--diff-filter=d", base, "--", root: root)
      lines = parse_unified_diff(out.to_s)
      base_dir = git_root(root: root) || root.to_s

      untracked_files(root: root).each do |path|
        full = File.expand_path(path, base_dir)
        next unless File.file?(full)

        count = File.readlines(full).size
        (lines[path] ||= Set.new).merge(1..count) if count.positive?
      end

      return lines unless absolute

      lines.each_with_object({}) { |(path, nums), out_hash| out_hash[File.expand_path(path, base_dir)] = nums }
    end

    # The revision everything is compared against, or nil when there isn't one.
    #
    # Order of preference:
    #   1. an explicit `since:` (a branch, tag or sha -- whatever the caller passed),
    #   2. the merge base with the first of DEFAULT_BASES that exists *and* isn't HEAD
    #      itself -- the branch-point, which is what "what did I change" means on a
    #      feature branch,
    #   3. HEAD, when we're sitting on the mainline with uncommitted work -- the diff is
    #      then simply the working tree,
    #   4. HEAD~1, when the tree is clean -- "what did the last commit change",
    #   5. the empty tree, on a repository with a single commit and nothing else to
    #      compare to.
    def resolve_base(since: nil, root: Constable.root)
      head = head_sha(root: root)
      return nil unless head

      if since
        resolved = rev_parse(since, root: root)
        return resolved
      end

      DEFAULT_BASES.each do |ref|
        next unless rev_parse(ref, root: root)

        merge_base = git("merge-base", "HEAD", ref, root: root)&.strip
        next if merge_base.nil? || merge_base.empty? || merge_base == head

        return merge_base
      end

      return head if dirty?(root: root)

      rev_parse("HEAD~1", root: root) || EMPTY_TREE
    end

    # True when there is uncommitted work (staged, unstaged or untracked).
    def dirty?(root: Constable.root)
      out = git("status", "--porcelain", root: root)
      !out.nil? && !out.strip.empty?
    end

    def head_sha(root: Constable.root)
      rev_parse("HEAD", root: root)
    end

    # --- internals -------------------------------------------------------------

    def untracked_files(root: Constable.root)
      git("ls-files", "--others", "--exclude-standard", root: root).to_s.lines.map { |l| unquote(l.chomp) }
    end

    def rev_parse(ref, root: Constable.root)
      out = git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", root: root)
      out.nil? || out.strip.empty? ? nil : out.strip
    end

    # Walks `git diff --unified=0` output. The `+++ b/path` line names the file in its new
    # state (so renames land under the new name, which is the one on disk); each `@@`
    # header carries the new-side start line and count.
    def parse_unified_diff(output)
      current = nil
      output.each_line.with_object({}) do |line, files|
        line = line.chomp

        if (match = NEW_FILE_HEADER.match(line))
          path = unquote(match[1])
          # git spells a missing side of the diff "/dev/null" in its own output -- that
          # is a marker in a text stream, not this platform's null device.
          current = path == "/dev/null" ? nil : path # rubocop:disable Style/FileNull
        elsif current && (match = HUNK_HEADER.match(line))
          start = match[1].to_i
          count = match[2] ? match[2].to_i : 1
          (files[current] ||= Set.new).merge(start...(start + count)) if count.positive?
        end
      end
    end

    # git quotes paths containing anything exotic, C-string style. Unwrap the common case
    # rather than pretending such paths don't exist.
    def unquote(path)
      return path unless path.start_with?('"') && path.end_with?('"') && path.length > 1

      body = path[1..-2]
      body.gsub(/\\([0-7]{3}|.)/) do
        token = Regexp.last_match(1)
        case token
        when "n" then "\n"
        when "t" then "\t"
        when '"', "\\" then token
        else token.match?(/\A[0-7]{3}\z/) ? token.to_i(8).chr : token
        end
      end.force_encoding(Encoding::UTF_8)
    end

    # Every shell-out funnels through here: argument array (never a shell string), a
    # fixed working directory, and nil rather than an exception on any kind of failure.
    def git(*args, root: Constable.root)
      dir = root.to_s
      return nil unless File.directory?(dir)

      out, _err, status = Open3.capture3("git", *args, chdir: dir)
      return nil unless status.success?

      out.dup.force_encoding(Encoding::UTF_8).scrub
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, IOError
      nil
    end
  end
end
