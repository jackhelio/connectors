require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../test/dummy/config/environment"

abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: true)

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

# Capture the connector registry once after all autoloaded connector classes
# have run their `connector ...` DSL calls. Restore it before every example
# so per-spec `Registry.clear!` calls don't leak between tests.
module ConnectorsSpecState
  class << self
    attr_accessor :initial_registry
  end
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.before(:suite) do
    Rails.application.eager_load!
    ConnectorsSpecState.initial_registry = Connectors::Registry.all.dup
  end

  config.before(:each) do
    Connectors.reset_configuration!
    Connectors::Registry.clear!
    ConnectorsSpecState.initial_registry.each { |k, v| Connectors::Registry.register(k, v) }
  end
end
