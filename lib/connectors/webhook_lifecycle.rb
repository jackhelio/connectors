module Connectors
  # Runs a connector's webhook_methods callbacks: subscribe = run create
  # (skipping when check_exists already returns true), unsubscribe = run
  # delete. State is persisted into `grant.static_data[group_name]`.
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

    # Skip creation when check_exists finds an existing subscription.
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
