require_dependency Connectors::Engine.root.join("app/connectors/gmail/api.rb").to_s
require_dependency Connectors::Engine.root.join("app/connectors/gmail/mime_builder.rb").to_s
require_dependency Connectors::Engine.root.join("app/connectors/gmail/mime_parser.rb").to_s
require_dependency Connectors::Engine.root.join("app/connectors/gmail/polling.rb").to_s

module Gmail
  # Gmail OAuth2 connector with PKCE and refresh-token support.
  # The declared scopes are defaults; hosts can override them with the
  # `scope` parameter when starting authorization.
  class Connector < Connectors::Connector
    DEFAULT_SCOPES = [
      "openid",
      "email",
      "https://www.googleapis.com/auth/gmail.modify",
      "https://www.googleapis.com/auth/gmail.labels"
    ].freeze

    connector key:               :gmail,
              auth:              :oauth2,
              base_url:          "https://gmail.googleapis.com/gmail/v1",
              display_name:      "Gmail",
              icon:              "https://www.gstatic.com/images/branding/product/2x/gmail_2020q4_48dp.png",
              icon_color:        "#EA4335",
              documentation_url: "https://developers.google.com/gmail/api/reference/rest",
              llm_docs:          "https://developers.google.com/gmail/api/reference/rest"

    oauth2 authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
           token_url:     "https://oauth2.googleapis.com/token",
           scope:         DEFAULT_SCOPES.join(" "),
           grant_type:    "pkce",
           authentication: "body",
           extra_authorize_params: {
             access_type: "offline",
             prompt:      "consent",
             include_granted_scopes: "true"
           }

    revoke_token_url "https://oauth2.googleapis.com/revoke"

    credentials do
      extends :oauth2

      field :authorization_url, type: "hidden",
                                default: "https://accounts.google.com/o/oauth2/v2/auth"
      field :access_token_url,  type: "hidden",
                                default: "https://oauth2.googleapis.com/token"
      field :grant_type,        type: "hidden", default: "pkce"
      field :scope,             type: "hidden", default: DEFAULT_SCOPES.join(" ")

      field :client_id,             type: "hidden"
      field :client_secret,         type: "hidden"
      field :auth_query_parameters, type: "hidden"
      field :authentication,        type: "hidden", default: "header"

      field :jwe_enabled, type: "hidden", default: false
      field :jwks_uri,    type: "hidden", default: ""
    end

    rate_limit 2, per: 1.second

    def self.post_token_exchange(raw_response, normalized)
      email = email_from_id_token(raw_response["id_token"])
      normalized.merge("email" => email).compact
    end

    def self.external_account_id_from_credentials(credentials)
      credentials["email"]
    end

    def self.email_from_id_token(id_token)
      return nil unless id_token.is_a?(String)
      payload = id_token.split(".")[1]
      return nil if payload.to_s.empty?
      padded   = payload + "=" * ((4 - payload.length % 4) % 4)
      decoded  = Base64.urlsafe_decode64(padded)
      JSON.parse(decoded)["email"]
    rescue StandardError
      nil
    end

    def refresh!
      new_tokens = Connectors::OAuth::TokenExchange.refresh(
        self.class, refresh_token: grant.credentials_hash.fetch("refresh_token")
      )
      grant.update_credentials!(new_tokens)
    end

    test_request method: :get, url: "users/me/profile"

    # Polls users.messages.list using a timestamp cursor and duplicate IDs.
    # Filters come from the polling state supplied by PollRunner.
    polling do |grant, sd|
      Gmail::Polling.new(grant, sd).run
    end

    # =========================================================================
    # MESSAGE ACTIONS
    # =========================================================================
    action :send_message,
           display_name: "Send Email",
           description:  "Compose and send an email via Gmail (users.messages.send)." do
      field :to, type: "string", display_name: "To", required: true,
            type_options: { multiple_values: true }
      field :subject, type: "string", display_name: "Subject", required: true
      field :html, type: "string", display_name: "HTML Body",
            type_options: { editor: "html" }
      field :text, type: "string", display_name: "Plain Text Body",
            type_options: { rows: 6 }
      field :cc, type: "string", display_name: "CC",
            type_options: { multiple_values: true }
      field :bcc, type: "string", display_name: "BCC",
            type_options: { multiple_values: true }
      field :reply_to, type: "string", display_name: "Reply To",
            type_options: { multiple_values: true }
      field :from, type: "string", display_name: "From",
            description: "Defaults to the authenticated user — only use to override with a configured 'Send mail as' alias."
      field :thread_id, type: "string", display_name: "Thread ID",
            description: "Reply in an existing thread by setting its Gmail thread id."
      field :in_reply_to, type: "string", display_name: "In-Reply-To"
      field :references, type: "string", display_name: "References"
      field :attachments, type: "json", display_name: "Attachments"
      field :headers, type: "json", display_name: "Custom Headers"

      output do
        field :id, type: "string"
        field :thread_id, type: "string"
        field :label_ids, type: "string"
      end

      execute { |input| send_message(**input.symbolize_keys) }
    end

    action :reply_to_message,
           display_name: "Reply to Email",
           description:  "Reply to an existing message, preserving thread + In-Reply-To/References headers." do
      field :message_id, type: "string", display_name: "Message ID", required: true,
            description: "The Gmail id of the message you're replying to."
      field :html, type: "string", display_name: "HTML Body",
            type_options: { editor: "html" }
      field :text, type: "string", display_name: "Plain Text Body",
            type_options: { rows: 6 }
      field :cc, type: "string", display_name: "CC",
            type_options: { multiple_values: true }
      field :bcc, type: "string", display_name: "BCC",
            type_options: { multiple_values: true }
      field :sender_name, type: "string", display_name: "Sender Name",
            description: "Optional friendly name to prefix the From header."
      field :reply_to_sender_only, type: "boolean", display_name: "Reply to Sender Only",
            default: false
      field :reply_to_recipients_only, type: "boolean", display_name: "Reply to Recipients Only",
            default: false
      field :attachments, type: "json", display_name: "Attachments"

      output do
        field :id, type: "string"
        field :thread_id, type: "string"
      end

      execute { |input| reply_to_message(**input.symbolize_keys) }
    end

    action :list_messages,
           display_name: "List Messages",
           description:  "Search the user's mailbox using Gmail search syntax (users.messages.list)." do
      field :q, type: "string", display_name: "Query",
            placeholder: "is:unread from:boss@example.com newer_than:7d"
      field :label_ids, type: "string", display_name: "Label IDs",
            type_options: { multiple_values: true }
      field :max_results, type: "number", display_name: "Max Results", default: 100
      field :include_spam_trash, type: "boolean", display_name: "Include Spam & Trash", default: false
      field :page_token, type: "string", display_name: "Page Token"

      output do
        field :messages, type: "json"
        field :next_page_token, type: "string"
        field :result_size_estimate, type: "number"
      end

      execute { |input| list_messages(**input.symbolize_keys) }
    end

    action :list_all_messages,
           display_name: "List All Messages (auto-paginate)",
           description:  "Same as List Messages but walks every `nextPageToken` and returns the full set." do
      field :q, type: "string", display_name: "Query"
      field :label_ids, type: "string", display_name: "Label IDs", type_options: { multiple_values: true }
      field :include_spam_trash, type: "boolean", display_name: "Include Spam & Trash", default: false

      output { field :messages, type: "json" }

      execute { |input| list_all_messages(**input.symbolize_keys) }
    end

    action :get_message,
           display_name: "Get Message",
           description:  "Fetch a single message by id. With format=full, returns a parsed envelope (from/to/subject/text/html/attachments)." do
      field :id, type: "string", display_name: "Message ID", required: true
      field :format, type: "options", display_name: "Format", default: "full",
            options: [
              { name: "Full (parsed envelope)",  value: "full" },
              { name: "Metadata (headers only)", value: "metadata" },
              { name: "Minimal (id + labels)",   value: "minimal" },
              { name: "Raw (full MIME)",         value: "raw" }
            ]
      field :metadata_headers, type: "string", display_name: "Metadata Headers",
            type_options: { multiple_values: true },
            display_options: { show: { format: [ "metadata" ] } }

      output do
        field :id, type: "string"
        field :thread_id, type: "string"
        field :label_ids, type: "string"
        field :snippet, type: "string"
        field :envelope, type: "json", description: "Parsed from/to/subject/html/text/attachments (only when format=full)."
        field :payload, type: "json", description: "Google's raw payload tree (always present unless format=minimal)."
      end

      execute { |input| get_message(**input.symbolize_keys) }
    end

    action :delete_message,
           display_name: "Delete Message (permanent)",
           description:  "Permanently delete a message. Prefer Trash Message in most cases." do
      field :id, type: "string", display_name: "Message ID", required: true
      output { field :success, type: "boolean" }
      execute { |input| delete_message(id: input["id"]) }
    end

    action :trash_message,
           display_name: "Trash Message",
           description:  "Move a message to the Trash folder (users.messages.trash)." do
      field :id, type: "string", display_name: "Message ID", required: true
      output do
        field :id, type: "string"
        field :label_ids, type: "string"
      end
      execute { |input| trash_message(id: input["id"]) }
    end

    action :untrash_message,
           display_name: "Untrash Message",
           description:  "Restore a message from Trash (users.messages.untrash)." do
      field :id, type: "string", display_name: "Message ID", required: true
      output do
        field :id, type: "string"
        field :label_ids, type: "string"
      end
      execute { |input| untrash_message(id: input["id"]) }
    end

    action :mark_message_as_read,
           display_name: "Mark Message as Read",
           description:  "Remove the UNREAD label (users.messages.modify)." do
      field :id, type: "string", display_name: "Message ID", required: true
      output do
        field :id, type: "string"
        field :label_ids, type: "string"
      end
      execute { |input| mark_message_as_read(id: input["id"]) }
    end

    action :mark_message_as_unread,
           display_name: "Mark Message as Unread",
           description:  "Add the UNREAD label (users.messages.modify)." do
      field :id, type: "string", display_name: "Message ID", required: true
      output do
        field :id, type: "string"
        field :label_ids, type: "string"
      end
      execute { |input| mark_message_as_unread(id: input["id"]) }
    end

    action :add_labels,
           display_name: "Add Labels to Message",
           description:  "Add one or more labels to a message (users.messages.modify)." do
      field :id, type: "string", display_name: "Message ID", required: true
      field :label_ids, type: "string", display_name: "Label IDs",
            type_options: { multiple_values: true }, required: true

      output do
        field :id, type: "string"
        field :label_ids, type: "string"
      end

      execute { |input| modify_message_labels(id: input["id"], add_label_ids: input["label_ids"], remove_label_ids: nil) }
    end

    action :remove_labels,
           display_name: "Remove Labels from Message",
           description:  "Remove one or more labels from a message (users.messages.modify)." do
      field :id, type: "string", display_name: "Message ID", required: true
      field :label_ids, type: "string", display_name: "Label IDs",
            type_options: { multiple_values: true }, required: true

      output do
        field :id, type: "string"
        field :label_ids, type: "string"
      end

      execute { |input| modify_message_labels(id: input["id"], add_label_ids: nil, remove_label_ids: input["label_ids"]) }
    end

    # =========================================================================
    # THREAD ACTIONS
    # =========================================================================
    action :list_threads,
           display_name: "List Threads",
           description:  "Search threads using Gmail search syntax (users.threads.list)." do
      field :q, type: "string", display_name: "Query"
      field :label_ids, type: "string", display_name: "Label IDs", type_options: { multiple_values: true }
      field :max_results, type: "number", display_name: "Max Results", default: 100
      field :include_spam_trash, type: "boolean", display_name: "Include Spam & Trash", default: false
      field :page_token, type: "string", display_name: "Page Token"

      output do
        field :threads, type: "json"
        field :next_page_token, type: "string"
        field :result_size_estimate, type: "number"
      end

      execute { |input| list_threads(**input.symbolize_keys) }
    end

    action :list_all_threads,
           display_name: "List All Threads (auto-paginate)",
           description:  "Same as List Threads but walks every `nextPageToken`." do
      field :q, type: "string", display_name: "Query"
      field :label_ids, type: "string", display_name: "Label IDs", type_options: { multiple_values: true }
      field :include_spam_trash, type: "boolean", display_name: "Include Spam & Trash", default: false

      output { field :threads, type: "json" }

      execute { |input| list_all_threads(**input.symbolize_keys) }
    end

    action :get_thread,
           display_name: "Get Thread",
           description:  "Fetch a thread + its messages (users.threads.get)." do
      field :id, type: "string", display_name: "Thread ID", required: true
      field :format, type: "options", display_name: "Format", default: "full",
            options: [
              { name: "Full",     value: "full" },
              { name: "Metadata", value: "metadata" },
              { name: "Minimal",  value: "minimal" }
            ]

      output do
        field :id, type: "string"
        field :messages, type: "json"
        field :history_id, type: "string"
      end

      execute { |input| get_thread(**input.symbolize_keys) }
    end

    action :delete_thread,
           display_name: "Delete Thread (permanent)",
           description:  "Permanently delete a thread and all its messages." do
      field :id, type: "string", display_name: "Thread ID", required: true
      output { field :success, type: "boolean" }
      execute { |input| delete_thread(id: input["id"]) }
    end

    action :trash_thread,
           display_name: "Trash Thread",
           description:  "Move a thread to the Trash folder." do
      field :id, type: "string", display_name: "Thread ID", required: true
      output do
        field :id, type: "string"
      end
      execute { |input| trash_thread(id: input["id"]) }
    end

    action :untrash_thread,
           display_name: "Untrash Thread",
           description:  "Restore a thread from Trash." do
      field :id, type: "string", display_name: "Thread ID", required: true
      output { field :id, type: "string" }
      execute { |input| untrash_thread(id: input["id"]) }
    end

    action :add_labels_to_thread,
           display_name: "Add Labels to Thread",
           description:  "Add one or more labels to every message in a thread." do
      field :id, type: "string", display_name: "Thread ID", required: true
      field :label_ids, type: "string", display_name: "Label IDs",
            type_options: { multiple_values: true }, required: true

      output { field :id, type: "string" }

      execute { |input| modify_thread_labels(id: input["id"], add_label_ids: input["label_ids"], remove_label_ids: nil) }
    end

    action :remove_labels_from_thread,
           display_name: "Remove Labels from Thread",
           description:  "Remove one or more labels from every message in a thread." do
      field :id, type: "string", display_name: "Thread ID", required: true
      field :label_ids, type: "string", display_name: "Label IDs",
            type_options: { multiple_values: true }, required: true

      output { field :id, type: "string" }

      execute { |input| modify_thread_labels(id: input["id"], add_label_ids: nil, remove_label_ids: input["label_ids"]) }
    end

    # =========================================================================
    # LABEL ACTIONS
    # =========================================================================
    action :list_labels,
           display_name: "List Labels",
           description:  "Returns the user's labels — including system labels like INBOX, SPAM." do
      output { field :labels, type: "json" }
      execute { |_input| list_labels }
    end

    action :get_label,
           display_name: "Get Label",
           description:  "Fetch a single label by id." do
      field :id, type: "string", display_name: "Label ID", required: true
      output do
        field :id, type: "string"
        field :name, type: "string"
        field :type, type: "string"
        field :messages_total, type: "number"
        field :messages_unread, type: "number"
      end
      execute { |input| get_label(id: input["id"]) }
    end

    action :create_label,
           display_name: "Create Label",
           description:  "Create a new user label (users.labels.create). Nested labels use slash-separated names (e.g. 'Work/Important')." do
      field :name, type: "string", display_name: "Name", required: true,
            placeholder: "Work/Important"
      field :label_list_visibility, type: "options", display_name: "Label List Visibility",
            default: "labelShow",
            options: [
              { name: "Show",            value: "labelShow" },
              { name: "Hide",            value: "labelHide" },
              { name: "Show If Unread",  value: "labelShowIfUnread" }
            ]
      field :message_list_visibility, type: "options", display_name: "Message List Visibility",
            default: "show",
            options: [
              { name: "Show", value: "show" },
              { name: "Hide", value: "hide" }
            ]

      output do
        field :id, type: "string"
        field :name, type: "string"
        field :type, type: "string"
      end

      execute { |input| create_label(**input.symbolize_keys) }
    end

    action :delete_label,
           display_name: "Delete Label",
           description:  "Delete a user label." do
      field :id, type: "string", display_name: "Label ID", required: true
      output { field :success, type: "boolean" }
      execute { |input| delete_label(id: input["id"]) }
    end

    # =========================================================================
    # DRAFT ACTIONS
    # =========================================================================
    action :create_draft,
           display_name: "Create Draft",
           description:  "Create an email draft (users.drafts.create)." do
      field :to, type: "string", display_name: "To",
            type_options: { multiple_values: true }
      field :subject, type: "string", display_name: "Subject"
      field :html, type: "string", display_name: "HTML Body", type_options: { editor: "html" }
      field :text, type: "string", display_name: "Plain Text Body", type_options: { rows: 6 }
      field :cc, type: "string", display_name: "CC", type_options: { multiple_values: true }
      field :bcc, type: "string", display_name: "BCC", type_options: { multiple_values: true }
      field :reply_to, type: "string", display_name: "Reply To", type_options: { multiple_values: true }
      field :from, type: "string", display_name: "From (alias)"
      field :thread_id, type: "string", display_name: "Thread ID",
            description: "Attach the draft to an existing thread."
      field :attachments, type: "json", display_name: "Attachments"
      field :headers, type: "json", display_name: "Custom Headers"

      output do
        field :id, type: "string"
        field :message, type: "json"
      end

      execute { |input| create_draft(**input.symbolize_keys) }
    end

    action :get_draft,
           display_name: "Get Draft",
           description:  "Fetch a single draft by id." do
      field :id, type: "string", display_name: "Draft ID", required: true
      field :format, type: "options", display_name: "Format", default: "full",
            options: [
              { name: "Full",     value: "full" },
              { name: "Metadata", value: "metadata" },
              { name: "Minimal",  value: "minimal" },
              { name: "Raw",      value: "raw" }
            ]

      output do
        field :id, type: "string"
        field :message, type: "json"
      end

      execute { |input| get_draft(**input.symbolize_keys) }
    end

    action :list_drafts,
           display_name: "List Drafts",
           description:  "Returns the user's drafts (users.drafts.list)." do
      field :q, type: "string", display_name: "Query"
      field :max_results, type: "number", display_name: "Max Results", default: 100
      field :include_spam_trash, type: "boolean", display_name: "Include Spam & Trash", default: false
      field :page_token, type: "string", display_name: "Page Token"

      output do
        field :drafts, type: "json"
        field :next_page_token, type: "string"
        field :result_size_estimate, type: "number"
      end

      execute { |input| list_drafts(**input.symbolize_keys) }
    end

    action :list_all_drafts,
           display_name: "List All Drafts (auto-paginate)",
           description:  "Same as List Drafts but walks every `nextPageToken`." do
      field :q, type: "string", display_name: "Query"

      output { field :drafts, type: "json" }

      execute { |input| list_all_drafts(**input.symbolize_keys) }
    end

    action :delete_draft,
           display_name: "Delete Draft",
           description:  "Permanently delete a draft." do
      field :id, type: "string", display_name: "Draft ID", required: true
      output { field :success, type: "boolean" }
      execute { |input| delete_draft(id: input["id"]) }
    end

    # =========================================================================
    # API METHODS — thin wrappers around Gmail REST endpoints. Actions
    # delegate to these methods; authorized Ruby callers can use
    # `grant.connector.<method>` directly.
    # =========================================================================

    def send_message(to:, subject:, html: nil, text: nil,
                     cc: nil, bcc: nil, reply_to: nil, from: nil,
                     thread_id: nil, in_reply_to: nil, references: nil,
                     attachments: nil, headers: nil)
      raw = Gmail::MimeBuilder.build(
        from:        from,
        to:          to,
        cc:          cc,
        bcc:         bcc,
        reply_to:    reply_to,
        subject:     subject,
        html:        html,
        text:        text,
        attachments: attachments,
        headers:     headers,
        in_reply_to: in_reply_to,
        references:  references
      )

      body = { "raw" => raw }
      body["threadId"] = thread_id if thread_id

      response = Api.request(client, :post, "users/me/messages/send", body: body, resource: "message")
      normalize_message(response)
    end

    # Fetches the parent message's headers and sends a threaded reply
    # using MimeBuilder.
    def reply_to_message(message_id:, html: nil, text: nil,
                          cc: nil, bcc: nil, sender_name: nil,
                          reply_to_sender_only: false,
                          reply_to_recipients_only: false,
                          attachments: nil)
      raise Connectors::ApiError.new("`reply_to_sender_only` and `reply_to_recipients_only` are mutually exclusive") \
        if reply_to_sender_only && reply_to_recipients_only
      raise Connectors::ApiError.new("reply requires html or text") if html.nil? && text.nil?

      parent = Api.request(
        client, :get,
        "users/me/messages/#{message_id}",
        query: { format: "metadata", metadataHeaders: %w[From To Cc Reply-To Subject Message-ID References] },
        resource: "message"
      )

      headers     = header_hash(parent.dig("payload", "headers"))
      thread_id   = parent["threadId"]
      message_gid = headers["message-id"]
      subject     = headers["subject"].to_s
      reply_subject = subject.start_with?(/re:\s/i) ? subject : "Re: #{subject}"

      # Apply sender/recipient flags, prefer Reply-To over From, and exclude self.
      profile = Api.request(client, :get, "users/me/profile", resource: "profile")
      my_email = profile["emailAddress"].to_s

      reply_to_header = headers["reply-to"]
      to = []
      unless reply_to_recipients_only
        primary = reply_to_header.presence || headers["from"]
        to.concat(parse_recipient_list(primary)) if primary
      end
      unless reply_to_sender_only
        to.concat(parse_recipient_list(headers["to"])) if headers["to"]
      end
      to = to.reject { |addr| addr.include?(my_email) }.uniq

      from = sender_name ? "#{sender_name} <#{my_email}>" : nil

      references_chain = [ headers["references"], message_gid ].compact.join(" ").strip

      raw = Gmail::MimeBuilder.build(
        from:        from,
        to:          to,
        cc:          cc,
        bcc:         bcc,
        subject:     reply_subject,
        html:        html,
        text:        text,
        attachments: attachments,
        in_reply_to: message_gid,
        references:  references_chain.presence
      )

      response = Api.request(
        client, :post, "users/me/messages/send",
        body: { "raw" => raw, "threadId" => thread_id },
        resource: "message"
      )
      normalize_message(response)
    end

    def list_messages(q: nil, label_ids: nil, max_results: nil,
                      include_spam_trash: nil, page_token: nil)
      body = Api.request(
        client, :get, "users/me/messages",
        query: list_query(q: q, label_ids: label_ids, max_results: max_results,
                          include_spam_trash: include_spam_trash, page_token: page_token),
        resource: "message"
      )
      {
        "messages"             => Array(body["messages"]).map { |m| { "id" => m["id"], "thread_id" => m["threadId"] } },
        "next_page_token"      => body["nextPageToken"],
        "result_size_estimate" => body["resultSizeEstimate"]
      }.compact
    end

    def list_all_messages(q: nil, label_ids: nil, include_spam_trash: nil)
      raw = Api.request_all(
        client, "messages", :get, "users/me/messages",
        query: list_query(q: q, label_ids: label_ids, include_spam_trash: include_spam_trash),
        resource: "message"
      )
      { "messages" => raw.map { |m| { "id" => m["id"], "thread_id" => m["threadId"] } } }
    end

    def get_message(id:, format: "full", metadata_headers: nil)
      query = { format: format }
      Array(metadata_headers).each_with_index { |h, i| query["metadataHeaders[#{i}]"] = h }
      body = Api.request(client, :get, "users/me/messages/#{id}", query: query, resource: "message")

      result = normalize_message(body)
      result["envelope"] = MimeParser.parse(body["payload"]) if format.to_s == "full" && body["payload"]
      result
    end

    def delete_message(id:)
      Api.request(client, :delete, "users/me/messages/#{id}", resource: "message")
      { "success" => true }
    end

    def trash_message(id:)
      body = Api.request(client, :post, "users/me/messages/#{id}/trash", body: {}, resource: "message")
      normalize_message(body)
    end

    def untrash_message(id:)
      body = Api.request(client, :post, "users/me/messages/#{id}/untrash", body: {}, resource: "message")
      normalize_message(body)
    end

    def mark_message_as_read(id:)
      modify_message_labels(id: id, add_label_ids: nil, remove_label_ids: [ "UNREAD" ])
    end

    def mark_message_as_unread(id:)
      modify_message_labels(id: id, add_label_ids: [ "UNREAD" ], remove_label_ids: nil)
    end

    def modify_message_labels(id:, add_label_ids: nil, remove_label_ids: nil)
      body = {}
      body["addLabelIds"]    = Array(add_label_ids)    if add_label_ids
      body["removeLabelIds"] = Array(remove_label_ids) if remove_label_ids
      response = Api.request(client, :post, "users/me/messages/#{id}/modify", body: body, resource: "message")
      normalize_message(response)
    end

    # ----- threads -----
    def list_threads(q: nil, label_ids: nil, max_results: nil,
                     include_spam_trash: nil, page_token: nil)
      body = Api.request(
        client, :get, "users/me/threads",
        query: list_query(q: q, label_ids: label_ids, max_results: max_results,
                          include_spam_trash: include_spam_trash, page_token: page_token),
        resource: "thread"
      )
      {
        "threads"              => Array(body["threads"]).map { |t| normalize_thread_stub(t) },
        "next_page_token"      => body["nextPageToken"],
        "result_size_estimate" => body["resultSizeEstimate"]
      }.compact
    end

    def list_all_threads(q: nil, label_ids: nil, include_spam_trash: nil)
      raw = Api.request_all(
        client, "threads", :get, "users/me/threads",
        query: list_query(q: q, label_ids: label_ids, include_spam_trash: include_spam_trash),
        resource: "thread"
      )
      { "threads" => raw.map { |t| normalize_thread_stub(t) } }
    end

    def get_thread(id:, format: "full")
      body = Api.request(client, :get, "users/me/threads/#{id}", query: { format: format }, resource: "thread")
      {
        "id"         => body["id"],
        "history_id" => body["historyId"],
        "messages"   => Array(body["messages"]).map { |m| normalize_message(m) }
      }
    end

    def delete_thread(id:)
      Api.request(client, :delete, "users/me/threads/#{id}", resource: "thread")
      { "success" => true }
    end

    def trash_thread(id:)
      body = Api.request(client, :post, "users/me/threads/#{id}/trash", body: {}, resource: "thread")
      { "id" => body["id"] }
    end

    def untrash_thread(id:)
      body = Api.request(client, :post, "users/me/threads/#{id}/untrash", body: {}, resource: "thread")
      { "id" => body["id"] }
    end

    def modify_thread_labels(id:, add_label_ids: nil, remove_label_ids: nil)
      body = {}
      body["addLabelIds"]    = Array(add_label_ids)    if add_label_ids
      body["removeLabelIds"] = Array(remove_label_ids) if remove_label_ids
      response = Api.request(client, :post, "users/me/threads/#{id}/modify", body: body, resource: "thread")
      { "id" => response["id"] }
    end

    # ----- labels -----
    def list_labels
      body = Api.request(client, :get, "users/me/labels", resource: "label")
      { "labels" => Array(body["labels"]) }
    end

    def get_label(id:)
      body = Api.request(client, :get, "users/me/labels/#{id}", resource: "label")
      {
        "id"              => body["id"],
        "name"            => body["name"],
        "type"            => body["type"],
        "messages_total"  => body["messagesTotal"],
        "messages_unread" => body["messagesUnread"]
      }
    end

    def create_label(name:, label_list_visibility: "labelShow", message_list_visibility: "show")
      body = Api.request(
        client, :post, "users/me/labels",
        body: {
          "name"                  => name,
          "labelListVisibility"   => label_list_visibility,
          "messageListVisibility" => message_list_visibility
        },
        resource: "label"
      )
      body
    end

    def delete_label(id:)
      Api.request(client, :delete, "users/me/labels/#{id}", resource: "label")
      { "success" => true }
    end

    # ----- drafts -----
    def create_draft(to: nil, subject: nil, html: nil, text: nil,
                     cc: nil, bcc: nil, reply_to: nil, from: nil,
                     thread_id: nil, attachments: nil, headers: nil)
      # Drafts allow empty bodies (Gmail itself does), so don't reject html+text=nil.
      raw = Gmail::MimeBuilder.build_draft(
        from:        from,
        to:          to,
        cc:          cc,
        bcc:         bcc,
        reply_to:    reply_to,
        subject:     subject.to_s,
        html:        html,
        text:        text,
        attachments: attachments,
        headers:     headers
      )

      message_body = { "raw" => raw }
      message_body["threadId"] = thread_id if thread_id

      response = Api.request(
        client, :post, "users/me/drafts",
        body: { "message" => message_body },
        resource: "draft"
      )
      { "id" => response["id"], "message" => normalize_message(response["message"]) }
    end

    def get_draft(id:, format: "full")
      body = Api.request(client, :get, "users/me/drafts/#{id}", query: { format: format }, resource: "draft")
      { "id" => body["id"], "message" => body["message"].is_a?(Hash) ? normalize_message(body["message"]) : nil }
    end

    def list_drafts(q: nil, max_results: nil, include_spam_trash: nil, page_token: nil)
      body = Api.request(
        client, :get, "users/me/drafts",
        query: list_query(q: q, max_results: max_results, include_spam_trash: include_spam_trash, page_token: page_token),
        resource: "draft"
      )
      {
        "drafts"               => Array(body["drafts"]).map { |d| { "id" => d["id"], "message" => normalize_message(d["message"]) } },
        "next_page_token"      => body["nextPageToken"],
        "result_size_estimate" => body["resultSizeEstimate"]
      }.compact
    end

    def list_all_drafts(q: nil)
      raw = Api.request_all(client, "drafts", :get, "users/me/drafts", query: list_query(q: q), resource: "draft")
      { "drafts" => raw.map { |d| { "id" => d["id"], "message" => normalize_message(d["message"]) } } }
    end

    def delete_draft(id:)
      Api.request(client, :delete, "users/me/drafts/#{id}", resource: "draft")
      { "success" => true }
    end

    def handle_webhook(event)
      Rails.logger.info("[gmail] webhook event=#{event.id} payload=#{event.payload_hash.inspect}")
    end

    private

    def list_query(q: nil, label_ids: nil, max_results: nil, include_spam_trash: nil, page_token: nil)
      query = {}
      query[:q]                = q                       if q && !q.to_s.empty?
      query["labelIds[]"]      = Array(label_ids)        if label_ids
      query[:maxResults]       = max_results             if max_results
      query[:includeSpamTrash] = include_spam_trash      unless include_spam_trash.nil?
      query[:pageToken]        = page_token              if page_token
      query
    end

    def normalize_message(body)
      return nil if body.nil?
      return body unless body.is_a?(Hash)
      {
        "id"         => body["id"],
        "thread_id"  => body["threadId"],
        "label_ids"  => body["labelIds"],
        "snippet"    => body["snippet"],
        "payload"    => body["payload"]
      }.compact
    end

    def normalize_thread_stub(t)
      {
        "id"         => t["id"],
        "history_id" => t["historyId"],
        "snippet"    => t["snippet"]
      }.compact
    end

    def header_hash(arr)
      Array(arr).each_with_object({}) do |h, acc|
        next unless h.is_a?(Hash) && h["name"]
        acc[h["name"].downcase] = h["value"]
      end
    end

    # Splits "Foo Bar <foo@bar>, Baz <baz@qux>" into proper RFC 5322 addrs.
    def parse_recipient_list(value)
      return [] if value.nil?
      value.to_s.split(",").map(&:strip).reject(&:empty?)
    end
  end
end
