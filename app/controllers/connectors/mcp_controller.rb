module Connectors
  class McpController < ApplicationController
    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    rescue_from MCP::Error, with: :mcp_error

    def tools
      render json: { tools: client.tools }
    end

    def call_tool
      render json: client.call_tool(name: params.require(:name), arguments: json_object(:arguments))
    end

    def resume
      render json: client.resume(interaction_id: params.require(:interaction_id), responses: json_object(:responses))
    end

    def authorize
      grant = Grant.find(params[:id])
      access = MCP::Access.new(grant: grant, actor: current_owner!, principals: current_principals)
      access.require!(:owner)
      if params[:authorization_context].present?
        challenge = MCP::AuthorizationContext.decode(params[:authorization_context], access: access)
        return render json: { authorization_url: authorization.start(challenge: challenge) }
      end
      # Challenge data is obtained from the MCP endpoint, not supplied as arbitrary URLs by the caller.
      service = client
      challenge = begin
        service.tools
        {}
      rescue MCP::AuthorizationRequired => error
        error.challenge
      end
      render json: { authorization_url: authorization.start(challenge: challenge) }
    end

    def callback
      state = params.require(:state)
      record = McpAuthorization.find_by!(state_digest: Digest::SHA256.hexdigest(state))
      service = MCP::Authorization.new(grant: record.grant, actor: current_owner!, principals: current_principals)
      service.complete(state: state, code: params[:code], iss: params[:iss], error: params[:error])
      render json: { status: "authorized" }
    end

    private

    def json_object(key)
      value = params[key]
      raise MCP::ValidationError, "#{key} must be an object" unless value.is_a?(ActionController::Parameters)
      value.to_unsafe_h
    end

    def client
      MCP::Client.new(grant: Grant.find(params[:id]), actor: current_owner!, principals: current_principals)
    end

    def authorization
      MCP::Authorization.new(grant: Grant.find(params[:id]), actor: current_owner!, principals: current_principals)
    end

    def mcp_error(error)
      status, kind = case error
      when MCP::AccessDenied then [ :forbidden, "access_denied" ]
      when MCP::AuthorizationRequired then [ :unauthorized, "authorization_required" ]
      when MCP::ConfigurationRequired then [ :unprocessable_content, "configuration_required" ]
      when MCP::ValidationError then [ :unprocessable_content, "validation_error" ]
      when MCP::ProtocolError then [ :bad_gateway, "protocol_error" ]
      when MCP::HTTPError
        error.status == 429 ? [ :too_many_requests, "rate_limited" ] : [ :bad_gateway, "transport_error" ]
      else [ :bad_gateway, "transport_error" ]
      end
      body = { error: { type: kind, message: error.message } }
      if kind == "rate_limited" && (retry_after = error.retry_after)
        response.headers["Retry-After"] = retry_after
        body[:error][:retry_after] = retry_after
      end
      if error.is_a?(MCP::AuthorizationRequired)
        grant = Grant.find(params[:id])
        body[:authorization_context] = MCP::AuthorizationContext.encode(grant: grant, challenge: error.challenge, fingerprint: error.fingerprint)
      end
      render json: body, status: status
    end

    def not_found
      head :not_found
    end
  end
end
