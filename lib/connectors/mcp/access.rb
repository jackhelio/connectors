module Connectors
  module MCP
    class Access
      RANK = GrantPolicy::ROLE_RANK
      attr_reader :grant, :actor, :principals

      def initialize(grant:, actor:, principals: nil)
        @grant, @actor = grant, actor
        @principals = principals || (actor ? [ [ actor.class.polymorphic_name, actor.id ] ] : [])
      end

      def require!(role = :viewer)
        grant.reload
        raise AccessDenied, "MCP grant is unavailable" unless Registry.fetch(grant.connector_key).mcp? && !grant.revoked?
        actual = role_for
        raise AccessDenied, "MCP grant requires #{role} access" unless actual && RANK.fetch(actual) >= RANK.fetch(role.to_s)
        self
      rescue ActiveRecord::RecordNotFound, Connectors::UnknownConnector
        raise AccessDenied, "MCP grant is unavailable"
      end

      def role_for
        GrantPolicy.role_for(grant, owner: actor, principals: principals)
      end

      def fingerprint
        data = canonical(configuration.except("mcp_oauth"))
        Digest::SHA256.hexdigest(JSON.generate([ grant.owner_type, grant.owner_id, grant.is_managed, grant.external_ref, data ]))
      end

      def configuration
        ConnectionConfig.resolve(grant.credentials_hash, connector: Registry.fetch(grant.connector_key), internal: true)
      end

      def actor_key
        actor.to_global_id.to_s
      end

      private

      def canonical(value)
        case value
        when Hash then value.sort_by { |key, _| key.to_s }.to_h.transform_values { |item| canonical(item) }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
    end
  end
end
