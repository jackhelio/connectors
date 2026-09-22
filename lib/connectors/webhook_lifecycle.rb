module Connectors
  # Runs a connector's webhook_methods callbacks: subscribe = run create
  # (skipping when check_exists already returns true), unsubscribe = run
  # delete. State is persisted into `grant.static_data[group_name]`.
  #
  # n8n parity: this is the per-trigger activation orchestration that
  # `cli/src/active-workflow-runner.ts` performs around each
  # `INodeType#webhookMethods.default.*` call. We provide it as a connector-
  # side primitive so the eventual workflow-side activation manager can
  # call into it without re-implementing the gating.
  class WebhookLifecycle
    def self.subscribe(grant, hook_url:, webhook_name: :default)
      new(grant, webhook_name).subscribe(hook_url: hook_url)
    end

    def self.unsubscribe(grant, webhook_name: :default)
      new(grant, webhook_name).unsubscribe
    end

    def initialize(grant, webhook_name)
      @grant         = grant
      @webhook_name  = webhook_name.to_sym
      @connector     = Registry.fetch(grant.connector_key)
      @group         = @connector.webhook_group(@webhook_name) or
        raise Connectors::Error.new(
          "#{@connector}: no webhook_methods declared for group #{@webhook_name.inspect}"
        )
    end

    # Mirrors n8n: if checkExists returns true, skip create — provider
    # already has an equivalent subscription. Otherwise run create.
    def subscribe(hook_url:)
      result = nil
      @grant.update_static_data!(@webhook_name) do |sub|
        if @group.check_exists && @group.check_exists.call(@grant, hook_url, sub)
          result = { status: "exists", static_data: sub.dup }
          next
        end

        if @group.create.nil?
          raise Connectors::Error.new("#{@connector}: webhook_methods #{@webhook_name.inspect} has no `create` block")
        end

        created = @group.create.call(@grant, hook_url, sub)
        unless created
          raise Connectors::Error.new("#{@connector}: webhook_methods #{@webhook_name.inspect} create returned false")
        end
        result = { status: "created", static_data: sub.dup }
      end
      result
    end

    def unsubscribe
      if @group.delete.nil?
        raise Connectors::Error.new("#{@connector}: webhook_methods #{@webhook_name.inspect} has no `delete` block")
      end

      result = nil
      @grant.update_static_data!(@webhook_name) do |sub|
        ok = @group.delete.call(@grant, sub)
        unless ok
          raise Connectors::Error.new("#{@connector}: webhook_methods #{@webhook_name.inspect} delete returned false")
        end
        result = { status: "deleted", static_data: sub.dup }
      end
      result
    end
  end
end
