module Connectors
  class McpAuthorization < ApplicationRecord
    REQUIRED_ROLE = :owner
    include MCP::PendingTransaction
  end
end
