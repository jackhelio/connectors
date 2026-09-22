module Connectors
  # Shared by HTTP endpoints and services invoked by workers.
  class GrantPolicy
    ROLE_RANK = { "viewer" => 0, "editor" => 1, "owner" => 2 }.freeze

    def self.role_for(grant, owner:, principals:)
      return unless owner
      return "owner" if grant.owner_type == owner.class.polymorphic_name && grant.owner_id == owner.id
      roles = grant.shares.for_principals(principals).pluck(:role)
      roles.max_by { |role| ROLE_RANK.fetch(role) }
    end
  end
end
