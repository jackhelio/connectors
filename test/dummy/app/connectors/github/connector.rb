module Github
  # GitHub OAuth App connector.
  # https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps
  #
  # Webhook style: per-grant (each installation/repo configures its own URL
  # with the grant id in it, and its own signing secret stored on the Grant).
  # Verification: X-Hub-Signature-256 HMAC-SHA256 of the raw body using the
  # grant's `webhook_secret`.
  class Connector < Connectors::Connector
    connector key:               :github,
              auth:              :oauth2,
              base_url:          "https://api.github.com",
              display_name:      "GitHub",
              icon:              "https://github.githubassets.com/favicons/favicon.svg",
              icon_color:        "#181717",
              documentation_url: "https://docs.github.com/en/rest"

    oauth2 authorize_url: "https://github.com/login/oauth/authorize",
           token_url:     "https://github.com/login/oauth/access_token",
           scope:         "repo read:user",
           authentication: "body"

    # GitHub OAuth — inherits the canonical OAuth2 form and locks the
    # endpoints + default scopes. The `webhook_secret` is the ONE manual
    # field admins paste (from the repo's webhook config), so it's declared
    # as a normal string field outside the OAuth2 inheritance chain.
    credentials do
      extends :oauth2

      field :authorization_url, type: "hidden",
                                default: "https://github.com/login/oauth/authorize"
      field :access_token_url,  type: "hidden",
                                default: "https://github.com/login/oauth/access_token"
      field :grant_type,        type: "hidden", default: "authorizationCode"
      field :scope,             type: "hidden", default: "repo read:user"

      field :webhook_secret,
            type:         "string",
            display_name: "Webhook Secret",
            secret:       true,
            description:  "Paste the signing secret from your GitHub repo's webhook config. " \
                          "Used to verify X-Hub-Signature-256 on inbound deliveries."
    end

    rate_limit 5000, per: 3600

    verify_webhooks_with Github::WebhookVerifier

    # GitHub returns the access token in the standard OAuth2 shape. We
    # extract `login` + `user_id` from /user so webhooks can route by them
    # without extra API calls.
    def self.post_token_exchange(_raw_response, normalized)
      access_token = normalized["access_token"]
      return normalized if access_token.to_s.empty?

      response = Faraday.new(url: "https://api.github.com") do |f|
        f.request  :json
        f.response :json, content_type: /\bjson$/
      end.get("user") do |req|
        req.headers["Authorization"] = "Bearer #{access_token}"
        req.headers["Accept"]        = "application/vnd.github+json"
      end

      user = response.body || {}
      normalized.merge("login" => user["login"], "user_id" => user["id"]).compact
    end

    # Denormalize the GitHub user id onto Grant#external_account_id so
    # webhook routing / per-account UIs can look up grants without
    # decrypting credentials.
    def self.external_account_id_from_credentials(credentials)
      credentials["user_id"]&.to_s
    end

    # ---------------------------------------------------------------------
    # API methods
    # ---------------------------------------------------------------------

    def get_user
      client.get("user").body
    end

    def list_repos(per_page: 30, page: 1)
      client.get("user/repos", per_page: per_page, page: page).body
    end

    def create_issue(repo:, title:, body: nil, labels: nil)
      client.post("repos/#{repo}/issues", { title: title, body: body, labels: labels }.compact).body
    end

    def handle_webhook(event)
      Rails.logger.info("[github] webhook event=#{event.id} type=#{event.payload_hash['action']}")
    end
  end
end
