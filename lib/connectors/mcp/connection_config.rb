module Connectors
  module MCP
    class ConnectionConfig
      FIELDS = %w[server_url auth_mode bearer_token headers client_information authorization_server].freeze
      PUBLIC_FIELDS = %w[server_url auth_mode authorization_server].freeze
      RESERVED_HEADERS = /\A(?:host|content-.*|accept|connection|transfer-encoding|cookie|proxy-.*|mcp-.*)\z/i

      def self.resolve(data, connector:, **options)
        fixed = connector.mcp_config
        raise ValidationError, "Connector does not support MCP" unless fixed
        fixed.each do |key, value|
          raise ValidationError, "#{key} is fixed for this MCP provider" if data.key?(key) && data[key] != value
        end
        if fixed["auth_mode"] == "oauth" && (data.keys & %w[bearer_token headers]).any?
          raise ValidationError, "This MCP provider requires OAuth authentication"
        end
        validate!(fixed.merge(data), **options)
      end

      def self.validate!(data, internal: false, require_secrets: true)
        allowed = internal ? FIELDS + [ "mcp_oauth" ] : FIELDS
        raise ValidationError, "Unsupported MCP credential fields" if (data.keys - allowed).any?
        HTTP.new.validate_url!(data.fetch("server_url", ""))
        mode = data.fetch("auth_mode", "none")
        raise ValidationError, "Unsupported MCP authentication mode" unless %w[none bearer headers oauth].include?(mode)
        if mode == "bearer" && (require_secrets || data.key?("bearer_token")) && (!data["bearer_token"].is_a?(String) || data["bearer_token"].blank? || data["bearer_token"].match?(/[\r\n]/))
          raise ValidationError, "A valid bearer token is required"
        end
        headers = data.fetch("headers", {})
        raise ValidationError, "Headers must be an object" unless headers.is_a?(Hash)
        headers.each do |key, value|
          unless key.is_a?(String) && key.match?(::MCP::Client::McpParamHeaders::RFC9110_TOKEN) && !key.match?(RESERVED_HEADERS) && value.is_a?(String) && !value.match?(/[\r\n\x00]/)
            raise ValidationError, "Invalid or reserved MCP header"
          end
          raise ValidationError, "Authorization header requires headers auth mode" if key.casecmp?("authorization") && mode != "headers"
        end
        if data["client_information"] && !data["client_information"].is_a?(Hash)
          raise ValidationError, "Client information must be an object"
        end
        data
      end

      def self.public_data(data)
        data.slice(*PUBLIC_FIELDS)
      end
    end
  end
end
