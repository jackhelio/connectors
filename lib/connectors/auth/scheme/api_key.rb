require "cgi"

module Connectors
  module Auth
    class Scheme
      # Attaches a static API key from grant.credentials["api_key"]. The
      # location (header vs query), parameter name, and optional prefix are
      # declared by the connector class via the `api_key_in` DSL:
      #
      #   class GithubConnector < Connectors::Connector
      #     connector  key: :github, auth: :api_key, base_url: "https://api.github.com"
      #     api_key_in :header, name: "Authorization", prefix: "token "
      #   end
      #
      # Default placement is `Authorization: Bearer <key>`.
      class ApiKey < Scheme
        register_as :api_key

        DEFAULT_OPTIONS = { location: :header, name: "Authorization", prefix: "Bearer " }.freeze

        def on_request(env)
          key = @grant.credentials_hash["api_key"]
          if key.nil? || key.to_s.empty?
            raise Connectors::AuthenticationFailed.new("grant #{@grant.id} has no api_key")
          end

          opts  = connector_options
          value = "#{opts[:prefix]}#{key}"

          case opts[:location]
          when :header
            env.request_headers[opts[:name]] = value
          when :query
            existing = env.url.query
            pair     = "#{opts[:name]}=#{CGI.escape(value)}"
            env.url.query = [ existing, pair ].compact.reject(&:empty?).join("&")
          else
            raise Connectors::Error.new("ApiKey scheme: unknown location #{opts[:location].inspect}")
          end
        end

        private

        def connector_options
          klass = @grant.connector.class
          (klass.respond_to?(:api_key_options) && klass.api_key_options) || DEFAULT_OPTIONS
        end
      end
    end
  end
end
