module Connectors
  # Reusable HTTP authentication schemas. Basic, bearer, header and query
  # types declare runtime injection inherited by extending connectors.
  # Digest and custom JSON types provide form metadata only.
  # All types advertise generic_auth for HTTP-request credential selection.
  module CredentialTypes
    # Basic authentication via the declarative username/password shortcut.
    HTTP_BASIC_AUTH = CredentialSchema.build do
      display_name      "Basic Auth"
      documentation_url "https://github.com/jackhelio/connectors/blob/main/CONNECTORS_FRAMEWORK.md#6-built-in-base-credential-types"
      generic_auth!

      field :user,
            type:         "string",
            display_name: "User",
            default:      ""
      field :password,
            type:         "string",
            display_name: "Password",
            default:      "",
            secret:       true

      authenticate type: :generic, properties: {
        auth: { username: "={{$credentials.user}}", password: "={{$credentials.password}}" }
      }
    end

    # Bearer token authentication.
    HTTP_BEARER_AUTH = CredentialSchema.build do
      display_name      "Bearer Auth"
      documentation_url "https://github.com/jackhelio/connectors/blob/main/CONNECTORS_FRAMEWORK.md#6-built-in-base-credential-types"
      generic_auth!

      field :token,
            type:         "string",
            display_name: "Bearer Token",
            default:      "",
            secret:       true

      field :_notice_custom_auth,
            type:         "notice",
            display_name: 'This credential uses the "Authorization" header. ' \
                          'To use a custom header, use a "Header Auth" credential instead',
            default:      ""

      authenticate type: :generic, properties: {
        headers: { "Authorization" => "=Bearer {{$credentials.token}}" }
      }
    end

    # Both header name and value are resolved from credential templates.
    HTTP_HEADER_AUTH = CredentialSchema.build do
      display_name      "Header Auth"
      documentation_url "https://github.com/jackhelio/connectors/blob/main/CONNECTORS_FRAMEWORK.md#6-built-in-base-credential-types"
      generic_auth!

      field :name,
            type:         "string",
            display_name: "Name",
            default:      ""
      field :value,
            type:         "string",
            display_name: "Value",
            default:      "",
            secret:       true

      field :_notice_multi,
            type:         "notice",
            display_name: 'To send multiple headers, use a "Custom Auth" credential instead',
            default:      ""

      authenticate type: :generic, properties: {
        headers: { "={{$credentials.name}}" => "={{$credentials.value}}" }
      }
    end

    # Query parameter authentication.
    HTTP_QUERY_AUTH = CredentialSchema.build do
      display_name      "Query Auth"
      documentation_url "https://github.com/jackhelio/connectors/blob/main/CONNECTORS_FRAMEWORK.md#6-built-in-base-credential-types"
      generic_auth!

      field :name,
            type:         "string",
            display_name: "Name",
            default:      ""
      field :value,
            type:         "string",
            display_name: "Value",
            default:      "",
            secret:       true

      authenticate type: :generic, properties: {
        qs: { "={{$credentials.name}}" => "={{$credentials.value}}" }
      }
    end

    # Digest credential form only; no challenge-response runtime is provided.
    HTTP_DIGEST_AUTH = CredentialSchema.build do
      display_name      "Digest Auth"
      documentation_url "https://github.com/jackhelio/connectors/blob/main/CONNECTORS_FRAMEWORK.md#6-built-in-base-credential-types"
      generic_auth!

      field :user,
            type:         "string",
            display_name: "User",
            default:      ""
      field :password,
            type:         "string",
            display_name: "Password",
            default:      "",
            secret:       true

      # No authenticate block: digest challenge handling is not implemented.
    end

    # Custom JSON credential form only; user-supplied JSON is not
    # applied to outbound requests by this schema.
    HTTP_CUSTOM_AUTH = CredentialSchema.build do
      display_name      "Custom Auth"
      documentation_url "https://github.com/jackhelio/connectors/blob/main/CONNECTORS_FRAMEWORK.md#6-built-in-base-credential-types"
      generic_auth!

      field :json,
            type:         "json",
            display_name: "JSON",
            required:     true,
            default:      "",
            description:  "Use JSON to specify authentication values for headers, body and qs.",
            placeholder:  '{ "headers": { "key" : "value" }, "body": { "key": "value" }, "qs": { "key": "value" } }',
            type_options: { redactJsonLeaves: true }
    end
  end
end
