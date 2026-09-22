module Connectors
  # Declarative webhook subscription lifecycle. Mirrors n8n's
  # `INodeType.webhookMethods.default.{checkExists, create, delete}`
  # (interfaces.ts:2017, 2091-2095; reference impl in
  # `packages/nodes-base/nodes/Postmark/PostmarkTrigger.node.ts:114-247`).
  #
  # Provider-specific contract:
  #
  #   webhook_methods do                    # implicit group: :default
  #     check_exists do |grant, hook_url, static_data|
  #       webhooks = grant.connector.client.get("hooks").body["Webhooks"]
  #       found    = webhooks.find { |h| h["Url"] == hook_url }
  #       static_data["webhook_id"] = found["ID"] if found
  #       !found.nil?
  #     end
  #
  #     create do |grant, hook_url, static_data|
  #       resp = grant.connector.client.post("hooks", { url: hook_url }).body
  #       static_data["webhook_id"] = resp["ID"]
  #       true
  #     end
  #
  #     delete do |grant, static_data|
  #       grant.connector.client.delete("hooks/#{static_data['webhook_id']}")
  #       static_data.delete("webhook_id")
  #       true
  #     end
  #   end
  #
  # Multi-webhook providers (Slack has separate `default` event-delivery
  # group + `setup` URL-verification group — n8n's `webhooks: IWebhookDescription[]`
  # at interfaces.ts:2600) declare additional named groups:
  #
  #   webhook_methods :setup    do ... end
  #   webhook_methods :default  do ... end
  #
  # The DSL builder for the inner block of `webhook_methods`. Captures each
  # of the three callbacks into a Group struct.
  class WebhookMethodsBuilder
    attr_reader :check_exists_block, :create_block, :delete_block

    def check_exists(&block) @check_exists_block = block end
    def create(&block)       @create_block       = block end
    def delete(&block)       @delete_block       = block end
  end

  WebhookGroup = Struct.new(:name, :check_exists, :create, :delete)
end
