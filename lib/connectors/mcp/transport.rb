module Connectors
  module MCP
    class Transport
      def initialize(url:, headers: {}, capabilities: {})
        @url, @headers, @capabilities = url, headers, capabilities
      end

      def request(method, params = {}, parameter_headers: {}, subscription: false, cancellation: nil)
        id = SecureRandom.uuid
        request = ::MCP::Client::ModernEnvelope.stamp(
          { jsonrpc: "2.0", id: id, method: method, params: params },
          protocol_version: PROTOCOL_VERSION,
          client_info: { name: Connectors.configuration.mcp.client_name, version: Connectors::VERSION },
          capabilities: @capabilities)
        headers = @headers.merge("Content-Type" => "application/json", "Accept" => "application/json, text/event-stream",
          "MCP-Protocol-Version" => PROTOCOL_VERSION, "Mcp-Method" => method).merge(parameter_headers)
        headers["Mcp-Name"] = ::MCP::Client::McpParamHeaders.encode_value(params.fetch("name")) if method == "tools/call"
        json = +""
        parser = EventStreamParser::Parser.new
        acknowledged = false
        filter = {}
        HTTP.new.call(url: @url, method: :post, headers: headers, body: JSON.generate(request), stream: subscription, cancellation: cancellation) do |chunk, response_headers|
          case response_headers["content-type"].to_s.split(";").first
          when "application/json"
            raise ProtocolError, "Subscriptions require an event stream" if subscription
            json << chunk
          when "text/event-stream"
            parser.feed(chunk) do |_type, data, _event_id|
              next if data.empty?
              message = parse(data)
              if message.key?("id")
                validate_response!(message, id)
                raise ProtocolError, "Subscription completed before acknowledgment" if subscription && !acknowledged
                if subscription && message.dig("result", "_meta", "io.modelcontextprotocol/subscriptionId") != id
                  raise ProtocolError, "Invalid subscription completion correlation"
                end
                return message.fetch("result")
              end
              validate_notification!(message)
              if subscription
                subscription_id = message.dig("params", "_meta", "io.modelcontextprotocol/subscriptionId")
                raise ProtocolError, "Invalid subscription correlation" unless subscription_id == id
                unless acknowledged
                  raise ProtocolError, "Missing subscription acknowledgment" unless message["method"] == "notifications/subscriptions/acknowledged"
                  filter = message.dig("params", "notifications")
                  requested = params.fetch("notifications", {})
                  unless filter.is_a?(Hash) && filter.all? { |key, value| value == true && requested[key] == true }
                    raise ProtocolError, "Invalid acknowledged subscription filter"
                  end
                  acknowledged = true
                else
                  key = { "notifications/tools/list_changed" => "toolsListChanged", "notifications/prompts/list_changed" => "promptsListChanged", "notifications/resources/list_changed" => "resourcesListChanged" }[message["method"]]
                  raise ProtocolError, "Notification violates subscription filter" unless key && filter[key]
                end
                yield message if block_given?
              end
            end
          else
            raise ProtocolError, "Unsupported MCP response content type"
          end
        end
        raise TransportError, "MCP stream ended without a result; outcome may be unknown" if json.empty?
        message = parse(json)
        validate_response!(message, id)
        message.fetch("result")
      rescue HTTPError => error
        if error.status == 401 || (error.status == 403 && challenge(error)["error"] == "insufficient_scope")
          raise AuthorizationRequired.new(challenge(error))
        end
        raise
      end

      private

      def challenge(error)
        ::MCP::Client::OAuth::Discovery.parse_www_authenticate(error.headers["www-authenticate"])
      end

      def parse(data)
        value = JSON.parse(data)
        raise ProtocolError, "Invalid JSON-RPC envelope" unless value.is_a?(Hash) && value["jsonrpc"] == "2.0"
        value
      rescue JSON::ParserError
        raise ProtocolError, "Malformed MCP JSON"
      end

      def validate_notification!(message)
        raise ProtocolError, "Invalid server notification" unless message["method"].is_a?(String) && !message.key?("result") && !message.key?("error")
      end

      def validate_response!(message, id)
        raise ProtocolError, "Mismatched JSON-RPC response ID" unless message["id"] == id
        if message.key?("error") && !message.key?("result")
          error = message["error"]
          raise ProtocolError, "Malformed JSON-RPC error" unless error.is_a?(Hash) && error["code"].is_a?(Integer) && error["message"].is_a?(String)
          # Remote error text/data can include secrets; do not expose it via exceptions.
          raise ProtocolError.new("Remote MCP protocol error (#{error['code']})", code: error["code"])
        end
        result = message["result"]
        raise ProtocolError, "Invalid JSON-RPC result" if message.key?("error") || message.key?("method") || !result.is_a?(Hash)
        raise ProtocolError, "Unknown MCP result type" unless %w[complete input_required].include?(result.fetch("resultType", "complete"))
      end
    end
  end
end
