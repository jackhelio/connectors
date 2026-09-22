module Connectors
  # Executes a connector's `test_request` declaration against the live
  # provider, applying configured rules to decide pass/fail.
  #
  #   result = CredentialTester.run(grant)
  #   # => { status: "OK", message: "Connection successful" }
  #   # or
  #   # => { status: "Error", message: "Slack token is invalid", details: {...} }
  #
  # Reuses the connector's Faraday client so the same auth middleware,
  # auto-refresh, rate-limit and error normalization apply. A successful
  # test verifies this request, not permissions for every provider operation.
  class CredentialTester
    OK    = "OK".freeze
    ERROR = "Error".freeze

    def self.run(grant)
      new(grant).run
    end

    def initialize(grant)
      @grant = grant
      @klass = grant.connector.class
      @cfg   = @klass.test_request_config
    end

    def run
      return inconclusive("No test_request declared for #{@klass.connector_key}") if @cfg.nil?

      response = issue_request
      verdict_for(response)
    rescue Connectors::AuthenticationFailed => e
      { status: ERROR, message: e.message }
    rescue Connectors::ApiError => e
      { status: ERROR, message: e.message, details: { status: e.respond_to?(:status) ? e.status : nil } }
    rescue => e
      { status: ERROR, message: "#{e.class}: #{e.message}" }
    end

    private

    def issue_request
      client = @grant.connector.client
      client.public_send(@cfg[:method], @cfg[:url], @cfg[:query]) do |req|
        (@cfg[:headers] || {}).each { |k, v| req.headers[k] = v }
      end
    end

    def verdict_for(response)
      expected = @cfg[:expect_status]
      if expected && response.status.to_i != expected.to_i
        return { status: ERROR, message: "Expected HTTP #{expected}, got #{response.status}" }
      end

      Array(@cfg[:rules]).each do |rule|
        verdict = apply_rule(rule, response)
        return verdict if verdict
      end

      { status: OK, message: "Connection successful" }
    end

    # Each rule short-circuits with an Error verdict when it matches the
    # failure condition; returns nil to mean "this rule said nothing, keep
    # going".
    def apply_rule(rule, response)
      case rule[:type].to_sym
      when :response_code
        return nil if response.status.to_i == rule[:value].to_i
        { status: ERROR, message: rule[:message] || "Unexpected status #{response.status}" }
      when :response_success_body
        actual = response.body.is_a?(Hash) ? response.body[rule[:key].to_s] : nil
        return nil unless actual == rule[:value]
        { status: ERROR, message: rule[:message] || "Response body indicated failure" }
      else
        raise Connectors::Error, "unknown test rule type #{rule[:type].inspect}"
      end
    end

    def inconclusive(msg)
      { status: ERROR, message: msg, details: { kind: "test_not_configured" } }
    end
  end
end
