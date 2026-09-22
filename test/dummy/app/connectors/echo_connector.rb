class EchoConnector < Connectors::Connector
  connector key: :echo, auth: :api_key, base_url: "https://httpbin.org"

  credentials do
    field :api_key, type: "string", required: true, secret: true,
                    display_name: "API Key"
  end

  api_key_in :header, name: "X-Echo-Token", prefix: nil

  def ping
    client.get("/get").body
  end
end
