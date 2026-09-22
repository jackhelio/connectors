module Connectors
  # Shared access boundary for every credential endpoint. The host supplies
  # identities; the engine applies the same roles to CRUD, actions and OAuth.
  module GrantAccess
    extend ActiveSupport::Concern

    private

    ROLE_RANK = GrantPolicy::ROLE_RANK

    def current_owner!
      @connectors_owner ||= Connectors.configuration.resolve_owner(self) or
        raise Connectors::Error, "current_owner_resolver returned nil"
    end

    def current_principals
      @connectors_principals ||= Connectors.configuration.resolve_principals(self) || []
    end

    def visible_grants
      owner = current_owner!
      shared_ids = CredentialShare.for_principals(current_principals).select(:grant_id)
      Grant.where(owner: owner).or(Grant.where(id: shared_ids))
    end

    def find_visible_grant!(id, min_role: :viewer)
      grant = visible_grants.find(id)
      require_grant_role!(grant, min_role)
      grant
    end

    def require_grant_role!(grant, min_role)
      role = role_for(grant, owner: current_owner!)
      if role.nil? || ROLE_RANK.fetch(role) < ROLE_RANK.fetch(min_role.to_s)
        raise Connectors::Error, "credential #{grant.id} requires #{min_role} role (you have #{role})"
      end
    end

    def role_for(grant, owner:)
      GrantPolicy.role_for(grant, owner: owner, principals: current_principals)
    end
  end
end
