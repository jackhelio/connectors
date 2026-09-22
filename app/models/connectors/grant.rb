module Connectors
  # A Grant is the user-authorized link between an owner (User, Workspace, etc.)
  # and a third-party service. It stores the encrypted tokens / API keys needed
  # to call that service's API on the owner's behalf.
  class Grant < ApplicationRecord
    serialize :credentials, coder: JSON, type: Hash
    encrypts  :credentials

    belongs_to :owner, polymorphic: true
    has_many   :shares,         class_name: "Connectors::CredentialShare", dependent: :destroy
    has_many   :webhook_events, class_name: "Connectors::WebhookEvent",    dependent: :destroy
    has_many   :poll_states,    class_name: "Connectors::PollState",       dependent: :destroy

    enum :status, { active: 0, expired: 1, revoked: 2, errored: 3 }, default: :active

    validates :connector_key, presence: true

    scope :for_connector, ->(key) { where(connector_key: key.to_s) }
    scope :expiring_within, ->(window) { where(expires_at: ..window.from_now).where.not(expires_at: nil) }

    # Returns an instance of the connector class registered for this grant's key.
    def connector
      Connectors::Registry.fetch(connector_key).new(self)
    end

    # Cached clients must observe revocation by another worker. Read only the
    # status so pending changes to credentials or polling state are preserved.
    def ensure_not_revoked!
      revoked_in_database = persisted? && self.class.uncached { self.class.where(id: id, status: :revoked).exists? }
      raise Connectors::AuthenticationFailed, "connection has been revoked" if revoked? || revoked_in_database
    end

    # Atomic merge into the encrypted credentials hash. Always go through this
    # instead of mutating the hash in-place, since serialized columns don't
    # dirty-track mutation. Invalidates the per-instance resolved cache so a
    # follow-up `credentials_hash` re-blends the vault values.
    def update_credentials!(patch)
      patch = patch.stringify_keys
      with_persistence_lock do
        attrs = { credentials: (credentials || {}).merge(patch) }
        attrs[:expires_at] = patch["expires_at"] && Time.at(patch["expires_at"].to_i) if patch.key?("expires_at")
        update!(attrs)
        clear_resolved_credentials
      end
    end

    def reload(...)
      clear_resolved_credentials
      super
    end

    # Unsaved candidates can use the same primitives without attempting a row
    # lock. Persisted grants always re-read under a database lock.
    def with_persistence_lock(&block)
      persisted? ? with_lock(&block) : yield
    end

    # Convenience accessor that always returns a hash, never nil. When the
    # grant is `is_managed?`, the host's `secrets_resolver` is invoked and
    # its return value is merged over the DB-stored credentials — the vault
    # wins, so rotating a value in Vault propagates without a DB write.
    # Cached per-instance to keep one request = one vault lookup.
    def credentials_hash
      return @resolved_credentials_hash if defined?(@resolved_credentials_hash)
      base = credentials || {}
      @resolved_credentials_hash = is_managed? ? base.merge(Connectors.configuration.resolve_secrets(self)) : base
    end

    # The raw, DB-only credentials hash (never consults the vault). Used by
    # the index serializer to compute `__overwritten_properties` without
    # tripping the resolver on every list response.
    def stored_credentials_hash
      credentials || {}
    end

    # Scratch storage for webhook subscriptions and polling cursors.
    # Save after mutation or use update_static_data! for an atomic update.
    def static_data_hash
      static_data || {}
    end

    # Yields the sub-hash for a webhook/polling group, then persists any
    # mutation in a single UPDATE. Group defaults to "default" so single-
    # webhook providers don't need to think about it.
    def update_static_data!(group = "default")
      with_persistence_lock do
        data = static_data_hash.deep_dup
        sub = (data[group.to_s] ||= {})
        result = yield(sub)
        update!(static_data: data)
        result
      end
    end

    private

    def clear_resolved_credentials
      remove_instance_variable(:@resolved_credentials_hash) if defined?(@resolved_credentials_hash)
    end
  end
end
