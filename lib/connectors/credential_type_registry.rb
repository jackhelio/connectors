module Connectors
  # Registry of reusable base credential schemas that connectors `extends`.
  # Mirrors n8n's pattern where every OAuth2 provider extends a single
  # canonical `OAuth2Api` credential type (packages/nodes-base/credentials/
  # OAuth2Api.credentials.ts:1-238). The registry is populated at engine
  # boot — see `Connectors::Engine`.
  class CredentialTypeRegistry
    class << self
      def register(name, schema)
        store[name.to_sym] = schema
      end

      def fetch(name)
        store.fetch(name.to_sym) do
          raise Error.new("unknown base credential type #{name.inspect}; known: #{store.keys.inspect}")
        end
      end

      def all
        store.dup
      end

      def clear!
        store.clear
      end

      private

      def store
        @store ||= {}
      end
    end

    # Canonical OAuth2 credential schema — every OAuth2 provider connector
    # extends this and overrides specific fields as `type: "hidden"` with a
    # fixed `default`. Field set matches n8n's OAuth2Api credentials type
    # (packages/nodes-base/credentials/OAuth2Api.credentials.ts:1-238).
    OAUTH2 = CredentialSchema.build do
      field :grant_type,
            type:         "options",
            display_name: "Grant Type",
            default:      "authorizationCode",
            required:     true,
            description:  "OAuth2 grant flow to use.",
            options: [
              { name: "Authorization Code",      value: "authorizationCode" },
              { name: "Client Credentials",      value: "clientCredentials" },
              { name: "Authorization Code (PKCE)", value: "pkce" }
            ]

      field :authorization_url,
            type:         "string",
            display_name: "Authorization URL",
            required:     true,
            placeholder:  "https://example.com/oauth/authorize",
            display_options: { show: { grant_type: %w[authorizationCode pkce] } }

      field :access_token_url,
            type:         "string",
            display_name: "Access Token URL",
            required:     true,
            placeholder:  "https://example.com/oauth/token"

      field :client_id,
            type:         "string",
            display_name: "Client ID",
            required:     true

      field :client_secret,
            type:         "string",
            display_name: "Client Secret",
            required:     true,
            secret:       true

      field :scope,
            type:         "string",
            display_name: "Scope",
            default:      "",
            description:  "Space-separated list of OAuth scopes to request."

      field :auth_query_parameters,
            type:         "string",
            display_name: "Auth URI Query Parameters",
            default:      "",
            description:  "Additional query parameters appended to the authorize URL " \
                          "(e.g., `access_type=offline&prompt=consent`)."

      field :authentication,
            type:         "options",
            display_name: "Authentication",
            default:      "header",
            description:  "How the client_id / client_secret are sent during token exchange.",
            options: [
              { name: "Header",          value: "header" },
              { name: "Body",            value: "body" }
            ]

      # Phase 11 polish — OAuth2 advanced fields. n8n parity:
      # `OAuth2Api.credentials.ts:208-237`. Form-only at the engine level
      # (no runtime JWE decryption); ship the schema so the editor can
      # render the configuration UI for enterprise SSO scenarios.
      field :jwe_enabled,
            type:         "boolean",
            display_name: "Encrypted Tokens (JWE)",
            default:      false,
            description:  "Whether the IdP returns tokens encrypted as JWE to the public key at this " \
                          "instance's JWKS endpoint."
      field :jwks_uri,
            type:         "string",
            display_name: "JWKS URI",
            default:      "",
            description:  "Provide this URL to your IdP so it can fetch the public key used to " \
                          "encrypt access and ID tokens for this instance.",
            display_options: { show: { jwe_enabled: [ true ] } }
    end

    # n8n's canonical `OAuth1Api` credential type
    # (packages/nodes-base/credentials/OAuth1Api.credentials.ts:1-72). Same
    # storage shape as OAuth2's `client_id` / `client_secret` — they map to
    # the `consumerKey` / `consumerSecret` here. Connectors that extend this
    # type generally `field :authorization_url, type: "hidden", default: "..."`
    # to lock the provider endpoint.
    OAUTH1 = CredentialSchema.build do
      display_name      "OAuth1 API"
      documentation_url "httprequest"
      generic_auth!

      field :authorization_url,
            type:         "string",
            display_name: "Authorization URL",
            required:     true
      field :access_token_url,
            type:         "string",
            display_name: "Access Token URL",
            required:     true
      field :request_token_url,
            type:         "string",
            display_name: "Request Token URL",
            required:     true
      field :consumer_key,
            type:         "string",
            display_name: "Consumer Key",
            required:     true,
            secret:       true
      field :consumer_secret,
            type:         "string",
            display_name: "Consumer Secret",
            required:     true,
            secret:       true
      field :signature_method,
            type:         "options",
            display_name: "Signature Method",
            required:     true,
            default:      "HMAC-SHA1",
            options: [
              { name: "HMAC-SHA1",   value: "HMAC-SHA1" },
              { name: "HMAC-SHA256", value: "HMAC-SHA256" },
              { name: "HMAC-SHA512", value: "HMAC-SHA512" }
            ]
    end
  end
end
