module Connectors
  module Webhooks
    # Base class for connector-specific webhook signature verifiers.
    # Subclass and override #verify! to raise Connectors::Webhooks::SignatureInvalid
    # when the request's signature doesn't match. Typical implementation:
    #
    #   class StripeWebhookVerifier < Connectors::Webhooks::Verifier
    #     def verify!(request)
    #       signature = request.headers["Stripe-Signature"]
    #       secret    = @grant.credentials_hash["webhook_secret"]
    #       expected  = OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)
    #       unless ActiveSupport::SecurityUtils.secure_compare(signature.to_s, expected)
    #         raise Connectors::Webhooks::SignatureInvalid.new("bad signature")
    #       end
    #     end
    #   end
    class Verifier
      def self.verify!(grant, request)
        new(grant).verify!(request)
      end

      def initialize(grant)
        @grant = grant
      end

      def verify!(_request)
        # No-op by default — subclasses override.
      end
    end
  end
end
