require "faraday"

module Connectors
  module Middleware
    # Converts non-2xx HTTP responses into typed Connectors::* exceptions so
    # callers can rescue with intent rather than parsing status codes.
    class ErrorNormalization < Faraday::Middleware
      def initialize(app, token_expired_status: 401)
        super(app)
        @token_expired_status = token_expired_status
      end

      def on_complete(env)
        return if env.status.between?(200, 299)

        if env.status == @token_expired_status
          raise Connectors::AuthenticationFailed.new(
            "authentication failed (status #{env.status})",
            status: env.status,
            body: env.body
          )
        end

        case env.status
        when 403
          raise Connectors::Forbidden.new("request forbidden (status 403)", status: env.status, body: env.body)
        when 429
          retry_after = env.response_headers["retry-after"] || env.response_headers["Retry-After"]
          raise Connectors::RateLimited.new(
            "remote rate limit (status 429)",
            status:      429,
            body:        env.body,
            retry_after: retry_after&.to_i
          )
        else
          raise Connectors::ApiError.new(
            "API request failed (status #{env.status})",
            status: env.status,
            body: env.body
          )
        end
      end
    end
  end
end
