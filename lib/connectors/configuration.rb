module Connectors
  # Host-app integration surface. The engine never references host constants
  # like `User` directly — it goes through this block, which the host wires up
  # in an initializer:
  #
  #   # config/initializers/connectors.rb
  #   Connectors.configure do |c|
  #     c.owner_class_name       = "User"
  #     c.current_owner_resolver = ->(controller) { controller.request.env["connectors.current_owner"] }
  #     c.host_base_url          = ENV.fetch("APP_BASE_URL", "http://localhost:3000")
  #     c.oauth_credentials = {
  #       slack:  { client_id: ENV["SLACK_CLIENT_ID"],  client_secret: ENV["SLACK_CLIENT_SECRET"] },
  #       linear: { client_id: ENV["LINEAR_CLIENT_ID"], client_secret: ENV["LINEAR_CLIENT_SECRET"] }
  #     }
  #     c.on_webhook = ->(event) { ProcessWebhookJob.perform_later(event.id) }
  #   end
  class Configuration
    attr_accessor :owner_class_name,
                  :current_owner_resolver,
                  :host_base_url,
                  :app_callback_url,
                  :on_webhook,
                  :principal_resolver,
                  :secrets_resolver,
                  :secrets_managed_fields_for

    attr_reader :oauth_credentials

    def mcp
      @mcp ||= MCP::Settings.new
    end

    def resolved_mcp_callback_url
      mcp.callback_url || "#{host_base_url.to_s.chomp('/')}#{Connectors::Engine.mount_path}/mcp/oauth/callback"
    end

    def initialize
      @oauth_credentials = {}
    end

    def oauth_credentials=(map)
      @oauth_credentials = (map || {}).transform_keys(&:to_sym)
    end

    def owner_class
      raise Error.new("Connectors.configuration.owner_class_name is not set") if owner_class_name.nil?
      owner_class_name.constantize
    end

    def oauth_credentials_for(connector_key)
      @oauth_credentials.fetch(connector_key.to_sym) do
        raise Error.new("no oauth_credentials configured for #{connector_key.inspect}")
      end
    end

    def resolve_owner(controller)
      raise Error.new("Connectors.configuration.current_owner_resolver is not set") if current_owner_resolver.nil?
      current_owner_resolver.call(controller)
    end

    # Resolve managed secrets through the host callback. Returned values
    # override stored credentials for the lifetime of the Grant instance.
    #
    #   c.secrets_resolver = ->(grant) { vault_client.read(grant.external_ref) }
    def resolve_secrets(grant)
      return {} if secrets_resolver.nil?
      secrets_resolver.call(grant).to_h.transform_keys(&:to_s)
    end

    # Vault-sourced field names exposed as __overwritten_properties
    # so clients can display the fields as managed.
    def managed_fields_for(connector_key)
      return [] if secrets_managed_fields_for.nil?
      Array(secrets_managed_fields_for.call(connector_key)).map(&:to_s)
    end

    def resolve_principals(controller)
      return principal_resolver.call(controller) if principal_resolver
      owner = resolve_owner(controller)
      return [] if owner.nil?
      [ [ owner.class.name, owner.id ] ]
    end

    # Use the configured frontend callback URL or the mounted engine callback.
    # Register the resulting URL with the OAuth provider.
    def resolved_app_callback_url(connector_key)
      return app_callback_url if app_callback_url.present?
      base = host_base_url or
        raise Error.new("Connectors.configuration.host_base_url is not set")
      "#{base.chomp('/')}#{Connectors::Engine.mount_path}/#{connector_key}/callback"
    end
  end

  class << self
    def configure
      yield configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # For tests — reset between cases.
    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
