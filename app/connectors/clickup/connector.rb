module Clickup
  class Connector < Connectors::Connector
    connector key: :clickup, auth: :api_key, base_url: nil, display_name: "ClickUp",
      documentation_url: "https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server",
      instructions: "Create the connection, then authorize your ClickUp account and select your Workspaces. ClickUp MCP requires OAuth; personal API tokens are not supported."

    mcp server_url: "https://mcp.clickup.com/mcp", auth_mode: "oauth"

    credentials do
      field :client_information, type: "json", secret: true, display_name: "Pre-registered OAuth client (optional)"
    end
  end
end
