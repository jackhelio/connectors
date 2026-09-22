# Connectors Framework Reference

Developer reference for the `connectors` Rails engine. For installation and supported environments, start with the [README](README.md).

Current behavior is verified by the repository test suite. [Architecture](docs/architecture.md), [connector authoring](docs/adding-connectors.md) and [MCP support](MCP_CLIENT.md) describe action execution and remote tools.

---

## 1. Architecture

```
Host Rails application
   └─ mounts Connectors::Engine at <host-chosen prefix>   (e.g. /api/v1/connectors)
        ├─ Configuration block       (host wires owner / OAuth secrets / vault)
        ├─ Registry                  (loaded at boot from app/connectors/*/)
        ├─ Models
        │    ├─ Grant                (one row = one authorized account)
        │    ├─ CredentialShare      (per-grant sharing with roles)
        │    └─ WebhookEvent         (inbound webhook persistence)
        ├─ Controllers
        │    ├─ TypesController        GET /types[/:name]
        │    ├─ CredentialsController  GET/POST/PATCH/DELETE /credentials[/:id][/share|transfer]
        │    ├─ GrantsController       /grants[/:id]/{test,webhook_subscribe,poll}
        │    ├─ OAuthController        /:key/{authorize,callback}  +  /credentials/:id/revoke
        │    └─ WebhooksController     POST /:key[/:grant_id][/webhook[/:name]]
        ├─ Per-connector classes      (user code in app/connectors/<key>/connector.rb)
        └─ Faraday middleware stack   (auth injection, refresh, rate-limit, error normalization)
```

**Host independence.** The engine never references host constants (`User`, `Team`, ...) directly — it goes through `Connectors.configuration` callables. The host owns the identity model (the `Owner`); the engine owns the credential model.

**Mount-path independence.** The host picks where to mount the engine in `config/routes.rb`. The engine introspects the actual mount path at boot (`Connectors::Engine.mount_path`) and every URL builder (OAuth callback, default webhook URL, types-endpoint `redirect_uri` field) is wired through it. No `mount_path` configuration in initializers, no string concatenation traps — the host's routes file is the single source of truth. See §1.1 below.

**Credential templates.** `Connectors::AuthInjection` substitutes `{{$credentials.<field>}}` lookups in authentication properties. It does not evaluate general expressions or workflow logic.

### 1.1 Mount-path introspection

```ruby
# host: config/routes.rb
Rails.application.routes.draw do
  namespace :api do
    scope "v1" do
      mount Connectors::Engine => "/connectors"
    end
  end
end

# engine: lazily reads from Rails.application.routes at first call
Connectors::Engine.mount_path  # => "/api/v1/connectors"
```

The engine walks the host's compiled route table (peeling any `Constraints` wrappers Rails inserts around mounted engines) and caches the result. Reset for spec remounts via `Connectors::Engine.reset_mount_path!`.

Concrete consequences:

| What | Without `mount_path` | With `mount_path` |
|---|---|---|
| OAuth `redirect_uri` sent to the provider | hardcoded `<host>/connectors/<key>/callback` | `<host>/api/v1/connectors/<key>/callback` automatically |
| Default `hook_url` for `POST /grants/:id/webhook_subscribe` | hardcoded `<host>/connectors/...` | matches the mount, whatever it is |
| `GET /types/:name` `connector.redirect_uri` / `authorize_url` / `authorize_json_url` | hardcoded | matches the mount |

For example, a mount under `/api/v2/connectors` produces callbacks and webhook URLs under that prefix.

---

## 2. Quick Start

Resend is already shipped; do not redefine it to get started. Follow the [installation and first-connection guide](README.md#installation), then use [Adding a connector](docs/adding-connectors.md) for a new provider. The engine loads host connector classes from `app/connectors/<key>/connector.rb`.

The host must configure PostgreSQL, UUID owner models, Rails encryption, authenticated owner resolution and the engine mount. See the README for concrete configuration. `GET <mount>/types` lists registered connectors; `POST <mount>/credentials` creates a credential; `POST <mount>/grants/:id/test` performs its declared connection test.

---

## 3. Connector DSL Reference

`Connectors::Connector` — subclass it. Every DSL below is a class-level method.

### 3.1 `connector key:, auth:, base_url:, **opts`

Registers the connector. **Required** — every connector class calls this first.

| Arg | Type | Meaning |
|---|---|---|
| `key:` | symbol | machine identifier, unique per app (`:slack`) |
| `auth:` | symbol | auth scheme name (`:api_key`, `:oauth2`). A declared `authenticate` block takes precedence for request injection (§3.3). |
| `base_url:` | string | every `client.get`/`post`/etc. is relative to this |
| `display_name:` | string | UI label (defaults to `key.humanize`) |
| `icon:` | string | URL or asset path |
| `icon_color:` | string | hex |
| `documentation_url:` | string | external docs link |

### 3.2 `credentials do ... end`

Declares the credential form. Inner block uses `field` (see §4).

### 3.3 `authenticate type: :generic, properties: { ... }`

Declarative authentication injection into outgoing requests. `properties` accepts any subset of:

```ruby
authenticate type: :generic, properties: {
  headers: { "Authorization" => "=Bearer {{$credentials.token}}" },
  qs:      { "api_key"      => "={{$credentials.api_key}}"      },
  body:    { "auth_token"   => "={{$credentials.token}}"        },
  auth:    { username: "={{$credentials.user}}",
             password: "={{$credentials.password}}" }   # HTTP Basic shortcut
}
```

Strings starting with `=` are templates; `{{$credentials.<field>}}` substitutes at request time. Strings without `=` are passed verbatim. Both keys AND values can be templates (HttpHeaderAuth's user-named-header case).

### 3.4 `pre_authentication do |credentials, helpers| ... end`

Runs before each request when the grant's `expires_at` is missing or in the past. The block's return value is merged into the grant's credentials before `authenticate` runs.

```ruby
pre_authentication do |credentials, helpers|
  resp = helpers.http_request(
    method: :post,
    url:    "#{credentials['url']}/oauth2/token",
    body:   { client_id: credentials["client_id"], client_secret: credentials["client_secret"] },
    headers: { "Content-Type" => "application/x-www-form-urlencoded" }
  )
  { "session_token" => resp["access_token"],
    "expires_at"    => Time.now.to_i + resp["expires_in"].to_i }
end
```

Helpers raise `Connectors::ApiError` on non-2xx — the middleware wraps any hook failure as `Connectors::AuthenticationFailed`.

### 3.5 `oauth2 ...`

```ruby
oauth2 authorize_url:  "https://slack.com/oauth/v2/authorize",
       token_url:      "https://slack.com/api/oauth.v2.access",
       scope:          "chat:write,channels:read",
       extra_authorize_params: { user_scope: "..." },
       grant_type:     "authorizationCode",    # or "clientCredentials" / "pkce"
       authentication: "header"                # or "body"
```

`grant_type` selects the runtime flow:
- `authorizationCode` (default) — standard redirect.
- `clientCredentials` — server-to-server (no `authorize_url` required).
- `pkce` — RFC 7636 S256.

`authentication` controls code exchange, refresh, and client-credentials requests: `header` = HTTP Basic, `body` = form parameters. Public PKCE clients send only their client ID and verifier. `token_expired_status: 401` defaults to 401; providers may explicitly declare another 4xx expiry status. A default 403 raises `Connectors::Forbidden` without refreshing.

### 3.6 `oauth1 ...`

```ruby
oauth1 request_token_url: "https://api.twitter.com/oauth/request_token",
       authorize_url:     "https://api.twitter.com/oauth/authorize",
       access_token_url:  "https://api.twitter.com/oauth/access_token",
       signature_method:  "HMAC-SHA1"   # or HMAC-SHA256 / HMAC-SHA512
```

The engine signs request-token and access-token exchanges. Consumer key/secret come from `Connectors.configuration.oauth_credentials_for(connector_key)` — same slot as OAuth2's client id/secret.

### 3.7 `revoke_token_url "..."` / `revoke_token { |grant| ... }`

```ruby
revoke_token_url "https://slack.com/api/auth.revoke"

# OR — for providers with a non-RFC-7009 shape:
revoke_token do |grant|
  Faraday.get("https://oauth2.googleapis.com/revoke",
              { token: grant.credentials_hash["access_token"] })
end
```

`POST <mount>/credentials/:id/revoke` calls this and flips the grant to `status: :revoked`.

### 3.8 `test_request method:, url:, headers:, query:, expect_status:, rules:`

Connection test performed through the connector client, using its authentication and middleware.

```ruby
test_request method: :get, url: "auth.test",
             rules: [
               { type: :response_success_body, key: "ok", value: false,
                 message: "Slack token is invalid" }
             ]
```

Rule types: `:response_code`, `:response_success_body`.

### 3.9 `rate_limit count, per: <interval>`

```ruby
rate_limit 5, per: 1.second
```

Wraps outbound calls in a token bucket via the rate-limit middleware.

### 3.10 `verify_webhooks_with VerifierClass`

Attach a `Connectors::Webhooks::Verifier` subclass to validate inbound signatures. When unset, the controller accepts any caller — useful in dev, dangerous in prod.

### 3.11 `webhook_challenge` / `resolve_grant_from_webhook` / `external_account_id_from_credentials`

Override in subclass:

```ruby
# URL-verification ping (Slack)
def self.webhook_challenge(payload)
  return nil unless payload["type"] == "url_verification"
  { challenge: payload["challenge"] }
end

# App-level webhook → grant lookup by payload team_id
def self.resolve_grant_from_webhook(payload, request)
  team_id = payload.dig("team_id") || payload.dig("team", "id")
  Connectors::Grant.where(connector_key: connector_key).find_by(external_account_id: team_id)
end

def self.external_account_id_from_credentials(creds)
  creds["team_id"]
end
```

The controller calls `webhook_style` to know whether to expect `:app_level` (single URL, payload-routed) or `:per_grant` (grant id in URL).

### 3.12 `webhook_methods(:group) do ... end`

Subscription lifecycle with `check_exists`, `create` and `delete` callbacks.

```ruby
webhook_methods do                       # group :default (implicit)
  check_exists do |grant, hook_url, static_data|
    body = grant.connector.client.get("hooks").body
    found = body["Webhooks"].find { |h| h["Url"] == hook_url }
    static_data["webhook_id"] = found["ID"] if found
    !found.nil?
  end

  create do |grant, hook_url, static_data|
    resp = grant.connector.client.post("hooks", { url: hook_url }.to_json).body
    if resp["ID"]
      static_data["webhook_id"] = resp["ID"]
      true
    else
      false
    end
  end

  delete do |grant, static_data|
    id = static_data["webhook_id"]
    next true if id.nil?
    grant.connector.client.delete("hooks/#{id}")
    static_data.delete("webhook_id")
    true
  end
end
```

Multi-webhook providers (Slack `setup` + `default`) declare additional named groups:

```ruby
webhook_methods(:setup)   do ... end
webhook_methods(:default) do ... end
```

State persists in `grant.static_data["<group_name>"]` — a per-grant jsonb hash.

### 3.13 `polling do |grant, static_data| ... end`

```ruby
polling do |grant, static_data|
  since = static_data["last_id"]
  items = grant.connector.client.get("messages", { since: since }.compact).body["items"]
  static_data["last_id"] = items.first["id"] if items.any?
  items
end
```

Manual fire: `POST <mount>/grants/:id/poll` with optional `instance_key`. Returns `{items: [...], static_data: {...}}`. Supply a stable consumer key for independent cursor and filter state in `Connectors::PollState#data`. Omitting the key retains `grant.static_data["polling"]`.

### 3.14 `generic_auth!`, `supported_nodes :...`, `http_request_node ...`

Credential visibility and HTTP-request picker metadata:

```ruby
generic_auth!                                            # eligible for the HTTP-Request node picker
supported_nodes :slack_send_message, :slack_get_channel  # restrict to specific node types
http_request_node name: "Slack API",
                  docs_url: "https://api.slack.com/",
                  api_base_url: "https://slack.com/api/"
```

Runtime check via `Connectors::PermissionCheck.permit!(grant, node_type:)`. Defaults: `supported_nodes` empty = "no restriction".

### 3.15 `skip_managed_creation!`

Disables managed-credential (external secrets) creation for this type. The editor hides the toggle; `POST /credentials` with `is_managed: true` against this type returns 401.

### 3.16 `post_token_exchange(_raw, normalized)`

Override in subclass to merge service-specific fields (Slack `team_id`, GitHub `installation_id`) into the credentials hash after OAuth token exchange:

```ruby
def self.post_token_exchange(raw, normalized)
  normalized.merge(
    "team_id"   => raw.dig("team", "id"),
    "team_name" => raw.dig("team", "name")
  )
end
```

### 3.17 Instance methods to override

```ruby
def refresh!; end                # called by AutoRefresh middleware on 401
def poll; end                    # called by PollJob; PollRunner uses the separate polling DSL
def handle_webhook(ctx); end     # called by DeliverWebhookJob; ctx = WebhookContext
def validate_credentials!; end   # auto: runs CredentialSchema.validate! against grant
```

---

## 4. CredentialSchema Field Reference

`Connectors::CredentialSchema::Field` describes an input and its rendering metadata:

```ruby
field :api_key,
      type:               "string",         # string|number|boolean|options|multiOptions|json|hidden|notice
      display_name:       "API Key",        # editor label
      default:            "",
      placeholder:        "re_...",
      description:        "...",
      hint:               "...",
      required:           true,
      no_data_expression: false,
      secret:             true,             # convenience for type_options[:password] = true
      type_options:       { password: true, expirable: true, redactJsonLeaves: true, resolvable_field: true },
      display_options:    { show: { grant_type: %w[authorizationCode pkce] } },
      options:            [{ name: "Header", value: "header" }]
```

`type_options` flags are serialized as form metadata for host renderers:

- `password: true` — suggests a masked input; also set by `secret: true`
- `expirable: true` — indicates a value that may rotate
- `redactJsonLeaves: true` — suggests masking JSON leaf values
- `resolvable_field: true` — indicates a host-resolvable input

These flags do not implement token rotation, log filtering or expression evaluation. Credential response access is enforced separately by the sharing policy; owner responses can include decrypted secrets.

Inheritance via `extends`:

```ruby
credentials do
  extends :oauth2                              # inherit OAuth2 base fields
  field :authorization_url, type: "hidden",    # lock provider endpoint
        default: "https://slack.com/oauth/v2/authorize"
end
```

Children override parents by redeclaring with the same field name. Most-specific wins.

### Schema-level DSL

Inside `credentials do ... end`:

- `extends :name` — inherit fields + injection from a registered base type
- `authenticate type: :generic, properties: {...}` — schema-level injection (inherited by every connector that `extends` this schema)
- `generic_auth!` — mark eligible for HTTP-Request node
- `display_name "Bearer Auth"` — UI label for the credential type itself
- `documentation_url "https://provider.example/docs/auth"` — documentation link

---

## 5. Configuration Reference

```ruby
Connectors.configure do |c|
  # ---- Identity (required) ------------------------------------------------
  c.owner_class_name       = "User"
  c.current_owner_resolver = ->(ctrl) { ctrl.request.env["connectors.current_owner"] }

  # ---- OAuth secrets (per connector) -------------------------------------
  c.host_base_url     = ENV["APP_BASE_URL"]   # the *scheme + host*; the engine adds its mount path automatically
  c.oauth_credentials = {
    slack:  { client_id: ENV["SLACK_CLIENT_ID"],  client_secret: ENV["SLACK_CLIENT_SECRET"] },
    twitter: { client_id: ENV["TW_CONSUMER_KEY"], client_secret: ENV["TW_CONSUMER_SECRET"] }
  }

  # ---- Optional: webhook dispatch hook -----------------------------------
  c.on_webhook = ->(event) { ProcessWebhookJob.perform_later(event.id) }

  # ---- Optional: sharing principals (host middleware supplies trusted owner) ----------------------------
  c.principal_resolver = ->(ctrl) {
    owner = ctrl.request.env["connectors.current_owner"]
    owner ? [[owner.class.name, owner.id]] : []
  }

  # ---- Optional: external secrets manager ---------------------
  c.secrets_resolver           = ->(grant) { vault.read(grant.external_ref) }
  c.secrets_managed_fields_for = ->(key)   { { slack: %w[client_secret] }.fetch(key.to_sym, []) }
end
```

The Rack owner entry in this example must be populated by trusted host authentication middleware; engine controllers do not inherit host controller callbacks. Slack/Twitter configuration here illustrates custom OAuth connectors, not shipped profiles.

`ProcessWebhookJob` and `vault` are examples supplied by the host.

All callables are invoked with `Connectors.configuration.<name>.call(...)` — the engine never invokes host constants directly.

---

## 6. Built-in Base Credential Types

Registered on engine boot in `Connectors::CredentialTypeRegistry`. Connectors `extends` any of these.

| Key | Support |
|---|---|
| `:oauth2` | Authorization code, client credentials and PKCE flows. JWE fields are form metadata only; no JWE decryption. |
| `:oauth1_api` | HMAC-SHA1, HMAC-SHA256 and HMAC-SHA512 signing. |
| `:http_basic_auth` | Basic authentication through the `auth:` shortcut. |
| `:http_bearer_auth` | Authorization bearer token. |
| `:http_header_auth` | Credential-defined header name and value. |
| `:http_query_auth` | Credential-defined query parameter name and value. |
| `:http_digest_auth` | Form schema only; no digest challenge handling. |
| `:http_custom_auth` | Form schema only; no runtime injection of custom JSON. |

---

## 7. Models

### `Connectors::Grant` (table `connectors_grants`)

One row = one authorized account. Columns:

| Column | Type | Notes |
|---|---|---|
| `owner_type`, `owner_id` | polymorphic | host's identity type (User, Team, ...) |
| `connector_key` | string | foreign key to the in-memory `Registry` |
| `display_name` | string | UI label |
| `credentials` | text | **encrypted at rest** via ActiveRecord::Encryption |
| `status` | enum | `active` / `expired` / `revoked` / `errored` |
| `expires_at`, `last_used_at` | datetime | |
| `external_account_id` | string | denormalized provider-side id for webhook routing |
| `static_data` | jsonb | per-group scratch (webhook + polling cursor state) |
| `external_ref`, `is_managed` | string + bool | external secrets manager |

Methods:

```ruby
grant.connector              # → Connector instance (Registry.fetch + .new(self))
grant.credentials_hash       # decrypted, vault-resolved if is_managed?
grant.stored_credentials_hash # raw DB view (no vault lookup)
grant.update_credentials!(patch)   # atomic merge + invalidate vault cache
grant.update_static_data!(group) { |sub| ... }   # atomic per-group mutation
grant.static_data_hash       # whole static_data jsonb
```

### `Connectors::CredentialShare` (table `connectors_credential_shares`)

```ruby
CredentialShare.new(grant:, principal_type:, principal_id:, role:)
# role: "viewer" | "editor" | "owner"
```

Unique on `(grant_id, principal_type, principal_id)`. `grant.shares dependent: :destroy`. Scope `for_principals([[type, id], ...])` drives the visibility query.

### `Connectors::WebhookEvent` (table `connectors_webhook_events`)

One row per inbound webhook. Idempotency via unique `(connector_key, external_event_id)`. Columns:

| Column | Type | Notes |
|---|---|---|
| `grant_id` | uuid | foreign key |
| `connector_key` | string | denormalized for fast scoping |
| `external_event_id` | string | `payload["event_id"]\|"id"\|event.id` — drives idempotency |
| `payload` | jsonb | parsed body |
| `raw_body` | text | untouched body string |
| `headers` | jsonb | lowercased dashed keys (`stripe-signature`) |
| `query` | jsonb | query string params |
| `webhook_name` | string | `default` / `setup` / etc. |
| `signature` | text | pre-extracted provider signature header |
| `status` | enum | `received` / `processed` / `failed` / `ignored` |
| `error_message` | text | failure detail (1KB cap) |
| `received_at`, `processed_at` | datetime | |

---

## 8. Endpoints

The host chooses the mount path. Every URL below is relative to the mount — the engine introspects it via `Connectors::Engine.mount_path` so the same routes table works under any prefix. All responses are JSON unless noted.

### 8.1 Catalog

| Method | Path | Purpose |
|---|---|---|
| GET | `/types` | list every registered connector |
| GET | `/types/:name` | full credential type description — fields, authenticate, generic_auth, supported_nodes, http_request_node, __overwritten_properties, __skip_managed_creation, connector capabilities |

### 8.2 Credentials CRUD

| Method | Path | Notes |
|---|---|---|
| GET | `/credentials[?type=&include_data=]` | owner-owned + shared-with-me; `include_data=true` returns decrypted data only to the owner role; MCP returns public configuration |
| GET | `/credentials/for-workflow` | same visibility, for the workflow editor's picker |
| GET | `/credentials/new?type=X` | server-generated unique default name (`"Resend account 3"`) |
| GET | `/credentials/:id` | single, viewer-or-better access |
| POST | `/credentials` | body: `{type, name?, data?, external_ref?, is_managed?}` |
| PATCH | `/credentials/:id` | body: `{name?, data?}` — editor-or-owner; replacing MCP authentication requires owner |
| DELETE | `/credentials/:id` | owner only |
| POST | `/credentials/test` | unsaved-credential test — body: `{type, data}` |
| POST | `/credentials/:id/revoke` | provider-declared REST revocation or MCP local disconnect; flips status to `:revoked` |
| PUT | `/credentials/:id/share` | body: `{principal_type, principal_id, role}` — owner only, idempotent |
| DELETE | `/credentials/:id/share` | body: `{principal_type, principal_id}` |
| PUT | `/credentials/:id/transfer` | body: `{owner_id}` — moves ownership |

### 8.3 Grants (manual harness)

| Method | Path | Notes |
|---|---|---|
| GET | `/grants[?connector_key=]` | @deprecated alias for credentials index |
| POST | `/grants/:id/test` | declarative `test_request` against live provider |
| POST | `/grants/:id/webhook_subscribe` | body: `{webhook_name?, hook_url?}` — runs check_exists + create |
| DELETE | `/grants/:id/webhook_subscribe` | runs delete; strips static_data |
| POST | `/grants/:id/poll` | runs the polling block once; returns `{items, static_data}` |

### 8.4 OAuth

| Method | Path | Notes |
|---|---|---|
| GET | `/:key/authorize` | 302 to provider authorize URL (or runs clientCredentials in-place) |
| GET | `/:key/authorize.json` | same as above but returns `{authorize_url}` JSON for popup-based flows |
| GET | `/:key/callback?code=&state=` | OAuth2 callback (also handles `oauth_token=&oauth_verifier=&state=` for OAuth1) |

### 8.5 Webhooks (inbound)

| Method | Path | Notes |
|---|---|---|
| POST | `/:key/webhook` | app-level (grant resolved from payload) |
| POST | `/:key/webhook/:webhook_name` | app-level, named group |
| POST | `/:key/:grant_id/webhook` | per-grant |
| POST | `/:key/:grant_id/webhook/:webhook_name` | per-grant, named group |

All persist a `WebhookEvent` and enqueue `DeliverWebhookJob` → calls `Connector#handle_webhook(ctx)` with a `WebhookContext`.

---

## 9. `WebhookContext`

Passed to `Connector#handle_webhook` with the captured request data and persisted event.

```ruby
def handle_webhook(ctx)
  ctx.body              # parsed JSON (Hash; also: ctx.payload_hash for back-compat)
  ctx.raw_body          # untouched request body string
  ctx.headers           # all headers, lowercased+dashed: "stripe-signature"
  ctx.query             # query string params
  ctx.webhook_name      # :default / :setup / ...
  ctx.signature         # pre-extracted provider signature header
  ctx.grant             # = ctx.event.grant
  ctx.event             # the persisted WebhookEvent row
end
```

---

## 10. Middleware Stack

`Connectors::ClientBuilder.build` assembles this Faraday stack for every connector's `client`:

Declared outermost to innermost:

```
   1. JSON request encoder
   2. RateLimit
   3. AutoRefresh
   4. ErrorNormalization
   5. Retry (502/503/504, at most two retries, idempotent methods)
   6. JSON response parser
   7. GrantStatus (revocation check on every attempt)
   8. PreAuthentication (when declared)
   9. AuthenticateGeneric or Auth::Scheme
  10. HTTP adapter
```

Error normalization runs after HTTP retry exhaustion, with the parsed response body. Automatic transient-response retries exclude POST. AutoRefresh coordinates through a grant row lock, rechecks the credentials that failed, and retries once with the original request body. PreAuthentication rechecks expiry under the same lock. RateLimit is a no-op without a configured quota.

---

## 11. OAuth Flows (detail)

Authorization without `grant_id` creates a new connection. Both authorize endpoints accept `grant_id` to reconnect an owned connection for that provider. Completion checks the connection snapshot again under a row lock and rejects changed credentials, ownership, status, or a different known account. Providers without an extracted account ID cannot enforce account matching. Revocation requires the owner role and shares the grant lock with refresh/reconnection.

State is authenticated, encrypted, and valid for 15 minutes. Existing signed state must be restarted on upgrade. State is stateless, so encryption does not enforce one-time use.

### authorizationCode (default)

```
1. GET /:key/authorize          → 302 to provider with `code_challenge` if pkce
2. user grants consent
3. provider → GET /:key/callback?code=&state=
4. State validated → POST <token_url> with code (+ code_verifier if pkce)
5. post_token_exchange hook merges provider-specific fields
6. Grant created (or explicit grant_id reconnected); status=:active
```

### clientCredentials

```
1. GET /:key/authorize          → POST <token_url> with grant_type=client_credentials
2. Grant created or explicitly reconnected in same request; no user redirect
```

`authentication: "header"` (default) sends client_id/secret as HTTP Basic; `"body"` sends them in the form.

### PKCE (S256)

Same as authorizationCode, but step 1 adds `code_challenge=<base64url(sha256(verifier))>` + `code_challenge_method=S256`. Verifier is stored in the encrypted state token (`state["x"]["cv"]`) and sent on the token exchange.

### OAuth1.0a

```
1. GET /:key/authorize          → POST <request_token_url> (OAuth1-signed)
                                → 302 to <authorize_url>?oauth_token=&state=
                                  (request-token secret stashed in state["x"]["ts"])
2. user grants consent
3. provider → GET /:key/callback?oauth_token=&oauth_verifier=&state=
4. POST <access_token_url> (OAuth1-signed with consumer + request-token secrets)
5. Grant created or explicitly reconnected with {oauth_token, oauth_token_secret, signature_method}
```

### Revoke

```
POST /credentials/:id/revoke    → revoke_token block OR RFC 7009 POST to revoke_token_url
                                → grant.status = :revoked
```

---

## 12. Webhook Subscription Lifecycle

```
POST /grants/:id/webhook_subscribe   (optional: webhook_name, hook_url)
   ↓
WebhookLifecycle.subscribe
   ├─ check_exists.call(grant, hook_url, static_data)   → true → status: "exists"
   └─ create.call(grant, hook_url, static_data)         → true → status: "created"
                                                           → false → raise Error

DELETE /grants/:id/webhook_subscribe
   ↓
WebhookLifecycle.unsubscribe
   └─ delete.call(grant, static_data)                   → true → status: "deleted"
```

Default `hook_url` is computed from `host_base_url` + `connector_key` + grant_id (per-grant) or omitted (app-level), based on `connector_class.webhook_style`.

---

## 13. Polling

```
POST /grants/:id/poll
   ↓
PollRunner.run
   └─ polling_block.call(grant, static_data["polling"])
       → items returned; static_data persisted in same UPDATE
```

The diagram shows the legacy call without an instance key. For independent consumers, call `PollRunner.run(grant, instance_key: trigger_id)` or send `instance_key` to the endpoint. The key must be a nonempty string; malformed keys return 400. Each `(grant_id, instance_key)` stores its cursor and optional filters in `Connectors::PollState#data`, protected by a unique database index and row lock. Failure rolls back cursor changes. Host scheduling and downstream delivery remain host responsibilities.

---

## 14. Sharing

Role hierarchy: `viewer (0) < editor (1) < owner (2)`. HTTP credential access uses `GrantAccess#find_visible_grant!(id, min_role:)` and `GrantPolicy`; MCP services enforce the same roles through `MCP::Access`. Direct REST Ruby callers must authorize their selected grant.

```
visible_grants = (owner == requester) ∪ (shares.for_principals(resolver.call(ctrl)))
```

Index returns the union. Show/update/destroy escalate the minimum role required. Decrypted regular credentials are returned only to the owner role; shared viewers/editors receive metadata. MCP returns public configuration only. Transfer reassigns `owner_id`; existing shares stay intact (host can prune via unshare).

---

## 15. External Secrets

```
grant.is_managed? + grant.external_ref
   ↓
credentials_hash = stored_credentials.merge(secrets_resolver.call(grant))
                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                      vault values win; cached per-instance
```

`AuthenticateGeneric` middleware reads `credentials_hash` per request, so a managed grant automatically gets vault-resolved values injected into outbound HTTP. No extra wiring.

`secrets_managed_fields_for(connector_key)` surfaces on `GET /types/:name` as `__overwritten_properties` so the editor can render the vault-sourced fields locked.

---

## 16. Errors

| Class | Status | Raised by |
|---|---|---|
| `Connectors::Error` | 401 (CredentialsController) | base |
| `Connectors::UnknownConnector` | 404 | `Registry.fetch` |
| `Connectors::UnknownAuthScheme` | 401 | `Auth::Scheme.lookup` |
| `Connectors::MissingCredentialFields` | 401 | `CredentialSchema#validate!` |
| `Connectors::ApiError` | 502 in ActionsController; upstream status in error details | ErrorNormalization middleware |
| `Connectors::AuthenticationFailed < ApiError` | 401 | OAuth flows + AutoRefresh |
| `Connectors::Forbidden < ApiError` | 403 | Provider permission denial |
| `Connectors::RateLimited < ApiError` | 429 | RateLimit middleware |
| `Connectors::CredentialNotPermitted` | — (caller chooses) | `PermissionCheck.permit!` |
| `Connectors::Webhooks::SignatureInvalid` | 401 (WebhooksController) | per-connector verifier |

---

## 17. Testing a Connector

```ruby
RSpec.describe MyConnector do
  let(:owner) { Owner.create!(name: "test") }
  let(:grant) do
    Connectors::Grant.create!(owner: owner, connector_key: "my",
                               credentials: { "api_key" => "test" })
  end

  it "sends the API key" do
    stub_request(:get, "https://api.my.test/me")
      .with(headers: { "Authorization" => "Bearer test" })
      .to_return(status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

    expect(grant.connector.client.get("me").body).to eq("ok" => true)
  end
end
```

Patterns used throughout `spec/connectors/`:
- **Anonymous classes** for per-spec test connectors → registry isolation in the RSpec setup
- **`WebMock`** for outbound HTTP
- **`stub_request(...)` with `.with(headers: ...)`** verifies the auth-injecting middleware did its job
- **`Connectors::OAuth::State.decode(token)`** to peek inside the encrypted state for round-trip testing

---

## 18. Further Reading

- [Installation and host setup](README.md)
- [Architecture and execution boundaries](docs/architecture.md)
- [Adding a connector](docs/adding-connectors.md)
- [Remote MCP connections](MCP_CLIENT.md)
- [HTTP API contract](openapi.yaml)
- [Development and testing](CONTRIBUTING.md)
