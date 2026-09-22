require "securerandom"
require "digest"
require "base64"

module Connectors
  module OAuth
    # RFC 7636 — Proof Key for Code Exchange. We generate a random
    # `code_verifier`, derive `code_challenge = BASE64URL(SHA256(verifier))`
    # (method `S256`), and embed the verifier in the signed OAuth state
    # token so the callback can include it in the token exchange.
    #
    # n8n parity: `oauth.service.ts:578-586` — same `S256` derivation,
    # verifier stashed in encrypted credential data until callback. We use
    # the signed state token instead of a DB write so the flow stays
    # stateless on the engine side.
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
