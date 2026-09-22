require "base64"
require "uri"

module Connectors
  module OAuth
    # RFC 6749 client authentication, shared by code, refresh and client-
    # credentials grants. A public PKCE client sends only its client ID.
    module ClientAuthentication
      module_function

      def apply(body, headers, secrets:, authentication:)
        if secrets[:client_secret].blank? || authentication == "body"
          body[:client_id] = secrets[:client_id]
          body[:client_secret] = secrets[:client_secret] if secrets[:client_secret].present?
        elsif authentication == "header"
          encoded = [ secrets[:client_id], secrets[:client_secret] ].map { |value| URI.encode_www_form_component(value.to_s) }
          headers["Authorization"] = "Basic #{Base64.strict_encode64(encoded.join(':'))}"
        else
          raise ArgumentError, "unsupported OAuth client authentication: #{authentication.inspect}"
        end
      end
    end
  end
end
