# Architecture and execution contracts

Connectors is a Rails engine. It does not provide a workflow executor, account login UI, scheduler or hosted provider proxy. The [README](../README.md) describes installation; the [framework reference](../CONNECTORS_FRAMEWORK.md) describes the DSL.

## Components

| Component | Responsibility |
| --- | --- |
| Host application | Authenticated owner/principals, encryption keys, provider application secrets, job backend, scheduling and business workflows |
| Registry and connector classes | Credential schemas, provider metadata, REST actions, authentication declarations and optional polling/webhooks |
| `Connectors::Grant` | One connected account; encrypted credentials, status, ownership and provider identity |
| Credential shares | Grant access for UUID principals with viewer, editor or owner roles |
| REST execution | Declared actions and Faraday middleware for credential injection, refresh, errors and retries |
| MCP client | Grant-scoped remote discovery, schema validation, transport, OAuth and durable interactions |
| Controllers | HTTP access checks and stable request/response envelopes |

Classes under `app/connectors/*/connector.rb` register through the connector DSL when Rails loads them. The engine's `to_prepare` hook loads shipped and host connector classes. Remote MCP tools are discovered for each authorized grant; they do not become global connector classes.

## REST actions

```text
Authenticated app request
  → engine role check (editor or owner)
  → declared action lookup and revocation check
  → required-parameter validation and input whitelist
  → provider action implementation
  → Faraday: rate limit / refresh / error normalization / retries
  → per-attempt revocation check / pre-authentication / credential injection
  → provider
  → normalized action result
```

`ActionRunner.call(grant, name, input)` is also available to trusted host code. It checks revocation, but it does not accept an actor or perform sharing authorization: the host must authorize the selected grant before calling it. Connector methods using `client` get the same HTTP checks. Provider implementations that bypass `client` also bypass that middleware.

Action field declarations describe the form and required values; they are not a general JSON Schema validator. Unknown REST action keys are dropped. Provider actions must validate constraints beyond required values where needed.

## MCP tools

```text
Authenticated app request
  → MCP access check for the grant and actor
  → discover provider tool descriptors
  → validate arguments against the selected tool's schema
  → transport with grant credentials and protocol metadata
  → provider tools/call
  → native tool result, or persisted input_required interaction
```

The backend handles discovery, registration, OAuth scopes and token use. The frontend renders tool input and explicit user consent/elicitation; it does not implement provider authentication or requests. Unlike the REST Ruby runner, `MCP::Client.new(grant:, actor:, principals:)` checks access itself. HTTP tools and actions currently have separate endpoints.

OAuth and elicitation use encrypted, expiring database records bound to the actor, grant and connection fingerprint. One-time transaction claims prevent local replay. They do not guarantee exactly-once execution at the remote provider. A network interruption can leave a remote operation's outcome unknown. See [MCP support and limits](../MCP_CLIENT.md).

## Persistence and encryption

Credentials and MCP transaction payloads use Rails Active Record Encryption. Owner IDs, connection metadata, polling state and webhook bodies are not all encrypted by this feature. Webhook raw bodies/payloads and polling state can contain provider data; hosts must apply their own retention and access rules.

Credential merges and OAuth refresh coordinate with row locks. Polling can keep one cursor per `(grant, instance_key)`, so independent consumers do not share progress accidentally. Revocation checks query current persisted status to handle cached clients; in-flight network requests cannot be recalled.

## Webhooks and polling

Inbound webhook handling resolves the connector and grant, applies that connector's verification, persists a `WebhookEvent` and queues delivery. `DeliverWebhookJob` invokes the connector handler and optional host hook. Deduplication uses provider event IDs when available. Verification and extraction rules are provider-specific.

The host activates/deactivates declared webhook subscriptions and schedules polling. Polling commits cursor changes after a successful provider call; reliable delivery of returned items to downstream workflows is a host concern. No engine process runs an autonomous schedule.

## Errors and operational limits

REST actions return typed error envelopes; the HTTP layer maps validation, authentication, permission and quota failures to appropriate statuses. Other provider action failures use 502. Direct Ruby clients raise library errors where no action envelope is involved.

MCP preserves tool-level `isError` results separately from HTTP/protocol errors. Upstream HTTP 429 returns `rate_limited` with valid optional retry guidance. MCP transport bounds request duration, body size, pagination and interaction rounds; it validates and pins destinations. See the MCP guide for exact defaults and supported authentication mechanisms.

Production acceptance requires verification in the intended host and provider account. Passing package checks demonstrates that consumers can load the distributed artifact; it does not establish provider uptime, sufficient scopes, application authorization or load capacity.
