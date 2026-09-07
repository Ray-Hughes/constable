# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "minitest", "~> 5.16"
gem "rubocop", "~> 1.60"
gem "rubocop-ast", ">= 1.30"

group :development, :test do
  gem "rails", ">= 7.0"
  # Needed to exercise the cold-case adapters in our own suite.
  gem "rspec-core", ">= 3.10"
  gem "rspec-expectations", ">= 3.10"
end
