module Connectors
  # Fires one consumer's polling block. Explicit instance keys isolate cursors
  # and filters even when consumers share credentials. Omitting the key keeps
  # the legacy, per-grant cursor for existing single-consumer integrations.
  #
  # n8n parity: `INodeType#poll(this: IPollFunctions)` (interfaces.ts:2060),
  # cursor persistence via `getWorkflowStaticData('node')`
  # (interfaces.ts:1257-1274). The scheduler that decides *when* to fire
  # this is a workflow-roadmap concern; this primitive just exposes the
  # one-shot contract.
  class PollRunner
    GROUP = "polling".freeze

    def self.run(grant, instance_key: nil)
      new(grant, instance_key: instance_key).run
    end

    def initialize(grant, instance_key: nil)
      @grant     = grant
      @instance_key = instance_key
      if !instance_key.nil? && (!instance_key.is_a?(String) || instance_key.blank?)
        raise ArgumentError, "instance_key must be a nonempty string"
      end
      @connector = Registry.fetch(grant.connector_key)
      @block     = @connector.polling_block or
        raise Connectors::Error.new("#{@connector}: no polling block declared")
    end

    def run
      items_out      = nil
      static_data_out = nil
      update_cursor do |sub|
        items_out       = @block.call(@grant, sub)
        static_data_out = sub.dup
      end
      { items: items_out.is_a?(Array) ? items_out : [], static_data: static_data_out }
    end

    private

    def update_cursor(&block)
      if @instance_key
        state = @grant.poll_states.create_or_find_by!(instance_key: @instance_key)
        state.update_cursor!(&block)
      else
        @grant.update_static_data!(GROUP, &block)
      end
    end
  end
end
