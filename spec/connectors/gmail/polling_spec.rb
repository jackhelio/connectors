require "rails_helper"

RSpec.describe Gmail::Polling do
  let(:owner) { Owner.create!(name: "polling owner") }
  let(:grant) do
    Connectors::Grant.create!(
      owner: owner, connector_key: "gmail",
      credentials: { "access_token" => "ya29.x", "email" => "user@example.com" }
    )
  end

  # Helper: build a full Gmail message JSON the way users.messages.get returns it.
  def gmail_message(id:, thread_id: "thr-#{id}", subject: "S", from: "a@x.com",
                    label_ids: [ "INBOX", "UNREAD" ], internal_date: 1_700_000_000)
    {
      id: id, threadId: thread_id, labelIds: label_ids, snippet: "...",
      internalDate: (internal_date * 1000).to_s,
      payload: {
        mimeType: "text/plain",
        headers: [
          { name: "From",    value: from },
          { name: "Subject", value: subject }
        ],
        body: { data: Base64.urlsafe_encode64("body", padding: false) }
      }
    }
  end

  describe "first-ever poll" do
    it "bootstraps last_checked_at to `now` and emits nothing" do
      sd = {}
      poller = described_class.new(grant, sd, now: 1_700_001_000)
      expect(poller.run).to eq([])
      expect(sd["last_checked_at"]).to eq(1_700_001_000)
      expect(sd["possible_duplicates"]).to eq([])
    end

    it "does NOT hit the Gmail API on the first poll" do
      stub = stub_request(:get, %r{users/me/messages})
      described_class.new(grant, {}, now: 1_700_001_000).run
      expect(stub).not_to have_been_requested
    end
  end

  describe "subsequent polls" do
    before do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m-new" } ] }.to_json)
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m-new?format=full")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: gmail_message(id: "m-new", internal_date: 1_700_000_500).to_json)
    end

    it "lists messages with `after:<last_checked_at>` and `-in:scheduled` baked in" do
      sd = { "last_checked_at" => 1_700_000_000 }
      described_class.new(grant, sd, now: 1_700_001_000).run

      expect(WebMock).to have_requested(:get, %r{users/me/messages\?})
        .with { |req|
          q = CGI.parse(URI.parse(req.uri).query)["q"].first.to_s
          q.include?("after:1700000000") && q.include?("-in:scheduled")
        }
    end

    it "emits a parsed envelope for each new message" do
      sd = { "last_checked_at" => 1_700_000_000, "possible_duplicates" => [] }
      result = described_class.new(grant, sd, now: 1_700_001_000).run

      expect(result.size).to eq(1)
      expect(result.first).to include(
        "id"            => "m-new",
        "thread_id"     => "thr-m-new",
        "label_ids"     => [ "INBOX", "UNREAD" ],
        "internal_date" => 1_700_000_500
      )
      expect(result.first["envelope"]).to include("from" => "a@x.com", "subject" => "S")
    end

    it "advances last_checked_at to the newest message's internalDate" do
      sd = { "last_checked_at" => 1_700_000_000, "possible_duplicates" => [] }
      described_class.new(grant, sd, now: 1_700_001_000).run

      expect(sd["last_checked_at"]).to eq(1_700_000_500)
      expect(sd["possible_duplicates"]).to eq([ "m-new" ])
    end
  end

  describe "boundary dedupe via possible_duplicates" do
    it "skips ids the previous poll already emitted at the same second" do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m-old" }, { id: "m-new" } ] }.to_json)
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m-new?format=full")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: gmail_message(id: "m-new", internal_date: 1_700_000_600).to_json)

      sd = { "last_checked_at" => 1_700_000_500, "possible_duplicates" => [ "m-old" ] }
      result = described_class.new(grant, sd, now: 1_700_001_000).run

      ids = result.map { |m| m["id"] }
      expect(ids).to eq([ "m-new" ])
      # m-old must NOT have been fetched
      expect(WebMock).not_to have_requested(:get, %r{users/me/messages/m-old})
    end

    it "preserves the dedupe set when the cursor doesn't move (multiple polls inside same second)" do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m-second" } ] }.to_json)
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m-second?format=full")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: gmail_message(id: "m-second", internal_date: 1_700_000_500).to_json)

      sd = { "last_checked_at" => 1_700_000_500, "possible_duplicates" => [ "m-first" ] }
      described_class.new(grant, sd, now: 1_700_001_000).run

      expect(sd["last_checked_at"]).to eq(1_700_000_500)
      expect(sd["possible_duplicates"]).to match_array(%w[m-first m-second])
    end
  end

  describe "filters" do
    let(:sd) do
      {
        "last_checked_at" => 1_700_000_000,
        "possible_duplicates" => [],
        "filters" => filters
      }
    end

    before do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [] }.to_json)
    end

    context "raw q + sender" do
      let(:filters) { { "q" => "has:attachment", "sender" => "boss@example.com" } }

      it "concatenates clauses Gmail-style" do
        described_class.new(grant, sd, now: 1_700_001_000).run
        expect(WebMock).to have_requested(:get, %r{users/me/messages\?})
          .with { |req|
            q = CGI.parse(URI.parse(req.uri).query)["q"].first.to_s
            q.include?("has:attachment") && q.include?("from:boss@example.com")
          }
      end
    end

    context "label_ids" do
      let(:filters) { { "label_ids" => [ "Label_42", "INBOX" ] } }

      it "passes them through as labelIds[]" do
        described_class.new(grant, sd, now: 1_700_001_000).run
        expect(WebMock).to have_requested(:get, %r{users/me/messages\?})
          .with { |req|
            params = CGI.parse(URI.parse(req.uri).query)
            (params["labelIds[]"] || []).sort == [ "INBOX", "Label_42" ]
          }
      end
    end

    context "read_status" do
      let(:filters) { { "read_status" => "unread" } }

      it "adds is:unread to the q" do
        described_class.new(grant, sd, now: 1_700_001_000).run
        expect(WebMock).to have_requested(:get, %r{users/me/messages\?})
          .with { |req|
            q = CGI.parse(URI.parse(req.uri).query)["q"].first.to_s
            q.include?("is:unread")
          }
      end
    end

    context "include_spam_trash" do
      let(:filters) { { "include_spam_trash" => true } }

      it "sets includeSpamTrash=true" do
        described_class.new(grant, sd, now: 1_700_001_000).run
        expect(WebMock).to have_requested(:get, %r{users/me/messages\?})
          .with { |req|
            CGI.parse(URI.parse(req.uri).query)["includeSpamTrash"] == [ "true" ]
          }
      end
    end
  end

  describe "drafts + sent-not-inbox skipping" do
    let(:sd) { { "last_checked_at" => 1_700_000_000, "possible_duplicates" => [] } }

    it "skips DRAFT messages by default" do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "draft-1" } ] }.to_json)
      stub_request(:get, %r{messages/draft-1})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: gmail_message(id: "draft-1", label_ids: [ "DRAFT" ]).to_json)

      result = described_class.new(grant, sd, now: 1_700_001_000).run
      expect(result).to be_empty
    end

    it "includes drafts when include_drafts: true" do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "draft-2" } ] }.to_json)
      stub_request(:get, %r{messages/draft-2})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: gmail_message(id: "draft-2", label_ids: [ "DRAFT" ]).to_json)

      sd["filters"] = { "include_drafts" => true }
      result = described_class.new(grant, sd, now: 1_700_001_000).run
      expect(result.map { |m| m["id"] }).to eq([ "draft-2" ])
    end

    it "skips SENT messages that aren't also in INBOX (outbound copy)" do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "sent-1" } ] }.to_json)
      stub_request(:get, %r{messages/sent-1})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: gmail_message(id: "sent-1", label_ids: [ "SENT" ]).to_json)

      result = described_class.new(grant, sd, now: 1_700_001_000).run
      expect(result).to be_empty
    end

    it "keeps a message labeled both SENT and INBOX (self-addressed)" do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "self-1" } ] }.to_json)
      stub_request(:get, %r{messages/self-1})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: gmail_message(id: "self-1", label_ids: [ "SENT", "INBOX" ]).to_json)

      result = described_class.new(grant, sd, now: 1_700_001_000).run
      expect(result.map { |m| m["id"] }).to eq([ "self-1" ])
    end
  end

  describe "max_results clamping" do
    it "caps fetched messages at the filter's max_results" do
      ids = %w[m1 m2 m3 m4 m5]
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: ids.map { |id| { id: id } } }.to_json)
      ids.each do |id|
        stub_request(:get, %r{messages/#{id}\?format=full})
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: gmail_message(id: id, internal_date: 1_700_000_500 + ids.index(id)).to_json)
      end

      sd = { "last_checked_at" => 1_700_000_000, "possible_duplicates" => [],
             "filters" => { "max_results" => 2 } }
      result = described_class.new(grant, sd, now: 1_700_001_000).run
      expect(result.map { |m| m["id"] }).to eq(%w[m1 m2])
    end
  end

  describe "integration with Connectors::PollRunner" do
    it "runs through PollRunner and persists static_data on the grant" do
      stub_request(:get, %r{users/me/messages\?})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m-poll" } ] }.to_json)
      stub_request(:get, %r{messages/m-poll})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: gmail_message(id: "m-poll", internal_date: 1_700_000_500).to_json)

      # Seed the cursor so we don't take the first-run path.
      grant.update_static_data!("polling") { |sd| sd["last_checked_at"] = 1_700_000_000 }

      result = Connectors::PollRunner.run(grant)
      expect(result[:items].map { |m| m["id"] }).to eq([ "m-poll" ])
      expect(grant.reload.static_data["polling"]["last_checked_at"]).to eq(1_700_000_500)
    end
  end
end
