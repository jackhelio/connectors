require "base64"

module Connectors
  module Middleware
    # Apply resolved authentication properties to each outgoing request.
    # Credential templates are evaluated per request so rotated values,
    # including values from pre_authentication, take effect immediately.
    class AuthenticateGeneric < Faraday::Middleware
      def initialize(app, grant:, authenticate_config:)
        super(app)
        @grant   = grant
        @config  = authenticate_config
      end

      def call(env)
        properties = resolved_properties
        apply_headers(env, properties[:headers] || properties["headers"])
        apply_query(env,   properties[:qs]      || properties["qs"])
        apply_body(env,    properties[:body]    || properties["body"])
        apply_basic_auth(env, properties[:auth] || properties["auth"])

        @app.call(env)
      end

      private

      def resolved_properties
        return {} if @config.nil?
        AuthInjection.resolve(@config[:properties] || @config["properties"] || {}, @grant.credentials_hash)
      end

      def apply_headers(env, headers)
        return if headers.nil? || headers.empty?
        headers.each { |k, v| env.request_headers[k.to_s] = v.to_s }
      end

      def apply_query(env, qs)
        return if qs.nil? || qs.empty?
        # Faraday 2.x doesn't expose `env.params` reliably during middleware
        # execution — the canonical mutation point is `env.url.query`. Merge
        # with any existing query string so per-request params from the
        # caller aren't clobbered.
        existing = env.url.query ? URI.decode_www_form(env.url.query).to_h : {}
        merged   = existing.merge(qs.each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s })
        env.url.query = URI.encode_www_form(merged)
      end

      # JSON-body injection only — most provider auth that sends creds in
      # the body uses JSON. If a non-Hash body is in flight (form-encoded,
      # multipart), leave it alone; Faraday's body coercion already ran by
      # the time this middleware sees the env.
      def apply_body(env, body)
        return if body.nil? || body.empty?
        return unless env.body.is_a?(Hash)
        body.each { |k, v| env.body[k.to_s] = v }
      end

      # Set the HTTP Basic Authorization header from username and password.
      def apply_basic_auth(env, auth)
        return if auth.nil?
        username = auth[:username] || auth["username"]
        password = auth[:password] || auth["password"]
        return if username.nil? && password.nil?
        encoded = Base64.strict_encode64("#{username}:#{password}")
        env.request_headers["Authorization"] = "Basic #{encoded}"
      end
    end
  end
end
