# Connectors

A mountable Rails engine for connecting accounts to provider APIs and remote MCP servers. It owns credential storage, authentication with providers, action execution, webhooks and polling. Your application owns user authentication, business workflows and scheduling.

**Status:** initial release series `0.1.x`. Check [RubyGems](https://rubygems.org/gems/connectors) for published versions. Package validation is separate from production acceptance for a particular host and provider.

## Requirements

| Component | Requirement | Validation baseline |
| --- | --- | --- |
| Ruby | 3.2 or later | Ruby 3.4.8 locally and in the CI configuration |
| Rails | 8.1.3 or later in the 8.1 series | Rails 8.1.3 |
| Database | PostgreSQL 13+; migrations use UUIDs, JSONB and partial indexes | CI targets PostgreSQL 16 |
| Identity | Persisted owner model with UUID primary keys; sharing principals also use UUIDs | Dummy `Owner` model in tests |
| Encryption | Host-configured Active Record Encryption keys and stable Rails `secret_key_base` | Synthetic keys in tests |

The declared Ruby minimum matches Rails' requirement; it is not a claim that every Ruby/OS combination has been tested. SQLite, MySQL and integer owner IDs are not supported by the shipped migrations. Install the host's PostgreSQL adapter (`pg`) in its Gemfile.

## Installation

For a published release, add to your host's Gemfile:

```ruby
gem "connectors", "~> 0.1.0"
gem "pg"
```

Then run `bundle install`. To test unreleased changes, use `gem "connectors", git: "https://github.com/jackhelio/connectors.git", ref: "<reviewed-commit-sha>"` instead, replacing the ref with an actual reviewed commit. Local development can use `gem "connectors", path: "../connectors"`. See [release checks](docs/releasing.md).

Mount the engine in `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Connectors::Engine => "/connectors"
end
```

Configure encryption before saving credentials:

```sh
bin/rails db:encryption:init
bin/rails credentials:edit
```

Store the generated `active_record_encryption` entries in the target environment's Rails credentials, or configure the equivalent Rails settings from your secret store. Keep the keys stable across restarts and all application/worker instances; retain them when restoring encrypted data. See the [Rails encryption setup](https://guides.rubyonrails.org/active_record_encryption.html#setup).

Configure the host identity boundary in `config/initializers/connectors.rb`:

```ruby
Connectors.configure do |config|
  config.owner_class_name = "User" # an existing model with UUID IDs
  config.host_base_url = ENV.fetch("APP_BASE_URL")
  config.current_owner_resolver = lambda do |controller|
    controller.request.env["connectors.current_owner"]
  end
end
```

Here, `connectors.current_owner` is a Rack environment entry that **your authenticated host middleware must populate** with the owner record. It is an integration example, not a built-in authentication mechanism. You can instead resolve through your existing trusted authentication middleware; for example, a Warden host can read `controller.request.env["warden"]&.user`. Never derive the trusted owner directly from a caller-supplied ID. Engine controllers inherit `ActionController::API`, so host `ApplicationController` methods and authentication callbacks are not inherited automatically.

Run the host migrations:

```sh
bin/rails db:migrate
```

The engine appends its migration directory; copying migrations is unnecessary. Owners must exist before creating grants. If building a new owner table, use `create_table :users, id: :uuid`; an existing integer-ID table requires a host schema decision before integration.

## First connection

The installed gem ships these connector profiles:

| Key | Connection |
| --- | --- |
| `resend` | Resend REST API, API key |
| `gmail` | Gmail REST API, user OAuth2 |
| `mcp` | Configurable remote MCP server |
| `clickup` | ClickUp's official OAuth-only MCP server |

Slack, GitHub and Echo under `test/dummy` are test fixtures, not shipped connectors. Inspect `GET /connectors/types` for the installed catalog and each connector's credential fields and actions.

In a Rails console, create a Resend connection for an existing owner:

```ruby
owner = User.find(ENV.fetch("CONNECTOR_OWNER_ID"))
grant = Connectors::Grant.create!(
  owner: owner,
  connector_key: "resend",
  display_name: "Transactional email",
  credentials: { "api_key" => ENV.fetch("RESEND_API_KEY") }
)
Connectors::CredentialTester.run(grant)
```

The connection test calls Resend's domains endpoint. It requires a key that can list domains; a sending-only key can still send email but will fail this read test.

For an authenticated HTTP client, the equivalent creation request is:

```http
POST /connectors/credentials
Content-Type: application/json

{"type":"resend","name":"Transactional email","data":{"api_key":"YOUR_API_KEY"}}
```

Use the returned `id` for `GET /connectors/credentials/:id/actions` to discover actions. Calling an action executes a real provider operation:

```http
POST /connectors/credentials/:id/actions/send_email
Content-Type: application/json

{"data":{"from":"sender@your-verified-domain.example","to":"recipient@example.com","subject":"Hello","text":"Hello from Connectors"}}
```

The backend validates required action parameters, attaches credentials, calls the provider and returns `{ "status": "ok", "action": "send_email", "data": ... }` or a typed error. REST action validation checks required values and filters undeclared inputs; it is not general JSON Schema validation. Direct Ruby callers use `Connectors::ActionRunner.call(grant, :send_email, input)` and must select an authorized grant themselves; HTTP endpoints enforce sharing roles.

For Gmail, configure `config.oauth_credentials = { gmail: { client_id: ..., client_secret: ... } }` from your secret store and register the callback shown by the connector catalog with Google. The default callback is `<APP_BASE_URL>/connectors/gmail/callback`. Start with `GET /connectors/gmail/authorize.json`, open `authorize_url`, and complete consent. Without `grant_id`, authorization creates a new connection; passing it explicitly reconnects an owned connection.

For ClickUp, create `{"type":"clickup","name":"ClickUp workspace"}`, then use the shared MCP authorization and tool endpoints. [The MCP guide](MCP_CLIENT.md#clickup) covers consent, discovery, invocation and supported protocol features. Applications do not implement ClickUp's provider transport or authentication. REST actions and MCP tools currently have distinct API endpoints.

## Operating the engine

- Configure a durable Active Job backend and run its workers for webhook delivery. The gem supplies jobs, not a queue service.
- Schedule polling with `Connectors::PollRunner.run(grant, instance_key: trigger_id)` for each independent consumer. The host supplies the stable key and handles downstream delivery.
- Configure a shared `Rails.cache` if using connector quotas across workers. The dummy application's null cache is for tests.
- Schedule `bundle exec rake connectors:mcp:cleanup` to remove expired authorization and interaction records. The engine does not start a scheduler.
- Shared viewers can inspect metadata; editors can execute actions. Only the owner role can retrieve regular decrypted credential `data` with `include_data=true`. MCP returns only public configuration, even to owners.
- Revoked grants are rejected before actions and HTTP attempts, including cached clients and retries. Already in-flight requests cannot be recalled. REST revocation requires a provider declaration; MCP disconnect is local and clears stored authentication.
- Regular HTTP clients retry transient 502/503/504 responses twice for GET, HEAD, OPTIONS, PUT and DELETE. POST is excluded from those retries; token refresh may retry once after authentication failure. MCP tool calls are not automatically replayed on transport failure or HTTP 429.

Host authentication, authorization of direct Ruby calls, encryption-key management, queue operations and provider permissions remain application responsibilities. [Architecture and contracts](docs/architecture.md) explains the boundaries and stored data.

## Documentation

- [Framework and DSL reference](CONNECTORS_FRAMEWORK.md)
- [Architecture and execution flows](docs/architecture.md)
- [Adding a connector with tests](docs/adding-connectors.md)
- [Remote MCP and ClickUp](MCP_CLIENT.md)
- [HTTP API contract](openapi.yaml) — paths are relative to the engine mount
- [Development and contributing](CONTRIBUTING.md)
- [Release requirements and verification](docs/releasing.md)
- [Changelog and upgrade notes](CHANGELOG.md)

## License

[MIT](MIT-LICENSE). The vendored MCP schema has its [upstream license](lib/connectors/mcp/protocol/LICENSE) and [source attribution](lib/connectors/mcp/protocol/README.md) included in the gem.
