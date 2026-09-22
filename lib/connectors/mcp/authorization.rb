module Connectors
  module MCP
    class Authorization
      def initialize(grant:, actor:, principals: nil)
        @access = Access.new(grant: grant, actor: actor, principals: principals)
      end

      def start(challenge: {})
        @access.require!(:owner)
        data = @access.configuration
        raise ConfigurationRequired, "Connection does not use OAuth" unless data["auth_mode"] == "oauth"
        fingerprint = @access.fingerprint
        resource, metadata = AuthorizationDiscovery.new(server_url: data.fetch("server_url"), issuer: data["authorization_server"]).call(challenge)
        unless Array(metadata["code_challenge_methods_supported"]).include?("S256")
          raise ConfigurationRequired, "Authorization server must advertise PKCE S256"
        end
        callback = callback_url
        HTTP.new.validate_url!(callback)
        scopes = requested_scopes(data, resource, metadata, challenge)
        client = register_client(data, metadata, callback)
        pkce = ::MCP::Client::OAuth::PKCE.generate
        state = SecureRandom.urlsafe_base64(32)
        @access.require!(:owner)
        raise AccessDenied, "MCP configuration changed" unless fingerprint == @access.fingerprint
        payload = { "metadata" => metadata, "client" => client, "resource" => ::MCP::Client::OAuth::Discovery.canonicalize_url(data.fetch("server_url")),
          "callback" => callback, "code_verifier" => pkce.fetch(:code_verifier), "requested_scopes" => scopes }
        Connectors::McpAuthorization.create!(grant: @access.grant, actor_key: @access.actor_key, fingerprint: fingerprint,
          state_digest: Digest::SHA256.hexdigest(state), expires_at: Connectors.configuration.mcp.transaction_ttl.from_now, payload: payload)
        uri = URI(metadata.fetch("authorization_endpoint"))
        query = URI.decode_www_form(uri.query.to_s).to_h.merge("response_type" => "code", "client_id" => client.fetch("client_id"),
          "redirect_uri" => callback, "state" => state, "code_challenge" => pkce.fetch(:code_challenge), "code_challenge_method" => "S256", "resource" => payload.fetch("resource"))
        query["scope"] = scopes.join(" ") if scopes.any?
        uri.query = URI.encode_www_form(query)
        uri.to_s
      end

      def complete(state:, code: nil, iss: nil, error: nil)
        @access.require!(:owner)
        record = Connectors::McpAuthorization.find_by(state_digest: Digest::SHA256.hexdigest(state.to_s))
        raise AccessDenied, "Invalid MCP authorization state" unless record
        payload = record.claim!(@access)
        claimed = true
        metadata = payload.fetch("metadata")
        if (iss && iss != metadata["issuer"]) || (iss.nil? && metadata["authorization_response_iss_parameter_supported"] == true)
          raise AccessDenied, "Authorization response issuer mismatch"
        end
        raise AccessDenied, "Authorization was denied or incomplete" if error || code.to_s.empty?
        locked do
          @access.require!(:owner)
          raise AccessDenied, "MCP configuration changed" unless record.fingerprint == @access.fingerprint
          tokens = TokenEndpoint.exchange(metadata: metadata, client: resolve_client(payload.fetch("client")), params: {
            "grant_type" => "authorization_code", "code" => code, "redirect_uri" => payload.fetch("callback"),
            "code_verifier" => payload.fetch("code_verifier"), "resource" => payload.fetch("resource") })
          persist(payload, tokens)
        end
        record.update!(status: "complete", payload: { "cleared" => true })
        true
      ensure
        record.update!(status: "failed", payload: { "cleared" => true }) if claimed && record.status == "claimed"
      end

      def access_token
        @access.require!
        stored = @access.grant.credentials_hash["mcp_oauth"]
        raise AuthorizationRequired unless stored && stored["fingerprint"] == @access.fingerprint
        tokens = stored.fetch("tokens")
        return tokens.fetch("access_token") unless tokens["expires_at"] && tokens["expires_at"] <= Time.current.to_f + 30
        refresh(expected_token: tokens["access_token"])
      end

      def refresh(expected_token:)
        invalid = false
        token = locked do
          @access.require!
          stored = @access.grant.credentials_hash["mcp_oauth"]
          raise AuthorizationRequired unless stored && stored["fingerprint"] == @access.fingerprint
          previous = stored.fetch("tokens")
          return previous.fetch("access_token") unless previous["access_token"] == expected_token
          raise AuthorizationRequired if previous["refresh_token"].blank?
          begin
            tokens = TokenEndpoint.exchange(metadata: stored.fetch("metadata"), client: resolve_client(stored.fetch("client")), params: {
              "grant_type" => "refresh_token", "refresh_token" => previous.fetch("refresh_token"), "resource" => stored.fetch("resource") })
          rescue HTTPError => error
            raise unless error.status == 400 && invalid_grant?(error.body)
            # Clear under the same lock, and commit before reporting reconnect.
            @access.grant.update_credentials!("mcp_oauth" => nil)
            invalid = true
            next
          end
          tokens["refresh_token"] = previous["refresh_token"] unless tokens.key?("refresh_token")
          persist(stored, tokens)
          tokens.fetch("access_token")
        end
        raise AuthorizationRequired if invalid
        token
      end

      private

      def locked(&block)
        Timeout.timeout(Connectors.configuration.mcp.request_timeout, TransportError, "MCP authorization deadline exceeded") do
          @access.grant.with_lock(&block)
        end
      end

      def resolve_client(client)
        return client unless client["configured"]
        configured = @access.grant.credentials_hash["client_information"]
        unless configured && configured["client_id"] == client["client_id"] && configured["issuer"] == client["issuer"]
          raise ConfigurationRequired, "Configured OAuth client changed"
        end
        configured
      end

      def invalid_grant?(body)
        JSON.parse(body)["error"] == "invalid_grant"
      rescue JSON::ParserError, TypeError
        false
      end

      def persist(payload, tokens)
        value = payload.slice("metadata", "client", "resource", "requested_scopes").merge("tokens" => tokens, "fingerprint" => @access.fingerprint)
        @access.grant.update_credentials!("mcp_oauth" => value)
        @access.grant.update!(expires_at: tokens["expires_at"] && Time.at(tokens["expires_at"]), status: :active)
      end

      def callback_url
        Connectors.configuration.resolved_mcp_callback_url
      end

      def requested_scopes(data, resource, metadata, challenge)
        scopes = if challenge.key?("scope")
          challenge.fetch("scope").to_s.split
        else
          Array(resource["scopes_supported"])
        end
        scopes |= Array(data.dig("mcp_oauth", "requested_scopes"))
        if Array(metadata["scopes_supported"]).include?("offline_access")
          scopes |= [ "offline_access" ]
        else
          scopes -= [ "offline_access" ]
        end
        raise ProtocolError, "Invalid OAuth scopes" unless scopes.all? { |s| s.is_a?(String) && s.match?(/\A[\x21\x23-\x5B\x5D-\x7E]+\z/) }
        scopes
      end

      def register_client(data, metadata, callback)
        client = data["client_information"] || data.dig("mcp_oauth", "client")
        if client
          raise ConfigurationRequired, "OAuth client issuer mismatch" unless client["issuer"] == metadata["issuer"]
          return client.slice("client_id", "issuer", "token_endpoint_auth_method").merge("configured" => true) if data["client_information"]
          return client
        end
        document_url = Connectors.configuration.mcp.client_metadata_url
        if document_url && metadata["client_id_metadata_document_supported"] == true
          uri = HTTP.new.validate_url!(document_url)
          raise ConfigurationRequired, "CIMD requires an HTTPS document path" unless uri.scheme == "https" && uri.path.present? && uri.path != "/" && !uri.query
          document = HTTP.new.json(url: document_url)
          unless document["client_id"] == document_url && document["client_name"].is_a?(String) && Array(document["redirect_uris"]).include?(callback)
            raise ConfigurationRequired, "Invalid client metadata document"
          end
          return document.slice("client_id", "token_endpoint_auth_method").merge("issuer" => metadata.fetch("issuer"))
        end
        endpoint = metadata["registration_endpoint"] or raise ConfigurationRequired, "Pre-registered client information is required"
        grant_types = [ "authorization_code", "refresh_token" ]
        grant_types &= Array(metadata["grant_types_supported"]) if metadata.key?("grant_types_supported")
        raise ConfigurationRequired, "Authorization server does not support authorization_code" unless grant_types.include?("authorization_code")
        client = HTTP.new.json(url: endpoint, method: :post, headers: { "Content-Type" => "application/json" }, body: {
          client_name: Connectors.configuration.mcp.client_name, redirect_uris: [ callback ], grant_types: grant_types,
          response_types: [ "code" ], token_endpoint_auth_method: "none", application_type: "web"
        }.to_json)
        raise ProtocolError, "Registration returned no client ID" unless client["client_id"].is_a?(String) && client["client_id"].present?
        client.merge("issuer" => metadata.fetch("issuer"))
      end
    end
  end
end
