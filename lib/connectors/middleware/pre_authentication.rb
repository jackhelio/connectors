module Connectors
  module Middleware
    # Runs the connector's `pre_authentication` block (Phase 3) before each
    # outgoing request — but only when the cached credentials look stale.
    # Mirrors n8n's contract at packages/workflow/src/interfaces.ts:374-377;
    # n8n's runtime gates re-runs on `credentialsExpired: boolean` (see
    # `ICredentialsHelper.runPreAuthentication` at :232-238). We use the
    # same conceptual signal: if the credentials hash carries an
    # `expires_at` (unix seconds) and it's in the past — OR no expires_at
    # has ever been set — the hook fires and its return value is merged
    # into the grant's credentials before the AuthenticateGeneric step.
    #
    # Reference impl: CrowdStrikeOAuth2Api.credentials.ts:62-76 — fetches
    # an access token from `/oauth2/token` using client_id + client_secret,
    # returns `{ sessionToken }` which feeds `authenticate.headers.Authorization`.
    class PreAuthentication < Faraday::Middleware
      def initialize(app, grant:, pre_auth_block:)
        super(app)
        @grant   = grant
        @block   = pre_auth_block
        @helpers = PreAuthenticationHelpers.new
      end

      def call(env)
        refresh_if_expired!
        @app.call(env)
      end

      private

      def refresh_if_expired!
        return unless credentials_expired?
        @grant.with_persistence_lock do
          next unless credentials_expired?
          delta = run_block
          next if delta.nil? || delta.empty?
          @grant.update_credentials!(delta.transform_keys(&:to_s))
        end
      end

      def credentials_expired?
        expires_at = @grant.credentials_hash["expires_at"]
        return true if expires_at.nil?
        Time.now.to_i >= expires_at.to_i
      end

      def run_block
        @block.call(@grant.credentials_hash, @helpers)
      rescue => e
        raise Connectors::AuthenticationFailed.new("pre_authentication failed: #{e.class}: #{e.message}")
      end
    end
  end
end
