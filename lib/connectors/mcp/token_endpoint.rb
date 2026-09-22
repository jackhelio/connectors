require "base64"

module Connectors
  module MCP
    class TokenEndpoint
      def self.exchange(metadata:, client:, params:)
        method = client.fetch("token_endpoint_auth_method", "none")
        supported = metadata.fetch("token_endpoint_auth_methods_supported", [ "client_secret_basic" ])
        # Public clients are permitted when the AS omits auth-method metadata.
        unless supported.include?(method) || (method == "none" && !metadata.key?("token_endpoint_auth_methods_supported"))
          raise ConfigurationRequired, "Client authentication method is not advertised"
        end
        headers = { "Accept" => "application/json", "Content-Type" => "application/x-www-form-urlencoded" }
        form = params.merge("client_id" => client.fetch("client_id"))
        case method
        when "none"
          raise ConfigurationRequired, "Confidential client cannot use public authentication" if client["client_secret"].present?
        when "client_secret_basic"
          pair = %w[client_id client_secret].map { |key| URI.encode_www_form_component(client.fetch(key)) }.join(":")
          headers["Authorization"] = "Basic #{Base64.strict_encode64(pair)}"
          form.delete("client_id")
        when "client_secret_post"
          form["client_secret"] = client.fetch("client_secret")
        when "private_key_jwt"
          signer = Connectors.configuration.mcp.assertion_provider or raise ConfigurationRequired, "Client assertion provider is required"
          form["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
          form["client_assertion"] = signer.call(client.fetch("client_id"), metadata.fetch("token_endpoint"))
        else
          raise ConfigurationRequired, "Unsupported client authentication method"
        end
        tokens = HTTP.new.json(url: metadata.fetch("token_endpoint"), method: :post, headers: headers, body: URI.encode_www_form(form))
        unless tokens["access_token"].is_a?(String) && tokens["access_token"].match?(/\A[A-Za-z0-9\-._~+\/]+=*\z/) && tokens["token_type"].to_s.casecmp?("Bearer")
          raise ProtocolError, "Invalid OAuth token response"
        end
        if tokens.key?("expires_in")
          raise ProtocolError, "Invalid token expiry" unless tokens["expires_in"].is_a?(Numeric) && tokens["expires_in"].finite? && tokens["expires_in"] >= 0
          tokens["expires_at"] = Time.current.to_f + tokens["expires_in"]
        end
        if tokens.key?("refresh_token") && !tokens["refresh_token"].is_a?(String)
          raise ProtocolError, "Invalid refresh token"
        end
        tokens
      rescue KeyError
        raise ConfigurationRequired, "Incomplete OAuth client information"
      end
    end
  end
end
