source "https://rubygems.org"

# Specify your gem's dependencies in connectors.gemspec.
gemspec

gem "puma"

gem "pg"

gem "propshaft"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"

group :development, :test do
  gem "rspec-rails", "~> 8.0"
  gem "webmock",     "~> 3.24"
end
