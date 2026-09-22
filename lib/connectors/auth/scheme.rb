require "faraday"

module Connectors
  module Auth
    # Abstract base class for auth schemes (OAuth2, ApiKey, HMAC, etc.). A
    # scheme is just a Faraday middleware that mutates the outgoing request
    # env with whatever the third-party service expects (Bearer header, signed
    # query, etc.).
    #
    # Subclasses register themselves with a symbolic key via `register_as`,
    # which is what the connector DSL `auth: :oauth2` resolves against.
    class Scheme < Faraday::Middleware
      class << self
        def register_as(name)
          Scheme.registry[name.to_sym] = self
        end

        def lookup(name)
          registry.fetch(name.to_sym) { raise UnknownAuthScheme.new(name, known: registry.keys) }
        end

        def registry
          @registry ||= {}
        end
      end

      def initialize(app, grant:)
        super(app)
        @grant = grant
      end

      # Subclasses override on_request(env) to attach credentials.
    end
  end
end
