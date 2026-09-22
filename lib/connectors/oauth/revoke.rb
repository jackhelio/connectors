require "faraday"
require "uri"

module Connectors
  module OAuth
    # RFC 7009 token revocation. POSTs `token=<access_token>` to the
    # provider's revoke endpoint. The connector class declares the URL via
    # `revoke_token_url "https://..."`; some providers want a different
    # request shape (Google's revoke is `?token=`, etc.), so a connector
    # can also override the whole call with a block:
    #
    #   revoke_token do |connector, grant|
    #     connector.client.delete("oauth/tokens/#{grant.credentials_hash['access_token']}")
    #   end
    #
    # n8n parity: per-provider, no centralized contract — n8n's oauth
    # service implements it ad-hoc on a per-credential basis. We give
    # connectors a single uniform DSL.
    class Revoke
      def self.call(connector_class, grant)
        new(connector_class, grant).call
      end

      def initialize(connector_class, grant)
        @connector_class = connector_class
        @grant           = grant
      end

      def call
        if (block = @connector_class.revoke_token_block)
          @connector_class.new(@grant).instance_exec(@grant, &block)
          return true
        end

        url = @connector_class.revoke_token_url or
          raise Connectors::Error.new("#{@connector_class}: no revoke_token_url or revoke_token block declared")

        token = @grant.credentials_hash["access_token"] || @grant.credentials_hash["refresh_token"]
        raise Connectors::Error.new("grant has no access_token to revoke") if token.to_s.empty?

        secrets = secrets_for_connector
        body    = { token: token, client_id: secrets[:client_id], client_secret: secrets[:client_secret] }.compact

        response = Faraday.post(url, URI.encode_www_form(body), {
          "Content-Type" => "application/x-www-form-urlencoded",
          "Accept"       => "application/json"
        }) do |request|
          request.options.open_timeout = ClientBuilder::DEFAULT_OPEN_TIMEOUT
          request.options.timeout = ClientBuilder::DEFAULT_TIMEOUT
        end

        if response.status >= 400
          raise Connectors::AuthenticationFailed.new(
            "OAuth token revocation failed (#{response.status}): #{response.body}",
            status: response.status,
            body:   response.body
          )
        end

        true
      end

      private

      def secrets_for_connector
        Connectors.configuration.oauth_credentials_for(@connector_class.connector_key)
      rescue Connectors::Error
        {}
      end
    end
  end
end
