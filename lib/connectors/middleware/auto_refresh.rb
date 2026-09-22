require "faraday"

module Connectors
  module Middleware
    # Catches AuthenticationFailed (raised by ErrorNormalization on 401), asks
    # the connector to refresh its credentials, then retries the request once.
    # Bails out if:
    #   - the connector hasn't overridden #refresh!
    #   - the request was already retried in this call chain
    #   - the refresh itself fails (re-raises the underlying error)
    class AutoRefresh < Faraday::Middleware
      def initialize(app, grant:)
        super(app)
        @grant = grant
      end

      def call(env)
        credentials = @grant.credentials_hash.deep_dup
        request_body = env.body
        @app.call(env)
      rescue Connectors::AuthenticationFailed => e
        raise e if env[:connectors_already_refreshed]
        raise e unless refreshable?

        perform_refresh!(credentials)
        env[:connectors_already_refreshed] = true
        env[:request_headers].delete("Authorization")
        env.body = request_body
        @app.call(env)
      end

      private

      # True only when the connector subclass actually implements refresh!.
      # The base Connector#refresh! raises NotImplementedError, which we don't
      # want to trigger accidentally.
      def refreshable?
        klass = @grant.connector.class
        klass.instance_method(:refresh!).owner != Connectors::Connector
      end

      def perform_refresh!(failed_credentials)
        failure = nil
        @grant.with_persistence_lock do
          raise Connectors::AuthenticationFailed, "connection has been revoked" if @grant.revoked?
          # Another worker may have refreshed while this request was in flight.
          next unless @grant.credentials_hash == failed_credentials

          begin
            @grant.connector.refresh!
            @grant.reload if @grant.persisted?
          rescue Connectors::Error => e
            mark_errored!
            failure = e
          rescue StandardError => e
            mark_errored!
            failure = Connectors::AuthenticationFailed.new("token refresh failed: #{e.class}")
          end
        end
        # Raise after committing failure bookkeeping, not inside the transaction.
        raise failure if failure
      end

      def mark_errored!
        @grant.update_columns(status: Connectors::Grant.statuses[:errored])
      rescue StandardError
        nil
      end
    end
  end
end
