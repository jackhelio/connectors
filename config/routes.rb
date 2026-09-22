Connectors::Engine.routes.draw do
  get  "/credentials/:id/mcp/tools", to: "mcp#tools"
  post "/credentials/:id/mcp/tools/call", to: "mcp#call_tool"
  post "/credentials/:id/mcp/interactions/resume", to: "mcp#resume"
  post "/credentials/:id/mcp/authorize", to: "mcp#authorize"
  get  "/mcp/oauth/callback", to: "mcp#callback"
  post "/mcp/oauth/callback", to: "mcp#callback"
  # Catalog and credential routes precede the dynamic :connector_key routes.
  get    "/credentials",                    to: "credentials#index",        as: :credentials
  get    "/credentials/for-workflow",       to: "credentials#for_workflow", as: :credentials_for_workflow
  post   "/credentials/test",               to: "credentials#test_unsaved", as: :test_unsaved_credential
  get    "/credentials/new",                to: "credentials#new",          as: :new_credential
  post   "/credentials",                    to: "credentials#create"
  get    "/credentials/:id",                to: "credentials#show",         as: :credential
  patch  "/credentials/:id",                to: "credentials#update"
  put    "/credentials/:id",                to: "credentials#update"
  delete "/credentials/:id",                to: "credentials#destroy"
  post   "/credentials/:id/revoke",         to: "oauth#revoke",             as: :revoke_credential

  # Action manifest + invocation. Per-credential because actions need an
  # authenticated grant to run against; the catalog at /types/:name also
  # includes a static `actions: [...]` array for design-time browsing.
  get    "/credentials/:id/actions",        to: "actions#index",            as: :credential_actions
  post   "/credentials/:id/actions/:name",  to: "actions#create",           as: :invoke_credential_action,
                                            constraints: { name: /[^\/]+/ }

  # Credential sharing and ownership transfer.
  put    "/credentials/:id/share",          to: "credentials#share",        as: :share_credential
  delete "/credentials/:id/share",          to: "credentials#unshare"
  put    "/credentials/:id/transfer",       to: "credentials#transfer",     as: :transfer_credential

  # @deprecated `/grants` aliases — keep working until the frontend migrates.
  get  "/grants",                           to: "grants#index",     as: :grants
  post "/grants/:id/test",                  to: "grants#test",      as: :test_grant
  post   "/grants/:id/webhook_subscribe",   to: "grants#webhook_subscribe",   as: :webhook_subscribe_grant
  delete "/grants/:id/webhook_subscribe",   to: "grants#webhook_unsubscribe"
  post   "/grants/:id/poll",                to: "grants#poll",                as: :poll_grant
  get  "/types",                            to: "types#index",      as: :types
  get  "/types/:name",                      to: "types#show",       as: :type, constraints: { name: /[^\/]+/ }

  # Separate frontend callbacks POST `{code, state}` here after consent.
  post "/oauth/exchange",                   to: "oauth#exchange",       as: :oauth_exchange

  get  "/:connector_key/authorize.json",    to: "oauth#authorize_json", as: :authorize_json
  get  "/:connector_key/authorize",         to: "oauth#authorize",      as: :authorize
  # Provider callback for hosts using the engine callback URL.
  # Hosts with a separate frontend callback use /oauth/exchange instead.
  get  "/:connector_key/callback",          to: "oauth#callback",       as: :callback

  # App-level webhook URL (Slack, GitHub Apps, Linear, Notion, ...): one URL
  # per app, grant resolved from payload via Connector.resolve_grant_from_webhook.
  post "/:connector_key/webhook",                          to: "webhooks#receive", as: :app_webhook

  # Named webhook groups have distinct URLs, such as default and setup.
  post "/:connector_key/webhook/:webhook_name",            to: "webhooks#receive", as: :named_app_webhook

  # Per-grant webhook URL (Stripe, Twilio, ...): grant explicit in URL.
  # Must be declared AFTER /webhook so the bare form isn't shadowed.
  post "/:connector_key/:grant_id/webhook",                to: "webhooks#receive", as: :webhook
  post "/:connector_key/:grant_id/webhook/:webhook_name",  to: "webhooks#receive", as: :named_webhook
end
