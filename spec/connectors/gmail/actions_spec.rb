require "rails_helper"

RSpec.describe Gmail::Connector, "actions" do
  let(:owner) { Owner.create!(name: "gmail actions") }
  let(:grant) do
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "gmail",
      credentials:   { "access_token" => "ya29.x", "email" => "user@example.com" }
    )
  end
  let(:connector) { grant.connector }

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
    end
  end

  describe "#send_message" do
    it "encodes MIME, base64url-wraps it, POSTs to messages/send" do
      stub = stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        .with(headers: { "Authorization" => "Bearer ya29.x" }) do |req|
          body = JSON.parse(req.body)
          raw  = Base64.urlsafe_decode64(body.fetch("raw"))
          raw.include?("To: alice@example.com") &&
            raw.include?("Subject: Hi") &&
            raw.include?(Base64.encode64("<p>hi</p>").chomp)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   { id: "msg-1", threadId: "thr-1", labelIds: [ "SENT" ] }.to_json
        )

      result = connector.send_message(to: "alice@example.com", subject: "Hi", html: "<p>hi</p>")
      expect(stub).to have_been_requested
      expect(result).to include("id" => "msg-1", "thread_id" => "thr-1", "label_ids" => [ "SENT" ])
    end

    it "carries thread_id through to the request body" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        .with(body: hash_including("threadId" => "thr-42"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   { id: "msg-2", threadId: "thr-42" }.to_json
        )

      connector.send_message(to: "a@x.com", subject: "Re: Hi", text: "ok", thread_id: "thr-42")
    end
  end

  describe "#list_messages" do
    it "passes Gmail search syntax through as `q` and folds the page response" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        .with(query: hash_including("q" => "is:unread", "maxResults" => "50"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   {
            messages: [ { id: "m1", threadId: "t1" }, { id: "m2", threadId: "t2" } ],
            nextPageToken: "page-2",
            resultSizeEstimate: 2
          }.to_json
        )

      result = connector.list_messages(q: "is:unread", max_results: 50)
      expect(result["messages"]).to eq([
        { "id" => "m1", "thread_id" => "t1" },
        { "id" => "m2", "thread_id" => "t2" }
      ])
      expect(result["next_page_token"]).to eq("page-2")
    end
  end

  describe "#get_message" do
    it "fetches by id with the requested format and normalizes the wire shape" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/msg-1")
        .with(query: hash_including("format" => "full"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   {
            id: "msg-1",
            threadId: "thr-1",
            labelIds: [ "INBOX" ],
            snippet: "Hello there",
            payload: { headers: [ { name: "From", value: "bob@x.com" } ] }
          }.to_json
        )

      result = connector.get_message(id: "msg-1")
      expect(result).to include(
        "id"        => "msg-1",
        "thread_id" => "thr-1",
        "label_ids" => [ "INBOX" ],
        "snippet"   => "Hello there"
      )
      expect(result["payload"]).to be_a(Hash)
    end
  end

  describe "#modify_message_labels" do
    it "supports add only" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/msg-1/modify")
        .with(body: hash_including("addLabelIds" => [ "Label_42" ]))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   { id: "msg-1", labelIds: [ "INBOX", "Label_42" ] }.to_json
        )

      connector.modify_message_labels(id: "msg-1", add_label_ids: [ "Label_42" ], remove_label_ids: nil)
    end

    it "supports remove only" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/msg-1/modify")
        .with(body: hash_including("removeLabelIds" => [ "INBOX" ]))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "msg-1", labelIds: [] }.to_json)

      connector.modify_message_labels(id: "msg-1", add_label_ids: nil, remove_label_ids: [ "INBOX" ])
    end
  end

  describe "#list_labels" do
    it "returns the user's labels" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/labels")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   { labels: [ { id: "INBOX", name: "INBOX", type: "system" } ] }.to_json
        )

      expect(connector.list_labels).to eq("labels" => [ { "id" => "INBOX", "name" => "INBOX", "type" => "system" } ])
    end
  end

  describe "#create_label" do
    it "POSTs a label with the requested visibility settings" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/labels")
        .with(body: hash_including(
          "name"                  => "Work/Important",
          "labelListVisibility"   => "labelShow",
          "messageListVisibility" => "show"
        ))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   { id: "Label_99", name: "Work/Important", type: "user" }.to_json
        )

      expect(connector.create_label(name: "Work/Important")).to include("id" => "Label_99")
    end
  end

  describe "action manifest end-to-end" do
    it "dispatches send_message through ActionRunner" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   { id: "msg-x", threadId: "thr-x" }.to_json
        )

      result = Connectors::ActionRunner.call(grant, :send_message, {
        "to" => "alice@example.com", "subject" => "Hi", "html" => "<p>hi</p>"
      })
      expect(result[:status]).to eq("ok")
      expect(result[:data]).to include("id" => "msg-x", "thread_id" => "thr-x")
    end

    it "returns invalid_params when required fields are missing" do
      result = Connectors::ActionRunner.call(grant, :send_message, { "subject" => "Hi" })
      expect(result[:status]).to eq("error")
      expect(result.dig(:error, :type)).to eq("invalid_params")
      expect(result.dig(:error, :missing)).to include("to")
    end
  end

  # Reply, trash, read state, thread, draft, label and pagination actions.

  describe "#reply_to_message" do
    let(:parent_payload) do
      {
        "id" => "msg-1",
        "threadId" => "thr-1",
        "payload" => {
          "headers" => [
            { "name" => "From",    "value" => "bob@example.com" },
            { "name" => "To",      "value" => "user@example.com, carol@example.com" },
            { "name" => "Subject", "value" => "Original" },
            { "name" => "Message-ID", "value" => "<orig@x>" }
          ]
        }
      }
    end

    before do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/msg-1")
        .with(query: hash_including("format" => "metadata"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: parent_payload.to_json)
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/profile")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { emailAddress: "user@example.com" }.to_json)
    end

    it "fetches the parent, builds a reply with In-Reply-To + References + threadId, and POSTs to send" do
      capture = nil
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        .with { |req|
          capture = JSON.parse(req.body)
          true
        }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "reply-1", threadId: "thr-1" }.to_json)

      result = connector.reply_to_message(message_id: "msg-1", text: "thanks!")
      expect(result["id"]).to eq("reply-1")
      expect(capture["threadId"]).to eq("thr-1")

      raw = Base64.urlsafe_decode64(capture["raw"])
      expect(raw).to include("In-Reply-To: <orig@x>")
      expect(raw).to include("References: <orig@x>")
      expect(raw).to include("Subject: Re: Original")
      # bob (the sender) goes in To:; user (us) gets stripped; carol (other To) is included too.
      expect(raw).to include("To:")
      expect(raw).to include("bob@example.com")
      expect(raw).to include("carol@example.com")
      expect(raw).not_to include("user@example.com")
    end

    it "honors reply_to_sender_only — only the From address in To:" do
      capture = nil
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        .with { |req| capture = JSON.parse(req.body); true }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "r", threadId: "thr-1" }.to_json)

      connector.reply_to_message(message_id: "msg-1", text: "ok", reply_to_sender_only: true)

      raw = Base64.urlsafe_decode64(capture["raw"])
      expect(raw).to include("bob@example.com")
      expect(raw).not_to include("carol@example.com")
    end

    it "rejects mutually-exclusive sender_only + recipients_only flags" do
      expect {
        connector.reply_to_message(
          message_id: "msg-1", text: "x",
          reply_to_sender_only: true, reply_to_recipients_only: true
        )
      }.to raise_error(Connectors::ApiError, /mutually exclusive/)
    end

    it "raises when neither html nor text is supplied" do
      expect { connector.reply_to_message(message_id: "msg-1") }
        .to raise_error(Connectors::ApiError, /html or text/)
    end
  end

  describe "trash / untrash" do
    it "POSTs to /messages/:id/trash" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/trash")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "m1", labelIds: [ "TRASH" ] }.to_json)
      expect(connector.trash_message(id: "m1")).to include("id" => "m1", "label_ids" => [ "TRASH" ])
    end

    it "POSTs to /messages/:id/untrash" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/untrash")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "m1", labelIds: [ "INBOX" ] }.to_json)
      expect(connector.untrash_message(id: "m1")["label_ids"]).to eq([ "INBOX" ])
    end
  end

  describe "mark as read / unread" do
    it "mark_message_as_read removes the UNREAD label" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify")
        .with(body: hash_including("removeLabelIds" => [ "UNREAD" ]))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "m1", labelIds: [ "INBOX" ] }.to_json)
      connector.mark_message_as_read(id: "m1")
    end

    it "mark_message_as_unread adds the UNREAD label" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify")
        .with(body: hash_including("addLabelIds" => [ "UNREAD" ]))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "m1", labelIds: [ "INBOX", "UNREAD" ] }.to_json)
      connector.mark_message_as_unread(id: "m1")
    end
  end

  describe "delete_message" do
    it "DELETEs and returns success" do
      stub_request(:delete, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1")
        .to_return(status: 204, body: "")
      expect(connector.delete_message(id: "m1")).to eq("success" => true)
    end
  end

  describe "#get_message with format=full" do
    it "attaches an `envelope` parsed by MimeParser" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1")
        .with(query: hash_including("format" => "full"))
        .to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: {
            id: "m1", threadId: "t1", labelIds: [ "INBOX" ], snippet: "...",
            payload: {
              mimeType: "text/plain",
              headers: [
                { name: "From",    value: "a@x.com" },
                { name: "Subject", value: "test" }
              ],
              body: { data: Base64.urlsafe_encode64("hi there", padding: false) }
            }
          }.to_json
        )

      result = connector.get_message(id: "m1")
      expect(result).to include("id" => "m1", "thread_id" => "t1")
      expect(result["envelope"]).to include("from" => "a@x.com", "subject" => "test", "text" => "hi there")
    end

    it "does NOT include `envelope` for non-full formats" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1")
        .with(query: hash_including("format" => "minimal"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "m1", threadId: "t1", labelIds: [ "INBOX" ] }.to_json)
      result = connector.get_message(id: "m1", format: "minimal")
      expect(result).not_to have_key("envelope")
    end
  end

  describe "list_all_messages (auto-paginate)" do
    it "walks every nextPageToken" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        .with(query: hash_including("q" => "is:unread", "maxResults" => "100"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m1", threadId: "t1" } ], nextPageToken: "p2" }.to_json)
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        .with(query: hash_including("pageToken" => "p2"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m2", threadId: "t2" } ] }.to_json)

      result = connector.list_all_messages(q: "is:unread")
      expect(result["messages"].map { |m| m["id"] }).to eq(%w[m1 m2])
    end
  end

  describe "threads" do
    it "#list_threads returns a normalized page" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/threads")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { threads: [ { id: "t1", historyId: "h1", snippet: "..." } ],
                           nextPageToken: "p2", resultSizeEstimate: 1 }.to_json)
      result = connector.list_threads
      expect(result["threads"].first).to eq("id" => "t1", "history_id" => "h1", "snippet" => "...")
      expect(result["next_page_token"]).to eq("p2")
    end

    it "#get_thread returns id + history_id + normalized messages" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/threads/t1")
        .with(query: hash_including("format" => "full"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "t1", historyId: "h1",
                           messages: [ { id: "m1", threadId: "t1", labelIds: [ "INBOX" ] } ] }.to_json)
      result = connector.get_thread(id: "t1")
      expect(result["id"]).to eq("t1")
      expect(result["history_id"]).to eq("h1")
      expect(result["messages"].first).to include("id" => "m1", "thread_id" => "t1")
    end

    it "#delete_thread DELETEs" do
      stub_request(:delete, "https://gmail.googleapis.com/gmail/v1/users/me/threads/t1")
        .to_return(status: 204, body: "")
      expect(connector.delete_thread(id: "t1")).to eq("success" => true)
    end

    it "#trash_thread POSTs to /threads/:id/trash" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/threads/t1/trash")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "t1" }.to_json)
      expect(connector.trash_thread(id: "t1")).to eq("id" => "t1")
    end

    it "#untrash_thread POSTs to /threads/:id/untrash" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/threads/t1/untrash")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "t1" }.to_json)
      expect(connector.untrash_thread(id: "t1")).to eq("id" => "t1")
    end

    it "#modify_thread_labels supports add" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/threads/t1/modify")
        .with(body: hash_including("addLabelIds" => [ "L1" ]))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "t1" }.to_json)
      connector.modify_thread_labels(id: "t1", add_label_ids: [ "L1" ], remove_label_ids: nil)
    end

    it "list_all_threads auto-paginates" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/threads")
        .with(query: hash_including("maxResults" => "100"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { threads: [ { id: "t1", historyId: "h1" } ], nextPageToken: "p2" }.to_json)
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/threads")
        .with(query: hash_including("pageToken" => "p2"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { threads: [ { id: "t2", historyId: "h2" } ] }.to_json)

      result = connector.list_all_threads
      expect(result["threads"].map { |t| t["id"] }).to eq(%w[t1 t2])
    end
  end

  describe "labels" do
    it "#get_label normalizes the response" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/labels/L1")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "L1", name: "Work", type: "user", messagesTotal: 42, messagesUnread: 3 }.to_json)
      expect(connector.get_label(id: "L1")).to include(
        "id" => "L1", "name" => "Work", "type" => "user",
        "messages_total" => 42, "messages_unread" => 3
      )
    end

    it "#delete_label DELETEs and returns success" do
      stub_request(:delete, "https://gmail.googleapis.com/gmail/v1/users/me/labels/L1")
        .to_return(status: 204, body: "")
      expect(connector.delete_label(id: "L1")).to eq("success" => true)
    end
  end

  describe "drafts" do
    it "#create_draft wraps the message in `{message: {raw, threadId}}`" do
      capture = nil
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/drafts")
        .with { |req| capture = JSON.parse(req.body); true }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "d1", message: { id: "m1", threadId: "t1" } }.to_json)

      result = connector.create_draft(to: "a@x.com", subject: "Draft", text: "body", thread_id: "t1")
      expect(capture).to have_key("message")
      expect(capture["message"]).to include("threadId" => "t1")
      expect(capture["message"]["raw"]).to be_present
      expect(result["id"]).to eq("d1")
    end

    it "#create_draft allows empty body (drafts can be blank)" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/drafts")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "d2", message: { id: "m2" } }.to_json)
      expect { connector.create_draft }.not_to raise_error
    end

    it "#get_draft normalizes the nested message" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/drafts/d1")
        .with(query: hash_including("format" => "full"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "d1", message: { id: "m1", threadId: "t1", labelIds: [ "DRAFT" ] } }.to_json)
      result = connector.get_draft(id: "d1")
      expect(result["id"]).to eq("d1")
      expect(result["message"]).to include("id" => "m1", "thread_id" => "t1")
    end

    it "#list_drafts normalizes drafts and pagination" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/drafts")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { drafts: [ { id: "d1", message: { id: "m1", threadId: "t1" } } ],
                           nextPageToken: "p2" }.to_json)
      result = connector.list_drafts
      expect(result["drafts"].first["id"]).to eq("d1")
      expect(result["drafts"].first["message"]).to include("id" => "m1", "thread_id" => "t1")
      expect(result["next_page_token"]).to eq("p2")
    end

    it "#list_all_drafts auto-paginates" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/drafts")
        .with(query: hash_including("maxResults" => "100"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { drafts: [ { id: "d1", message: { id: "m1" } } ], nextPageToken: "p2" }.to_json)
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/drafts")
        .with(query: hash_including("pageToken" => "p2"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { drafts: [ { id: "d2", message: { id: "m2" } } ] }.to_json)
      result = connector.list_all_drafts
      expect(result["drafts"].map { |d| d["id"] }).to eq(%w[d1 d2])
    end

    it "#delete_draft DELETEs" do
      stub_request(:delete, "https://gmail.googleapis.com/gmail/v1/users/me/drafts/d1")
        .to_return(status: 204, body: "")
      expect(connector.delete_draft(id: "d1")).to eq("success" => true)
    end
  end

  describe "error normalization end-to-end" do
    it "404 from a message read surfaces as 'Message not found' through the action runner" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/bad")
        .with(query: hash_including("format" => "full"))
        .to_return(status: 404, headers: { "Content-Type" => "application/json" },
                   body: { error: { code: 404, message: "Not Found" } }.to_json)
      result = Connectors::ActionRunner.call(grant, :get_message, { "id" => "bad" })
      expect(result[:status]).to eq("error")
      expect(result.dig(:error, :type)).to eq("api_error")
      expect(result.dig(:error, :message)).to eq("Message not found")
    end
  end
end
