module Gmail
  # Polling trigger logic. Invoked once per scheduler tick by
  # `Connectors::PollRunner.run(grant)`, which threads in the per-grant
  # scratch hash stored at `grant.static_data["polling"]`.
  #
  # n8n parity: `packages/nodes-base/nodes/Google/Gmail/GmailTrigger.node.ts`.
  # Key invariants we copy 1:1:
  #
  #   * Cursor = `last_checked_at` (unix seconds). First-ever poll bootstraps
  #     the cursor to `now` and emits nothing.
  #   * Query: `after:<last_checked_at> -in:scheduled` plus any author-
  #     supplied filters. Gmail's `after:` is INCLUSIVE at the second
  #     boundary, so we maintain `possible_duplicates` — ids emitted at
  #     exactly the cursor second — and exclude them from the next list.
  #   * For each new id, fetch full message via Api.request, run through
  #     MimeParser, return the parsed envelope.
  #   * Drafts (`labelIds includes DRAFT`) skipped unless `include_drafts`.
  #   * Sent-but-not-Inbox messages skipped (Gmail emits them as both
  #     SENT and INBOX when the user is the recipient; we want the inbound
  #     copy, not the outbound).
  #
  # Filters are passed via `grant.static_data["polling"]["filters"]` so the
  # workflow author can configure them per-trigger when the automations
  # engine hooks this up:
  #
  #   {
  #     "q"               => "from:boss has:attachment",  # raw Gmail search
  #     "label_ids"       => ["INBOX", "Label_42"],
  #     "sender"          => "alerts@stripe.com",
  #     "read_status"     => "unread",                     # unread | read | both
  #     "include_spam_trash" => false,
  #     "include_drafts"  => false,
  #     "max_results"     => 25                            # per poll
  #   }
  class Polling
    DEFAULT_MAX_RESULTS = 25

    def initialize(grant, static_data, now: nil)
      @grant       = grant
      @sd          = static_data
      @now         = now || Time.now.to_i
      @connector   = grant.connector
      @client      = @connector.client
      @filters     = (static_data["filters"] || {}).transform_keys(&:to_s)
      @max_results = (@filters["max_results"] || DEFAULT_MAX_RESULTS).to_i
    end

    def run
      first_run = @sd["last_checked_at"].nil?

      if first_run
        @sd["last_checked_at"]      = @now
        @sd["possible_duplicates"]  = []
        return []
      end

      list_body = Api.request(
        @client, :get, "users/me/messages",
        query: build_query,
        resource: "message"
      )

      ids = Array(list_body["messages"]).map { |m| m["id"] }
      duplicates = Array(@sd["possible_duplicates"])
      ids -= duplicates
      return [] if ids.empty?

      messages = []
      max_internal_date = 0

      ids.first(@max_results).each do |id|
        full = Api.request(@client, :get, "users/me/messages/#{id}",
                            query: { format: "full" }, resource: "message")
        next if skip?(full)

        envelope = MimeParser.parse(full["payload"]) if full["payload"]
        internal_date = full["internalDate"].to_i / 1000   # Gmail uses ms

        messages << {
          "id"            => full["id"],
          "thread_id"     => full["threadId"],
          "label_ids"     => full["labelIds"],
          "snippet"       => full["snippet"],
          "envelope"      => envelope,
          "internal_date" => internal_date
        }.compact

        max_internal_date = internal_date if internal_date > max_internal_date
      end

      advance_cursor(messages, max_internal_date)
      messages
    end

    private

    # Gmail search syntax. n8n's prepareQuery is the reference; the order
    # of clauses doesn't matter to Gmail, but keep the same join scheme so
    # diffs against n8n are easy to read.
    def build_query
      qs = {}
      qs["labelIds[]"]      = Array(@filters["label_ids"]) if @filters["label_ids"]
      qs[:maxResults]       = @max_results
      qs[:includeSpamTrash] = true if @filters["include_spam_trash"]

      q_parts = []
      q_parts << @filters["q"] if @filters["q"].to_s.length.positive?
      q_parts << "from:#{@filters['sender']}" if @filters["sender"].to_s.length.positive?

      status = @filters["read_status"].to_s
      q_parts << "is:#{status}" if status == "unread" || status == "read"

      # Boundary-inclusive `after:` — same behavior n8n leans on; we
      # de-dupe via possible_duplicates rather than narrowing the window.
      q_parts << "after:#{@sd['last_checked_at']}"

      # `-in:scheduled` matches n8n's v1.4+ guard (scheduled-send drafts
      # appear in users.messages.list but aren't real inbound mail yet).
      q_parts << "-in:scheduled"

      qs[:q] = q_parts.join(" ")
      qs
    end

    def skip?(message)
      label_ids = Array(message["labelIds"])
      return true if label_ids.include?("DRAFT") && !@filters["include_drafts"]
      return true if label_ids.include?("SENT") && !label_ids.include?("INBOX")
      false
    end

    # Advance `last_checked_at` to the newest message we just emitted,
    # and capture the ids at that boundary for next-poll deduplication.
    def advance_cursor(messages, max_internal_date)
      return if messages.empty?

      previous_cursor = @sd["last_checked_at"].to_i
      next_cursor     = [ max_internal_date, previous_cursor ].max

      ids_at_boundary = messages.select { |m| m["internal_date"] == next_cursor }
                                 .map { |m| m["id"] }

      if next_cursor == previous_cursor
        # Cursor didn't move — same second as last time. Append new ids
        # to the existing dedupe set rather than replacing it.
        existing = Array(@sd["possible_duplicates"])
        @sd["possible_duplicates"] = (existing + ids_at_boundary).uniq
      else
        @sd["last_checked_at"]     = next_cursor
        @sd["possible_duplicates"] = ids_at_boundary
      end
    end
  end
end
