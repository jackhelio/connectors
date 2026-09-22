module Connectors
  module MCP
    module PendingTransaction
      extend ActiveSupport::Concern
      included do
        belongs_to :grant, class_name: "Connectors::Grant"
        serialize :payload, coder: JSON, type: Hash
        encrypts :payload
        scope :expired, -> { where(expires_at: ..Time.current) }
      end

      def claim!(access)
        with_lock do
          access.require!(self.class::REQUIRED_ROLE)
          unless status == "pending" && expires_at > Time.current && grant_id == access.grant.id && actor_key == access.actor_key && fingerprint == access.fingerprint
            raise AccessDenied, "MCP transaction is expired, changed, or already used"
          end
          data = payload.deep_dup
          yield data if block_given?
          update!(status: "claimed")
          data
        end
      end
    end
  end
end
