module Slack
  # Slack OAuth2 connector. Talks to api.slack.com using a Bearer access_token.
  # Webhooks are signed with the app-level signing secret; see Slack::WebhookVerifier.
  class Connector < Connectors::Connector
    connector key:               :slack,
              auth:              :oauth2,
              base_url:          "https://slack.com/api",
              display_name:      "Slack",
              icon:              "https://a.slack-edge.com/80588/marketing/img/icons/icon_slack.png",
              icon_color:        "#4A154B",
              documentation_url: "https://api.slack.com/web"

    oauth2 authorize_url: "https://slack.com/oauth/v2/authorize",
           token_url:     "https://slack.com/api/oauth.v2.access",
           scope:         "chat:write,channels:read,users:read"

    # Slack inherits the canonical OAuth2 form (grantType / authUrl / tokenUrl /
    # client_id / client_secret / scope / etc.) and locks the Slack-specific
    # endpoints + default scopes by re-declaring them as hidden with fixed
    # defaults.
    #
    # The tokens Slack returns after the OAuth dance (access_token, team_id,
    # bot_user_id, ...) are NOT user-input fields — they get stored on the
    # Grant's credentials blob by OAuthController, not declared here.
    credentials do
      extends :oauth2

      field :authorization_url, type: "hidden",
                                default: "https://slack.com/oauth/v2/authorize"
      field :access_token_url,  type: "hidden",
                                default: "https://slack.com/api/oauth.v2.access"
      field :grant_type,        type: "hidden", default: "authorizationCode"
      field :scope,             type: "hidden", default: "chat:write,channels:read,users:read"
    end

    rate_limit 50, per: 60

    verify_webhooks_with Slack::WebhookVerifier

    # Pull Slack-specific fields out of the oauth.v2.access response and
    # merge them into the credentials hash.
    def self.post_token_exchange(raw_response, normalized)
      normalized.merge(
        "team_id"        => raw_response.dig("team", "id"),
        "team_name"      => raw_response.dig("team", "name"),
        "bot_user_id"    => raw_response["bot_user_id"],
        "app_id"         => raw_response["app_id"],
        "authed_user_id" => raw_response.dig("authed_user", "id")
      ).compact
    end

    # Denormalize team_id onto Grant#external_account_id at save time so
    # webhook routing can look up the grant by team without decrypting
    # the credentials blob.
    def self.external_account_id_from_credentials(credentials)
      credentials["team_id"]
    end

    # When Slack first registers the webhook URL, it POSTs
    # {"type":"url_verification","challenge":"..."} and expects the same
    # challenge string echoed back. Short-circuit that before grant lookup.
    def self.webhook_challenge(payload)
      return nil unless payload.is_a?(Hash) && payload["type"] == "url_verification"
      { challenge: payload["challenge"] }
    end

    # Slack only allows one webhook URL per app; every team that installs
    # the app posts to the same URL. Route to the right Grant by team_id.
    def self.resolve_grant_from_webhook(payload, _request)
      return nil unless payload.is_a?(Hash)
      team_id = payload["team_id"] || payload.dig("team", "id")
      return nil if team_id.to_s.empty?
      Connectors::Grant.where(connector_key: "slack", external_account_id: team_id).first
    end

    def refresh!
      new_tokens = Connectors::OAuth::TokenExchange.refresh(
        self.class, refresh_token: grant.credentials_hash.fetch("refresh_token")
      )
      grant.update_credentials!(new_tokens)
    end

    # ---------------------------------------------------------------------
    # API methods — thin wrappers around Slack web API endpoints.
    # ---------------------------------------------------------------------

    def auth_test
      slack_call :post, "auth.test"
    end

    def list_channels(types: "public_channel", limit: 200, cursor: nil)
      slack_call :get, "conversations.list", types: types, limit: limit, cursor: cursor
    end

    def post_message(channel:, text:, blocks: nil)
      slack_call :post, "chat.postMessage", channel: channel, text: text, blocks: blocks
    end

    def handle_webhook(event)
      Rails.logger.info("[slack] webhook event=#{event.id} type=#{event.payload_hash['type']}")
    end

    private

    # Slack returns 200 with {"ok": false, "error": "..."} on logical errors.
    # Promote that to a typed exception so callers don't have to remember.
    def slack_call(method, path, **params)
      response = client.public_send(method, path, params.compact)
      body     = response.body

      if body.is_a?(Hash) && body["ok"] == false
        raise Connectors::ApiError.new(
          "Slack #{path} failed: #{body['error']}",
          status: response.status,
          body:   body
        )
      end

      body
    end
  end
end
