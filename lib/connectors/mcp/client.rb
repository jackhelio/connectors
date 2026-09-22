module Connectors
  module MCP
    class Client
      def initialize(grant:, actor:, principals: nil, cancellation: nil)
        @access = Access.new(grant: grant, actor: actor, principals: principals)
        @cancellation = cancellation
      end

      def tools
        @access.require!
        fingerprint = @access.fingerprint
        result = []
        cursors = Set.new
        cursor = nil
        Connectors.configuration.mcp.max_pages.times do
          @access.require!
          unchanged!(fingerprint)
          page = request("tools/list", cursor.nil? ? {} : { "cursor" => cursor })
          raise ProtocolError, "Invalid tools page" unless page.fetch("resultType", "complete") == "complete" && page["tools"].is_a?(Array)
          page["tools"].each do |tool|
            raise ProtocolError, "Invalid tool descriptor" unless tool.is_a?(Hash) && tool["name"].is_a?(String) && !tool["name"].empty?
            scan = ::MCP::Client::McpParamHeaders.scan(tool["inputSchema"])
            next unless scan[:valid] && scan[:declarations].none? { |d| d[:type] == "number" }
            ProtocolSchema.validate!("Tool", tool)
            Schema.new(tool["inputSchema"])
            Schema.new(tool["outputSchema"]) if tool.key?("outputSchema")
            if (previous = result.find { |t| t["name"] == tool["name"] })
              raise ProtocolError, "Conflicting tool definitions" unless previous == tool
            else
              result << tool
            end
            raise ProtocolError, "Tool catalog exceeds limit" if result.size > Connectors.configuration.mcp.max_tools
          end
          cursor = page["nextCursor"]
          return result if cursor.nil?
          raise ProtocolError, "Invalid or repeated pagination cursor" unless cursor.is_a?(String) && cursors.add?(cursor)
        end
        raise ProtocolError, "Tool pagination exceeds limit"
      end

      def call_tool(name:, arguments:)
        @access.require!(:editor)
        fingerprint = @access.fingerprint
        raise ValidationError, "Tool arguments must be an object" unless arguments.is_a?(Hash)
        tool = tools.find { |t| t["name"] == name } or raise ValidationError, "Unknown MCP tool"
        Schema.new(tool["inputSchema"]).validate!(arguments)
        params = { "name" => name, "arguments" => arguments }
        invoke(tool, params, fingerprint: fingerprint)
      end

      def subscribe
        raise ArgumentError, "A notification consumer is required" unless block_given?
        @access.require!
        fingerprint = @access.fingerprint
        transport.request("subscriptions/listen", { "notifications" => { "toolsListChanged" => true } }, subscription: true, cancellation: @cancellation) do |message|
          @access.require!
          unchanged!(fingerprint)
          yield message
        end
      end

      def resume(interaction_id:, responses:)
        Interaction.new(@access).resume(id: interaction_id, responses: responses) do |tool, params, rounds, fingerprint|
          invoke(tool, params, rounds: rounds, fingerprint: fingerprint)
        end
      end

      private

      def invoke(tool, params, rounds: 0, fingerprint:)
        @access.require!(:editor)
        unchanged!(fingerprint)
        headers = ::MCP::Client::McpParamHeaders.build(::MCP::Client::McpParamHeaders.scan(tool["inputSchema"])[:declarations], params["arguments"])
        result = request("tools/call", params, parameter_headers: headers, fingerprint: fingerprint)
        if result["resultType"] == "input_required"
          return Interaction.new(@access).pause(tool: tool, params: params, result: result, rounds: rounds, fingerprint: fingerprint)
        end
        ProtocolSchema.validate!("CallToolResult", result)
        if tool.key?("outputSchema") && !result["isError"]
          raise ValidationError, "Missing structured tool result" unless result.key?("structuredContent")
          Schema.new(tool["outputSchema"]).validate!(result["structuredContent"])
        end
        result
      end

      def transport
        @token = nil
        data = @access.configuration
        fingerprint = @access.fingerprint
        headers = data.fetch("headers", {}).dup
        case data.fetch("auth_mode", "none")
        when "bearer" then headers["Authorization"] = "Bearer #{data.fetch('bearer_token')}"
        when "oauth"
          begin
            @token = authorization.access_token
            headers["Authorization"] = "Bearer #{@token}"
          rescue AuthorizationRequired
            # Probe without credentials to obtain the authoritative resource/scope challenge.
          end
        end
        unchanged!(fingerprint)
        modes = Connectors.configuration.mcp.elicitation_modes
        capabilities = modes.empty? ? {} : { "elicitation" => modes.to_h { |mode| [ mode, {} ] } }
        Transport.new(url: data.fetch("server_url"), headers: headers, capabilities: capabilities)
      end

      def authorization
        Authorization.new(grant: @access.grant, actor: @access.actor, principals: @access.principals)
      end

      def request(method, params, fingerprint: nil, **options)
        role = method == "tools/call" ? :editor : :viewer
        @access.require!(role)
        fingerprint ||= @access.fingerprint
        unchanged!(fingerprint)
        begin
          result = transport.request(method, params, cancellation: @cancellation, **options)
        rescue AuthorizationRequired => error
          @access.require!(role)
          unchanged!(fingerprint)
          if error.challenge["error"] == "insufficient_scope" || !@token
            raise AuthorizationRequired.new(error.challenge, fingerprint: fingerprint)
          end
          authorization.refresh(expected_token: @token)
          result = transport.request(method, params, cancellation: @cancellation, **options)
        end
        @access.require!(role)
        unchanged!(fingerprint)
        result
      end

      def unchanged!(fingerprint)
        raise AccessDenied, "MCP connection changed during the request" unless fingerprint == @access.fingerprint
      end
    end
  end
end
