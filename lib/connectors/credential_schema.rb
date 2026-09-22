module Connectors
  # Declarative description of every field a credential type's data hash can
  # contain. Mirrors n8n's `INodeProperties` shape exactly (n8n source:
  # packages/workflow/src/interfaces.ts:1773-1812) so a single frontend
  # renderer handles every connector with no per-connector logic.
  #
  #   credentials do
  #     field :api_key,
  #           type:         "string",
  #           display_name: "API Key",
  #           required:     true,
  #           type_options: { password: true },
  #           placeholder:  "re_...",
  #           description:  "Generate at https://resend.com/api-keys"
  #   end
  #
  # Inheritance: a connector can `extends :oauth2` (or any other registered
  # base type) and `field` calls in the block can REDECLARE inherited fields
  # — typically as `type: "hidden"` with a fixed `default:` to lock provider
  # endpoints (matches n8n's Slack/Google override pattern at
  # SlackOAuth2Api.credentials.ts:38-122).
  class CredentialSchema
    # n8n's `NodePropertyTypes` enum (interfaces.ts:1561-1584). Wave A ships
    # the most commonly-used subset; later waves add resourceLocator /
    # collection / fixedCollection / dateTime as connectors demand them.
    ALLOWED_TYPES = %w[
      string number boolean
      options multiOptions
      json hidden notice
    ].freeze

    Field = Struct.new(
      :name, :display_name, :type, :default, :placeholder, :description, :hint,
      :required, :no_data_expression,
      :type_options, :display_options, :options,
      keyword_init: true
    ) do
      def required?
        required == true
      end

      def password?
        (type_options || {}).any? { |k, v| k.to_s == "password" && v == true }
      end

      # Frontend-shaped hash. n8n serializes property names in camelCase
      # (`displayName`, `typeOptions`); we mirror that so the editor's
      # generic form renderer eats it without translation.
      def to_property
        {
          name:             name.to_s,
          displayName:      display_name || name.to_s.tr("_", " ").capitalize,
          type:             type.to_s,
          default:          default,
          placeholder:      placeholder,
          description:      description,
          hint:             hint,
          required:         required == true,
          noDataExpression: no_data_expression == true,
          typeOptions:      stringify(type_options),
          displayOptions:   stringify(display_options),
          options:          options&.map { |o| stringify(o) }
        }.compact
      end

      private

      def stringify(v)
        case v
        when Hash  then v.each_with_object({}) { |(k, vv), out| out[k.to_s] = stringify(vv) }
        when Array then v.map { |vv| stringify(vv) }
        else v
        end
      end
    end

    def self.build(&block)
      schema = new
      schema.instance_eval(&block) if block
      schema
    end

    def initialize
      @fields          = {}
      @extends         = []
      @authenticate    = nil
      @generic_auth    = false
      @display_name    = nil
      @documentation_url = nil
    end

    # Inherit fields from one or more registered base credential schemas
    # (today only `:oauth2`). Inherited fields can be REDECLARED below via
    # `field` — typically as `type: "hidden", default: "..."` to lock
    # provider-specific endpoints. Doubles as a getter when called with
    # no args (the serializer needs to read it back).
    def extends(*base_names)
      return @extends if base_names.empty?
      @extends = base_names.flatten.map(&:to_sym)
    end

    # n8n-shape declarative auth injection (mirrors `ICredentialType.authenticate`
    # at packages/workflow/src/interfaces.ts:367; type `IAuthenticateGeneric`
    # at :278-288). Per-credential-type so any connector that `extends` this
    # schema inherits the injection contract automatically.
    def authenticate(type: nil, properties: nil)
      return @authenticate if type.nil? && properties.nil?
      raise ArgumentError, "authenticate type: must be :generic" unless type.to_sym == :generic
      @authenticate = { "type" => "generic", "properties" => properties }
    end

    # n8n flag: this credential type is visible to the future generic HTTP
    # Request node's credential picker (`interfaces.ts:379`; example
    # consumer `HttpBearerAuth.credentials.ts:12`). Stored here so the
    # serializer surfaces it; runtime enforcement lands in Phase 5.
    def generic_auth!
      @generic_auth = true
    end

    def generic_auth?
      @generic_auth == true || @extends.any? { |b| CredentialTypeRegistry.fetch(b).generic_auth? rescue false }
    end

    # Optional metadata that lives on the credential type rather than the
    # connector class. Set on base credential types (HttpBearerAuth's
    # "Bearer Auth" name) — the serializer prefers these over connector-
    # level fallbacks when present.
    def display_name(value = nil)
      return @display_name if value.nil?
      @display_name = value.to_s
    end

    def documentation_url(value = nil)
      return @documentation_url if value.nil?
      @documentation_url = value.to_s
    end

    def field(name,
              type:               "string",
              display_name:       nil,
              default:            nil,
              placeholder:        nil,
              description:        nil,
              hint:               nil,
              required:           false,
              no_data_expression: false,
              secret:             false,     # convenience — sets type_options[:password] = true
              type_options:       nil,
              display_options:    nil,
              options:            nil)
      raise ArgumentError, "unknown credential field type #{type.inspect}; allowed: #{ALLOWED_TYPES.inspect}" \
        unless ALLOWED_TYPES.include?(type.to_s)

      effective_type_options = (type_options || {}).dup
      effective_type_options[:password] = true if secret

      @fields[name.to_sym] = Field.new(
        name:               name.to_sym,
        display_name:       display_name,
        type:               type.to_s,
        default:            default,
        placeholder:        placeholder,
        description:        description,
        hint:               hint,
        required:           required,
        no_data_expression: no_data_expression,
        type_options:       effective_type_options.empty? ? nil : effective_type_options,
        display_options:    display_options,
        options:            options
      )
    end

    # The fields declared directly on this schema, in declaration order.
    # For the full resolved form (parents + own), use `resolved_fields`.
    def own_fields
      @fields.values
    end

    # n8n's editor walks `extends` and merges parent properties before
    # rendering. We do the walk server-side and emit the union so the
    # frontend doesn't need to fetch each parent type separately. Children
    # override parents by re-declaring with the same name.
    def resolved_fields
      parent_fields = @extends.flat_map { |name| CredentialTypeRegistry.fetch(name).own_fields }
      union         = {}
      (parent_fields + own_fields).each { |f| union[f.name] = f }
      union.values
    end

    # Walk `extends` to find the inherited authenticate block; the child's
    # own block (if declared) overrides. Returns nil when no parent in the
    # chain declared one. Matches n8n's runtime credential-walker pattern
    # at packages/cli/src/credential-types.ts:26-37.
    def resolved_authenticate
      return @authenticate if @authenticate
      @extends.each do |name|
        parent = CredentialTypeRegistry.fetch(name) rescue nil
        next if parent.nil?
        block = parent.resolved_authenticate
        return block if block
      end
      nil
    end

    # Back-compat — older code referenced `.fields` and `.required_fields`.
    alias_method :fields, :resolved_fields

    def required_fields
      resolved_fields.select(&:required?)
    end

    def validate!(credentials_hash)
      data    = (credentials_hash || {}).transform_keys(&:to_s)
      missing = required_fields.map { |f| f.name.to_s }.reject { |k| data[k].to_s.length.positive? }
      raise MissingCredentialFields.new(missing) if missing.any?
      true
    end
  end
end
