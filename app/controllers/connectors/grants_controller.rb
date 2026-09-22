module Connectors
  # Lists the current owner's authorized third-party accounts. The frontend
  # uses this to render the "Connected accounts" picker on credential fields
  # and the Settings → Connections page.
  #
  # Filter by connector with `?connector_key=slack`.
  #
  # Credentials are never serialized — only metadata (status, expiry, the
  # provider-side account id, and the granted scope list).
  class GrantsController < ApplicationController
    rescue_from Connectors::Error,             with: :render_unauthorized
    rescue_from ActiveRecord::RecordNotFound,  with: :render_not_found
    rescue_from ArgumentError, with: :render_bad_request

    # GET /connectors/grants
    def index
      owner  = current_owner!
      grants = Grant.where(owner: owner)
      grants = grants.for_connector(params[:connector_key]) if params[:connector_key].present?
      render json: { grants: grants.order(updated_at: :desc).map { |g| serialize(g) } }
    end

    # POST /connectors/grants/:id/test
    # Runs the connector's declared `test_request` against the live
    # provider using THIS grant's credentials. Returns `{status, message}`
    # — n8n parity (packages/cli/src/credentials/credentials.controller.ts:141-152).
    def test
      owner = current_owner!
      grant = Grant.where(owner: owner).find(params[:id])
      result = Connectors::CredentialTester.run(grant)
      status_code = result[:status] == Connectors::CredentialTester::OK ? :ok : :unprocessable_content
      render json: result, status: status_code
    end

    # POST /connectors/grants/:id/webhook_subscribe
    # Runs the connector's `webhook_methods` create flow (skipping when
    # check_exists already returns true). Manual entry point for Phase 6 —
    # the workflow activation manager will call into this same lifecycle
    # primitive (`Connectors::WebhookLifecycle.subscribe`) once it ships.
    #
    # Params:
    #   webhook_name=:default — group name (multi-webhook providers)
    #   hook_url=<override>   — defaults to the per-grant or app-level URL
    def webhook_subscribe
      owner = current_owner!
      grant = Grant.where(owner: owner).find(params[:id])

      name = (params[:webhook_name].presence || :default).to_sym
      url  = params[:hook_url].presence || default_hook_url(grant)

      result = Connectors::WebhookLifecycle.subscribe(grant, hook_url: url, webhook_name: name)
      render json: result.merge(webhook_name: name, hook_url: url)
    end

    # DELETE /connectors/grants/:id/webhook_subscribe
    def webhook_unsubscribe
      owner = current_owner!
      grant = Grant.where(owner: owner).find(params[:id])
      name  = (params[:webhook_name].presence || :default).to_sym
      result = Connectors::WebhookLifecycle.unsubscribe(grant, webhook_name: name)
      render json: result.merge(webhook_name: name)
    end

    # POST /connectors/grants/:id/poll
    # Runs the connector's `polling` block once. Manual harness for Phase 8 —
    # the workflow-side scheduler will call into `Connectors::PollRunner.run`
    # directly once it ships.
    def poll
      owner  = current_owner!
      grant  = Grant.where(owner: owner).find(params[:id])
      result = Connectors::PollRunner.run(grant, instance_key: params[:instance_key])
      render json: result
    end

    private

    def default_hook_url(grant)
      base            = Connectors.configuration.host_base_url.to_s.chomp("/")
      mount           = Connectors::Engine.mount_path
      connector_class = Registry.fetch(grant.connector_key)
      if connector_class.webhook_style == :app_level
        "#{base}#{mount}/#{grant.connector_key}/webhook"
      else
        "#{base}#{mount}/#{grant.connector_key}/#{grant.id}/webhook"
      end
    end

    def serialize(grant)
      {
        id:                  grant.id,
        connector_key:       grant.connector_key,
        display_name:        grant.display_name,
        external_account_id: grant.external_account_id,
        status:              grant.status,
        expires_at:          grant.expires_at,
        last_used_at:        grant.last_used_at,
        scopes:              extract_scopes(grant)
      }
    end

    # Most OAuth2 providers return scopes as a comma- or space-separated string
    # in the token response and we store it verbatim. Normalize to an array so
    # the frontend doesn't have to know the provider's separator convention.
    def extract_scopes(grant)
      raw = grant.credentials_hash["scope"]
      return nil if raw.nil?
      return raw if raw.is_a?(Array)
      raw.to_s.split(/[,\s]+/).reject(&:empty?)
    end

    def render_unauthorized(exception)
      render json: { error: exception.message }, status: :unauthorized
    end

    def render_not_found(exception)
      render json: { error: exception.message }, status: :not_found
    end

    def render_bad_request(exception)
      render json: { error: exception.message }, status: :bad_request
    end
  end
end
