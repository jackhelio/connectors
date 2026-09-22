module Connectors
  # Static catalog of registered connectors. Clients use its metadata to
  # render credential forms, authorization links and action inputs.
  # The catalog contains no secrets or per-user state.
  class TypesController < ApplicationController
    # GET /connectors/types
    def index
      types = Registry.all.sort_by { |key, _| key.to_s }.map { |key, klass| serialize(key, klass) }
      render json: { types: types }
    end

    # GET /connectors/types/:name
    def show
      klass = Registry.fetch(params[:name])
      render json: serialize(klass.connector_key, klass)
    rescue Connectors::UnknownConnector => e
      render json: { error: e.message }, status: :not_found
    end

    private

    # The OAuth provider's "Authorized Redirect URI". This MUST match what
    # `AuthorizeUrl` and `TokenExchange` actually send — both read from
    # `Connectors.configuration.resolved_app_callback_url(...)`. Surfacing a
    # different value here would mislead admins into registering a URL the
    # engine never uses.
    def redirect_uri_for(connector_key)
      Connectors.configuration.resolved_app_callback_url(connector_key)
    rescue Connectors::Error
      # `host_base_url` not configured — return the engine's own callback
      # path so introspection still works in headless setups.
      "#{Connectors::Engine.mount_path}/#{connector_key}/callback"
    end

    def serialize(key, klass)
      schema = klass.credential_schema

      {
        # `name` identifies the connector; `display_name` is its UI label.
        # `key` and `label` remain aliases for existing consumers.
        name:              key.to_s,
        display_name:      klass.display_name || key.to_s.humanize,
        key:               key.to_s,                                       # @deprecated — use `name`
        label:             klass.display_name || key.to_s.humanize,        # @deprecated — use `display_name`
        icon:              klass.icon,
        icon_color:        klass.icon_color,
        documentation_url: klass.documentation_url,
        # URL to an LLM-optimized docs bundle (provider's `llms.txt` /
        # `llms-full.txt`, per llmstxt.org). Lets agents + frontend tools
        # fetch authoritative API behavior without scraping HTML.
        llm_docs:          klass.llm_docs,
        # Optional markdown the frontend renders at the top of the
        # "Add connection" dialog. Backend-driven: nil when the
        # connector doesn't need to walk the user through setup
        # (e.g. Gmail's OAuth dance is self-explanatory); populated
        # for connectors where the user needs to generate an API key
        # or install an app first (e.g. Resend).
        instructions:      klass.instructions,

        # Credential inheritance chain. The properties below already merge
        # inherited and local fields, with local definitions taking precedence.
        extends:          schema ? schema.extends.map(&:to_s) : [],
        properties:       schema ? schema.resolved_fields.map(&:to_property) : [],

        # Resolved auth injection: connector override, then inherited schema.
        # Nil when neither declares an authenticate block.
        authenticate:     klass.resolved_authenticate_config,
        # True when the connector or an inherited schema enables generic_auth.
        generic_auth:     klass.generic_auth?,

        # Allowed node types. An empty list imposes no node-type restriction.
        supported_nodes:  klass.supported_nodes.map(&:to_s),

        # Optional label, documentation link and base URL for an HTTP-request
        # credential picker.
        http_request_node: klass.http_request_node,

        # Vault-sourced field names for the editor to display as managed.
        # Empty when the host has not configured managed fields for this type.
        __overwritten_properties: Connectors.configuration.managed_fields_for(key),

        # When true, clients should hide managed-credential creation.
        __skip_managed_creation: klass.skip_managed_creation?,

        # Action manifest — what this connector can DO with a credential.
        # Each entry includes its own typed `properties` (input schema), an
        # optional `output` schema, and metadata for the picker UI. Frontend
        # browses these at design time; runtime invocation goes through
        # `POST /credentials/:id/actions/:name`. Empty array when the
        # connector hasn't declared any actions yet.
        actions: klass.actions.map(&:to_manifest),

        # Connector capabilities, separate from credential form metadata.
        # OAuth redirect_uri is the callback URL to register with the provider.
        connector: {
          base_url:      klass.base_url,
          webhook_style: klass.webhook_style.to_s,
          rate_limit:    klass.rate_limit_config,
          authorize_url:      klass.oauth2_config ? "#{Connectors::Engine.mount_path}/#{key}/authorize"      : nil,
          authorize_json_url: klass.oauth2_config ? "#{Connectors::Engine.mount_path}/#{key}/authorize.json" : nil,
          redirect_uri:  klass.mcp? ? Connectors.configuration.resolved_mcp_callback_url : (klass.oauth2_config ? redirect_uri_for(key) : nil),
          mcp: mcp_metadata(klass),
          # Frontend gates the "Test connection" button on this flag.
          test_supported: !klass.test_request_config.nil?
        }
      }
    end

    def mcp_metadata(klass)
      return unless klass.mcp?
      base = "#{Connectors::Engine.mount_path}/credentials/:id/mcp"
      klass.mcp_config.merge("protocol_version" => MCP::PROTOCOL_VERSION,
        "tools_url" => "#{base}/tools", "call_url" => "#{base}/tools/call",
        "resume_url" => "#{base}/interactions/resume", "authorize_url" => "#{base}/authorize")
    end
  end
end
