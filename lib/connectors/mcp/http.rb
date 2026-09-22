require "net/http"
require "ipaddr"
require "socket"
require "timeout"

module Connectors
  module MCP
    # Pins the validated address while retaining the hostname for TLS/SNI.
    # Redirects and environment proxies are deliberately not followed.
    class HTTP
      Response = Data.define(:status, :headers, :body)
      BLOCKED = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8].map { |s| IPAddr.new(s) }.freeze

      def initialize(settings: Connectors.configuration.mcp)
        @settings = settings
      end

      def validate_url!(url)
        uri = URI.parse(url.to_s)
        raise ConfigurationRequired, "Invalid MCP destination" unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && !uri.fragment
        loopback = uri.hostname == "localhost" || IPAddr.new(uri.hostname).loopback? rescue false
        unless uri.scheme == "https" || (@settings.allow_loopback_http && loopback && uri.scheme == "http")
          raise ConfigurationRequired, "MCP destinations require HTTPS"
        end
        uri
      rescue URI::InvalidURIError
        raise ConfigurationRequired, "Invalid MCP destination"
      end

      def call(url:, method: :get, headers: {}, body: nil, stream: false, cancellation: nil, &consumer)
        cancellation_key = nil
        cancellation&.check!
        timeout = stream ? @settings.stream_timeout : @settings.request_timeout
        raise ConfigurationRequired, "Request limits must be positive" unless timeout.to_f.positive? && @settings.max_bytes.to_i.positive?
        raise ValidationError, "MCP request exceeds size limit" if body && body.bytesize > @settings.max_bytes
        Timeout.timeout(timeout, TransportError, "MCP request deadline exceeded") do
          uri = validate_url!(url)
          addresses = Addrinfo.getaddrinfo(uri.hostname, uri.port, nil, :STREAM).map(&:ip_address).uniq
          raise TransportError, "MCP destination could not be resolved" if addresses.empty?
          permitted = @settings.private_hosts.include?(uri.hostname) || (@settings.allow_loopback_http && addresses.all? { |ip| IPAddr.new(ip).loopback? })
          unless permitted || addresses.none? { |ip| blocked?(ip) }
            raise ConfigurationRequired, "MCP destination resolves to a restricted network"
          end
          connection = Net::HTTP.new(uri.hostname, uri.port, nil)
          connection.ipaddr = addresses.first
          connection.use_ssl = uri.scheme == "https"
          connection.open_timeout = @settings.open_timeout
          connection.read_timeout = timeout
          connection.write_timeout = timeout
          connection.max_retries = 0
          request = Net::HTTPGenericRequest.new(method.to_s.upcase, !body.nil?, true, uri.request_uri, headers)
          request.body = body if body
          connection.start do |http|
            cancellation_key = cancellation&.attach do
              begin
                http.finish if http.started?
              rescue IOError
                # The response may have closed the connection concurrently.
              end
            end
            http.request(request) do |response|
              status = response.code.to_i
              response_headers = response.each_header.to_h
              content = +""
              size = 0
              response.read_body do |chunk|
                cancellation&.check!
                size += chunk.bytesize
                raise TransportError, "MCP response exceeds size limit" if size > @settings.max_bytes
                if consumer && status.between?(200, 299)
                  consumer.call(chunk, response_headers)
                else
                  content << chunk
                end
              end
              result = Response.new(status: status, headers: response_headers, body: content)
              raise HTTPError.new(status: status, headers: response_headers, body: content) unless status.between?(200, 299)
              return result
            end
          end
        end
      rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
        cancellation&.check!
        raise TransportError, "MCP network request failed"
      ensure
        cancellation&.detach(cancellation_key) if cancellation_key
      end

      def json(**options)
        response = call(**options)
        raise ProtocolError, "Expected JSON metadata" unless response.headers["content-type"].to_s.split(";").first == "application/json"
        parsed = JSON.parse(response.body)
        raise ProtocolError, "Expected JSON object" unless parsed.is_a?(Hash)
        parsed
      rescue JSON::ParserError
        raise ProtocolError, "Invalid JSON metadata"
      end

      private

      def blocked?(address)
        ip = IPAddr.new(address)
        ip = ip.native if ip.ipv4_mapped?
        BLOCKED.any? { |range| range.include?(ip) }
      end
    end
  end
end
