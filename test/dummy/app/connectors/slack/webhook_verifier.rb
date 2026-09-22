require "openssl"

module Slack
  # Verifies Slack's HMAC-SHA256 request signature.
  # See: https://api.slack.com/authentication/verifying-requests-from-slack
  #
  # Slack signs requests with the app-level signing secret (not per-team), so
  # the secret lives in Connectors.configuration.oauth_credentials[:slack],
  # alongside client_id/client_secret.
  class WebhookVerifier < Connectors::Webhooks::Verifier
    TIMESTAMP_TOLERANCE = 5 * 60   # seconds — Slack's recommendation for replay protection
    VERSION             = "v0"

    def verify!(request)
      timestamp = request.headers["X-Slack-Request-Timestamp"].to_s
      signature = request.headers["X-Slack-Signature"].to_s

      if timestamp.empty? || signature.empty?
        raise Connectors::Webhooks::SignatureInvalid, "missing Slack signature headers"
      end

      age = Time.now.to_i - timestamp.to_i
      if age.abs > TIMESTAMP_TOLERANCE
        raise Connectors::Webhooks::SignatureInvalid, "stale Slack request: age=#{age}s"
      end

      basestring = "#{VERSION}:#{timestamp}:#{request.raw_post}"
      expected   = "#{VERSION}=" + OpenSSL::HMAC.hexdigest("SHA256", signing_secret, basestring)

      unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
        raise Connectors::Webhooks::SignatureInvalid, "Slack signature mismatch"
      end
    end

    private

    def signing_secret
      secret = Connectors.configuration.oauth_credentials_for(:slack)[:signing_secret]
      raise Connectors::Error, "Slack signing_secret not configured" if secret.to_s.empty?
      secret
    end
  end
end
