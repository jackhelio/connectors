module Connectors
  # Enforce supported_nodes restrictions, including generic_auth permission
  # for :http_request. An empty allowlist permits every node type.
  #
  # Call from inside a node's execution wrapper before it touches the grant:
  #
  #   Connectors::PermissionCheck.permit!(grant, node_type: :slack_send_message)
  #
  # Raises `Connectors::CredentialNotPermitted` on a denied match so callers
  # see one consistent failure mode.
  module PermissionCheck
    module_function

    def permits?(grant, node_type:)
      connector_class = Registry.fetch(grant.connector_key)
      connector_class.supports_node?(node_type)
    end

    def permit!(grant, node_type:)
      connector_class = Registry.fetch(grant.connector_key)
      return true if connector_class.supports_node?(node_type)
      reason =
        if connector_class.supported_nodes.any?
          "supported_nodes: #{connector_class.supported_nodes.inspect}"
        else
          "credential generic-auth-only"
        end
      raise CredentialNotPermitted.new(grant.connector_key, node_type, reason: reason)
    end
  end
end
