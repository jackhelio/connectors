# Adding a connector

Use a REST connector when the backend should implement provider actions against an HTTP API. Use an MCP profile when the provider exposes a compatible remote MCP server and supplies its own tool schemas. See [architecture](architecture.md) for the separation.

## REST connector

Choose a unique key and place the class in the host's `app/connectors/<key>/connector.rb`. Match the Ruby namespace to the directory for Zeitwerk. The example below is a fictional CRM template, not a claim about an existing provider API:

```ruby
# app/connectors/example_crm/connector.rb
module ExampleCrm
  class Connector < Connectors::Connector
    connector key: :example_crm, auth: :api_key,
      base_url: "https://api.example.test", display_name: "Example CRM"

    credentials do
      field :api_key, type: "string", required: true, secret: true
    end

    authenticate type: :generic, properties: {
      headers: { "Authorization" => "=Bearer {{$credentials.api_key}}" }
    }

    test_request method: :get, url: "me"

    action :find_contact, display_name: "Find Contact" do
      field :email, type: "string", required: true
      execute do |input|
        client.get("contacts", { email: input.fetch("email") }).body
      end
    end
  end
end
```

Replace the endpoint, authentication and action with the provider's documented contract. Use the shared `client` for request timeouts, authentication, revocation, retries and error handling. Do not store real keys in connector classes. Set safe fixed provider URLs; do not turn untrusted action inputs into arbitrary destinations.

`test_request` should use a cheap, read-only endpoint compatible with the credential's permissions. A successful test establishes access to that endpoint, not every possible action. Document scope restrictions.

REST actions check required values and remove undeclared keys. Add provider-specific validation when required; field types primarily describe the UI. OAuth2/OAuth1, pre-authentication, webhooks, polling and credential inheritance are documented in the [DSL reference](../CONNECTORS_FRAMEWORK.md). Declare only capabilities you actually implement.

## Test first

In the gem repository, use `rails_helper` for the dummy application, registry reset and WebMock. In a host project, configure equivalent owner, encryption and database fixtures. With the example connector loaded:

```ruby
require "rails_helper"

RSpec.describe ExampleCrm::Connector do
  let(:owner) { Owner.create!(name: "CRM test") }
  let(:grant) do
    Connectors::Grant.create!(owner: owner, connector_key: "example_crm",
      credentials: { "api_key" => "synthetic-key" })
  end

  it "finds contacts through the authenticated client" do
    stub_request(:get, "https://api.example.test/contacts")
      .with(query: { email: "person@example.test" },
        headers: { "Authorization" => "Bearer synthetic-key" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
        body: '{"contacts":[]}')

    result = Connectors::ActionRunner.call(grant, :find_contact,
      { "email" => "person@example.test" })
    expect(result[:status]).to eq("ok")
    expect(result[:data]).to eq("contacts" => [])
  end
end
```

Add cases for the provider's documented errors, scope restrictions and required input; verify write operations are not replayed unexpectedly. For webhooks test signature validation, grant routing and duplicate events. For polling test cursor isolation and rollback on failure. Avoid tests that only repeat DSL declarations without verifying behavior.

## Named MCP profile

For a server supported by the generic MCP integration, a named profile supplies fixed connection metadata. It does not copy remote tools into Ruby action classes:

```ruby
# app/connectors/example_mcp/connector.rb
module ExampleMcp
  class Connector < Connectors::Connector
    connector key: :example_mcp, auth: :api_key, base_url: nil,
      display_name: "Example MCP"
    mcp server_url: "https://mcp.example.test/mcp", auth_mode: "oauth"
  end
end
```

The `auth: :api_key` field is the current base connector DSL marker; the `mcp` declaration selects OAuth for the remote connection. It does not enable an API-key fallback. For servers needing preregistered clients, declare the optional secret `client_information` credential field as the shipped ClickUp profile does.

Confirm the actual server's transport/protocol support, endpoint, OAuth discovery metadata, scopes and client registration requirements using official documentation and live read-only metadata. Do not assume all servers support dynamic registration, refresh tokens or the same scopes. Test fixed-profile configuration, consent requirements, sanitized credential responses, discovery and invocation. Use the shared MCP services; add no provider-specific token logic unless the actual contract requires it.

See [ClickUp](../MCP_CLIENT.md#clickup) for the implemented example and [contributing](../CONTRIBUTING.md) for full verification commands.
