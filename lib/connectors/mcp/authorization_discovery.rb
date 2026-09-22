module Connectors
  module MCP
    class AuthorizationDiscovery
      SDK = ::MCP::Client::OAuth::Discovery

      def initialize(server_url:, issuer: nil)
        @server_url, @issuer = server_url, issuer
        @http = HTTP.new
      end

      def call(challenge = {})
        @http.validate_url!(@server_url)
        resource = fetch_first(SDK.protected_resource_metadata_urls(server_url: @server_url, resource_metadata_url: challenge["resource_metadata"]))
        unless resource["resource"].is_a?(String) && SDK.resource_covers?(prm: resource["resource"], server: @server_url)
          raise ConfigurationRequired, "Protected resource metadata does not cover this MCP server"
        end
        issuers = resource["authorization_servers"]
        raise ConfigurationRequired, "No authorization server advertised" unless issuers.is_a?(Array) && issuers.any? && issuers.all? { |v| v.is_a?(String) }
        issuer = @issuer || issuers.first
        raise ConfigurationRequired, "Configured issuer is not advertised" unless issuers.include?(issuer)
        @http.validate_url!(issuer)
        metadata = fetch_first(SDK.authorization_server_metadata_urls(issuer))
        raise ConfigurationRequired, "Authorization issuer mismatch" unless metadata["issuer"] == issuer
        %w[authorization_endpoint token_endpoint].each { |key| @http.validate_url!(metadata.fetch(key, "")) }
        [ resource, metadata ]
      end

      private

      def fetch_first(urls)
        urls.each do |url|
          begin
            return @http.json(url: url, headers: { "Accept" => "application/json" })
          rescue HTTPError => error
            raise unless [ 404, 405 ].include?(error.status)
          end
        end
        raise ConfigurationRequired, "MCP authorization metadata unavailable"
      end
    end
  end
end
