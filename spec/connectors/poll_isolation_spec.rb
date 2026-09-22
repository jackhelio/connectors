require "rails_helper"

RSpec.describe "Polling consumer isolation", type: :request do
  let(:owner) { Owner.create!(name: "Polling owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "isolated_poll", credentials: {}) }
  let!(:connector_class) do
    Class.new(Connectors::Connector) do
      connector key: :isolated_poll, auth: :api_key, base_url: "https://poll.test"
      polling do |_grant, cursor|
        cursor["position"] = cursor.fetch("position", 0) + 1
        [ { "position" => cursor["position"], "filter" => cursor["filter"] } ]
      end
    end
  end

  before { Connectors.configuration.current_owner_resolver = ->(_) { owner } }

  it "maintains separate cursors and filters for consumers sharing a grant" do
    grant.poll_states.create!(instance_key: "inbox", data: { "filter" => "in:inbox" })
    grant.poll_states.create!(instance_key: "sent", data: { "filter" => "in:sent" })
    first = Connectors::PollRunner.run(grant, instance_key: "inbox")
    second = Connectors::PollRunner.run(grant, instance_key: "sent")
    again = Connectors::PollRunner.run(grant, instance_key: "inbox")
    expect(first[:items]).to eq([ { "position" => 1, "filter" => "in:inbox" } ])
    expect(second[:items]).to eq([ { "position" => 1, "filter" => "in:sent" } ])
    expect(again[:static_data]).to eq("position" => 2, "filter" => "in:inbox")
    expect(grant.reload.static_data_hash).to eq({})
  end

  it "rolls back cursor mutation when polling fails" do
    state = grant.poll_states.create!(instance_key: "trigger", data: { "position" => 5 })
    connector_class.polling do |_grant, cursor|
      cursor["position"] = 6
      raise Connectors::ApiError, "upstream failed"
    end
    expect { Connectors::PollRunner.run(grant, instance_key: "trigger") }.to raise_error(Connectors::ApiError)
    expect(state.reload.data).to eq("position" => 5)
  end

  it "passes the consumer key through the polling endpoint" do
    post "/connectors/grants/#{grant.id}/poll", params: { instance_key: "trigger" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(grant.poll_states.find_by!(instance_key: "trigger").data).to eq("position" => 1)
  end

  it "rejects malformed consumer keys without advancing a cursor" do
    [ "", " ", [ "key" ], { "key" => "value" } ].each do |key|
      post "/connectors/grants/#{grant.id}/poll", params: { instance_key: key }, as: :json
      expect(response).to have_http_status(:bad_request)
    end
    expect(grant.poll_states.count).to eq(0)
  end

  it "does not let another owner advance a consumer's cursor" do
    stranger = Owner.create!(name: "Stranger")
    grant.update!(owner: stranger)
    post "/connectors/grants/#{grant.id}/poll", params: { instance_key: "trigger" }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(grant.poll_states.count).to eq(0)
  end

  it "deletes consumer state when its grant is deleted" do
    state = grant.poll_states.create!(instance_key: "trigger")
    grant.destroy!
    expect(Connectors::PollState.exists?(state.id)).to be(false)
  end
end
