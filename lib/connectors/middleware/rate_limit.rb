require "faraday"

module Connectors
  module Middleware
    # Per-grant token-bucket rate limiter backed by Rails.cache (typically Solid
    # Cache in production). No-op unless the connector class declares
    # `rate_limit count, per: window`.
    #
    #   class SlackConnector < Connectors::Connector
    #     connector  key: :slack, auth: :oauth2, base_url: "..."
    #     rate_limit 50, per: 1.minute
    #   end
    class RateLimit < Faraday::Middleware
      def initialize(app, grant:)
        super(app)
        @grant = grant
      end

      def call(env)
        config = @grant.connector.class.rate_limit_config
        enforce!(config) if config
        @app.call(env)
      end

      private

      def enforce!(config)
        key   = "connectors:ratelimit:#{@grant.connector_key}:#{@grant.id}"
        count = Rails.cache.increment(key, 1, expires_in: config[:per])
        count ||= Rails.cache.write(key, 1, expires_in: config[:per]) && 1

        return if count <= config[:limit]
        raise Connectors::RateLimited.new(
          "local rate limit exceeded (#{config[:limit]} per #{config[:per].inspect})",
          status: 429
        )
      end
    end
  end
end
