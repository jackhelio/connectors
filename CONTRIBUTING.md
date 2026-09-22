# Development and contributing

Read the [README](README.md) for host setup, the [architecture](docs/architecture.md) for execution boundaries, and the [connector guide](docs/adding-connectors.md) for provider additions.

## Local setup

Use Ruby 3.4.8 (`.ruby-version`), PostgreSQL 16 and Python 3.9+ for the independent MCP fixture. Bundler installs the development/test dependencies from `Gemfile`; consumers receive only `connectors.gemspec` runtime dependencies. `Gemfile.lock` records the development baseline.

From the repository root:

```sh
bundle install
export RAILS_ENV=test
export DATABASE_URL=postgresql://localhost/connectors_test
bundle exec rake app:db:prepare
bundle exec rspec --order random
bundle exec rubocop
```

Use a disposable database: the suite includes committed-record concurrency tests and cleanup. Do not point it at a host's development or production data. PostgreSQL role permissions must allow database creation, or create the test database beforehand. `PYTHON` can select the Python executable; otherwise tests use `python3`. Local socket/loopback access is required by MCP interoperability and streaming tests.

Use a TCP database connection, as CI does, when validating concurrency changes. MCP tests use `stub_mcp_dns` to replace only provider fixture lookups; never stub all DNS resolution, because the PostgreSQL driver uses it too.

The dummy Rails application lives in `test/dummy`. It provides UUID owners, synthetic encryption keys, test routes and fixture connectors. Its keys and authentication setup are not installation defaults for host applications.

## Test workflow

For behavior changes, first write a failing RSpec example that demonstrates the requirement; run it, implement the smallest change, then rerun it. Use request tests for HTTP access/response contracts and service tests for Ruby entry points. Stub external providers with WebMock; never require personal credentials or real writes in the automated suite. Use real PostgreSQL connections for locking/concurrency claims.

Examples:

```sh
bundle exec rspec spec/requests/credentials_crud_spec.rb
bundle exec rspec spec/connectors/mcp/client_spec.rb
bundle exec rspec --order random
bundle exec rubocop
```

Report the command and seed when reporting a failure. A test count is not a coverage percentage; there is currently no enforced line/branch coverage threshold.

## Package verification

```sh
bundle exec ruby script/verify_package.rb
```

This strict-builds the gem, checks required files and local documentation links, installs it into a temporary gem directory without downloading dependencies, then boots a separate Rails host against the installed artifact. It checks the shipped registry, migration paths and vendored MCP schema. Dependencies must already be installed with Bundler. Temporary artifacts are removed automatically. The same check runs through `spec/packaging_spec.rb` in the full suite, so CI exercises it too.

The test suite validates provider behavior with fixtures and local interoperability servers. It does not certify live provider availability, account permissions, every supported Ruby version, or production load.

## Change conventions

- Keep provider-specific code under `app/connectors/<provider>/`; reusable mechanisms belong under `lib/connectors/`.
- Add host requirements, examples and API changes to the relevant guide and `openapi.yaml`. Record compatibility changes under `Unreleased` in `CHANGELOG.md`.
- Avoid provider secrets in fixtures, logs, failures and screenshots. Use synthetic credentials and sanitized captured public metadata.
- Do not edit already released migrations to upgrade existing hosts. Add migrations and upgrade instructions.
- For protocol changes, retain upstream attribution and add contract/interoperability tests. See the [vendored schema notes](lib/connectors/mcp/protocol/README.md).
- Keep HTTP retries explicit, particularly for actions that can produce side effects.

Before handing off a change, include the problem, changed behavior, tests run and any unresolved limitation. Release preparation is documented separately in [releasing](docs/releasing.md).
