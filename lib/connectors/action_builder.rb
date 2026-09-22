module Connectors
  # DSL surface for the `action` block on a Connector subclass. Collects
  # `field`, optional `output`, and `execute` declarations into an Action
  # value object.
  #
  # Reuses `CredentialSchema::Field` as the property struct because n8n's
  # node-property shape and credential-property shape are identical (both
  # `INodeProperties` at packages/workflow/src/interfaces.ts:1773-1812) —
  # only the allowed `type` set differs (see `Action::ALLOWED_TYPES`).
  class ActionBuilder
    Field = CredentialSchema::Field

    def self.build(key, display_name: nil, description: nil, tags: [], deprecated: false, &block)
      builder = new(key, display_name: display_name, description: description,
                         tags: tags, deprecated: deprecated)
      builder.instance_eval(&block) if block
      builder.to_action
    end

    def initialize(key, display_name:, description:, tags:, deprecated:)
      @key           = key
      @display_name  = display_name
      @description   = description
      @tags          = tags
      @deprecated    = deprecated
      @params        = []
      @output        = []
      @execute_block = nil
    end

    # Declare one input parameter. Mirrors `CredentialSchema#field` with the
    # broader `Action::ALLOWED_TYPES` set — same kwargs, same semantics.
    def field(name,
              type:               "string",
              display_name:       nil,
              default:            nil,
              placeholder:        nil,
              description:        nil,
              hint:               nil,
              required:           false,
              no_data_expression: false,
              type_options:       nil,
              display_options:    nil,
              options:            nil)
      raise ArgumentError, "unknown action field type #{type.inspect}; allowed: #{Action::ALLOWED_TYPES.inspect}" \
        unless Action::ALLOWED_TYPES.include?(type.to_s)

      @params << Field.new(
        name:               name.to_sym,
        display_name:       display_name,
        type:               type.to_s,
        default:            default,
        placeholder:        placeholder,
        description:        description,
        hint:               hint,
        required:           required == true,
        no_data_expression: no_data_expression == true,
        type_options:       type_options,
        display_options:    display_options,
        options:            options
      )
    end

    # Declare the shape of the value the action returns. Optional but
    # encouraged — agents and downstream nodes use it to know what fields
    # they can reference (Activepieces calls this `returns:`). The same
    # `field` DSL is used inside the block.
    def output(&block)
      raise ArgumentError, "output requires a block" if block.nil?
      collector = OutputCollector.new
      collector.instance_eval(&block)
      @output = collector.fields
    end

    # Capture the execute block. Invoked by `ActionRunner` in the connector
    # instance's context, so `self.client`, `self.send_email`, etc. are all
    # accessible. Receives one positional Hash of params.
    def execute(&block)
      raise ArgumentError, "execute requires a block" if block.nil?
      @execute_block = block
    end

    def to_action
      Action.new(
        key:           @key,
        display_name:  @display_name,
        description:   @description,
        params:        @params,
        output:        @output,
        execute_block: @execute_block,
        tags:          @tags,
        deprecated:    @deprecated
      )
    end

    # Tiny sibling builder so `output do field ... end` can reuse the same
    # `field` semantics without picking up the outer builder's @params slot.
    class OutputCollector
      attr_reader :fields

      def initialize
        @fields = []
      end

      def field(name,
                type:         "string",
                display_name: nil,
                description:  nil,
                hint:         nil,
                type_options: nil,
                options:      nil)
        @fields << CredentialSchema::Field.new(
          name:         name.to_sym,
          display_name: display_name,
          type:         type.to_s,
          description:  description,
          hint:         hint,
          required:     false,
          type_options: type_options,
          options:      options
        )
      end
    end
  end
end
