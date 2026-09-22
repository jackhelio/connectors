require "digest"

module Connectors
  module OAuth
    # New authorizations create new connections. Reconnection must name an
    # existing connection and preserve its owner, provider and known account.
    class GrantWriter
      def self.fingerprint(grant)
        Digest::SHA256.hexdigest(JSON.generate([ grant.credentials, grant.external_account_id, grant.status ]))
      end

      def initialize(owner:, connector_class:, grant_id: nil, fingerprint: nil)
        @owner = owner
        @connector_class = connector_class
        @grant_id = grant_id
        @fingerprint = fingerprint
      end

      def validate!
        return unless @grant_id
        verify_snapshot!(target)
      end

      def call(tokens, name: nil)
        unless @grant_id
          grant = Grant.new(owner: @owner, connector_key: @connector_class.connector_key.to_s)
          return persist(grant, tokens, name)
        end

        grant = target
        grant.with_lock do
          # Ownership/credentials may have changed while the provider request
          # was in flight. Never overwrite that newer connection snapshot.
          verify_snapshot!(grant)
          persist(grant, tokens, name)
        end
        grant
      end

      private

      def target
        Grant.where(owner: @owner).for_connector(@connector_class.connector_key).find(@grant_id)
      end

      def verify_snapshot!(grant)
        unless grant.owner == @owner && grant.connector_key == @connector_class.connector_key.to_s &&
               @fingerprint == self.class.fingerprint(grant)
          raise Connectors::Error, "connection changed during authorization; start again"
        end
      end

      def persist(grant, tokens, name)
        account_id = @connector_class.external_account_id_from_credentials(tokens)
        if grant.external_account_id.present? && account_id.present? && grant.external_account_id != account_id
          raise Connectors::Error, "authorized account does not match this connection"
        end

        credentials = grant.stored_credentials_hash.merge(tokens)
        grant.assign_attributes(
          credentials: credentials,
          status: :active,
          expires_at: (Time.at(credentials["expires_at"]) if credentials["expires_at"]),
          last_used_at: Time.current,
          external_account_id: account_id.presence || grant.external_account_id
        )
        grant.display_name = name if name.present?
        grant.save!
        grant
      end
    end
  end
end
