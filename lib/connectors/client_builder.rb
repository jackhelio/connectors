require "faraday"
require "faraday/retry"

module Connectors
  # Assembles the Faraday client used by a connector. Middleware order matters:
  # outermost (declared first) wraps everything below. On the response side,
  # outer middleware runs LAST, so anything that needs the parsed JSON body
  # (ErrorNormalization, AutoRefresh's rescue path) must sit OUTER to the JSON
  # response parser.
  #
  # Stack (outer → inner):
  #   1. JSON request encoder                      — body marshaling
  #   2. RateLimit                                  — per-grant quota
  #   3. AutoRefresh                                — rescues 401 -> refresh -> retry
  #   4. ErrorNormalization                         — raises after retry exhaustion
  #   5. Retry / JSON response parser               — inspect parsed responses
  #   6. GrantStatus                               — reject revoked grants on each attempt
  #   7. PreAuthentication                          — proactive token refresh
  #   8. Auth injection — declarative or imperative (one or the other)
  #   9. Adapter                                    — sends the HTTP request
  class ClientBuilder
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_TIMEOUT      = 30

    # AuthenticateGeneric applies a resolved authenticate declaration when
    # present; otherwise the client uses the configured auth_scheme.
    # PreAuthentication runs the optional hook when expires_at is absent or past.
    def initialize(base_url:, grant:, auth_scheme:, authenticate_config: nil, pre_auth_block: nil,
                   open_timeout: DEFAULT_OPEN_TIMEOUT, timeout: DEFAULT_TIMEOUT)
      @base_url            = base_url
      @grant               = grant
      @auth_scheme         = auth_scheme
      @authenticate_config = authenticate_config
      @pre_auth_block      = pre_auth_block
      @open_timeout        = open_timeout
      @timeout             = timeout
    end

    def build
      grant               = @grant
      auth_scheme         = @auth_scheme
      authenticate_config = @authenticate_config
      pre_auth_block      = @pre_auth_block
      open_timeout        = @open_timeout
      timeout             = @timeout

      Faraday.new(url: @base_url) do |f|
        f.options.open_timeout = open_timeout
        f.options.timeout      = timeout

        f.request :json
        f.use Middleware::RateLimit,   grant: grant
        f.use Middleware::AutoRefresh, grant: grant
        f.use Middleware::ErrorNormalization,
              token_expired_status: grant.connector.class.oauth2_config&.fetch(:token_expired_status, 401) || 401
        f.request :retry, max: 2, interval: 0.5, backoff_factor: 2,
                          retry_statuses: [ 502, 503, 504 ],
                          methods: [ :get, :head, :options, :put, :delete ]
        f.response :json, content_type: /\bjson\z/
        f.use Middleware::GrantStatus, grant: grant

        # PreAuthentication MUST sit before AuthenticateGeneric so the fresh
        # credentials it writes to the grant are visible to the template
        # resolver on the same request.
        if pre_auth_block
          f.use Middleware::PreAuthentication, grant: grant, pre_auth_block: pre_auth_block
        end

        if authenticate_config
          f.use Middleware::AuthenticateGeneric,
                grant:               grant,
                authenticate_config: authenticate_config
        else
          f.use auth_scheme, grant: grant
        end

        f.adapter Faraday.default_adapter
      end
    end
  end
end
