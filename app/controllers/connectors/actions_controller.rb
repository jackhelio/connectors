module Connectors
  # HTTP surface for invoking a connector's declared actions.
  #
  #   POST /connectors/credentials/:id/actions/:name
  #   { "data": { "to": "alice@example.com", "subject": "Hi", "html": "..." } }
  #
  # Looks up the Grant (scoped to the current owner + any shares), resolves
  # the action on the grant's connector class, validates the input against
  # the action's param schema, then dispatches through `ActionRunner`. The
  # response envelope is always `{ status: "ok"|"error", action:, ... }` so
  # frontends and workflow executors consume the same shape.
  class ActionsController < ApplicationController
    # Order matters: Rails `rescue_from` iterates in REVERSE declaration
    # order, so the more-specific subclasses must be declared AFTER
    # `Connectors::Error` to be matched first. UnknownAction is a
    # Connectors::Error subclass — without its own handler, the generic
    # Error path would return 401 instead of 404.
    rescue_from Connectors::Error,            with: :render_unauthorized
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from Connectors::UnknownAction,    with: :render_not_found

    # GET /connectors/credentials/:id/actions
    # Lists the actions available on the grant's connector. Same data as
    # /connectors/types/:name → actions[], but resolved against the actual
    # grant so the frontend can render an "actions for this connection"
    # picker without re-fetching the catalog.
    def index
      grant = find_visible_grant!(params[:id])
      render json: { actions: grant.connector.class.actions.map(&:to_manifest) }
    end

    # POST /connectors/credentials/:id/actions/:name
    # Body: { data: {...} }   — the action's input params.
    def create
      grant = find_visible_grant!(params[:id], min_role: :editor)
      input = (params[:data] || {}).to_unsafe_h
      result = Connectors::ActionRunner.call(grant, params[:name], input)

      status_code =
        if result[:status] == Connectors::ActionRunner::OK
          :ok
        else
          case result.dig(:error, :type)
          when "invalid_params"         then :unprocessable_content
          when "authentication_failed"  then :unauthorized
          when "forbidden"              then :forbidden
          when "rate_limited"           then :too_many_requests
          else                               :bad_gateway
          end
        end

      render json: result, status: status_code
    end

    private

    def render_not_found(e);    render(json: { error: e.message }, status: :not_found);    end
    def render_unauthorized(e); render(json: { error: e.message }, status: :unauthorized); end
  end
end
