module McpDnsSpecHelpers
  # pg resolves database hosts through Addrinfo too. Only replace fixture hosts.
  def stub_mcp_dns(host = /\.example\.test\z/, addresses: [ "93.184.216.34" ])
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo).with(host, anything, nil, :STREAM)
      .and_return(addresses.map { |address| Addrinfo.ip(address) })
  end
end
