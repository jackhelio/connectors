module Connectors
  # One sharing entry per (grant, principal) pair. The engine intentionally
  # doesn't know what a principal is — `principal_type` / `principal_id`
  # are opaque tuples supplied by the host's
  # `Connectors.configuration.principal_resolver` block.
  #
  # `role` mirrors n8n's enterprise model: viewer = read-only, editor =
  # update + use, owner = full control (delete + share + transfer). Only
  # one `:owner` per grant — enforced by the unique index on
  # `(grant_id, principal_type, principal_id)` plus a custom uniqueness
  # validation per role.
  class CredentialShare < ApplicationRecord
    self.table_name = "connectors_credential_shares"

    belongs_to :grant, class_name: "Connectors::Grant"

    ROLES = %w[viewer editor owner].freeze
    validates :role, inclusion: { in: ROLES }
    validates :principal_type, :principal_id, presence: true
    validates :principal_id, uniqueness: { scope: %i[grant_id principal_type] }

    # `principals` is an array of [type, id] tuples, as returned by the
    # host's `principal_resolver`. Returns shares matching ANY of them.
    scope :for_principals, ->(principals) {
      next none if principals.blank?
      clause = principals.map { "(principal_type = ? AND principal_id = ?)" }.join(" OR ")
      args   = principals.flat_map { |type, id| [ type.to_s, id ] }
      where(clause, *args)
    }
  end
end
