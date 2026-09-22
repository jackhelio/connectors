require "faraday"
require "uri"

module Connectors
  module OAuth
    # Server-to-server OAuth2 flow — no user redirect. POSTs
    # `grant_type=client_credentials` + `client_id`/`client_secret` to the
    # provider's token endpoint and returns a normalized token hash that the
    # OAuthController writes to a new or explicitly selected Grant.
    #
    # n8n parity: `OAuth2Api.credentials.ts:1-45` declares the `grantType`
    # field with `clientCredentials` as one option; the runtime branch lives
    # at `oauth.service.ts:783-789`.
    class ClientCredentials
      def self.exchange(connector_class)
        new(connector_class).exchange
      end

      def initialize(connector_class)
        @connector_class = connector_class
        @config          = connector_class.oauth2_config or
          raise Connectors::Error.new("#{connector_class}: oauth2 ... DSL not declared")
        @secrets         = Connectors.configuration.oauth_credentials_for(connector_class.connector_key)
      end

      def exchange
        body = { grant_type: "client_credentials" }
        body[:scope] = @config[:scope] if @config[:scope].to_s.length.positive?

        headers = { "Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json" }

        ClientAuthentication.apply(body, headers, secrets: @secrets, authentication: @config[:authentication])

        response = Faraday.post(@config[:token_url], URI.encode_www_form(body), headers) do |request|
          request.options.open_timeout = ClientBuilder::DEFAULT_OPEN_TIMEOUT
          request.options.timeout = ClientBuilder::DEFAULT_TIMEOUT
        end
        parsed = TokenResponse.parse(response)
        @connector_class.post_token_exchange(parsed, TokenResponse.normalize(parsed))
      end
    end
  end
end
