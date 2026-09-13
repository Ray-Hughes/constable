# frozen_string_literal: true

require_relative "../helper"

module Constable
  # `constable modernize --port`: the mode that actually moves a suite.
  #
  # Converting a file only helps if it ends up somewhere the runner looks. --alongside
  # leaves it in spec/, so porting a real suite meant a conversion followed by several
  # hundred `git mv`s -- enough friction that nobody starts. This mirrors the path into
  # test/cases/ instead, so a port is one command per directory.
  class PortModeTest < TestCase
    def port(path, write: :port)
      Importer.modernize([path], config: Constable.config, root: tmp_root,
                                 write: write, report: false).results.first
    end

    def test_a_clean_conversion_is_written_as_a_native_case
      write_file("spec/models/widget_spec.rb", <<~SPEC)
        describe "Widget" do
          it "adds up" do
            expect(1 + 1).to eq(2)
          end
        end
      SPEC

      result = port("spec/models/widget_spec.rb")

      assert_equal "test/cases/models/widget_case.rb", result.written_to
      assert_equal :native, result.written_as
      assert_path_exists File.join(tmp_root, "test/cases/models/widget_case.rb")
    end

    # A flagged conversion is not runnable: the flagged constructs are left verbatim, so
    # the class raises the moment it loads. Verified against a real file -- a ported
    # `it { ... }` died with `NoMethodError: undefined method 'it'`. Handing someone a
    # broken file and calling it progress is worse than not moving it.
    def test_a_flagged_conversion_is_ported_verbatim_instead_of_broken
      # A file-level flag, so there is nothing to split out -- the whole file stays cold.
      write_file("spec/models/gadget_spec.rb", <<~SPEC)
        describe "Gadget" do
          before(:all) { @shared = [1, 2] }
          it "includes one" do
            expect(@shared).to include(1)
          end
        end
      SPEC

      result = port("spec/models/gadget_spec.rb")

      assert_equal "test/cases/models/gadget_case.rb", result.written_to
      assert_equal :cold, result.written_as
      assert_match(/Constable::ColdCase::RSpec/,
                   File.read(File.join(tmp_root, result.written_to)))
    end

    def test_the_spec_path_is_mirrored_under_test_cases
      write_file("spec/services/tasks/reorder_spec.rb", <<~SPEC)
        describe "Reorder" do
          it("works") { expect(1).to eq(1) }
        end
      SPEC

      assert_equal "test/cases/services/tasks/reorder_case.rb",
                   port("spec/services/tasks/reorder_spec.rb").written_to
    end

    # A port is run repeatedly while a suite is converted a directory at a time. The second
    # run must not quietly overwrite what the first produced, or any edit made since.
    def test_porting_twice_refuses_to_overwrite
      write_file("spec/models/widget_spec.rb", <<~SPEC)
        describe "Widget" do
          it("adds up") { expect(1 + 1).to eq(2) }
        end
      SPEC

      port("spec/models/widget_spec.rb")
      second = port("spec/models/widget_spec.rb")

      assert_match(/refusing to overwrite/, second.error.to_s)
    end

    def test_port_cold_moves_even_a_convertible_file_verbatim
      write_file("spec/models/widget_spec.rb", <<~SPEC)
        describe "Widget" do
          it("adds up") { expect(1 + 1).to eq(2) }
        end
      SPEC

      result = port("spec/models/widget_spec.rb", write: :port_cold)

      assert_equal "test/cases/models/widget_case.rb", result.written_to
      assert_match(/Constable::ColdCase::RSpec/,
                   File.read(File.join(tmp_root, result.written_to)))
    end

    # --- --delete: finish the move ------------------------------------------------------
    #
    # A port that leaves the original behind has not moved anything. Both files are then
    # collected, so the suite runs those tests twice and the adoption number never moves:
    # it counts the file in test/cases/ and the spec it was made from.

    def port_and_delete(path)
      Importer.modernize([path], config: Constable.config, root: tmp_root,
                                 write: :port, report: false, delete_original: true).results.first
    end

    def test_delete_removes_the_original_once_it_has_been_written
      write_file("spec/models/widget_spec.rb", <<~SPEC)
        describe "Widget" do
          it("adds up") { expect(1 + 1).to eq(2) }
        end
      SPEC

      result = port_and_delete("spec/models/widget_spec.rb")

      assert_path_exists File.join(tmp_root, "test/cases/models/widget_case.rb")
      refute_path_exists File.join(tmp_root, "spec/models/widget_spec.rb")
      assert_equal "spec/models/widget_spec.rb", result.removed_original
    end

    # The one unrecoverable mistake available here is deleting a test that was never
    # copied, so every path that did not write keeps the original.
    def test_a_refused_overwrite_never_deletes_the_original
      write_file("spec/models/widget_spec.rb", <<~SPEC)
        describe "Widget" do
          it("adds up") { expect(1 + 1).to eq(2) }
        end
      SPEC
      port("spec/models/widget_spec.rb")

      # Recreate the source the first port consumed, then port again into the existing target.
      write_file("spec/models/widget_spec.rb", <<~SPEC)
        describe "Widget" do
          it("adds up") { expect(1 + 1).to eq(2) }
        end
      SPEC
      result = port_and_delete("spec/models/widget_spec.rb")

      assert_match(/refusing to overwrite/, result.error.to_s)
      assert_path_exists File.join(tmp_root, "spec/models/widget_spec.rb")
      assert_nil result.removed_original
    end

    def test_a_file_that_cannot_be_parsed_is_never_deleted
      write_file("spec/models/broken_spec.rb", "describe 'x' do\n  it 'y' do\n")

      result = port_and_delete("spec/models/broken_spec.rb")

      assert_path_exists File.join(tmp_root, "spec/models/broken_spec.rb")
      assert_nil result.removed_original
    end

    # --- --batch: port a directory a few files at a time --------------------------------
    #
    # `--limit` caps how many rows are printed and nothing else. Porting sixty-five files
    # while showing twenty is a display choice; porting twenty of them is a different
    # request, and conflating the two with --delete in play would delete forty-five files
    # someone thought they had excluded.

    def batch(path, size, delete: true)
      Importer.modernize([path], config: Constable.config, root: tmp_root, write: :port,
                                 report: false, delete_original: delete, batch: size)
    end

    def three_specs
      %w[a b c].each do |name|
        write_file("spec/models/#{name}_spec.rb", <<~SPEC)
          describe "#{name.upcase}" do
            it("works") { expect(1).to eq(1) }
          end
        SPEC
      end
    end

    def test_batch_ports_only_the_first_n_files
      three_specs

      run = batch("spec/models", 2)

      assert_equal 2, run.results.size
      assert_equal 1, run.remaining
      assert_path_exists File.join(tmp_root, "spec/models/c_spec.rb")
    end

    # The point of pairing it with --delete: the ported ones are gone, so the same command
    # picks up where it left off.
    def test_running_again_takes_the_next_batch
      three_specs

      batch("spec/models", 2)
      second = batch("spec/models", 2)

      assert_equal 1, second.results.size
      assert_equal 0, second.remaining
      assert_equal %w[a_case.rb b_case.rb c_case.rb],
                   Dir[File.join(tmp_root, "test/cases/models/*.rb")].map { |f| File.basename(f) }.sort
      assert_empty Dir[File.join(tmp_root, "spec/models/*.rb")]
    end

    # A batch is a prefix of a sorted list, not of whatever order the filesystem returned,
    # or "run it again for the next batch" would revisit files it had already taken.
    def test_batches_are_taken_in_a_stable_order
      three_specs

      assert_equal %w[spec/models/a_spec.rb spec/models/b_spec.rb],
                   batch("spec/models", 2, delete: false).results.map(&:relative_path)
    end

    def test_no_batch_processes_everything
      three_specs

      run = Importer.modernize(["spec/models"], config: Constable.config, root: tmp_root,
                                                write: :port, report: false)

      assert_equal 3, run.results.size
      assert_equal 0, run.remaining.to_i
    end

    # --- companions: what a ported file requires by relative path -----------------------
    #
    # `require_relative "task_shared_examples.rb"` resolves against the file's own
    # directory. Move the spec, leave the companion, and the path no longer exists -- the
    # ported file dies on LoadError before running a line. Observed on a real port: 65
    # files moved, two support files left behind, and every file requiring one broken.

    def spec_with_companion
      write_file("spec/models/shared_examples.rb", <<~RUBY)
        shared_examples_for "a thing" do
          it("works") { expect(1).to eq(1) }
        end
      RUBY
      write_file("spec/models/widget_spec.rb", <<~SPEC)
        describe "Widget" do
          require_relative "shared_examples.rb"
          it_behaves_like "a thing"
        end
      SPEC
    end

    def test_a_required_companion_is_carried_to_the_destination
      spec_with_companion

      run = Importer.modernize(["spec/models"], config: Constable.config, root: tmp_root,
                                                write: :port, report: false)

      assert_path_exists File.join(tmp_root, "test/cases/models/shared_examples.rb"),
                         "the ported file requires this by relative path"
      assert_includes run.carried, "test/cases/models/shared_examples.rb"
    end

    # Copied, not moved. Specs that have not been ported yet may still require it -- a
    # --batch port guarantees some will -- and a duplicated support file is harmless where
    # a deleted one breaks whatever still points at it.
    def test_a_companion_is_copied_rather_than_moved
      spec_with_companion

      Importer.modernize(["spec/models"], config: Constable.config, root: tmp_root,
                                          write: :port, report: false, delete_original: true)

      assert_path_exists File.join(tmp_root, "spec/models/shared_examples.rb")
      refute_path_exists File.join(tmp_root, "spec/models/widget_spec.rb")
    end

    # A port that empties a directory should not leave the directory behind.
    def test_directories_the_port_emptied_are_removed
      write_file("spec/models/nested/thing_spec.rb", <<~SPEC)
        describe "Thing" do
          it("works") { expect(1).to eq(1) }
        end
      SPEC

      Importer.modernize(["spec/models"], config: Constable.config, root: tmp_root,
                                          write: :port, report: false, delete_original: true)

      refute_path_exists File.join(tmp_root, "spec/models/nested")
    end

    # Only when empty. Anything the port did not take keeps its directory.
    def test_a_directory_still_holding_something_is_left_alone
      spec_with_companion

      Importer.modernize(["spec/models"], config: Constable.config, root: tmp_root,
                                          write: :port, report: false, delete_original: true)

      assert_path_exists File.join(tmp_root, "spec/models")
    end

    # require_relative is relative to the file, and a port moves the file. A spec at
    # spec/services/x_spec.rb requiring "../../../app/..." resolved to <root>/app; the same
    # line one level deeper resolves to <root>/test/app, which does not exist. The file
    # converts, parses, and dies on load with a LoadError naming a path nobody wrote.
    def test_a_require_relative_to_app_code_is_repointed
      write_file("app/services/thing.rb", "class Thing; end\n")
      write_file("spec/services/thing_spec.rb", <<~SPEC)
        require_relative "../../app/services/thing"

        describe Thing do
          it "works" do
            expect(1).to eq(1)
          end
        end
      SPEC

      port("spec/services/thing_spec.rb")
      written = File.read(File.join(tmp_root, "test/cases/services/thing_case.rb"))
      ref = written[/require_relative\s+"([^"]+)"/, 1]

      refute_nil ref
      assert_path_exists File.expand_path("#{ref}.rb",
                                          File.join(tmp_root, "test/cases/services"))
    end

    # App code is not a companion. Copying it duplicated production code into the test tree
    # and left a second copy nothing updates.
    def test_app_code_is_not_copied_into_the_test_tree
      write_file("app/services/thing.rb", "class Thing; end\n")
      write_file("spec/services/thing_spec.rb", <<~SPEC)
        require_relative "../../app/services/thing"

        describe Thing do
          it "works" do
            expect(1).to eq(1)
          end
        end
      SPEC

      port("spec/services/thing_spec.rb")

      refute_path_exists File.join(tmp_root, "test/cases/services/thing.rb")
    end

    # A test helper beside the spec does move with it, so its require still resolves as
    # written and must not be repointed.
    def test_a_test_helper_companion_still_moves_alongside
      write_file("spec/services/helper.rb", "module Helper; end\n")
      write_file("spec/services/thing_spec.rb", <<~SPEC)
        require_relative "./helper"

        describe "Thing" do
          it "works" do
            expect(1).to eq(1)
          end
        end
      SPEC

      port("spec/services/thing_spec.rb")

      assert_path_exists File.join(tmp_root, "test/cases/services/helper.rb")
      assert_includes File.read(File.join(tmp_root, "test/cases/services/thing_case.rb")),
                      %(require_relative "./helper")
    end
  end
end
