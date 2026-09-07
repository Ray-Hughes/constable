# frozen_string_literal: true

require "generators/constable/base"

module Constable
  module Generators
    # Invoked by `rails generate job CleanUp`.
    #
    #   test/cases/jobs/clean_up_job_case.rb   class CleanUpJobCase < IntegrationCase
    class JobGenerator < Base
      check_class_collision suffix: "JobCase"

      strips_suffix(/_job\z/i)

      def create_case_file
        template "job_case.rb.tt", case_path("jobs", class_path, "#{file_name}_job_case.rb")
      end
    end
  end
end
