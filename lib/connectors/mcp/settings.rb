module Connectors
  module MCP
    class Settings
      attr_accessor :private_hosts, :allow_loopback_http, :client_name, :callback_url,
                    :client_metadata_url, :open_timeout, :request_timeout, :stream_timeout,
                    :max_bytes, :max_pages, :max_tools, :max_rounds, :transaction_ttl,
                    :schema_timeout, :max_schema_nodes, :elicitation_modes, :assertion_provider

      def initialize
        @private_hosts = []
        @allow_loopback_http = false
        @client_name = "Connectors"
        @open_timeout = 5
        @request_timeout = 30
        @stream_timeout = 300
        @max_bytes = 4 * 1024 * 1024
        @max_pages = 100
        @max_tools = 1000
        @max_rounds = 10
        @transaction_ttl = 15.minutes
        @schema_timeout = 1
        @max_schema_nodes = 10_000
        @elicitation_modes = []
      end
    end
  end
end
