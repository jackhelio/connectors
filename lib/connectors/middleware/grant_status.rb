require "faraday"

module Connectors
  module Middleware
    # Runs inside the retry middleware so every attempt checks revocation
    # before pre-authentication or provider credentials can be used.
    class GrantStatus < Faraday::Middleware
      def initialize(app, grant:)
        super(app)
        @grant = grant
      end

      def call(env)
        @grant.ensure_not_revoked!
        @app.call(env)
      end
    end
  end
end
