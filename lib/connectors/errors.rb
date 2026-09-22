module Connectors
  class Error < StandardError; end

  class UnknownConnector < Error
    def initialize(key, known: [])
      super("no connector registered for #{key.inspect}. Known keys: #{known.inspect}")
    end
  end

  class UnknownAuthScheme < Error
    def initialize(name, known: [])
      super("no auth scheme registered for #{name.inspect}. Known schemes: #{known.inspect}")
    end
  end

  class MissingCredentialFields < Error
    def initialize(fields)
      super("missing required credential fields: #{Array(fields).join(', ')}")
    end
  end

  class ApiError < Error
    attr_reader :status, :body

    def initialize(message, status: nil, body: nil)
      super(message)
      @status = status
      @body   = body
    end
  end

  class AuthenticationFailed < ApiError; end
  class Forbidden < ApiError; end

  # A credential was used with a node that's not on its `supported_nodes`
  # allowlist, OR the credential is marked generic_auth-only and the caller
  # is a non-HTTP-Request node. Mirrors the visibility gate n8n applies via
  # the credential's `supportedNodes` field (interfaces.ts:381) and
  # `genericAuth` flag (interfaces.ts:379).
  class CredentialNotPermitted < Error
    def initialize(connector_key, node_type, reason: nil)
      msg = "credential #{connector_key.inspect} is not permitted for node #{node_type.inspect}"
      msg += " (#{reason})" if reason
      super(msg)
    end
  end

  class RateLimited < ApiError
    attr_reader :retry_after

    def initialize(message, status: nil, body: nil, retry_after: nil)
      super(message, status: status, body: body)
      @retry_after = retry_after
    end
  end

  # Caller tried to invoke an action that wasn't declared on the connector.
  # Mirrors UnknownConnector: includes the known set so the frontend can
  # render a helpful error.
  class UnknownAction < Error
    attr_reader :action_key, :connector_key, :known

    def initialize(action_key, connector_key: nil, known: [])
      @action_key    = action_key
      @connector_key = connector_key
      @known         = known
      msg = "no action #{action_key.inspect} declared"
      msg += " on connector #{connector_key.inspect}" if connector_key
      msg += ". Known actions: #{known.inspect}" if known.any?
      super(msg)
    end
  end

  # Action params failed schema validation — missing required fields or
  # extraneous unknown fields. Surfaced as a 422 from the actions endpoint.
  class InvalidActionParams < Error
    attr_reader :missing, :unknown

    def initialize(missing: [], unknown: [])
      @missing = Array(missing)
      @unknown = Array(unknown)
      parts = []
      parts << "missing required params: #{@missing.join(', ')}" if @missing.any?
      parts << "unknown params: #{@unknown.join(', ')}"          if @unknown.any?
      super(parts.join("; ").presence || "invalid action params")
    end
  end
end
