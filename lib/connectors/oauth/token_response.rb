require "json"
require "uri"

module Connectors
  module OAuth
    # Both OAuth2 token flows accept JSON and form-encoded provider responses.
    # Validate their shape before any credentials can be persisted.
    class TokenResponse
      def self.parse(response)
        body = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          URI.decode_www_form(response.body.to_s).to_h
        end
        body = {} unless body.is_a?(Hash)

        token = body["access_token"]
        if !response.status.between?(200, 299) || body["ok"] == false || body["error"] || !token.is_a?(String) || token.blank?
          reason = body["error"].presence || "invalid token response"
          raise Connectors::AuthenticationFailed.new(
            "OAuth token exchange failed (#{response.status}): #{reason}",
            status: response.status, body: body
          )
        end
        body
      end

      def self.normalize(body)
        expires_at = body["expires_in"] ? Time.now.to_i + body["expires_in"].to_i : body["expires_at"]&.to_i
        {
          "access_token" => body["access_token"],
          "refresh_token" => body["refresh_token"],
          "expires_at" => expires_at,
          "scope" => body["scope"],
          "token_type" => body["token_type"]
        }.compact
      end
    end
  end
end
