require "rails_helper"

RSpec.describe "OAuth token endpoint client authentication" do
  let(:client_id) { "client:id" }
  let(:client_secret) { "secret +:/" }

  def connector(authentication: "header", grant_type: "authorizationCode")
    Class.new(Connectors::Connector) do
      connector key: :token_auth, auth: :oauth2, base_url: "https://oauth.test"
      oauth2 authorize_url: "https://oauth.test/authorize", token_url: "https://oauth.test/token",
        authentication: authentication, grant_type: grant_type
    end
  end

  before do
    Connectors.configuration.host_base_url = "https://app.test"
    Connectors.configuration.oauth_credentials = { token_auth: { client_id: client_id, client_secret: client_secret } }
  end

  { code: "authorization_code", refresh: "refresh_token", client_credentials: "client_credentials" }.each do |flow, grant_type|
    [ "header", "body" ].each do |authentication|
      it "uses #{authentication} authentication for #{flow}" do
        klass = connector(authentication: authentication)
        endpoint = stub_request(:post, "https://oauth.test/token").with do |request|
          params = URI.decode_www_form(request.body).to_h
          expect(params["grant_type"]).to eq(grant_type)
          if authentication == "header"
            # RFC 6749 section 2.3.1 encodes each component before Basic auth.
            expected = Base64.strict_encode64("client%3Aid:secret+%2B%3A%2F")
            expect(request.headers["Authorization"]).to eq("Basic #{expected}")
            expect(params).not_to have_key("client_secret")
            expect(params).not_to have_key("client_id")
          else
            expect(params).to include("client_id" => client_id, "client_secret" => client_secret)
            expect(request.headers).not_to have_key("Authorization")
          end
          true
        end.to_return(status: 200, body: '{"access_token":"token"}', headers: { "Content-Type" => "application/json" })

        result = case flow
        when :code then Connectors::OAuth::TokenExchange.exchange_code(klass, code: "code")
        when :refresh then Connectors::OAuth::TokenExchange.refresh(klass, refresh_token: "refresh")
        when :client_credentials then Connectors::OAuth::ClientCredentials.exchange(klass)
        end
        expect(result["access_token"]).to eq("token")
        expect(endpoint).to have_been_requested.once
      end
    end
  end

  it "sends the public client identifier and verifier without synthesizing a client secret" do
    Connectors.configuration.oauth_credentials = { token_auth: { client_id: client_id } }
    klass = connector(grant_type: "pkce")
    endpoint = stub_request(:post, "https://oauth.test/token").with do |request|
      params = URI.decode_www_form(request.body).to_h
      expect(params).to include("client_id" => client_id, "code_verifier" => "verifier")
      expect(params).not_to have_key("client_secret")
      expect(request.headers).not_to have_key("Authorization")
      true
    end.to_return(status: 200, body: '{"access_token":"token"}')
    Connectors::OAuth::TokenExchange.exchange_code(klass, code: "code", code_verifier: "verifier")
    expect(endpoint).to have_been_requested.once
  end
end
