module Connectors
  # Generic HTTP authentication credential types — n8n parity with the six
  # `Http*Auth.credentials.ts` types shipped in
  # `packages/nodes-base/credentials/`. Each is `generic_auth: true` so a
  # future HTTP-Request-style node can offer them in its credential picker
  # (the runtime check lands in Phase 5).
  #
  # Connectors inherit any of these via `extends :http_bearer_auth` etc.
  # When a connector extends one of the runtime-supported types
  # (basic / bearer / header / query), the AuthenticateGeneric middleware
  # picks up the inherited `authenticate` block and injects per-request —
  # no `api_key_in` boilerplate needed.
  #
  # n8n source: `packages/nodes-base/credentials/HttpBasicAuth.credentials.ts`,
  # `HttpBearerAuth.credentials.ts`, `HttpHeaderAuth.credentials.ts`,
  # `HttpQueryAuth.credentials.ts`, `HttpDigestAuth.credentials.ts`,
  # `HttpCustomAuth.credentials.ts`.
  module CredentialTypes
    # --- :http_basic_auth -------------------------------------------------
    # n8n: HttpBasicAuth.credentials.ts:1-33. n8n's HTTP node implements
    # Basic auth itself (no `authenticate` block on the credential). We
    # synthesize one using AuthenticateGeneric's `auth: { username, password }`
    # shortcut so the declarative path works end-to-end.
    HTTP_BASIC_AUTH = CredentialSchema.build do
      display_name      "Basic Auth"
      documentation_url "httprequest"
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

    # --- :http_bearer_auth ------------------------------------------------
    # n8n: HttpBearerAuth.credentials.ts:1-43.
    HTTP_BEARER_AUTH = CredentialSchema.build do
      display_name      "Bearer Auth"
      documentation_url "httprequest"
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

    # --- :http_header_auth ------------------------------------------------
    # n8n: HttpHeaderAuth.credentials.ts:1-45. Both header NAME and VALUE
    # are templated — AuthInjection.walk resolves keys as well as values
    # (see auth_injection.rb).
    HTTP_HEADER_AUTH = CredentialSchema.build do
      display_name      "Header Auth"
      documentation_url "httprequest"
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

    # --- :http_query_auth -------------------------------------------------
    # n8n: HttpQueryAuth.credentials.ts:1-30. n8n's HTTP node handles
    # injection imperatively; we synthesize the equivalent generic block.
    HTTP_QUERY_AUTH = CredentialSchema.build do
      display_name      "Query Auth"
      documentation_url "httprequest"
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

    # --- :http_digest_auth ------------------------------------------------
    # n8n: HttpDigestAuth.credentials.ts:1-32. n8n consumes this via axios's
    # built-in digest challenge handling. Faraday has no equivalent
    # middleware out of the box — we ship the SCHEMA (so the frontend can
    # render the form + a future generic HTTP-Request node can offer the
    # type) but the AuthenticateGeneric middleware can't perform the
    # challenge-response handshake on its own.
    #
    # Runtime support requires a Faraday-Digest middleware. Tracked as a
    # follow-up; for now the type is form-only.
    HTTP_DIGEST_AUTH = CredentialSchema.build do
      display_name      "Digest Auth"
      documentation_url "httprequest"
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

      # No authenticate block — requires challenge-response middleware
      # (Faraday-Digest gem or equivalent). Phase 2 ships the schema only.
    end

    # --- :http_custom_auth ------------------------------------------------
    # n8n: HttpCustomAuth.credentials.ts:1-29. Single `json` field carrying
    # `{ headers, body, qs }`. n8n's HTTP node parses this JSON at request
    # time and applies it. Our AuthenticateGeneric middleware works on a
    # static `properties` block; runtime injection of a user-supplied JSON
    # is deferred until a Custom-API-Call style node lands (workflow
    # roadmap). Phase 2 ships the schema only.
    HTTP_CUSTOM_AUTH = CredentialSchema.build do
      display_name      "Custom Auth"
      documentation_url "httprequest"
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
