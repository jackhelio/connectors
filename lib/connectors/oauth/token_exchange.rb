require "faraday"
require "uri"

module Connectors
  module OAuth
    # Talks to the provider's token endpoint for both the authorization-code
    # exchange (initial connection) and refresh-token grant (token rotation).
    # Returns a normalized hash that can be merged directly into a Grant's
    # credentials column.
    class TokenExchange
      def self.exchange_code(connector_class, code:, code_verifier: nil)
        new(connector_class).exchange_code(code, code_verifier: code_verifier)
      end

      def self.refresh(connector_class, refresh_token:)
        new(connector_class).refresh(refresh_token)
      end

      def initialize(connector_class)
        @connector_class = connector_class
        @config          = connector_class.oauth2_config or
          raise Connectors::Error.new("#{connector_class}: oauth2 ... DSL not declared")
        @secrets         = Connectors.configuration.oauth_credentials_for(connector_class.connector_key)
      end

      def exchange_code(code, code_verifier: nil)
        # PKCE supplements client authentication for confidential clients.
        params = {
          grant_type:    "authorization_code",
          code:          code,
          redirect_uri:  redirect_uri
        }
        params[:code_verifier] = code_verifier if code_verifier
        post_token(params)
      end

      def refresh(refresh_token)
        post_token(
          grant_type:    "refresh_token",
          refresh_token: refresh_token
        )
      end

      private

      def post_token(params)
        headers = {
          "Content-Type" => "application/x-www-form-urlencoded",
          "Accept"       => "application/json"
        }
        ClientAuthentication.apply(params, headers, secrets: @secrets, authentication: @config[:authentication])
        response = Faraday.post(@config[:token_url], URI.encode_www_form(params.compact), headers) do |request|
          request.options.open_timeout = ClientBuilder::DEFAULT_OPEN_TIMEOUT
          request.options.timeout = ClientBuilder::DEFAULT_TIMEOUT
        end

        body = TokenResponse.parse(response)
        @connector_class.post_token_exchange(body, TokenResponse.normalize(body))
      end

      # Must match the redirect_uri sent during the authorize leg or the
      # provider rejects the exchange with `redirect_uri_mismatch`. Both
      # legs read from the same config slot so they stay in lockstep.
      def redirect_uri
        Connectors.configuration.resolved_app_callback_url(@connector_class.connector_key)
      end
    end
  end
end
