module Connectors
  module MCP
    # The normative schema is an offline, pinned upstream artifact; do not recreate its types here.
    module ProtocolSchema
      DOCUMENT = JSON.parse(File.read(File.join(__dir__, "protocol/2026-07-28.json"))).freeze
      VALIDATORS = %w[Tool CallToolResult InputRequiredResult ElicitRequest ElicitResult].to_h do |name|
        document = DOCUMENT
        if name == "ElicitResult"
          # Normative schema.ts at the pinned commit, line 3148, permits `number`.
          # The generated JSON incorrectly narrows this union member to integer.
          document = DOCUMENT.deep_dup
          alternatives = document.fetch("$defs").fetch(name).fetch("properties").fetch("content").fetch("additionalProperties").fetch("anyOf")
          alternatives.last["type"] = %w[string number boolean]
        end
        [ name, JSONSchemer.schema(document.merge("$ref" => "#/$defs/#{name}"), ref_resolver: ->(_) { raise ProtocolError, "External protocol reference" }) ]
      end.freeze
      module_function

      def validate!(name, value)
        candidate = value
        if %w[CallToolResult InputRequiredResult].include?(name) && value.is_a?(Hash) && !value.key?("resultType")
          candidate = value.merge("resultType" => "complete")
        end
        Timeout.timeout(Connectors.configuration.mcp.schema_timeout, ProtocolError, "Protocol validation deadline exceeded") do
          raise ProtocolError, "Invalid MCP #{name}" unless VALIDATORS.fetch(name).valid?(candidate)
        end
      end
    end
  end
end
