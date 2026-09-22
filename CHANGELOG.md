# Changelog

Changes are recorded here before release. Published packages are listed on [RubyGems](https://rubygems.org/gems/connectors).

## Unreleased

### Documentation

- Describe connector contracts directly across guides, API metadata, source comments and test names.
- Remove obsolete demo smoke scripts from the public source tree; supported development and package checks are documented in the contributing guide.

## 0.1.0 — 2026-09-22

### Added

- Rails engine for encrypted credential grants, role-based sharing, provider OAuth, REST actions, webhook processing and polling.
- Shipped Gmail and Resend REST connectors, configurable remote MCP connections and the ClickUp MCP profile.
- MCP 2026-07-28 remote tool discovery/invocation, durable user authorization and elicitation, and cancellable subscriptions. Supported scope is documented in the MCP guide.
- Per-consumer polling state and regression/interoperability coverage.
- Installation, architecture, connector authoring, development and release documentation; strict package installation/boot verification.
- Public RubyGems metadata and a tag-triggered trusted publishing workflow gated by lint, tests and installed-package verification.

### Fixed

- Shared viewers/editors cannot retrieve regular provider secrets with `include_data=true`; owner access remains supported. MCP credentials return public configuration only.
- Revocation is checked before REST action execution and HTTP attempts, including cached clients and retries.
- Upstream MCP HTTP 429 responses retain their rate-limit classification and valid `Retry-After` guidance without automatic replay.
- Distributable gem includes its referenced user guides, API contract, changelog and upstream protocol license.
- Development lockfile includes dependency checksums and Linux platform declarations for CI.
- Streaming cancellation test accepts the expected TCP reset on Linux; CI reports individual examples and bounds execution time.
- MCP test DNS stubs preserve real database resolution so concurrency checks work with TCP PostgreSQL connections.

### Compatibility and upgrade notes

- Rails dependency is bounded to the 8.1 series, starting at 8.1.3; Ruby minimum remains 3.2. The validated baseline is Ruby 3.4.8, Rails 8.1.3 and PostgreSQL 16.
- Host owner and sharing-principal IDs must be UUIDs. Shipped migrations target PostgreSQL.
- Run host `bin/rails db:migrate` to add polling and MCP transaction tables; migrations are loaded directly from the engine.
- Authorization creates a new grant unless `grant_id` explicitly selects an existing owned connection. Reconnection retains an existing refresh token when omitted by the provider.
- In-flight authorizations using the older signed state format must restart. Current regular OAuth state is authenticated and encrypted, expires after 15 minutes, and remains stateless.
- Shared editors must update credentials without first reading their decrypted values. The credential response omits `data` for non-owner roles on regular connectors.
