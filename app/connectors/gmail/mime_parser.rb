require "base64"

module Gmail
  # Parses Google's `messages.get?format=full` payload tree into a clean,
  # normalized message envelope.
  #
  # Google returns:
  #   { payload: {
  #       headers: [{name, value}, ...],
  #       mimeType: "...",
  #       body: { data: <base64url>, attachmentId: ... },
  #       parts: [ recursive parts ... ]
  #     } }
  #
  # We flatten that into:
  #   { from:, to:, cc:, bcc:, reply_to:, subject:, date:,
  #     headers: { ... lowercased keys ... },
  #     text:, html:, attachments: [{filename, content_type, size, attachment_id}, ...] }
  class MimeParser
    HEADERS_TO_LIFT = %w[from to cc bcc reply-to subject date].freeze

    def self.parse(payload)
      new(payload).parse
    end

    def initialize(payload)
      @payload = payload || {}
    end

    def parse
      headers = headers_hash(@payload["headers"])

      result = {
        "headers" => headers,
        "subject" => headers["subject"],
        "from"    => headers["from"],
        "to"      => split_list(headers["to"]),
        "cc"      => split_list(headers["cc"]),
        "bcc"     => split_list(headers["bcc"]),
        "reply_to" => split_list(headers["reply-to"]),
        "date"    => headers["date"],
        "text"    => nil,
        "html"    => nil,
        "attachments" => []
      }

      walk(@payload, result)
      result.compact
    end

    private

    def walk(part, result)
      mime_type = part["mimeType"].to_s
      filename  = part["filename"].to_s
      body      = part["body"] || {}

      if filename.empty?
        case mime_type
        when "text/plain"
          result["text"] ||= decode_body_data(body["data"])
        when "text/html"
          result["html"] ||= decode_body_data(body["data"])
        end
      elsif body["attachmentId"]
        result["attachments"] << {
          "filename"      => filename,
          "content_type"  => mime_type,
          "size"          => body["size"],
          "attachment_id" => body["attachmentId"]
        }
      elsif body["data"]
        # Inline attachment with body data already present.
        result["attachments"] << {
          "filename"      => filename,
          "content_type"  => mime_type,
          "size"          => body["size"],
          "content"       => body["data"]
        }
      end

      Array(part["parts"]).each { |child| walk(child, result) }
    end

    def headers_hash(arr)
      Array(arr).each_with_object({}) do |h, acc|
        next unless h.is_a?(Hash) && h["name"]
        acc[h["name"].downcase] = h["value"]
      end
    end

    def split_list(value)
      return nil if value.nil?
      value.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def decode_body_data(b64)
      return nil if b64.to_s.empty?
      padded = b64 + "=" * ((4 - b64.length % 4) % 4)
      Base64.urlsafe_decode64(padded)
    rescue StandardError
      nil
    end
  end
end
