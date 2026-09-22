module Connectors
  # Periodic poller for connectors that opt into polling. Two modes:
  #
  #   PollJob.perform_later          # fan-out: enqueues one PollJob per eligible grant
  #   PollJob.perform_later(grant.id) # poll one grant
  #
  # In production, schedule the fan-out from Solid Queue's recurring config:
  #
  #   # config/recurring.yml (in the host app)
  #   production:
  #     poll_connectors:
  #       class: Connectors::PollJob
  #       queue: default
  #       schedule: every 5 minutes
  #
  # Grants whose connector class hasn't overridden #poll are skipped so we
  # don't enqueue dead work.
  class PollJob < ApplicationJob
    queue_as :default

    def perform(grant_id = nil)
      grant_id ? poll_one(grant_id) : fan_out
    end

    def self.poll_implemented?(connector_key)
      klass = Registry.fetch(connector_key)
      klass.instance_method(:poll).owner != Connectors::Connector
    rescue Connectors::UnknownConnector
      false
    end

    private

    def fan_out
      Grant.active.find_each do |grant|
        next unless self.class.poll_implemented?(grant.connector_key)
        self.class.perform_later(grant.id)
      end
    end

    def poll_one(grant_id)
      grant = Grant.find(grant_id)
      return unless grant.active?

      grant.connector.poll
      grant.update_columns(last_used_at: Time.current)
    end
  end
end
