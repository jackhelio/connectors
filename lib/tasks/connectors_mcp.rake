namespace :connectors do
  namespace :mcp do
    desc "Delete expired MCP authorization and interaction records"
    task cleanup: :environment do
      Connectors::McpAuthorization.expired.delete_all
      Connectors::McpInteraction.expired.delete_all
    end
  end
end
