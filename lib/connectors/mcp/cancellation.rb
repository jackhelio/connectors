module Connectors
  module MCP
    class Cancellation
      def initialize
        @mutex = Mutex.new
        @cancelled = false
        @callbacks = {}
      end

      def cancel
        callbacks = @mutex.synchronize do
          @cancelled = true
          @callbacks.values.dup
        end
        callbacks.each(&:call)
      end

      def check!
        raise Cancelled, "MCP request cancelled" if @mutex.synchronize { @cancelled }
      end

      def attach(&abort)
        @mutex.synchronize do
          raise Cancelled, "MCP request cancelled" if @cancelled
          key = Object.new
          @callbacks[key] = abort
          key
        end
      end

      def detach(key)
        @mutex.synchronize { @callbacks.delete(key) }
      end
    end
  end
end
