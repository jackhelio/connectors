module RemoteMcp
  class Connector < Connectors::Connector
    connector key: :mcp, auth: :api_key, base_url: nil, display_name: "MCP server",
      documentation_url: "https://modelcontextprotocol.io/specification/2026-07-28"

    mcp

    credentials do
      field :server_url, type: "string", required: true, display_name: "Server URL"
      field :auth_mode, type: "options", required: true, default: "none", display_name: "Authentication mode",
        options: [ { name: "Public server", value: "none" }, { name: "Bearer token", value: "bearer" }, { name: "Custom headers", value: "headers" }, { name: "OAuth", value: "oauth" } ]
      field :bearer_token, type: "string", secret: true, display_name: "Bearer token", display_options: { show: { auth_mode: [ "bearer" ] } }
      field :headers, type: "json", secret: true, display_name: "Custom headers", display_options: { show: { auth_mode: [ "headers" ] } }
      field :client_information, type: "json", secret: true, display_name: "Pre-registered OAuth client (optional)", display_options: { show: { auth_mode: [ "oauth" ] } }
      field :authorization_server, type: "string", display_name: "Authorization server (optional)", display_options: { show: { auth_mode: [ "oauth" ] } }
    end
  end
end
