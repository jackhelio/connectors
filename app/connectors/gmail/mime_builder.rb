require "base64"
require "securerandom"
require "time"

module Gmail
  # Minimal RFC 5322 / RFC 2045 / RFC 2047 / RFC 2231 builder for the Gmail
  # `users.messages.send` and `users.drafts.create` endpoints. Gmail wants
  # the entire message as base64url-encoded MIME in a `raw` field — there's
  # no JSON shortcut for `body`/`subject`/`attachments`.
  #
  # Handles:
  #   1. text only                        → text/plain
  #   2. html only                        → text/html
  #   3. html + text                      → multipart/alternative
  #   4. (any of the above) + attachments → multipart/mixed
  #   5. empty body (drafts)              → empty text/plain
  #
  # Non-ASCII data is handled via:
  #   - Subject + From/To/Cc display-name phrases: RFC 2047 encoded-word
  #   - Attachment filenames: RFC 2231 continuation (filename*=UTF-8''…)
  #   - Bodies: base64 transfer-encoded UTF-8
  class MimeBuilder
    CRLF = "\r\n".freeze

    def self.build(**opts)
      new(**opts).build
    end

    # Like `.build`, but allows an empty body (drafts only — Gmail's
    # `users.drafts.create` accepts empty messages).
    def self.build_draft(**opts)
      new(**opts.merge(allow_empty: true)).build
    end

    def initialize(to: nil, subject: nil, from: nil, cc: nil, bcc: nil, reply_to: nil,
                   html: nil, text: nil, attachments: nil, headers: nil,
                   thread_id: nil, in_reply_to: nil, references: nil,
                   allow_empty: false)
      @to          = Array(to).reject { |v| v.to_s.empty? }
      @cc          = Array(cc).reject { |v| v.to_s.empty? }
      @bcc         = Array(bcc).reject { |v| v.to_s.empty? }
      @reply_to    = Array(reply_to).reject { |v| v.to_s.empty? }
      @from        = from
      @subject     = subject.to_s
      @html        = html
      @text        = text
      @attachments = Array(attachments)
      @headers     = headers || {}
      @thread_id   = thread_id
      @in_reply_to = in_reply_to
      @references  = references
      @allow_empty = allow_empty

      return if allow_empty

      raise ArgumentError, "send_message requires html or text" if @html.nil? && @text.nil?
      raise ArgumentError, "send_message requires at least one recipient" if @to.empty?
    end

    # Returns the full MIME message as a base64url-encoded string, ready to
    # drop into Gmail's `raw` field.
    def build
      Base64.urlsafe_encode64(raw_message, padding: false)
    end

    def raw_message
      if @attachments.any?
        build_multipart_mixed
      elsif @html && @text
        build_multipart_alternative
      elsif @html
        build_part(content_type: "text/html; charset=UTF-8", body: @html, with_headers: true)
      else
        # Covers text-only AND empty-body drafts (text becomes "").
        build_part(content_type: "text/plain; charset=UTF-8", body: @text || "", with_headers: true)
      end
    end

    private

    def build_multipart_alternative
      boundary = "alt_#{SecureRandom.hex(8)}"
      body = +""
      body << "--#{boundary}" << CRLF
      body << inline_part(content_type: "text/plain; charset=UTF-8", body: @text)
      body << "--#{boundary}" << CRLF
      body << inline_part(content_type: "text/html; charset=UTF-8", body: @html)
      body << "--#{boundary}--" << CRLF

      headers_lines("multipart/alternative; boundary=\"#{boundary}\"") + CRLF + body
    end

    def build_multipart_mixed
      boundary = "mix_#{SecureRandom.hex(8)}"
      body = +""

      body << "--#{boundary}" << CRLF
      if @html && @text
        body << build_multipart_alternative_without_headers
      elsif @html
        body << inline_part(content_type: "text/html; charset=UTF-8", body: @html)
      else
        body << inline_part(content_type: "text/plain; charset=UTF-8", body: @text || "")
      end

      @attachments.each do |att|
        body << "--#{boundary}" << CRLF
        body << inline_attachment(att)
      end
      body << "--#{boundary}--" << CRLF

      headers_lines("multipart/mixed; boundary=\"#{boundary}\"") + CRLF + body
    end

    def build_multipart_alternative_without_headers
      boundary = "alt_#{SecureRandom.hex(8)}"
      part = +""
      part << "Content-Type: multipart/alternative; boundary=\"#{boundary}\"" << CRLF << CRLF
      part << "--#{boundary}" << CRLF
      part << inline_part(content_type: "text/plain; charset=UTF-8", body: @text || "")
      part << "--#{boundary}" << CRLF
      part << inline_part(content_type: "text/html; charset=UTF-8", body: @html || "")
      part << "--#{boundary}--" << CRLF
      part
    end

    def build_part(content_type:, body:, with_headers:)
      header_block = with_headers ? headers_lines(content_type) : ""
      "#{header_block}#{CRLF}#{base64_wrapped(body)}"
    end

    def inline_part(content_type:, body:)
      part = +""
      part << "Content-Type: #{content_type}" << CRLF
      part << "Content-Transfer-Encoding: base64" << CRLF << CRLF
      part << base64_wrapped(body) << CRLF
      part
    end

    def inline_attachment(att)
      filename     = att[:filename] || att["filename"] || "attachment"
      content_type = att[:content_type] || att["content_type"] || "application/octet-stream"
      content      = att[:content] || att["content"]
      raise ArgumentError, "attachment #{filename.inspect} missing `content`" if content.to_s.empty?

      cid           = att[:content_id] || att["content_id"]
      disposition   = (att[:disposition] || att["disposition"] || "attachment").to_s

      part = +""
      part << "Content-Type: #{content_type}; #{filename_param(filename)}" << CRLF
      part << "Content-Disposition: #{disposition}; #{filename_param(filename, disposition: true)}" << CRLF
      part << "Content-ID: <#{cid}>" << CRLF if cid
      part << "Content-Transfer-Encoding: base64" << CRLF << CRLF
      part << base64_normalize(content) << CRLF
      part
    end

    def headers_lines(content_type)
      lines = []
      lines << "MIME-Version: 1.0"
      lines << "Date: #{Time.now.utc.rfc2822}"
      lines << "From: #{encode_address(@from)}"               if @from
      lines << "To: #{format_address_list(@to)}"              if @to.any?
      lines << "Cc: #{format_address_list(@cc)}"              if @cc.any?
      lines << "Bcc: #{format_address_list(@bcc)}"            if @bcc.any?
      lines << "Reply-To: #{format_address_list(@reply_to)}"  if @reply_to.any?
      lines << "Subject: #{encode_rfc2047(@subject)}"
      lines << "In-Reply-To: #{@in_reply_to}"                 if @in_reply_to
      lines << "References: #{@references}"                   if @references
      lines << "Message-ID: <#{SecureRandom.uuid}@flow>"
      @headers.each { |k, v| lines << "#{k}: #{v}" }
      lines << "Content-Type: #{content_type}"
      # multipart containers don't carry a transfer-encoding line — each
      # sub-part declares its own.
      lines << "Content-Transfer-Encoding: base64" unless content_type.start_with?("multipart")
      lines.join(CRLF) + CRLF
    end

    def format_address_list(list)
      list.map { |a| encode_address(a) }.join(", ")
    end

    # If the address has a display-name phrase, RFC 2047-encode the phrase
    # when it carries non-ASCII chars. Examples:
    #   "héllo@example.com"        → "héllo@example.com"           (ASCII addr-spec, passes through)
    #   "Héllo <h@example.com>"    → "=?UTF-8?B?SMOpbGxv?= <h@example.com>"
    #   "h@example.com"            → "h@example.com"
    def encode_address(address)
      addr = address.to_s
      if (m = addr.match(/\A(.+?)\s*<(.+)>\z/))
        phrase, mailbox = m[1].strip, m[2].strip
        encoded_phrase = encode_rfc2047(phrase)
        "#{encoded_phrase} <#{mailbox}>"
      else
        addr
      end
    end

    # RFC 2047 encoded-word for non-ASCII text. ASCII strings pass through
    # unchanged. Long inputs are chunked into multiple encoded-words at
    # 70-byte boundaries (the RFC allows up to 75; 70 gives breathing room).
    def encode_rfc2047(text)
      str = text.to_s
      return str if str.ascii_only?

      bytes = str.dup.force_encoding(Encoding::UTF_8).bytes
      chunks = []
      chunks << [] while false # placeholder; built below
      buf = []
      bytes.each do |b|
        if buf.length >= 45  # 45 raw bytes ≈ 60 base64 chars + wrapper → ~75 total
          chunks << buf
          buf = []
        end
        buf << b
      end
      chunks << buf unless buf.empty?

      chunks.map { |chunk|
        "=?UTF-8?B?#{Base64.strict_encode64(chunk.pack('C*'))}?="
      }.join(" ")
    end

    # Builds `name="ascii"` for plain ASCII filenames; RFC 2231-continuation
    # `filename*=UTF-8''…percent…encoded…` for non-ASCII. `name` (Content-
    # Type) vs `filename` (Content-Disposition) handled via `disposition:`.
    def filename_param(filename, disposition: false)
      key = disposition ? "filename" : "name"
      if filename.ascii_only?
        %Q(#{key}="#{filename.gsub('"', '\\"')}")
      else
        encoded = percent_encode(filename)
        %Q(#{key}*=UTF-8''#{encoded})
      end
    end

    def percent_encode(str)
      str.b.unpack("C*").map { |b|
        # Allow only the RFC 2231 attribute-char set; percent-encode everything else.
        if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || [ 0x2D, 0x2E, 0x5F, 0x7E ].include?(b)
          b.chr
        else
          format("%%%02X", b)
        end
      }.join
    end

    def base64_wrapped(body)
      str = body.to_s.dup.force_encoding(Encoding::UTF_8)
      Base64.encode64(str).gsub("\n", CRLF)
    end

    def base64_normalize(b64)
      stripped = b64.to_s.delete("\r\n ")
      stripped.scan(/.{1,76}/).join(CRLF)
    end
  end
end
