module Connectors
  module Middleware
    # Run pre_authentication when expires_at is absent or in the past.
    # Merge returned credentials before AuthenticateGeneric injects them.
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
