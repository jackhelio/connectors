module Connectors
  # Credential form schema used by client renderers.
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
  # endpoints.
  class CredentialSchema
    # Supported credential form field types.
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

      # Serialize form metadata with camelCase field keys for client renderers.
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
    # such as :oauth2 or :http_bearer_auth. Redeclare inherited fields via
    # `field` — typically as `type: "hidden", default: "..."` to lock
    # provider-specific endpoints. Doubles as a getter when called with
    # no args (the serializer needs to read it back).
    def extends(*base_names)
      return @extends if base_names.empty?
      @extends = base_names.flatten.map(&:to_sym)
    end

    # Declare authentication properties inherited by connectors extending
    # this credential schema.
    def authenticate(type: nil, properties: nil)
      return @authenticate if type.nil? && properties.nil?
      raise ArgumentError, "authenticate type: must be :generic" unless type.to_sym == :generic
      @authenticate = { "type" => "generic", "properties" => properties }
    end

    # Allow generic HTTP-request use and advertise it in the catalog.
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

    # Resolve inherited fields server-side. Children replace parent fields
    # with the same name, so clients receive a complete form schema.
    def resolved_fields
      parent_fields = @extends.flat_map { |name| CredentialTypeRegistry.fetch(name).own_fields }
      union         = {}
      (parent_fields + own_fields).each { |f| union[f.name] = f }
      union.values
    end

    # Resolve the nearest authenticate declaration, preferring this schema.
    # Returns nil when no schema in the inheritance chain declares one.
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
