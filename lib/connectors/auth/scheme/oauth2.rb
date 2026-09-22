module Connectors
  module Auth
    class Scheme
      # Attaches an OAuth2 access token as a Bearer Authorization header. The
      # token is read from grant.credentials["access_token"]. Token refresh is
      # handled separately by the AutoRefresh middleware + the connector's
      # #refresh! method.
      class OAuth2 < Scheme
        register_as :oauth2

        def on_request(env)
          token = @grant.credentials_hash["access_token"]
          if token.nil? || token.to_s.empty?
            raise Connectors::AuthenticationFailed.new(
              "grant #{@grant.id} has no access_token"
            )
          end
          env.request_headers["Authorization"] = "Bearer #{token}"
        end
      end
    end
  end
end
