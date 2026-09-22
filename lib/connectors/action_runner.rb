module Connectors
  # Validates an Action's input params and invokes its execute block in the
  # connector instance's context. Returns the same normalized response
  # envelope to HTTP controllers and direct Ruby callers.
  #
  #   result = ActionRunner.call(grant, :send_email, { "from" => "x", "to" => "y", ... })
  #   # => { status: "ok",    action: "send_email", data: { "id" => "abc-123" } }
  #   # or
  #   # => { status: "error", action: "send_email",
  #   #      error: { type: "api_error", message: "...", status: 422 } }
  #
  # The runner does not catch arbitrary StandardError — only Connectors::
  # errors. Unexpected failures propagate to the caller.
  class ActionRunner
    OK    = "ok".freeze
    ERROR = "error".freeze

    def self.call(grant, action_name, input)
      new(grant, action_name, input).call
    end

    def initialize(grant, action_name, input)
      @grant       = grant
      @action_name = action_name
      @input       = (input || {}).transform_keys(&:to_s)
    end

    def call
      action = @grant.connector.class.action_lookup(@action_name)
      @grant.ensure_not_revoked!
      validate!(action)

      result = @grant.connector.instance_exec(coerced_input(action), &action.execute_block)

      { status: OK, action: action.key.to_s, data: result }
    rescue Connectors::InvalidActionParams => e
      error_envelope(action&.key,
                     type: "invalid_params", message: e.message,
                     details: { missing: e.missing, unknown: e.unknown })
    rescue Connectors::AuthenticationFailed => e
      error_envelope(action&.key, type: "authentication_failed", message: e.message,
                     details: { status: safe_status(e) })
    rescue Connectors::Forbidden => e
      error_envelope(action&.key, type: "forbidden", message: e.message, details: { status: safe_status(e) })
    rescue Connectors::RateLimited => e
      error_envelope(action&.key, type: "rate_limited", message: e.message,
                     details: { status: safe_status(e), retry_after: e.retry_after })
    rescue Connectors::ApiError => e
      error_envelope(action&.key, type: "api_error", message: e.message,
                     details: { status: safe_status(e), body: e.body })
    rescue Connectors::UnknownAction => e
      # `action` is nil here — re-raise so the controller renders a 404
      # rather than a 200 with an error body (mirrors UnknownConnector).
      raise
    end

    private

    def validate!(action)
      provided = @input.keys
      missing  = action.required_param_names.reject { |k| @input.key?(k) && !blank?(@input[k]) }
      raise Connectors::InvalidActionParams.new(missing: missing) if missing.any?
      # Unknown keys do not fail validation; coerced_input drops them
      # before invoking the execute block.
      _ = provided
    end

    # Whitelist incoming keys to the action's declared param names so the
    # execute block doesn't see surprise data from a malformed caller. Keys
    # arrive as strings (JSON), which is what every connector method in the
    # codebase keyword-splats from — execute blocks call `**input.symbolize_keys`.
    def coerced_input(action)
      allowed = action.param_names.to_set
      @input.slice(*allowed)
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def safe_status(err)
      err.respond_to?(:status) ? err.status : nil
    end

    def error_envelope(action_key, type:, message:, details: {})
      {
        status: ERROR,
        action: action_key.to_s,
        error:  { type: type, message: message }.merge(details.compact)
      }
    end
  end
end
