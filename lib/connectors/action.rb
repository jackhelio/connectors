module Connectors
  # Declarative description of one thing a connector can DO with a credential
  # — Slack "post message", Resend "send email", GitHub "create issue". Each
  # action describes its inputs, outputs and execution handler.
  #
  # The class is a value object — `ActionBuilder` materialises it from the
  # DSL, `Connector.actions` stores them, `ActionRunner` invokes them.
  # Frontend / agents read `to_manifest` to know what inputs the action
  # accepts and what shape it returns.
  #
  #   action :send_email,
  #          display_name: "Send Email",
  #          description:  "Send a transactional email via Resend." do
  #     field :from,        type: "string", required: true,
  #           placeholder:  "Updates <updates@yourdomain.com>"
  #     field :to,          type: "string", required: true,
  #           type_options: { multiple_values: true }
  #     field :subject,     type: "string", required: true
  #     field :html,        type: "string", type_options: { editor: "html" }
  #     field :text,        type: "string", type_options: { rows: 4 }
  #
  #     output do
  #       field :id, type: "string", description: "Resend message id."
  #     end
  #
  #     execute do |input|
  #       send_email(**input.symbolize_keys)
  #     end
  #   end
  class Action
    # Supported action input types. Action fields include collections and
    # other per-execution inputs beyond the credential form types.
    ALLOWED_TYPES = %w[
      string number boolean
      options multiOptions
      json hidden notice
      collection fixedCollection
      dateTime color
      resourceLocator resourceMapper
      filter assignmentCollection
    ].freeze

    attr_reader :key, :display_name, :description, :params, :output, :execute_block,
                :tags, :deprecated

    def initialize(key:, display_name:, description: nil,
                   params: [], output: [], execute_block: nil,
                   tags: [], deprecated: false)
      raise ArgumentError, "execute block is required for action #{key.inspect}" if execute_block.nil?

      @key           = key.to_sym
      @display_name  = display_name || key.to_s.tr("_", " ").capitalize
      @description   = description
      @params        = params
      @output        = output
      @execute_block = execute_block
      @tags          = Array(tags).map(&:to_sym)
      @deprecated    = deprecated == true
    end

    # Frontend / agent-facing shape. camelCase the keys that go into the
    # property objects so they look identical to credential properties (the
    # generic form renderer handles both with no special-casing). Output
    # shape is the same — fields describing what the runner returns.
    def to_manifest
      {
        name:         key.to_s,
        display_name: display_name,
        description:  description,
        deprecated:   deprecated,
        tags:         tags.map(&:to_s),
        properties:   params.map(&:to_property),
        output:       output.map(&:to_property)
      }.compact
    end

    # Names of params marked `required: true`. Used by ActionRunner to
    # short-circuit before the execute block runs.
    def required_param_names
      params.select(&:required?).map { |f| f.name.to_s }
    end

    def param_names
      params.map { |f| f.name.to_s }
    end
  end
end
