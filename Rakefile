# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

desc "Run the RuboCop extension's own suite"
task :cops do
  Dir.chdir("rubocop-constable") { sh "bundle exec rake test" }
end

task default: :test
