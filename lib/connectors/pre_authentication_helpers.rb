module Connectors
  # HTTP helper for pre_authentication. Fetches credentials independently
  # of the connector client, whose authentication may not yet be available.
  #
  #   pre_authentication do |credentials, helpers|
  #     response = helpers.http_request(
  #       method: :post,
  #       url:    "#{credentials['url']}/oauth2/token",
  #       body:   { client_id: credentials['client_id'],
  #                 client_secret: credentials['client_secret'] },
  #       headers: { "Content-Type" => "application/x-www-form-urlencoded" }
  #     )
  #     { "session_token" => response["access_token"],
  #       "expires_at"    => Time.now.to_i + response["expires_in"].to_i }
  #   end
  class PreAuthenticationHelpers
    DEFAULT_TIMEOUT = 30

    # Performs the HTTP request through a fresh Faraday connection (no
    # auth/middleware stack — this runs BEFORE auth injection by design).
    # Body content-type is inferred from the headers; defaults to JSON.
    def http_request(method:, url:, body: nil, headers: nil, query: nil, timeout: DEFAULT_TIMEOUT)
      connection = Faraday.new do |f|
        f.options.timeout = timeout
        if json?(headers)
          f.request  :json
          f.response :json, content_type: /\bjson\b/
        elsif form_urlencoded?(headers)
          f.request  :url_encoded
          f.response :json, content_type: /\bjson\b/
        else
          f.response :json, content_type: /\bjson\b/
        end
        f.adapter Faraday.default_adapter
      end

      response = connection.public_send(method.to_sym, url) do |req|
        (headers || {}).each { |k, v| req.headers[k.to_s] = v.to_s }
        req.params = query if query
        req.body   = body  if body
      end

      # Raise on non-2xx responses so the hook cannot silently merge
      # an unsuccessful token response into credentials.
      if response.status >= 400
        body_preview = response.body.is_a?(String) ? response.body.byteslice(0, 200) : response.body.inspect
        raise Connectors::ApiError.new(
          "pre_authentication HTTP #{response.status}: #{body_preview}",
          status: response.status,
          body:   response.body
        )
      end

      response.body
    end

    private

    def json?(headers)
      return true if headers.nil?
      content_type = (headers["Content-Type"] || headers[:"Content-Type"] || "").to_s
      content_type.empty? || content_type.include?("json")
    end

    def form_urlencoded?(headers)
      (headers || {}).any? do |k, v|
        k.to_s.downcase == "content-type" && v.to_s.include?("application/x-www-form-urlencoded")
      end
    end
  end
end
