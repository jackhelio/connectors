# External MCP connections

The engine consumes remote MCP **2026-07-28** servers through Streamable HTTP. It supports public servers, bearer tokens, custom authentication headers, and user OAuth with discovery, PKCE, registration, refresh and scope upgrades. Tools remain scoped to their grant; they are not added to the global connector registry.

The implementation uses public helpers from `mcp` **1.6.0**, `json_schemer` **2.5**, and `event_stream_parser` **1.0**. Its durable OAuth coordinator and HTTP transport are owned by this engine. The SDK's synchronous OAuth flow and high-level tool projection did not meet the reviewed requirements. No SDK private methods are patched or invoked. Server result types are validated against the vendored, versioned official schema; its source and license are in [protocol/README.md](lib/connectors/mcp/protocol/README.md).

## Installation and host setup

Run `bundle install` and the host's migrations. The new migration creates encrypted, expiring authorization and interaction records, with PostgreSQL foreign keys and one-time claims. Existing connector tables and credentials are preserved.

Follow the [host installation guide](README.md#installation), including encryption and trusted authentication middleware. Configure the engine's existing owner/principal resolvers. These remain the authentication boundary; callers must never supply their own trusted principal list through request parameters.

```ruby
Connectors.configure do |config|
  config.owner_class_name = "User"
  config.current_owner_resolver = ->(controller) { controller.request.env["connectors.current_owner"] }
  config.host_base_url = ENV.fetch("APP_BASE_URL")

  # Must match the URI registered with the authorization server / CIMD document.
  config.mcp.callback_url = ENV.fetch("MCP_CALLBACK_URL")
end
```

Without an explicit MCP callback URL, the engine uses its mounted `/mcp/oauth/callback` endpoint under `host_base_url`. A split frontend/backend host can configure a frontend callback and POST the returned parameters to the engine callback endpoint. The callback request must resolve to the same owner that started authorization.

Only HTTPS destinations are allowed by default. Private, loopback and link-local addresses are refused after DNS resolution. The chosen address is pinned for the request while preserving TLS hostname verification. Redirects and environment proxies are not followed. Configure an explicit hostname in `config.mcp.private_hosts` for an intended private enterprise server; use `config.mcp.allow_loopback_http = true` only for deliberate local development/testing.

## Create a connection

Use the existing credential endpoint, with `type: "mcp"`:

```json
{
  "type": "mcp",
  "name": "My MCP server",
  "data": {
    "server_url": "https://server.example/mcp",
    "auth_mode": "oauth"
  }
}
```

Supported credential fields:

| Field | Use |
| --- | --- |
| `server_url` | Exact remote MCP endpoint. |
| `auth_mode` | `none`, `bearer`, `headers`, or `oauth`. |
| `bearer_token` | Secret for `bearer` mode. |
| `headers` | Secret JSON object for custom header authentication. Transport-owned headers cannot be overridden. A custom `Authorization` header requires `headers` mode. |
| `authorization_server` | Optional issuer selection when the resource advertises multiple authorization servers. |
| `client_information` | Optional preregistered OAuth client: `client_id`, exact `issuer`, optional `client_secret`, and `token_endpoint_auth_method`. |

OAuth token/client state is internal. Credential APIs reject attempts to inject it. `include_data=true` returns only server URL, authentication mode and issuer selection for MCP connections. Editors can invoke shared connections; only owners can replace credentials or perform OAuth. Sharing grants access to the remote account represented by the grant.

For managed credentials, the existing secrets resolver can supply authentication fields. Configured client secrets are resolved at exchange/refresh time and are not duplicated into pending transactions or the token namespace. Changes to owner, destination, authentication fields or managed-secret reference invalidate pending work and token bindings.

## ClickUp

ClickUp is a built-in named MCP connector. Create it without supplying an endpoint or secrets:

```http
POST /connectors/credentials
Content-Type: application/json

{"type":"clickup","name":"ClickUp workspace"}
```

Then POST `/connectors/credentials/:id/mcp/authorize`, open the returned `authorization_url` for the owner to consent and select Workspaces, and complete the shared MCP callback. The host must configure its callback URL and owner resolver as described above. ClickUp's advertised dynamic registration handles client registration; a preregistered client is optional. This does not use the separate ClickUp REST API OAuth configuration.

After authorization, GET `/connectors/credentials/:id/mcp/tools` and invoke a returned tool name through the shared call endpoint. The tool catalog and schemas come from the authorized server; the engine does not maintain a fixed ClickUp tool list. Permissions and remote rate limits remain controlled by ClickUp.

The named connector fixes the official endpoint to `https://mcp.clickup.com/mcp` and authentication to OAuth. API tokens, custom authentication headers and endpoint overrides are rejected, including values supplied by a managed-secret resolver. Owners can replace client registration, which clears previous authorization. Disconnect uses the shared local revocation behavior.

`GET /connectors/types/clickup` exposes `connector.mcp` metadata with endpoint, authentication mode, protocol version and grant-scoped URL templates. Replace `:id` with the created credential ID. `connector.redirect_uri` uses the same callback resolver as authorization. The generic MCP type exposes the same workflow metadata, with a user-configured endpoint and authentication mode.

**Evidence and validation (2026-09-22):** [ClickUp's official documentation](https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server) specifies the endpoint and OAuth-only authentication. Its live 401 challenge points to [protected-resource metadata](https://mcp.clickup.com/.well-known/oauth-protected-resource/mcp), advertising `read` and `write` scopes. Its [authorization-server metadata](https://mcp.clickup.com/.well-known/oauth-authorization-server) advertises S256 PKCE, dynamic registration, public-client token authentication and required callback issuer identification. It advertises `authorization_code` without `refresh_token`; registration requests respect that metadata. Endpoints and scopes are discovered at runtime, not copied into provider-specific OAuth code.

Request specs use captured public metadata and simulated registration/token/tool responses. The synthetic tool in those specs is explicitly a fixture. Live verification has covered public discovery and a demo owner completing consent with encrypted credential storage. Authenticated tool discovery/invocation against that Workspace has not been verified by the automated fixture suite.

## Discover, invoke and resume

Paths below are relative to the engine mount, normally `/connectors`.

| Method and path | Behavior |
| --- | --- |
| `GET /credentials/:id/mcp/tools` | Returns `{ "tools": [...] }` with complete native descriptors and schemas. Requires viewer access. |
| `POST /credentials/:id/mcp/tools/call` | Body: `{ "name": "tool_name", "arguments": {} }`. Requires editor access. Returns the MCP tool result. |
| `POST /credentials/:id/mcp/interactions/resume` | Body: `{ "interaction_id": "...", "responses": { ... } }`. Requires the initiating actor's editor access. |
| `POST /credentials/:id/mcp/authorize` | Owner-only. Returns `authorization_url`. Accepts an optional `authorization_context` from a failed MCP request. |
| `GET` or `POST /mcp/oauth/callback` | Accepts `state`, `code`, `iss` or an OAuth `error`; completes a one-time authorization transaction. |
| `POST /credentials/:id/revoke` | Owner-only local disconnect: marks the grant revoked and clears stored authentication fields. It does not claim to revoke tokens at the remote authorization server. |

Arguments are validated without coercion or dropping extra fields. JSON Schema 2020-12 and draft-07 are supported; external schema references are disabled. Output schemas are checked. Content blocks and structured results, including arrays/scalars/null, are preserved. `isError: true` is a completed tool result, distinct from HTTP or protocol failure.

The Ruby application entry points use the same access policy as HTTP:

```ruby
client = Connectors::MCP::Client.new(grant: grant, actor: current_owner)
client.tools
result = client.call_tool(name: "search", arguments: { "query" => "ruby" })
```

Pass trusted `principals:` when the host uses team/workspace sharing. Create a client for the operation; do not share a mutable client instance across worker threads. Use `Client` and `Authorization` as application entry points; transport and schema classes are implementation helpers.

A failed call can return HTTP 401 with `error.type: "authorization_required"` and an encrypted `authorization_context`. Pass that context to the owner-only authorize endpoint so it retains the **actual failed operation's** scope challenge. After consent, retry the intended operation explicitly. Unrelated 403s are not treated as scope upgrades. Ruby callers can catch `Connectors::MCP::AuthorizationRequired` and pass its `challenge` to `Authorization#start`.

No tool call is automatically replayed after a timeout or broken stream. Its remote outcome may be unknown. A recognized authentication failure can trigger one coordinated refresh and one retry. Protocol errors retain their numeric code in Ruby but never trigger an automatic legacy downgrade.

## OAuth registration and token handling

The engine follows protected-resource, OAuth authorization-server and OIDC discovery. It requires advertised S256 PKCE, binds client information to the selected issuer, validates callback issuer/state, and includes the MCP resource in authorization/token requests.

Registration preference is preregistration, advertised Client ID Metadata Documents (CIMD), then advertised Dynamic Client Registration (DCR). Otherwise the owner must provide client information. DCR is a compatibility mechanism, not assumed universally available.

To use CIMD, publish a public HTTPS JSON document with matching `client_id`, `client_name` and `redirect_uris`, then set `config.mcp.client_metadata_url`. The URL must identify that document. The engine validates it before use; it does not publish a document for your host automatically.

Token endpoint authentication supports `none`, `client_secret_basic`, `client_secret_post`, and host-signed `private_key_jwt`, subject to server metadata. For the last method, configure:

```ruby
config.mcp.assertion_provider = ->(client_id, token_endpoint) {
  # Return a short-lived JWT signed by the host's key manager with the required
  # issuer, subject, audience, expiry and replay protection for this registration.
  MyKeyManager.oauth_client_assertion(client_id: client_id, audience: token_endpoint)
}
```

The host owns signing-key management; the engine does not invent a signing key or JWT policy. Requested scopes are retained separately from token response scopes. `offline_access` is requested only when advertised. Refresh rotation is serialized across processes; transient failures preserve credentials, while `invalid_grant` requires reconnect. Grants expose token expiry through their existing `expires_at` field.

## Elicitation, subscriptions and cancellation

A host that implements the corresponding presentation can enable `config.mcp.elicitation_modes = ["form", "url"]`. The default is empty, and unadvertised modes are rejected.

An `input_required` result includes `interaction_id` and the server's input requests. The engine retains the original call and opaque state in encrypted storage. Present the request to the user, then resume with responses keyed by the server's input-request IDs. Form acceptance includes schema-valid `content`; URL acceptance, decline and cancel omit content. URL acceptance is consent to an external interaction, not proof that it completed. Never prefetch/open a URL automatically; show the requesting server and full URL, then open it only after user consent. Third-party credentials must stay outside this client.

Each resume is claimed once. A duplicate submission is rejected, not replayed. State-only continuations can be resumed with `{}`; hosts should back off rather than loop immediately. Limits bound rounds and expiry. This is not a guarantee of exactly-once execution at the remote server.

For on-demand tools-list notifications:

```ruby
cancellation = Connectors::MCP::Cancellation.new
client = Connectors::MCP::Client.new(grant: grant, actor: current_owner, cancellation: cancellation)
client.subscribe { |notification| handle_mcp_notification(notification) }
# Another thread can call cancellation.cancel to close an idle stream.
```

The stream validates acknowledgment, filter and correlation. It ends on cancellation, graceful completion, deadline, size limit or error. Hosts can start a fresh subscription after disconnection. The engine starts no background daemon and maintains no cross-request tool cache.

## Limits, maintenance and supported scope

Defaults: 5-second connection timeout, 30-second request/authorization deadline, 300-second subscription deadline, 4 MiB request/response limit, 100 pages, 1,000 tools, 10 interaction rounds, 15-minute pending-state expiry, and a 1-second schema-validation deadline. Settings are available on `config.mcp`; configure positive bounds appropriate for the host. Error messages and filtered Rails parameters avoid exposing authentication material and tool input bodies.

Upstream HTTP 429 responses return HTTP 429 with `error.type: "rate_limited"`. Valid `Retry-After` guidance is exposed in the response header and `error.retry_after` as a string containing seconds or an HTTP date; missing or malformed guidance is omitted. Tool calls are not automatically replayed. Other upstream HTTP failures remain sanitized 502 responses.

Schedule `bundle exec rake connectors:mcp:cleanup` through the host's existing scheduler to delete expired pending records. There is no additional scheduler dependency.

This release targets **2026-07-28 remote tools**. It does not advertise historical session-based transports, local stdio execution, prompts/resources product APIs, sampling, roots, Tasks, Apps, client-credentials grant extensions or enterprise authorization extensions. Those are separate protocol features, not implicit support claims. `private_key_jwt` client authentication above is supported for user OAuth; that does not imply support for the separate machine-to-machine grant extension.

## Validation

Validated on 2026-09-22 after packaging and documentation review: **543 examples, 0 failures** (random seed `17450`, frozen lockfile), **200 Ruby files with no RuboCop offenses**, and a strict gem build plus isolated installation/boot check. This includes the existing connector regression suite.

RSpec covers protocol/schema contracts, authentication/registration, access isolation, secret serialization, real PostgreSQL concurrency, durable resume, real chunked SSE and idle cancellation. Interoperability runs against:

1. The official Ruby SDK 1.6.0 server over real HTTP.
2. An independent Python stdlib fixture (`spec/support/mcp/oauth_server.py`, fixture version 1), covering public/bearer access and OAuth discovery, PKCE, callback completion in a separate Rails process, scope upgrade and refresh. Its test-only consent is automatic.

Run `bundle exec rspec --order random` and `bundle exec rubocop` after preparing an isolated PostgreSQL test database. Tests also need Python 3.9+ for the independent fixture. No production credentials or external account authorization is needed. These tests establish the documented integration behavior; they are not an official conformance certification or a claim that every hosted MCP provider has been tested.
