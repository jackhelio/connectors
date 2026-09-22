require "rails_helper"
require "socket"
require "timeout"

RSpec.describe "MCP real HTTP streaming" do
  before do
    Connectors.configuration.mcp.allow_loopback_http = true
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.addr[1]}/mcp"
    @connections = []
  end
  after do
    @connections.each { |socket| socket.close unless socket.closed? }
    @server.close
    @worker&.kill if @worker&.alive?
    @worker&.join
  end

  def serve(&handler)
    @worker = Thread.new do
      socket = @server.accept
      @connections << socket
      request_line = socket.gets
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      handler.call(socket, JSON.parse(body), request_line)
    rescue IOError
      # Test teardown can close an intentionally idle server stream.
    end
  end

  it "parses a response split across actual TCP writes" do
    serve do |socket, request, _|
      body = "data: #{ { jsonrpc: '2.0', id: request['id'], result: { content: [ { type: 'text', text: 'streamed' } ] } }.to_json }\n\n"
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
      body.chars.each_slice(7) do |slice|
        chunk = slice.join
        socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
      end
      socket.write("0\r\n\r\n")
      socket.close
    end
    result = Connectors::MCP::Transport.new(url: @url).request("tools/call", { "name" => "echo" })
    expect(result["content"].first["text"]).to eq("streamed")
    Timeout.timeout(5) { @worker.value }
  end

  it "cancels an idle subscription without waiting for the read deadline" do
    entered = Queue.new
    serve do |socket, request, _|
      ack = { jsonrpc: "2.0", method: "notifications/subscriptions/acknowledged", params: { _meta: { "io.modelcontextprotocol/subscriptionId" => request["id"] }, notifications: { toolsListChanged: true } } }
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: #{ack.to_json}\n\n")
      entered << true
      socket.read
    rescue Errno::ECONNRESET
      # Cancelling with unread response bytes can reset the socket on Linux.
    end
    cancellation = Connectors::MCP::Cancellation.new
    reader = Thread.new do
      Connectors::MCP::Transport.new(url: @url).request("subscriptions/listen", { "notifications" => { "toolsListChanged" => true } }, subscription: true, cancellation: cancellation) { }
    rescue Connectors::MCP::Cancelled
      :cancelled
    end
    Timeout.timeout(5) { entered.pop }
    cancellation.cancel
    expect(Timeout.timeout(5) { reader.value }).to eq(:cancelled)
  ensure
    reader&.kill if reader&.alive?
    reader&.join
  end
end
