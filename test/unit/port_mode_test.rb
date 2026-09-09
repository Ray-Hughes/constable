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
      write_file("spec/models/gadget_spec.rb", <<~SPEC)
        describe "Gadget" do
          subject { [1, 2] }
          it { is_expected.to include(1) }
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
  end
end
