# frozen_string_literal: true

require_relative "../helper"
require "open3"
require "constable/diff"

module Constable
  # Diff is what the Runner leans on to decide what to run and what Coverage leans on to
  # decide what to gate, so these tests drive a real git repository rather than stubbing
  # the plumbing -- the interesting bugs here are all in what git actually prints.
  class DiffTest < TestCase
    # Resolved once, at load: every test in here needs a real git binary and there is no
    # point shelling out twenty times to ask the same question.
    GIT_AVAILABLE = begin
      _out, _err, status = Open3.capture3("git", "--version")
      status.success?
    rescue StandardError
      false
    end

    def setup
      super
      @repo = nil
    end

    # --- no git, no repository -------------------------------------------------

    def test_a_directory_that_is_not_a_repository_reports_no_diff_information
      plain = File.join(tmp_root, "not-a-repo")
      FileUtils.mkdir_p(plain)

      refute_predicate_for_root plain
      assert_empty Diff.changed_files(root: plain)
      assert_empty Diff.changed_lines(root: plain)
      assert_nil Diff.git_root(root: plain)
    end

    def test_a_missing_directory_degrades_instead_of_raising
      missing = File.join(tmp_root, "nowhere")

      refute Diff.available?(root: missing)
      assert_empty Diff.changed_files(root: missing)
      assert_empty Diff.changed_lines(root: missing)
    end

    def test_a_repository_with_no_commits_reports_no_diff_information
      skip_without_git
      dir = File.join(tmp_root, "empty-repo")
      FileUtils.mkdir_p(dir)
      run_git("init", "--quiet", dir: dir)

      refute Diff.available?(root: dir), "a repository with no HEAD has nothing to diff against"
      assert_empty Diff.changed_files(root: dir)
      assert_empty Diff.changed_lines(root: dir)
    end

    # --- the single-commit repository -------------------------------------------

    def test_available_once_there_is_a_commit
      skip_without_git
      seed_repo

      assert Diff.available?(root: repo)
      assert_equal File.realpath(repo), Diff.git_root(root: repo)
      assert_match(/\A[0-9a-f]{40}\z/, Diff.head_sha(root: repo))
    end

    def test_the_first_commit_counts_as_entirely_changed
      skip_without_git
      seed_repo

      assert_includes Diff.changed_files(root: repo), "app/models/user.rb"
      assert_equal Set[1, 2, 3, 4, 5], Diff.changed_lines(root: repo)["app/models/user.rb"]
    end

    # --- working tree changes ----------------------------------------------------

    def test_modified_lines_in_a_tracked_file
      skip_without_git
      seed_repo
      write_repo("app/models/user.rb", <<~RUBY)
        class User
          def name
            "CHANGED"
          end
        end
      RUBY

      assert_equal ["app/models/user.rb"], Diff.changed_files(root: repo)
      assert_equal Set[3], Diff.changed_lines(root: repo)["app/models/user.rb"]
    end

    def test_appended_lines_are_all_reported
      skip_without_git
      seed_repo
      write_repo("app/models/user.rb", "#{File.read(File.join(repo, "app/models/user.rb"))}\n# one\n# two\n")

      assert_equal Set[6, 7, 8], Diff.changed_lines(root: repo)["app/models/user.rb"]
    end

    def test_an_untracked_file_counts_as_changed_in_its_entirety
      skip_without_git
      seed_repo
      write_repo("app/models/order.rb", "class Order\nend\n")

      assert_includes Diff.changed_files(root: repo), "app/models/order.rb"
      assert_equal Set[1, 2], Diff.changed_lines(root: repo)["app/models/order.rb"]
    end

    def test_a_deleted_file_is_not_reported_as_changed
      skip_without_git
      seed_repo
      FileUtils.rm(File.join(repo, "app/models/user.rb"))

      refute_includes Diff.changed_files(root: repo), "app/models/user.rb"
      refute Diff.changed_lines(root: repo).key?("app/models/user.rb")
    end

    def test_an_ignored_file_is_not_reported_as_changed
      skip_without_git
      seed_repo
      write_repo(".gitignore", "generated/\n")
      write_repo("generated/thing.rb", "# generated\n")

      refute_includes Diff.changed_files(root: repo), "generated/thing.rb"
    end

    def test_dirty_reflects_the_working_tree
      skip_without_git
      seed_repo

      refute_predicate_dirty
      write_repo("app/models/user.rb", "# touched\n")

      assert Diff.dirty?(root: repo)
    end

    # --- branches ----------------------------------------------------------------

    def test_a_feature_branch_is_compared_against_its_branch_point
      skip_without_git
      seed_repo
      write_repo("app/models/account.rb", "class Account\nend\n")
      commit("second commit on main")

      run_git("checkout", "--quiet", "-b", "feature")
      write_repo("app/models/account.rb", "class Account\n  def id = 1\nend\n")
      commit("work on the branch")

      changed = Diff.changed_files(root: repo)

      assert_equal ["app/models/account.rb"], changed,
                   "only the branch's own work should count, not everything since the repo began"
      assert_equal Set[2], Diff.changed_lines(root: repo)["app/models/account.rb"]
    end

    def test_uncommitted_work_on_a_branch_is_included_alongside_its_commits
      skip_without_git
      seed_repo
      run_git("checkout", "--quiet", "-b", "feature")
      write_repo("app/models/account.rb", "class Account\nend\n")
      commit("committed on the branch")
      write_repo("app/jobs/purge_job.rb", "class PurgeJob\nend\n")

      assert_equal %w[app/jobs/purge_job.rb app/models/account.rb], Diff.changed_files(root: repo).sort
    end

    def test_an_explicit_since_overrides_the_detected_base
      skip_without_git
      seed_repo
      first = Diff.head_sha(root: repo)
      write_repo("app/models/account.rb", "class Account\nend\n")
      commit("second")
      write_repo("app/models/invoice.rb", "class Invoice\nend\n")
      commit("third")

      assert_equal %w[app/models/account.rb app/models/invoice.rb],
                   Diff.changed_files(since: first, root: repo).sort
      assert_equal ["app/models/invoice.rb"],
                   Diff.changed_files(since: "HEAD~1", root: repo)
    end

    def test_an_unresolvable_since_yields_no_diff_information
      skip_without_git
      seed_repo

      assert_empty Diff.changed_files(since: "no-such-ref", root: repo)
      assert_empty Diff.changed_lines(since: "no-such-ref", root: repo)
    end

    # --- shapes ------------------------------------------------------------------

    def test_absolute_paths_are_anchored_at_the_repository_root
      skip_without_git
      seed_repo
      write_repo("app/models/user.rb", "# rewritten\n")

      expected = File.join(File.realpath(repo), "app/models/user.rb")

      assert_equal [expected], Diff.changed_files(root: repo, absolute: true)
      assert Diff.changed_lines(root: repo, absolute: true).key?(expected)
    end

    def test_changed_lines_values_are_sets_of_integers
      skip_without_git
      seed_repo

      Diff.changed_lines(root: repo).each_value do |numbers|
        assert_kind_of Set, numbers
        assert(numbers.all? { |n| n.is_a?(Integer) && n.positive? })
      end
    end

    def test_a_renamed_file_is_reported_under_its_new_name
      skip_without_git
      seed_repo
      run_git("checkout", "--quiet", "-b", "feature")
      run_git("mv", "app/models/user.rb", "app/models/person.rb")
      commit("rename")

      changed = Diff.changed_files(root: repo)

      assert_includes changed, "app/models/person.rb"
      refute_includes changed, "app/models/user.rb"
    end

    # --- path unquoting ----------------------------------------------------------

    def test_unquote_leaves_ordinary_paths_alone
      assert_equal "app/models/user.rb", Diff.unquote("app/models/user.rb")
    end

    def test_unquote_decodes_gits_c_style_quoting
      assert_equal "app/a b.rb", Diff.unquote('"app/a b.rb"')
      assert_equal "app/weiß.rb", Diff.unquote('"app/wei\303\237.rb"')
      assert_equal 'app/"q".rb', Diff.unquote('"app/\"q\".rb"')
    end

    # --- helpers -----------------------------------------------------------------

    private

    def repo
      @repo ||= begin
        dir = File.join(tmp_root, "repo")
        FileUtils.mkdir_p(dir)
        run_git("init", "--quiet", dir: dir)
        run_git("symbolic-ref", "HEAD", "refs/heads/main", dir: dir)
        run_git("config", "user.email", "constable@example.test", dir: dir)
        run_git("config", "user.name", "Constable", dir: dir)
        run_git("config", "commit.gpgsign", "false", dir: dir)
        dir
      end
    end

    def seed_repo
      write_repo("app/models/user.rb", <<~RUBY)
        class User
          def name
            "constable"
          end
        end
      RUBY
      commit("first commit")
    end

    def write_repo(relative, contents)
      path = File.join(repo, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    def commit(message)
      run_git("add", "-A")
      run_git("commit", "--quiet", "--no-gpg-sign", "-m", message)
    end

    def run_git(*args, dir: repo)
      out, err, status = Open3.capture3("git", *args, chdir: dir)
      flunk("git #{args.join(" ")} failed: #{err}") unless status.success?
      out
    end

    def refute_predicate_for_root(dir)
      refute Diff.available?(root: dir)
    end

    def refute_predicate_dirty
      refute Diff.dirty?(root: repo)
    end

    def skip_without_git
      skip("git is not available on this machine") unless GIT_AVAILABLE
    end
  end
end
