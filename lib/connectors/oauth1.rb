require "openssl"
require "base64"
require "securerandom"
require "uri"
require "faraday"

module Connectors
  # OAuth1.0a — RFC 5849. Two-leg request-token / access-token flow with
  # HMAC-SHA1/SHA256/SHA512 request signing. n8n parity:
  # `oauth.service.ts:601-700` (request-token leg) +
  # `oauth1-credential.controller.ts:43-101` (callback / access-token leg).
  # n8n uses the `oauth-1.0a` npm package; we implement the signing inline
  # to keep the engine dependency-free.
  module OAuth1
    module_function

    SIG_ALGORITHMS = {
      "HMAC-SHA1"   => "SHA1",
      "HMAC-SHA256" => "SHA256",
      "HMAC-SHA512" => "SHA512"
    }.freeze

    # Phase 1 of the flow: request the unauthorized request token. Sends an
    # OAuth1-signed POST to `requestTokenUrl`. Provider returns
    # `oauth_token` + `oauth_token_secret` (URL-encoded form). We need both
    # to (a) build the authorize URL the owner is redirected to and (b)
    # sign the access-token request when the owner returns via callback.
    def request_token(connector_class, callback_url:)
      config  = connector_class.oauth1_config or
        raise Connectors::Error.new("#{connector_class}: oauth1 ... DSL not declared")
      secrets = Connectors.configuration.oauth_credentials_for(connector_class.connector_key)

      headers = build_authorization_header(
        method:           "POST",
        url:              config[:request_token_url],
        consumer_key:     secrets[:client_id],
        consumer_secret:  secrets[:client_secret],
        token:            nil,
        token_secret:     nil,
        signature_method: config[:signature_method],
        extra_params:     { "oauth_callback" => callback_url }
      )

      response = Faraday.post(config[:request_token_url], "", headers)

      if response.status >= 400
        raise Connectors::AuthenticationFailed.new(
          "OAuth1 request_token failed (#{response.status}): #{response.body}",
          status: response.status, body: response.body
        )
      end

      parsed = URI.decode_www_form(response.body.to_s).to_h
      raise Connectors::AuthenticationFailed.new("OAuth1 request_token response missing oauth_token") \
        unless parsed["oauth_token"]

      {
        "oauth_token"        => parsed["oauth_token"],
        "oauth_token_secret" => parsed["oauth_token_secret"]
      }
    end

    # Phase 2: trade the verifier + token for the long-lived access token.
    def exchange_access_token(connector_class, oauth_token:, oauth_verifier:, oauth_token_secret:)
      config  = connector_class.oauth1_config or
        raise Connectors::Error.new("#{connector_class}: oauth1 ... DSL not declared")
      secrets = Connectors.configuration.oauth_credentials_for(connector_class.connector_key)

      headers = build_authorization_header(
        method:           "POST",
        url:              config[:access_token_url],
        consumer_key:     secrets[:client_id],
        consumer_secret:  secrets[:client_secret],
        token:            oauth_token,
        token_secret:     oauth_token_secret,
        signature_method: config[:signature_method],
        extra_params:     { "oauth_verifier" => oauth_verifier }
      )

      response = Faraday.post(config[:access_token_url], "", headers)

      if response.status >= 400
        raise Connectors::AuthenticationFailed.new(
          "OAuth1 access_token exchange failed (#{response.status}): #{response.body}",
          status: response.status, body: response.body
        )
      end

      parsed = URI.decode_www_form(response.body.to_s).to_h
      raise Connectors::AuthenticationFailed.new("OAuth1 access_token response missing oauth_token") \
        unless parsed["oauth_token"]

      normalized = {
        "oauth_token"        => parsed["oauth_token"],
        "oauth_token_secret" => parsed["oauth_token_secret"],
        "signature_method"   => config[:signature_method]
      }
      connector_class.post_token_exchange(parsed, normalized)
    end

    # Build an `Authorization: OAuth ...` header for a signed request. Each
    # `extra_params` entry (e.g. `oauth_callback`, `oauth_verifier`) takes
    # part in the signature base string and the final header.
    def build_authorization_header(method:, url:, consumer_key:, consumer_secret:,
                                   token:, token_secret:, signature_method:, extra_params: {})
      oauth_params = {
        "oauth_consumer_key"     => consumer_key.to_s,
        "oauth_nonce"            => SecureRandom.hex(16),
        "oauth_signature_method" => signature_method,
        "oauth_timestamp"        => Time.now.to_i.to_s,
        "oauth_version"          => "1.0"
      }
      oauth_params["oauth_token"] = token if token
      oauth_params.merge!(extra_params)

      signature = sign(
        method:           method,
        url:              url,
        params:           oauth_params,
        consumer_secret:  consumer_secret,
        token_secret:     token_secret,
        signature_method: signature_method
      )

      header_params = oauth_params.merge("oauth_signature" => signature)
      header_value  = header_params.sort.map { |k, v| %(#{percent_encode(k)}="#{percent_encode(v)}") }.join(", ")

      { "Authorization" => "OAuth #{header_value}", "Accept" => "*/*" }
    end

    # RFC 5849 §3.4.1: signature base string = method & URL & sorted params.
    # All three are percent-encoded individually then joined by `&`.
    def sign(method:, url:, params:, consumer_secret:, token_secret:, signature_method:)
      algo = SIG_ALGORITHMS.fetch(signature_method) do
        raise Connectors::Error.new("unsupported OAuth1 signature_method #{signature_method.inspect}")
      end

      sorted_params = params.sort.map { |k, v| "#{percent_encode(k)}=#{percent_encode(v)}" }.join("&")
      base = [ method.to_s.upcase, percent_encode(url), percent_encode(sorted_params) ].join("&")
      key  = "#{percent_encode(consumer_secret.to_s)}&#{percent_encode(token_secret.to_s)}"

      Base64.strict_encode64(OpenSSL::HMAC.digest(algo, key, base))
    end

    # RFC 3986 percent-encoding (stricter than CGI.escape — encodes `*`,
    # leaves `-._~` intact, uses `%20` not `+` for spaces).
    def percent_encode(str)
      str.to_s.b.gsub(/[^A-Za-z0-9\-._~]/) { |c| "%%%02X" % c.ord }
    end
  end
end
