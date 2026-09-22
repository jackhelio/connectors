module Connectors
  # Catalog of every connector class registered in the engine. Read by the
  # frontend at startup to render the "Add credential" form, the connect-OAuth
  # popup, the credential picker on nodes — purely by reading this metadata.
  # No per-connector frontend logic.
  #
  # Response shape mirrors n8n's `ICredentialType` description (n8n source:
  # packages/workflow/src/interfaces.ts:356-382) so a single frontend renderer
  # handles every connector. Returns only static metadata — never any secrets
  # or per-user state.
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
        # `name` is the n8n vocabulary for the machine identifier; `display_name`
        # is the picker label. We keep `key`/`label` as aliases for back-compat
        # with the existing /grants response — frontend should prefer the n8n
        # names going forward.
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

        # n8n inheritance chain. Empty array when the credential type stands
        # alone (e.g., API-key connectors). Frontend can fetch the parent's
        # schema via `/connectors/types/:parent` OR rely on the resolved
        # `properties` array below which already merges parent + own.
        extends:          schema ? schema.extends.map(&:to_s) : [],
        properties:       schema ? schema.resolved_fields.map(&:to_property) : [],

        # Declarative auth injection — mirrors n8n's `IAuthenticateGeneric`
        # at packages/workflow/src/interfaces.ts:278-288. Reads the resolved
        # config (connector-level override OR inherited from the credential
        # type via `extends`). nil when the connector still uses the
        # imperative `api_key_in` shim AND no parent declared one.
        authenticate:     klass.resolved_authenticate_config,
        # n8n's `genericAuth: boolean` (`interfaces.ts:379`). True when the
        # connector itself flips `generic_auth!` OR when it extends a schema
        # that already does (HttpBearerAuth etc.).
        generic_auth:     klass.generic_auth?,

        # n8n's `supportedNodes: string[]` (`interfaces.ts:381`). Empty array
        # means "no restriction" — same default as n8n. The frontend uses
        # this to filter the credential picker per node type.
        supported_nodes:  klass.supported_nodes.map(&:to_s),

        # n8n's `httpRequestNode: ICredentialHttpRequestNode` (interfaces.ts:380,
        # union shape at :350-354). Tells the generic HTTP-Request node's
        # credential picker how to label + link this credential. nil when the
        # connector hasn't declared it.
        http_request_node: klass.http_request_node,

        # n8n's `__overwrittenProperties: string[]` (`interfaces.ts:382`;
        # populated at `frontend.service.ts:681-705`). Field names whose
        # values are sourced from the external secrets manager — the editor
        # renders them locked / hidden. Empty array when no vault is
        # configured for this connector type.
        __overwritten_properties: Connectors.configuration.managed_fields_for(key),

        # n8n's `__skipManagedCreation` (frontend.service.ts:707-711). When
        # true the editor hides the "Use external secret" toggle.
        __skip_managed_creation: klass.skip_managed_creation?,

        # Action manifest — what this connector can DO with a credential.
        # Each entry includes its own typed `properties` (input schema), an
        # optional `output` schema, and metadata for the picker UI. Frontend
        # browses these at design time; runtime invocation goes through
        # `POST /credentials/:id/actions/:name`. Empty array when the
        # connector hasn't declared any actions yet.
        actions: klass.actions.map(&:to_manifest),

        # Connector capabilities — orthogonal to credentials. Lives in its own
        # block so frontend code that only cares about credential rendering
        # can ignore it. For OAuth connectors, `redirect_uri` is the URL the
        # admin must paste into the provider's app console (computed from the
        # host's base URL — n8n does the same server-side at
        # packages/cli/src/oauth/oauth.service.ts:528,690).
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
