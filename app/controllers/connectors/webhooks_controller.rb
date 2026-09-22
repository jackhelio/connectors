module Connectors
  class WebhooksController < ApplicationController
    rescue_from Connectors::UnknownConnector,           with: :render_not_found
    rescue_from ActiveRecord::RecordNotFound,           with: :render_not_found
    rescue_from Connectors::Webhooks::SignatureInvalid, with: :render_unauthorized

    # POST /:connector_key/webhook                 (app-level: grant resolved from payload)
    # POST /:connector_key/:grant_id/webhook       (grant_id explicit in URL)
    #
    # Providers like Slack only allow one webhook URL per app — for those,
    # leave grant_id out and implement Connector.resolve_grant_from_webhook
    # to look up the grant by the payload's team/account id.
    def receive
      connector_class = Registry.fetch(params[:connector_key])
      payload         = request_payload

      grant = params[:grant_id].present? ? Grant.for_connector(connector_class.connector_key).find(params[:grant_id]) : nil

      verify_signature!(connector_class, grant)

      # URL-verification ping (Slack et al.) — short-circuit before grant lookup.
      if (challenge = connector_class.webhook_challenge(payload))
        return render(json: challenge)
      end

      grant ||= connector_class.resolve_grant_from_webhook(payload, request)
      if grant.nil? || grant.connector_key != connector_class.connector_key.to_s
        return render(json: { error: "no matching grant for webhook" }, status: :not_found)
      end

      external_id = extract_external_event_id(payload)
      if external_id.present? &&
         (existing = WebhookEvent.find_by(connector_key: grant.connector_key, external_event_id: external_id))
        return render(json: { event_id: existing.id, status: "duplicate" }, status: :ok)
      end

      event = WebhookEvent.create!(
        grant:             grant,
        connector_key:     grant.connector_key,
        external_event_id: external_id,
        payload:           payload,
        raw_body:          request.raw_post,
        headers:           inbound_headers,
        query:             request.query_parameters.to_h,
        webhook_name:      (params[:webhook_name].presence || "default").to_s,
        signature:         signature_header,
        received_at:       Time.current,
        status:            :received
      )

      DeliverWebhookJob.perform_later(event.id)
      render json: { event_id: event.id, status: "accepted" }, status: :accepted
    end

    private

    def verify_signature!(connector_class, grant)
      verifier = connector_class.webhook_verifier
      return if verifier.nil?
      verifier.verify!(grant, request)
    end

    def request_payload
      ct = request.content_type.to_s
      if ct.include?("json")
        body = request.raw_post
        body.empty? ? {} : (JSON.parse(body) rescue {})
      else
        request.request_parameters.to_unsafe_h
      end
    end

    def extract_external_event_id(payload)
      return nil unless payload.is_a?(Hash)
      payload["event_id"] || payload["id"] || payload.dig("event", "id")
    end

    def signature_header
      request.headers["X-Slack-Signature"]      ||
        request.headers["Stripe-Signature"]     ||
        request.headers["X-Hub-Signature-256"]  ||
        request.headers["X-Signature"]          ||
        request.headers["Signature"]
    end

    # Capture every HTTP_* header on the inbound request, normalized to
    # lowercase + dashed keys (`http_x_hub_signature` → `x-hub-signature`),
    # so the n8n-style `ctx.headers["stripe-signature"]` access works
    # without callers having to know about Rack's mangling.
    def inbound_headers
      request.headers.env.each_with_object({}) do |(k, v), out|
        next unless k.start_with?("HTTP_")
        name = k.sub("HTTP_", "").downcase.tr("_", "-")
        out[name] = v.is_a?(String) ? v : v.to_s
      end.merge(
        # Content-Type/Length aren't prefixed `HTTP_` in Rack
        "content-type"   => request.content_type.to_s,
        "content-length" => request.content_length.to_s
      ).reject { |_, v| v.nil? || v.empty? }
    end

    def render_not_found(e);    render(json: { error: e.message }, status: :not_found);    end
    def render_unauthorized(e); render(json: { error: e.message }, status: :unauthorized); end
  end
end
