module Connectors
  # Base class for every connector (Slack, Linear, Stripe, ...). Subclasses
  # declare themselves with the `connector` DSL and define instance methods
  # that wrap the third-party API.
  #
  #   class SlackConnector < Connectors::Connector
  #     connector key: :slack, auth: :oauth2, base_url: "https://slack.com/api"
  #
  #     credentials do
  #       field :access_token,  required: true, secret: true
  #       field :refresh_token, required: true, secret: true
  #     end
  #
  #     def post_message(channel:, text:)
  #       client.post("chat.postMessage", channel: channel, text: text).body
  #     end
  #
  #     def refresh!
  #       # ... call the OAuth token endpoint, then:
  #       grant.update_credentials!(access_token: "...", refresh_token: "...")
  #     end
  #   end
  class Connector
    class << self
      attr_reader :connector_key, :base_url, :credential_schema, :rate_limit_config, :test_request_config,
                  :display_name, :icon, :icon_color, :documentation_url, :llm_docs, :instructions,
                  :authenticate_config, :mcp_config

      def connector(key:, auth:, base_url:,
                    display_name: nil, icon: nil, icon_color: nil,
                    documentation_url: nil, llm_docs: nil, instructions: nil)
        @connector_key     = key.to_sym
        @auth_scheme_name  = auth.to_sym
        @base_url          = base_url
        @display_name      = display_name
        @icon              = icon
        @icon_color        = icon_color
        @documentation_url = documentation_url
        # URL to an LLM-friendly docs bundle (typically the provider's
        # `llms.txt` or `llms-full.txt` per llmstxt.org). Surfaced on the
        # types endpoint so the frontend / agents can fetch authoritative
        # API behavior without scraping HTML docs.
        @llm_docs          = llm_docs
        # Optional markdown-formatted instructions shown at the top of the
        # "Add connection" dialog — use it for connectors that need the user
        # to do something on the provider's side first (generate an API
        # key, install an app, register a webhook URL, …). Nil when the
        # connector doesn't need guidance; the frontend renders nothing.
        @instructions      = instructions
        Connectors::Registry.register(@connector_key, self)
      end

      def credentials(&block)
        @credential_schema = CredentialSchema.build(&block)
      end

      # Remote MCP types share one client and OAuth flow. A named provider can
      # pin its endpoint/authentication; the generic type leaves both editable.
      def mcp(server_url: nil, auth_mode: nil)
        @mcp_config = { "server_url" => server_url, "auth_mode" => auth_mode }.compact.freeze
        revoke_token do |grant|
          grant.update!(credentials: Connectors::MCP::ConnectionConfig.public_data(grant.stored_credentials_hash))
        end
      end

      def mcp?
        !mcp_config.nil?
      end

      def rate_limit(count, per:)
        @rate_limit_config = { limit: count, per: per }
      end

      # Declarative "Test connection" — mirrors n8n's `ICredentialTestRequest`
      # (packages/workflow/src/interfaces.ts:340-348). The test fires a real
      # HTTP request via the connector's middleware stack (so credentials are
      # injected the same way they would be at runtime) and applies the
      # configured rules to decide pass/fail.
      #
      #   test_request method: :get, url: "domains"
      #
      #   test_request method: :get, url: "auth.test",
      #                rules: [
      #                  { type: :response_success_body, key: "ok", value: false,
      #                    message: "Slack token is invalid" }
      #                ]
      #
      # Status-code rules: a successful test is any 2xx by default. Pass
      # `expect_status: 200` to require an exact code.
      def test_request(method: :get, url:, headers: nil, query: nil,
                       expect_status: nil, rules: [])
        @test_request_config = {
          method:        method.to_sym,
          url:           url,
          headers:       headers,
          query:         query,
          expect_status: expect_status,
          rules:         Array(rules)
        }
      end

      # n8n-style declarative auth injection (mirrors `IAuthenticateGeneric`
      # at packages/workflow/src/interfaces.ts:278-288 + the shape of
      # `IRequestOptionsSimplifiedAuth` at :197-208).
      #
      # `properties` accepts any subset of:
      #   headers:                  { "Authorization" => "=Bearer {{$credentials.api_key}}" }
      #   qs:                       { "api_key" => "={{$credentials.api_key}}" }
      #   body:                     { "auth_token" => "={{$credentials.token}}" }
      #   auth:                     { username: "...", password: "..." }  # Basic-auth shortcut
      #   skip_ssl_certificate_validation: true
      #
      # Strings beginning with `=` are templates; `{{$credentials.field}}`
      # substitutes the grant's credential field at request time. Strings
      # without `=` are passed verbatim.
      #
      #   authenticate type: :generic, properties: {
      #     headers: { "Authorization" => "=Bearer {{$credentials.api_key}}" }
      #   }
      #
      # When declared, this replaces the old `api_key_in` imperative shim
      # at runtime — both the schema serializer and the Faraday client
      # honor the declarative form first, falling back to `api_key_in` only
      # if `authenticate` is absent.
      def authenticate(type:, properties:)
        raise ArgumentError, "only type: :generic is supported (n8n's IAuthenticateGeneric)" \
          unless type.to_sym == :generic
        @authenticate_config = { "type" => "generic", "properties" => properties }
      end

      # Resolved authenticate block: connector-level override wins, otherwise
      # delegate to the credential schema (which walks `extends`). Lets a
      # connector that only does `extends :http_bearer_auth` inherit both
      # the `token` field AND the injection contract with no extra DSL.
      def resolved_authenticate_config
        @authenticate_config || @credential_schema&.resolved_authenticate
      end

      # n8n's `preAuthentication` hook (interfaces.ts:374-377). The block
      # runs BEFORE each outgoing request, but only when the grant's
      # credentials look stale (`expires_at` missing or in the past).
      # Returns a hash merged into the grant's credentials before the
      # AuthenticateGeneric step injects them into the request.
      #
      # Reference impl: CrowdStrikeOAuth2Api.credentials.ts:62-76 —
      # fetches a session token from /oauth2/token using client_id +
      # client_secret, returns `{ session_token, expires_at }`.
      #
      #   pre_authentication do |credentials, helpers|
      #     response = helpers.http_request(
      #       method: :post,
      #       url:    "#{credentials['url']}/oauth2/token",
      #       body:   { client_id: credentials['client_id'],
      #                 client_secret: credentials['client_secret'] }
      #     )
      #     { "session_token" => response["access_token"],
      #       "expires_at"    => Time.now.to_i + response["expires_in"].to_i }
      #   end
      def pre_authentication(&block)
        @pre_authentication_block = block
      end

      attr_reader :pre_authentication_block

      # Imperative API-key shim — kept for back-compat with connectors that
      # declared `api_key_in` before Phase 1. New code should use the
      # declarative `authenticate` DSL above. When both are declared,
      # `authenticate` wins.
      #
      #   api_key_in :header, name: "Authorization", prefix: "token "
      #   api_key_in :query,  name: "api_key"
      def api_key_in(location, name:, prefix: nil)
        @api_key_options = { location: location, name: name, prefix: prefix }
      end

      attr_reader :api_key_options

      # Declares OAuth2 provider endpoints + default scope. Client id/secret
      # are supplied by the host via Connectors.configuration.oauth_credentials.
      #
      # `grant_type:` mirrors n8n's `OAuth2Api.credentials.ts:33-46` enum and
      # selects the runtime flow:
      #   - "authorizationCode" (default) — standard redirect flow
      #   - "clientCredentials"           — server-to-server, no user redirect
      #   - "pkce"                        — RFC 7636 with S256 challenge
      #
      # `authentication:` (header | body) — how client credentials are sent
      # to the token endpoint. Matches n8n's same-named field. Default
      # `"header"` (HTTP Basic).
      #
      #   oauth2 authorize_url: "https://slack.com/oauth/v2/authorize",
      #          token_url:     "https://slack.com/api/oauth.v2.access",
      #          scope:         "chat:write,channels:read"
      def oauth2(authorize_url: nil, token_url:, scope: nil, extra_authorize_params: {},
                 grant_type: "authorizationCode", authentication: "header", token_expired_status: 401)
        unless %w[header body].include?(authentication.to_s)
          raise ArgumentError, "OAuth authentication must be header or body"
        end
        unless token_expired_status.is_a?(Integer) && (400..499).cover?(token_expired_status)
          raise ArgumentError, "token_expired_status must be an HTTP 4xx status"
        end
        @oauth2_config = {
          authorize_url:          authorize_url,
          token_url:              token_url,
          scope:                  scope,
          extra_authorize_params: extra_authorize_params,
          grant_type:             grant_type.to_s,
          authentication:         authentication.to_s,
          token_expired_status:   token_expired_status
        }
      end

      attr_reader :oauth2_config

      # Declares OAuth1.0a provider endpoints + consumer signature method.
      # Consumer key/secret come from `Connectors.configuration.oauth_credentials`
      # (same `client_id` / `client_secret` slot as OAuth2 — they're
      # semantically identical in n8n's storage too).
      #
      #   oauth1 request_token_url: "https://api.twitter.com/oauth/request_token",
      #          authorize_url:     "https://api.twitter.com/oauth/authorize",
      #          access_token_url:  "https://api.twitter.com/oauth/access_token",
      #          signature_method:  "HMAC-SHA1"   # default
      def oauth1(request_token_url:, authorize_url:, access_token_url:,
                 signature_method: "HMAC-SHA1")
        @oauth1_config = {
          request_token_url: request_token_url,
          authorize_url:     authorize_url,
          access_token_url:  access_token_url,
          signature_method:  signature_method
        }
      end

      attr_reader :oauth1_config

      # Optional token-revocation surface. EITHER set `revoke_token_url`
      # (RFC 7009: POST `token=<...>&client_id=<...>&client_secret=<...>`
      # to the configured URL) OR pass a block to `revoke_token` for
      # providers with a non-standard revoke shape.
      #
      #   revoke_token_url "https://slack.com/api/auth.revoke"
      #
      #   # or, for a provider whose revoke endpoint is GET'd with the
      #   # token in the query string (e.g. Google):
      #   revoke_token do |grant|
      #     Faraday.get("https://oauth2.googleapis.com/revoke",
      #                 { token: grant.credentials_hash["access_token"] })
      #   end
      def revoke_token_url(url = nil)
        @revoke_token_url = url if url
        @revoke_token_url
      end

      def revoke_token(&block)
        @revoke_token_block = block
      end

      attr_reader :revoke_token_block

      # n8n's `__skipManagedCreation` (frontend.service.ts:707-711). When
      # an admin disables managed-credential creation for this type, the
      # editor hides the "Use external secret" toggle AND the API refuses
      # POSTs that pass `is_managed: true`. Surfaces on the types endpoint.
      def skip_managed_creation!
        @skip_managed_creation = true
      end

      def skip_managed_creation?
        @skip_managed_creation == true
      end

      # n8n's `genericAuth: boolean` flag on `ICredentialType`
      # (interfaces.ts:379). Marks the credential as eligible for the future
      # generic HTTP-Request node's picker. Most provider-specific connectors
      # leave this off; generic HTTP types (HttpBearerAuth etc.) flip it on.
      # Connector-level call so non-`extends` connectors can opt in directly:
      #
      #   generic_auth!
      #
      # When the connector `extends` an Http*Auth schema, the schema's flag
      # already propagates — but this stays available as a per-connector override.
      def generic_auth!
        @generic_auth = true
      end

      def generic_auth?
        return true if @generic_auth
        @credential_schema&.generic_auth? || false
      end

      # n8n's `supportedNodes: string[]` (interfaces.ts:381). When set, only
      # the listed node types are allowed to use this credential. Empty/unset
      # means "any node may use it" — same default as n8n.
      #
      #   supported_nodes :slack_send_message, :slack_get_channel
      #
      # The check itself is `Connectors::PermissionCheck.permit!` — call it
      # from your node's execution wrapper to enforce.
      def supported_nodes(*names)
        if names.empty?
          @supported_nodes || []
        else
          @supported_nodes = names.flatten.map(&:to_sym)
        end
      end

      # n8n's `httpRequestNode: { name, docsUrl, apiBaseUrl | apiBaseUrlPlaceholder, hidden? }`
      # (interfaces.ts:380; type `ICredentialHttpRequestNode` at :350-354).
      # Advertises the connector to the generic HTTP-Request node's
      # "credential picker" UI — the user sees "Linear API" alongside the
      # docs link + a pre-filled base URL.
      #
      #   http_request_node name: "Linear API",
      #                     docs_url: "https://developers.linear.app/",
      #                     api_base_url: "https://api.linear.app/"
      def http_request_node(name: nil, docs_url: nil, api_base_url: nil, api_base_url_placeholder: nil, hidden: false)
        # Reader form: `klass.http_request_node` with no args returns the
        # stored config (nil when undeclared). Writer form supplies `name:`
        # + `docs_url:` + one of the base-URL slots.
        return @http_request_node if name.nil? && docs_url.nil?
        unless api_base_url || api_base_url_placeholder
          raise ArgumentError, "http_request_node requires either api_base_url or api_base_url_placeholder " \
                               "(n8n's `ICredentialHttpRequestNode` union, interfaces.ts:350-354)"
        end
        @http_request_node = {
          "name"                  => name,
          "docsUrl"               => docs_url,
          "apiBaseUrl"            => api_base_url,
          "apiBaseUrlPlaceholder" => api_base_url_placeholder,
          "hidden"                => hidden == true
        }.compact
      end

      # Combined predicate used by `Connectors::PermissionCheck.permit!`.
      # n8n's logic (oauth/credentials.controller flow, applied at credential
      # picker render time): if `supportedNodes` is non-empty, the requesting
      # node must be in it. The generic HTTP-Request node bypasses this
      # check entirely when `genericAuth` is true on the credential type.
      def supports_node?(node_type)
        node_type = node_type.to_sym
        return true if supported_nodes.empty?           # no allowlist → permitted
        return true if generic_auth? && node_type == :http_request
        supported_nodes.include?(node_type)
      end

      # Hook called by TokenExchange after each successful token exchange or
      # refresh. Default is a no-op (returns `normalized` unchanged). Override
      # in subclasses to merge service-specific fields (Slack's team.id,
      # bot_user_id, GitHub's installation_id, etc.) into the credentials hash.
      #
      # Receives the raw provider response and the normalized OAuth2 fields
      # (access_token, refresh_token, expires_at, scope, token_type). Returns
      # the final hash to write into Grant#credentials.
      def post_token_exchange(_raw_response, normalized)
        normalized
      end

      # Resolved lazily so connector files can be loaded before auth schemes are.
      def auth_scheme
        Connectors::Auth::Scheme.lookup(@auth_scheme_name)
      end

      # Attach a Connectors::Webhooks::Verifier subclass for signature checks
      # on inbound webhooks. If unset, the WebhooksController accepts any
      # caller — useful in development, dangerous in production.
      def verify_webhooks_with(verifier_class)
        @webhook_verifier = verifier_class
      end

      attr_reader :webhook_verifier

      # Declares the provider-side webhook subscription lifecycle. See
      # `Connectors::WebhookMethodsBuilder` for the block API. Implicit
      # group name is `:default` so single-webhook providers don't need
      # to think about groups:
      #
      #   webhook_methods do
      #     check_exists { |grant, hook_url, static_data| ... }
      #     create       { |grant, hook_url, static_data| ... }
      #     delete       { |grant, static_data| ... }
      #   end
      #
      # For multi-webhook providers (Slack/Linear with separate `setup`
      # and `default` groups) call `webhook_methods :setup do ... end`.
      def webhook_methods(name = :default, &block)
        builder = WebhookMethodsBuilder.new
        builder.instance_eval(&block)
        @webhook_groups ||= {}
        @webhook_groups[name.to_sym] = WebhookGroup.new(
          name.to_sym, builder.check_exists_block, builder.create_block, builder.delete_block
        )
      end

      def webhook_group(name)
        (@webhook_groups || {})[name.to_sym]
      end

      def webhook_group_names
        (@webhook_groups || {}).keys
      end

      # Polling primitive — n8n's `polling: true` flag + `poll()` method
      # on trigger nodes (interfaces.ts:2060; reference impl
      # `nodes-base/nodes/Google/Gmail/GmailTrigger.node.ts:65, 281-553`).
      # The block runs once per scheduler tick (or once per manual POST to
      # /poll), receives the per-grant scratch hash for cursor persistence,
      # and returns the new items.
      #
      #   polling do |grant, static_data|
      #     since = static_data["last_id"]
      #     items = grant.connector.client.get("issues", since: since).body
      #     static_data["last_id"] = items.first["id"] if items.any?
      #     items
      #   end
      #
      # The scheduler itself is a workflow-roadmap concern; the connector
      # side just provides the block + cursor contract.
      def polling(&block)
        @polling_block = block
      end

      attr_reader :polling_block

      def polling?
        !@polling_block.nil?
      end

      # Some providers send a one-time URL-verification ping when you register
      # the webhook URL and expect a specific response (e.g. Slack:
      # {"type":"url_verification","challenge":"..."}  →  {"challenge":"..."}).
      # Return a hash to render as JSON, or nil to fall through to normal
      # event processing. Default: nil.
      def webhook_challenge(_payload)
        nil
      end

      # Most providers (Slack, GitHub Apps, Linear, Notion) only let you set
      # ONE webhook URL for your app — the grant must be inferred from the
      # payload. Override to look up the Grant from `payload`/`request`.
      # Return nil to refuse the event with 404. Default: nil.
      def resolve_grant_from_webhook(_payload, _request)
        nil
      end

      # Optional hook: extract a stable provider-side account identifier from
      # the credentials hash (Slack team_id, GitHub installation_id, etc.).
      # OAuthController persists the return value to Grant#external_account_id
      # so webhook routing can look it up without decrypting credentials.
      def external_account_id_from_credentials(_credentials)
        nil
      end

      # :app_level   — subclass overrode resolve_grant_from_webhook, so every
      #                team posts to a single /:connector_key/webhook URL.
      # :per_grant   — subclass uses /:connector_key/:grant_id/webhook (the
      #                grant id is in the URL itself).
      # Used by the /connectors/types catalog so the frontend can render
      # the right URL hint when installing a provider.
      def webhook_style
        if method(:resolve_grant_from_webhook).owner != Connectors::Connector.singleton_class
          :app_level
        else
          :per_grant
        end
      end

      # Declarative action manifest — what this connector can DO with a
      # credential. Mirrors n8n's `(resource, operation)` slot
      # (packages/workflow/src/interfaces.ts NodeProperties) and Activepieces'
      # `createAction(...)`. Each action gets a typed param schema, an
      # optional output schema, and an execute block that runs in the
      # connector instance's context.
      #
      #   action :send_email,
      #          display_name: "Send Email",
      #          description:  "Send a transactional email." do
      #     field :to,      type: "string", required: true
      #     field :subject, type: "string", required: true
      #     field :html,    type: "string"
      #
      #     output do
      #       field :id, type: "string", description: "Resend message id."
      #     end
      #
      #     execute { |input| send_email(**input.symbolize_keys) }
      #   end
      #
      # Surfaced on `/connectors/types/:name` as `actions: [...]` so frontends
      # and agents can discover everything the connector exposes; invocation
      # goes through `POST /connectors/credentials/:id/actions/:name`.
      def action(key, display_name: nil, description: nil, tags: [], deprecated: false, &block)
        action = ActionBuilder.build(key,
                                     display_name: display_name,
                                     description:  description,
                                     tags:         tags,
                                     deprecated:   deprecated,
                                     &block)
        (@actions ||= {})[action.key] = action
        action
      end

      # All actions declared on this connector, in declaration order.
      def actions
        (@actions || {}).values
      end

      def action_lookup(name)
        (@actions || {})[name.to_sym] or
          raise Connectors::UnknownAction.new(name, connector_key: @connector_key,
                                                    known: (@actions || {}).keys)
      end

      def action?(name)
        (@actions || {}).key?(name.to_sym)
      end
    end

    attr_reader :grant

    def initialize(grant)
      @grant = grant
    end

    # The Faraday client with the full middleware stack assembled. When the
    # connector class (or its inherited credential schema, via Phase 2)
    # declares an `authenticate` block, AuthenticateGeneric middleware
    # applies it; otherwise the imperative `auth_scheme` is used.
    def client
      @client ||= ClientBuilder.new(
        base_url:            self.class.base_url,
        grant:               grant,
        auth_scheme:         self.class.auth_scheme,
        authenticate_config: self.class.resolved_authenticate_config,
        pre_auth_block:      self.class.pre_authentication_block
      ).build
    end

    # Override in subclass. Called by the AutoRefresh middleware on 401.
    # Should fetch new tokens from the provider and persist via
    # `grant.update_credentials!(...)`.
    def refresh!
      raise NotImplementedError, "#{self.class.name}#refresh! is not implemented"
    end

    # Override in subclass. Called periodically by Connectors::PollJob if
    # the connector opts into polling.
    def poll; end

    # Override in subclass. Called by the webhook dispatcher when an event
    # arrives for this grant. The argument is a `Connectors::WebhookContext`
    # (Phase 7) exposing `.body`, `.headers`, `.query`, `.raw_body`,
    # `.webhook_name`, `.signature`, `.grant`, plus `.event` for direct
    # access to the persisted `Connectors::WebhookEvent`. The context
    # delegates `.payload_hash` / `.payload` for back-compat with handlers
    # written before Phase 7 — the same method works on both.
    def handle_webhook(ctx); end

    # Convenience — validates the grant's credentials against the connector's
    # declared schema. Use in #refresh! callbacks or before risky calls.
    def validate_credentials!
      schema = self.class.credential_schema
      schema&.validate!(grant.credentials_hash)
    end
  end
end
