module Connectors
  # n8n-shaped credential CRUD. Underneath, a "credential" is a Grant — but
  # this controller exposes it under the vocabulary the frontend uses
  # (matches packages/cli/src/credentials/credentials.controller.ts:67-411).
  #
  # The paste-the-key flow lives here: `POST /credentials` with `{type,
  # name, data}` creates a Grant directly without the OAuth dance.
  # OAuth-issued grants continue to flow through OAuthController#callback
  # and show up in this list automatically.
  class CredentialsController < ApplicationController
    # Order matters: Rails `rescue_from` iterates in REVERSE declaration
    # order, so the more-specific subclasses must be declared AFTER
    # `Connectors::Error` to be matched first.
    rescue_from Connectors::Error,              with: :render_unauthorized
    rescue_from ActiveRecord::RecordNotFound,   with: :render_not_found
    rescue_from Connectors::UnknownConnector,   with: :render_not_found
    rescue_from MCP::ValidationError, MCP::ConfigurationRequired do |error|
      render json: { error: error.message }, status: :unprocessable_content
    end

    # GET /connectors/credentials
    #   ?type=resend                # filter by connector type
    #   ?include_data=true          # owner-only secrets; MCP public config only
    #
    # Returns the union of: credentials this owner owns + credentials shared
    # with any of the requester's principals (User, Team, Project — whatever
    # the host's `principal_resolver` returns). n8n parity:
    # enterprise/credentials.controller.ee.ts.
    def index
      grants = visible_grants
      grants = grants.for_connector(params[:type]) if params[:type].present?
      include_data = params[:include_data].to_s == "true"

      render json: { credentials: grants.order(updated_at: :desc).map { |g| serialize(g, include_data: include_data) } }
    end

    # GET /connectors/credentials/for-workflow
    def for_workflow
      grants = visible_grants
      grants = grants.for_connector(params[:type]) if params[:type].present?
      render json: { credentials: grants.order(updated_at: :desc).map { |g| serialize(g) } }
    end

    # GET /connectors/credentials/:id
    def show
      grant = find_visible_grant!(params[:id])
      render json: serialize(grant, include_data: params[:include_data].to_s == "true")
    end

    # POST /connectors/credentials
    # Body: { type, name, data?, external_ref?, is_managed? }
    #
    # When `is_managed: true` is passed (typically alongside `external_ref:
    # "vault/path/foo"`), the DB only stores the reference + non-sensitive
    # field defaults; the actual credential values come from the host's
    # `secrets_resolver` at request time. n8n parity: external-secrets EE
    # module (external-secrets.controller.ee.ts).
    def create
      owner = current_owner!
      type  = params.fetch(:type)
      klass = Registry.fetch(type)   # raises UnknownConnector → 404 if bogus

      is_managed = [ true, "true", "1", 1 ].include?(params[:is_managed])
      if is_managed && klass.skip_managed_creation?
        raise Connectors::Error.new("managed credentials are disabled for #{type.inspect}")
      end

      data = (params[:data] || ActionController::Parameters.new).to_unsafe_h
      data = MCP::ConnectionConfig.resolve(data, connector: klass, require_secrets: !is_managed) if klass.mcp?
      grant = Grant.create!(
        owner:         owner,
        connector_key: type.to_s,
        display_name:  params[:name].presence,
        credentials:   data,
        external_ref:  params[:external_ref].presence,
        is_managed:    is_managed,
        status:        :active,
        last_used_at:  Time.current
      )
      render json: serialize(grant), status: :created
    end

    # GET /connectors/credentials/new?type=resend
    # Server-generated unique default name ("Resend account 3"). n8n parity:
    # `credentials.controller.ts:100-111`. The frontend pre-fills the name
    # field with the response so the user can rename or accept the default.
    def new
      current_owner!
      type = params.fetch(:type)
      klass = Registry.fetch(type)
      base  = klass.display_name || type.to_s.humanize
      base += " account"

      taken = Grant.where(connector_key: type.to_s)
                   .where("display_name LIKE ?", "#{base}%")
                   .pluck(:display_name)
                   .compact
      n = 1
      n += 1 while taken.include?("#{base} #{n}")
      render json: { name: "#{base} #{n}" }
    end

    # PATCH /connectors/credentials/:id
    # Body: { name?, data? }   — data is merged into existing credentials.
    # Requires `editor` (or owner) role.
    def update
      grant = find_visible_grant!(params[:id], min_role: :editor)

      if params.key?(:data)
        new_data = (params[:data] || {}).to_unsafe_h
        klass = Registry.fetch(grant.connector_key)
        if klass.mcp?
          require_grant_role!(grant, :owner)
          MCP::ConnectionConfig.resolve(grant.credentials_hash.except("mcp_oauth").merge(new_data), connector: klass)
          new_data["mcp_oauth"] = nil
        end
        grant.update_credentials!(new_data)
      end
      grant.display_name = params[:name] if params.key?(:name)
      grant.save! if grant.changed?

      render json: serialize(grant)
    end

    # DELETE /connectors/credentials/:id — owner only.
    def destroy
      find_visible_grant!(params[:id], min_role: :owner).destroy
      head :no_content
    end

    # PUT /connectors/credentials/:id/share
    # Body: { principal_type: "User"|"Team"|..., principal_id: <uuid>, role: "viewer"|"editor" }
    # Owner only. Adds (or updates) a share row.
    def share
      grant = find_visible_grant!(params[:id], min_role: :owner)
      share = CredentialShare.find_or_initialize_by(
        grant:          grant,
        principal_type: params.fetch(:principal_type),
        principal_id:   params.fetch(:principal_id).to_s
      )
      share.role = params.fetch(:role, "viewer")
      share.save!
      render json: serialize_share(share)
    end

    # DELETE /connectors/credentials/:id/share
    # Body: { principal_type, principal_id: <uuid> }
    def unshare
      grant = find_visible_grant!(params[:id], min_role: :owner)
      share = grant.shares.find_by!(
        principal_type: params.fetch(:principal_type),
        principal_id:   params.fetch(:principal_id).to_s
      )
      share.destroy
      head :no_content
    end

    # PUT /connectors/credentials/:id/transfer
    # Body: { owner_id: <uuid> } — moves ownership to a different owner.
    # n8n parity: enterprise/credentials.controller.ee.ts transfer endpoint.
    def transfer
      grant         = find_visible_grant!(params[:id], min_role: :owner)
      new_owner_klass = Connectors.configuration.owner_class_name.constantize
      new_owner       = new_owner_klass.find(params.fetch(:owner_id).to_s)
      grant.update!(owner: new_owner)
      render json: serialize(grant)
    end

    # POST /connectors/credentials/test
    # Test an UNSAVED credential. Body: { type, data: {...} }
    # Spins up a transient Grant (not persisted) and runs the connector's
    # declared test_request through it.
    def test_unsaved
      type = params.fetch(:type)
      data = (params[:data] || {}).to_unsafe_h

      transient = Grant.new(
        owner:         current_owner!,
        connector_key: type.to_s,
        credentials:   data,
        status:        :active
      )
      # Bypass save — we just need #connector and #credentials_hash.
      transient.define_singleton_method(:credentials_hash) { credentials || {} }

      result      = Connectors::CredentialTester.run(transient)
      status_code = result[:status] == Connectors::CredentialTester::OK ? :ok : :unprocessable_content
      render json: result, status: status_code
    end

    private

    def serialize_share(share)
      {
        id:             share.id,
        grant_id:       share.grant_id,
        principal_type: share.principal_type,
        principal_id:   share.principal_id,
        role:           share.role
      }
    end

    def serialize(grant, include_data: false)
      h = {
        id:                  grant.id,
        type:                grant.connector_key,                       # n8n name
        connector_key:       grant.connector_key,                       # @deprecated alias
        name:                grant.display_name || "#{grant.connector_key} ##{grant.id}",
        external_account_id: grant.external_account_id,
        status:              grant.status,
        expires_at:          grant.expires_at,
        last_used_at:        grant.last_used_at,
        created_at:          grant.created_at,
        updated_at:          grant.updated_at,
        scopes:              extract_scopes(grant),
        # Phase 10 — external secrets manager. `is_managed: true` means the
        # actual credential values are vault-sourced; `external_ref` is the
        # opaque key the host's `secrets_resolver` uses to look them up.
        is_managed:          grant.is_managed,
        external_ref:        grant.external_ref,
        # n8n's `__overwrittenProperties` (interfaces.ts:382) but per-grant
        # so the editor can show "this field comes from Vault: <api_key>".
        __overwritten_properties: grant.is_managed ? Connectors.configuration.managed_fields_for(grant.connector_key) : []
      }
      if include_data
        if Registry.fetch(grant.connector_key).mcp?
          h[:data] = MCP::ConnectionConfig.public_data(grant.credentials_hash)
        elsif role_for(grant, owner: current_owner!) == "owner"
          h[:data] = grant.credentials_hash
        end
      end
      h
    end

    def extract_scopes(grant)
      raw = grant.credentials_hash["scope"]
      return nil if raw.nil?
      return raw if raw.is_a?(Array)
      raw.to_s.split(/[,\s]+/).reject(&:empty?)
    end

    def render_not_found(e);     render(json: { error: e.message }, status: :not_found);     end
    def render_unauthorized(e);  render(json: { error: e.message }, status: :unauthorized);  end
  end
end
