require "securerandom"
require "digest"
require "base64"

module Connectors
  module OAuth
    # RFC 7636 PKCE using S256. Generate a random verifier and derive
    # BASE64URL(SHA256(verifier)). Store the verifier in authenticated, encrypted
    # OAuth state for use during the callback token exchange.
    module Pkce
      module_function

      VERIFIER_BYTES = 64

      def generate
        verifier  = base64url(SecureRandom.random_bytes(VERIFIER_BYTES))
        challenge = base64url(Digest::SHA256.digest(verifier))
        { verifier: verifier, challenge: challenge, method: "S256" }
      end

      def base64url(bytes)
        Base64.urlsafe_encode64(bytes, padding: false)
      end
    end
  end
end
