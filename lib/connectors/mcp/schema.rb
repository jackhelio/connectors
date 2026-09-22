module Connectors
  module MCP
    class Schema
      DIALECTS = %w[https://json-schema.org/draft/2020-12/schema http://json-schema.org/draft-07/schema#].freeze
      def initialize(schema)
        raise ValidationError, "Tool schema must be an object" unless schema.is_a?(Hash)
        dialect = schema.fetch("$schema", DIALECTS.first)
        raise ValidationError, "Unsupported schema dialect" unless DIALECTS.include?(dialect)
        check_complexity!(schema)
        resolver = ->(_uri) { raise ValidationError, "External schema references are disabled" }
        @schema = JSONSchemer.schema(schema, ref_resolver: resolver)
        bounded { raise ValidationError, "Invalid tool schema" unless @schema.valid_schema? }
      rescue JSONSchemer::UnknownRef
        raise ValidationError, "Unresolved schema reference"
      end

      def validate!(value)
        bounded { raise ValidationError, "Value does not satisfy tool schema" unless @schema.valid?(value) }
      rescue JSONSchemer::UnknownRef
        raise ValidationError, "Unresolved schema reference"
      end

      private

      def bounded(&block)
        Timeout.timeout(Connectors.configuration.mcp.schema_timeout, ValidationError, "Schema validation deadline exceeded", &block)
      end

      def check_complexity!(schema)
        nodes = [ [ schema, 0 ] ]
        count = 0
        until nodes.empty?
          node, depth = nodes.pop
          count += 1
          raise ValidationError, "Schema is too complex" if count > Connectors.configuration.mcp.max_schema_nodes || depth > 50
          children = node.is_a?(Hash) ? node.values : (node.is_a?(Array) ? node : [])
          if node.is_a?(Hash) && node["$ref"].is_a?(String) && !node["$ref"].start_with?("#")
            raise ValidationError, "External schema references are disabled"
          end
          children.each { |child| nodes << [ child, depth + 1 ] }
        end
      end
    end
  end
end
