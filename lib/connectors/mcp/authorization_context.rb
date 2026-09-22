module Connectors
  module MCP
    # Carries a server-issued challenge from a failed call to the owner's consent screen.
    # The browser cannot replace discovery URLs or scopes inside it.
    module AuthorizationContext
      module_function

      def encode(grant:, challenge:, fingerprint: nil)
        access = Access.new(grant: grant, actor: grant.owner)
        OAuth::State.encode(connector_key: "mcp", owner_gid: grant.owner.to_global_id.to_s,
          extra: { "purpose" => "mcp_challenge", "grant_id" => grant.id, "fingerprint" => fingerprint || access.fingerprint, "challenge" => challenge })
      end

      def decode(token, access:)
        access.require!(:owner)
        state = OAuth::State.decode(token)
        extra = state&.dig("x")
        unless state && state["k"] == "mcp" && state["o"] == access.actor_key && extra.is_a?(Hash) && extra["purpose"] == "mcp_challenge" && extra["grant_id"] == access.grant.id && extra["fingerprint"] == access.fingerprint
          raise AccessDenied, "Invalid MCP authorization context"
        end
        extra.fetch("challenge")
      end
    end
  end
end
