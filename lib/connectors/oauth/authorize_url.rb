require "uri"

module Connectors
  module OAuth
    # Builds the URL we redirect the owner to so they can authorize the
    # connector. Includes an encrypted `state` token that the callback validates.
    class AuthorizeUrl
      def self.for(connector_class, owner:, return_to: nil, scope: nil, name: nil, grant: nil)
        new(connector_class).build(owner: owner, return_to: return_to, scope: scope, name: name, grant: grant)
      end

      def initialize(connector_class)
        @connector_class = connector_class
        @config          = connector_class.oauth2_config or
          raise Connectors::Error.new("#{connector_class}: oauth2 ... DSL not declared")
        @secrets         = Connectors.configuration.oauth_credentials_for(connector_class.connector_key)
      end

      # The connector declares a DEFAULT scope set; callers can override it
      # per request via the `scope:` argument (multi-tenant hosts often
      # need a wider or narrower scope than the connector's baseline).
      # n8n's `Gmail OAuth2 API.credentials.ts` does the same thing — the
      # node ships defaults, the workflow editor can ask for more.
      def build(owner:, return_to: nil, scope: nil, name: nil, grant: nil)
        pkce = pkce_params if @config[:grant_type].to_s == "pkce"

        extras = {}
        extras["cv"] = pkce[:verifier] if pkce
        extras["n"]  = name            if name.to_s.length.positive?
        if grant
          extras["g"] = grant.id
          extras["v"] = GrantWriter.fingerprint(grant)
        end

        state = State.encode(
          connector_key: @connector_class.connector_key,
          owner_gid:     owner.to_global_id.to_s,
          return_to:     return_to,
          extra:         extras.empty? ? nil : extras
        )

        effective_scope = scope.presence || @config[:scope]

        params = {
          response_type: "code",
          client_id:     @secrets[:client_id],
          redirect_uri:  redirect_uri,
          scope:         effective_scope,
          state:         state
        }
        if pkce
          params[:code_challenge]        = pkce[:challenge]
          params[:code_challenge_method] = pkce[:method]
        end
        params = params.merge(@config[:extra_authorize_params] || {}).compact

        uri = URI.parse(@config[:authorize_url])
        existing = URI.decode_www_form(uri.query.to_s)
        uri.query = URI.encode_www_form(existing + params.to_a)
        uri.to_s
      end

      private

      def pkce_params
        Connectors::OAuth::Pkce.generate
      end

      # Reads from Connectors.configuration.app_callback_url when the host
      # has wired a separate frontend callback page (Activepieces-style split
      # frontend/backend); otherwise falls back to the engine's own
      # `/<connector>/callback` route (n8n-style monolithic).
      def redirect_uri
        Connectors.configuration.resolved_app_callback_url(@connector_class.connector_key)
      end
    end
  end
end
