require "securerandom"

module Connectors
  module OAuth
    # Stateless CSRF token for the OAuth authorize → callback round trip.
    # Carries the connector key, owner GlobalID, and an optional return-to URL,
    # authenticated and encrypted so PKCE/OAuth1 secrets never appear in the
    # authorization URL. Expires in 15 minutes. This is not a session cookie.
    module State
      module_function

      EXPIRES_IN = 15.minutes
      PURPOSE    = :connectors_oauth_state

      def encode(connector_key:, owner_gid:, return_to: nil, extra: nil)
        payload = {
          "k" => connector_key.to_s,
          "o" => owner_gid,
          "r" => return_to,
          "n" => SecureRandom.hex(16),
          "t" => Time.now.to_i
        }
        payload["x"] = extra if extra.is_a?(Hash) && extra.any?
        encryptor.encrypt_and_sign(payload, expires_in: EXPIRES_IN, purpose: PURPOSE)
      end

      def decode(token)
        return nil unless token.is_a?(String) && token.present?
        encryptor.decrypt_and_verify(token, purpose: PURPOSE).presence
      rescue ActiveSupport::MessageEncryptor::InvalidMessage, ArgumentError
        nil
      end

      def encryptor
        cipher = "aes-256-gcm"
        key = Rails.application.key_generator.generate_key(PURPOSE.to_s, ActiveSupport::MessageEncryptor.key_len(cipher))
        ActiveSupport::MessageEncryptor.new(key, cipher: cipher, serializer: JSON)
      end
    end
  end
end
