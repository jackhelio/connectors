require "mcp"
require "mcp/client"
require "mcp/client/modern_envelope"
require "mcp/client/mcp_param_headers"
require "mcp/client/oauth/discovery"
require "mcp/client/oauth/pkce"
require "json_schemer"
require "event_stream_parser"
require "time"

module Connectors
  module MCP
    PROTOCOL_VERSION = "2026-07-28".freeze
    class Error < Connectors::Error; end
    class AccessDenied < Error; end
    class ValidationError < Error; end
    class ProtocolError < Error
      attr_reader :code
      def initialize(message, code: nil)
        @code = code
        super(message)
      end
    end
    class TransportError < Error; end
    class ConfigurationRequired < Error; end
    class Cancelled < Error; end
    class AuthorizationRequired < Error
      attr_reader :challenge, :fingerprint
      def initialize(challenge = {}, fingerprint: nil)
        @challenge = challenge
        @fingerprint = fingerprint
        super("MCP owner authorization required")
      end
    end
    class HTTPError < TransportError
      attr_reader :status, :headers, :body
      def initialize(status:, headers:, body:)
        @status, @headers, @body = status, headers, body
        super("Remote HTTP request failed (#{status})")
      end

      # Retry-After permits delay-seconds or an HTTP date. Do not reflect
      # arbitrary upstream header content into host responses.
      def retry_after
        value = headers["retry-after"].to_s
        return value if value.match?(/\A[0-9]+\z/)
        Time.httpdate(value).httpdate
      rescue ArgumentError
        nil
      end
    end
  end
end

require "connectors/mcp/settings"
require "connectors/mcp/cancellation"
require "connectors/mcp/access"
require "connectors/mcp/pending_transaction"
require "connectors/mcp/http"
require "connectors/mcp/connection_config"
require "connectors/mcp/authorization_discovery"
require "connectors/mcp/token_endpoint"
require "connectors/mcp/authorization"
require "connectors/mcp/authorization_context"
require "connectors/mcp/schema"
require "connectors/mcp/protocol_schema"
require "connectors/mcp/transport"
require "connectors/mcp/interaction"
require "connectors/mcp/client"
