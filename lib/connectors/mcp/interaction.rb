module Connectors
  module MCP
    class Interaction
      def initialize(access)
        @access = access
      end

      def pause(tool:, params:, result:, rounds:, fingerprint:)
        ProtocolSchema.validate!("InputRequiredResult", result)
        raise ProtocolError, "MCP interaction round limit exceeded" if rounds >= Connectors.configuration.mcp.max_rounds
        requests = result.fetch("inputRequests", {})
        raise ProtocolError, "Invalid MCP input requests" unless requests.is_a?(Hash) && (requests.any? || result["requestState"].is_a?(String))
        if result.key?("requestState") && !result["requestState"].is_a?(String)
          raise ProtocolError, "Invalid MCP request state"
        end
        requests.each_value { |request| validate_request!(request) }
        @access.require!(:editor)
        raise AccessDenied, "MCP connection changed" unless fingerprint == @access.fingerprint
        record = Connectors::McpInteraction.create!(grant: @access.grant, actor_key: @access.actor_key, fingerprint: fingerprint,
          expires_at: Connectors.configuration.mcp.transaction_ttl.from_now,
          payload: { "tool" => tool, "params" => params, "result" => result, "rounds" => rounds })
        # The opaque server state stays encrypted at rest, never in a caller-controlled resume payload.
        result.except("requestState").merge("interaction_id" => record.id)
      end

      def resume(id:, responses:)
        @access.require!(:editor)
        record = Connectors::McpInteraction.find_by(id: id, grant_id: @access.grant.id)
        raise AccessDenied, "Unknown MCP interaction" unless record
        payload = record.claim!(@access) do |pending|
          validate_responses!(pending.fetch("result").fetch("inputRequests", {}), responses)
        end
        claimed = true
        params = payload.fetch("params").except("inputResponses", "requestState")
        params["inputResponses"] = responses unless responses.empty?
        params["requestState"] = payload["result"]["requestState"] if payload["result"].key?("requestState")
        yield payload.fetch("tool"), params, payload.fetch("rounds") + 1, record.fingerprint
      ensure
        record.update!(status: "consumed", payload: { "cleared" => true }) if claimed
      end

      private

      def validate_request!(request)
        ProtocolSchema.validate!("ElicitRequest", request)
        unless request.is_a?(Hash) && request["method"] == "elicitation/create" && request["params"].is_a?(Hash)
          raise ProtocolError, "Unsupported MCP input request"
        end
        params = request["params"]
        mode = params.fetch("mode", "form")
        raise ProtocolError, "Unadvertised elicitation mode" unless Connectors.configuration.mcp.elicitation_modes.include?(mode)
        raise ProtocolError, "Invalid elicitation message" unless params["message"].is_a?(String)
        case mode
        when "url" then HTTP.new.validate_url!(params["url"])
        when "form" then Schema.new(params["requestedSchema"])
        else raise ProtocolError, "Unsupported elicitation mode"
        end
      end

      def validate_responses!(requests, responses)
        unless responses.is_a?(Hash) && responses.keys.sort == requests.keys.sort
          raise ValidationError, "Input responses must match the pending requests"
        end
        requests.each do |key, request|
          response = responses[key]
          ProtocolSchema.validate!("ElicitResult", response)
          unless response.is_a?(Hash) && %w[accept decline cancel].include?(response["action"])
            raise ValidationError, "Invalid elicitation action"
          end
          mode = request["params"].fetch("mode", "form")
          if mode == "form" && response["action"] == "accept"
            Schema.new(request["params"]["requestedSchema"]).validate!(response["content"])
          elsif response.key?("content")
            raise ValidationError, "This elicitation response must omit content"
          end
        end
      rescue ProtocolError
        raise ValidationError, "Invalid elicitation response"
      end
    end
  end
end
