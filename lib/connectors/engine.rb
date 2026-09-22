ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "OAuth"
end

module Connectors
  class Engine < ::Rails::Engine
    isolate_namespace Connectors

    config.generators.api_only = true

    initializer :connectors_mcp_filter_secrets do |app|
      app.config.filter_parameters += %i[bearer_token mcp_oauth client_information code state authorization_context arguments responses headers]
    end

    # Rails's built-in append_migrations sometimes misses path-based engine
    # sources, so wire our migration directory in explicitly. Without this,
    # `bin/rails db:migrate` in a host app silently skips the engine's
    # tables.
    initializer :connectors_append_engine_migrations do |app|
      # Rails adds this engine's paths itself when running its Rake tasks.
      # Adding them here too makes every migration appear twice.
      next if defined?(ENGINE_ROOT) && File.expand_path(ENGINE_ROOT) == root.to_s

      paths = app.config.paths["db/migrate"]
      own   = ::Connectors::Engine.root.join("db/migrate").to_s
      paths << own unless paths.to_a.include?(own)
    end

    # Register canonical base credential schemas so connectors can declare
    # `extends :oauth2` (and inherit the OAuth2 form fields). The registry
    # is process-local; reset between tests via the spec helper.
    initializer :connectors_register_credential_types do
      reg = ::Connectors::CredentialTypeRegistry
      reg.register(:oauth2,           reg::OAUTH2)
      # Phase 4 — n8n's `OAuth1Api` base type
      # (packages/nodes-base/credentials/OAuth1Api.credentials.ts:1-72).
      reg.register(:oauth1_api,       reg::OAUTH1)
      # Phase 2 — n8n's generic HTTP auth credential types
      # (packages/nodes-base/credentials/Http*Auth.credentials.ts).
      reg.register(:http_basic_auth,  ::Connectors::CredentialTypes::HTTP_BASIC_AUTH)
      reg.register(:http_bearer_auth, ::Connectors::CredentialTypes::HTTP_BEARER_AUTH)
      reg.register(:http_header_auth, ::Connectors::CredentialTypes::HTTP_HEADER_AUTH)
      reg.register(:http_query_auth,  ::Connectors::CredentialTypes::HTTP_QUERY_AUTH)
      reg.register(:http_digest_auth, ::Connectors::CredentialTypes::HTTP_DIGEST_AUTH)
      reg.register(:http_custom_auth, ::Connectors::CredentialTypes::HTTP_CUSTOM_AUTH)
    end

    # Connector classes register themselves with Connectors::Registry as a
    # side effect of being loaded (the `connector key:, ...` DSL call in
    # the class body). Zeitwerk autoloads on-demand though — so without
    # something pulling each class in, `GET /connectors/types` would return
    # an empty list in dev. Force-load every `app/connectors/<key>/connector.rb`
    # on boot so the registry is populated before the first request.
    #
    # Walks every Engine root (including the host's main app) and globs each
    # one's `app/connectors/` — the union covers shipped connectors here in
    # the engine, plus host-app overrides under flow-api's own
    # `app/connectors/` (if/when the host decides to ship its own).
    config.to_prepare do
      ::Rails::Engine.subclasses.map(&:instance).push(::Rails.application).uniq.each do |engine|
        dir = engine.root.join("app/connectors")
        next unless dir.directory?
        dir.glob("*/connector.rb").each { |f| require_dependency f.to_s }
      end
    end

    # Returns the path the engine is actually mounted at in the host app —
    # `/connectors`, `/api/v1/connectors`, anything the host chose. Walks
    # the host's compiled route table to find this engine's mount; falls
    # back to `/connectors` only when the engine isn't mounted (isolated
    # specs that boot without a full app). Cached after first lookup; the
    # `to_prepare` block above ensures it's still warm after code reloads.
    #
    # Used by every URL builder in the engine that needs to round-trip an
    # absolute URL back to the engine's own routes (OAuth callback,
    # default webhook URL, types-endpoint `redirect_uri` field) so that
    # `mount Engine => "/api/v1/connectors"` Just Works without any host
    # configuration beyond the routes line itself.
    def self.mount_path
      return @mount_path if defined?(@mount_path) && @mount_path
      @mount_path = lookup_mount_path
    end

    # Reset the cache. Call after re-mounting in a spec; the host never
    # needs this in normal operation.
    def self.reset_mount_path!
      remove_instance_variable(:@mount_path) if defined?(@mount_path)
    end

    def self.lookup_mount_path
      return "/connectors" unless defined?(::Rails) && ::Rails.application&.routes
      ::Rails.application.routes.routes.each do |route|
        next unless route_targets_engine?(route)
        path = route.path.spec.to_s.dup
        path.chomp!("(.:format)")
        path.chomp!("/")
        return path.empty? ? "/" : path
      end
      "/connectors"
    end

    # Mounted engines sit at varying depths in `route.app`'s wrapper chain.
    # In a bare host (`mount Connectors::Engine => "/connectors"`) the
    # chain is `Constraints → Connectors::Engine`. Inside a namespace
    # (`namespace :api { scope "v1" { mount Connectors::Engine => "/connectors" } }`)
    # the chain becomes `Constraints → Connectors::Engine → LazyRouteSet`,
    # so unwrapping to the terminal misses the engine entirely. Walk every
    # layer instead and stop the first time we encounter `self`.
    def self.route_targets_engine?(route)
      target  = route.app
      visited = {}
      while target && !visited[target.object_id]
        return true if target == self
        visited[target.object_id] = true
        return false unless target.respond_to?(:app)
        nxt = target.app
        return false if nxt == target
        target = nxt
      end
      false
    end
  end
end
