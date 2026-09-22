module Connectors
  # In-memory map of connector_key => Connector subclass. Populated when each
  # connector class is autoloaded (via the `connector key:, ...` DSL call in
  # the class body).
  class Registry
    class << self
      def register(key, klass)
        store[key.to_sym] = klass
      end

      def fetch(key)
        store.fetch(key.to_sym) { raise UnknownConnector.new(key, known: store.keys) }
      end

      def registered?(key)
        store.key?(key.to_sym)
      end

      def all
        store.dup
      end

      def keys
        store.keys
      end

      def clear!
        store.clear
      end

      private

      def store
        @store ||= {}
      end
    end
  end
end
