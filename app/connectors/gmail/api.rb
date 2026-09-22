module Gmail
  # Shared HTTP layer for every Gmail action. Mirrors n8n's
  # `googleApiRequest` / `googleApiRequestAllItems` in
  # `packages/nodes-base/nodes/Google/Gmail/GenericFunctions.ts` —
  # one entry point that normalizes Google-specific errors into our
  # `Connectors::ApiError` hierarchy with user-friendly messages,
  # plus an auto-paginating variant for `*.list` endpoints.
  module Api
    module_function

    # @param resource [String, Symbol] — "message" / "label" / "thread" / "draft".
    #   Used to compose human-readable error messages ("Message not found",
    #   "Label name already exists", "Invalid thread ID").
    def request(client, method, path, body: nil, query: nil, resource: "resource")
      response =
        case method.to_sym
        when :get, :delete
          client.public_send(method, path, query)
        when :post, :patch, :put
          client.public_send(method, path, body || {}) do |req|
            req.params.update(query) if query && !query.empty?
          end
        else
          raise ArgumentError, "unsupported HTTP method: #{method.inspect}"
        end

      response.body
    rescue Connectors::ApiError => e
      raise translate(e, resource: resource)
    end

    # Walks `nextPageToken` until exhausted; concatenates the array at
    # `property_name`. Matches n8n's signature so the porting is mechanical.
    def request_all(client, property_name, method, path, body: nil, query: nil, resource: "resource", page_size: 100)
      items = []
      q     = (query || {}).dup
      q[:maxResults] = page_size

      loop do
        page = request(client, method, path, body: body, query: q, resource: resource)
        Array(page[property_name.to_s]).each { |it| items << it }
        token = page["nextPageToken"]
        break if token.to_s.empty?
        q[:pageToken] = token
      end

      items
    end

    # n8n's `googleApiRequest` rescue ladder — translated to our types.
    # When a translation matches, we raise a new ApiError with the
    # user-meaningful message; otherwise the original passes through.
    def translate(error, resource:)
      status  = error.respond_to?(:status) ? error.status.to_i : 0
      body    = error.respond_to?(:body) ? error.body : nil
      message = error.message.to_s
      details = google_error_details(body)
      reason  = details[:message].to_s

      case status
      when 400
        if reason.include?("Invalid id value")
          raise Connectors::ApiError.new(
            "Invalid #{resource} ID — Gmail IDs should look something like `182b676d244938bd`",
            status: status, body: body
          )
        end
      when 401
        raise Connectors::AuthenticationFailed.new(reason.presence || message, status: status, body: body)
      when 404
        raise Connectors::ApiError.new(
          "#{titlecase(resource)} not found",
          status: status, body: body
        )
      when 409
        # n8n parity: any 409 on the label resource is treated as a
        # name collision — Gmail's API doesn't return 409 for any other
        # reason on /users/me/labels.
        if resource.to_s == "label"
          raise Connectors::ApiError.new("Label name already exists", status: status, body: body)
        end
      when 429
        raise Connectors::RateLimited.new(reason.presence || "Gmail rate-limit hit", status: status, body: body)
      end

      error
    end

    # ErrorNormalization supplies parsed JSON. Also accept raw strings from
    # custom clients using the same translation helper.
    def google_error_details(body)
      hash =
        case body
        when Hash    then body
        when String  then (JSON.parse(body) rescue {})
        else              {}
        end

      err = hash["error"]
      case err
      when Hash
        { message: err["message"], status: err["status"], errors: Array(err["errors"]) }
      when String
        { message: err }
      else
        {}
      end
    end

    def titlecase(s)
      s.to_s.tr("_", " ").split(" ").map(&:capitalize).join(" ")
    end
  end
end
