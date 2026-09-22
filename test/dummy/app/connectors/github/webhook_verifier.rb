require "openssl"

module Github
  # Verifies GitHub's webhook signature.
  # https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries
  #
  # Header: X-Hub-Signature-256 = "sha256=<hex hmac of raw body using webhook_secret>"
  # Secret: per-grant — admin pastes from the repo's webhook config into
  # Grant#credentials["webhook_secret"].
  class WebhookVerifier < Connectors::Webhooks::Verifier
    HEADER = "X-Hub-Signature-256"

    def verify!(request)
      signature = request.headers[HEADER].to_s
      raise Connectors::Webhooks::SignatureInvalid, "missing #{HEADER}" if signature.empty?

      secret = @grant&.credentials_hash&.dig("webhook_secret")
      raise Connectors::Webhooks::SignatureInvalid, "no webhook_secret on grant" if secret.to_s.empty?

      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)

      unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
        raise Connectors::Webhooks::SignatureInvalid, "GitHub signature mismatch"
      end
    end
  end
end
