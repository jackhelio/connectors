module Connectors
  class McpInteraction < ApplicationRecord
    REQUIRED_ROLE = :editor
    include MCP::PendingTransaction
  end
end
