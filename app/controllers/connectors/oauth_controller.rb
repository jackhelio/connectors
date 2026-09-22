require "global_id"

module Connectors
  class OAuthController < ApplicationController
    rescue_from Connectors::Error, with: :render_auth_error
    rescue_from ActiveRecord::RecordNotFound, Connectors::UnknownConnector, with: :render_not_found

    # Omit grant_id to connect a new account; supply it to reconnect an owned
    # grant. Both popup and redirect entry points use the same authorization.
    def authorize
      start_authorization(json: false)
    end

    def authorize_json
      start_authorization(json: true)
    end

    # Split frontend/backend completion. Authorization is carried by the
    # authenticated, encrypted state issued to the owner at the start.
    def exchange
      state = OAuth::State.decode(params[:state])
      return invalid_state if state.nil?

      grant = complete_authorization(state)
      render json: grant_payload(grant).merge(
        name: grant.display_name || "#{grant.connector_key} ##{grant.id}",
        external_account_id: grant.external_account_id
      )
    end

    def callback
      state = OAuth::State.decode(params[:state])
      return invalid_state if state.nil? || state["k"] != params[:connector_key].to_s

      grant = complete_authorization(state)
      if state["r"].present?
        redirect_to state["r"], allow_other_host: true
      else
        render json: grant_payload(grant)
      end
    end

    def revoke
      grant = find_visible_grant!(params[:id], min_role: :owner)
      # Serialize revocation with refresh/reconnection on the same grant.
      grant.with_lock do
        require_grant_role!(grant, :owner)
        OAuth::Revoke.call(Registry.fetch(grant.connector_key), grant)
        grant.update!(status: :revoked)
      end
      render json: { grant_id: grant.id, status: grant.status }
    end

    private

    def start_authorization(json:)
      klass = Registry.fetch(params[:connector_key])
      owner = current_owner!
      grant = Grant.where(owner: owner).for_connector(klass.connector_key).find(params[:grant_id]) if params[:grant_id].present?

      if klass.oauth2_config&.dig(:grant_type) == "clientCredentials"
        writer = OAuth::GrantWriter.new(owner: owner, connector_class: klass,
          grant_id: grant&.id, fingerprint: (OAuth::GrantWriter.fingerprint(grant) if grant))
        connected = writer.call(OAuth::ClientCredentials.exchange(klass), name: params[:name])
        return render json: grant_payload(connected)
      end

      url = if klass.oauth1_config
        oauth1_authorize_url(klass, owner, grant)
      else
        OAuth::AuthorizeUrl.for(klass, owner: owner, grant: grant,
          return_to: params[:return_to], scope: params[:scope], name: params[:name])
      end

      if json
        render json: { authorize_url: url, connector_key: klass.connector_key.to_s }
      else
        redirect_to url, allow_other_host: true
      end
    end

    def oauth1_authorize_url(klass, owner, grant)
      callback_url = Connectors.configuration.resolved_app_callback_url(klass.connector_key)
      token = OAuth1.request_token(klass, callback_url: callback_url)
      extras = { "ts" => token["oauth_token_secret"], "n" => params[:name] }
      extras.merge!("g" => grant.id, "v" => OAuth::GrantWriter.fingerprint(grant)) if grant
      state = OAuth::State.encode(connector_key: klass.connector_key,
        owner_gid: owner.to_global_id.to_s, return_to: params[:return_to], extra: extras)
      uri = URI.parse(klass.oauth1_config[:authorize_url])
      uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s) +
        [ [ "oauth_token", token["oauth_token"] ], [ "state", state ] ])
      uri.to_s
    end

    def complete_authorization(state)
      klass = Registry.fetch(state["k"])
      owner = locate_owner(state["o"])
      raise ActiveRecord::RecordNotFound, "owner_not_found" unless owner

      writer = OAuth::GrantWriter.new(owner: owner, connector_class: klass,
        grant_id: state.dig("x", "g"), fingerprint: state.dig("x", "v"))
      writer.validate!
      tokens = if klass.oauth1_config
        OAuth1.exchange_access_token(klass, oauth_token: params[:oauth_token],
          oauth_verifier: params[:oauth_verifier], oauth_token_secret: state.dig("x", "ts"))
      else
        OAuth::TokenExchange.exchange_code(klass, code: params[:code], code_verifier: state.dig("x", "cv"))
      end
      writer.call(tokens, name: state.dig("x", "n"))
    end

    def locate_owner(gid)
      GlobalID::Locator.locate(gid)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def grant_payload(grant)
      { grant_id: grant.id, connector_key: grant.connector_key, status: grant.status }
    end

    def invalid_state
      render json: { error: "invalid_state" }, status: :unauthorized
    end

    def render_not_found(exception)
      render json: { error: exception.message }, status: :not_found
    end

    def render_auth_error(exception)
      render json: { error: exception.message }, status: :unauthorized
    end
  end
end
