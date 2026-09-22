require_relative "lib/connectors/version"

Gem::Specification.new do |spec|
  spec.name        = "connectors"
  spec.version     = Connectors::VERSION
  spec.authors     = [ "Jackson Helio" ]
  spec.email       = [ "4428869+jackhelio@users.noreply.github.com" ]
  spec.homepage    = "https://github.com/jackhelio/connectors"
  spec.summary     = "Rails connector engine for provider APIs and remote MCP tools."
  spec.description = "Mountable Rails engine with encrypted credentials, role-based sharing, OAuth, provider actions, webhooks and polling. Includes authenticated HTTP clients and remote MCP tool discovery and invocation with durable OAuth and elicitation. Hosts supply authentication, encryption keys and scheduling."
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2.0"
  spec.requirements = [ "PostgreSQL 13+; UUID primary keys for owner and sharing-principal models" ]

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = "#{spec.homepage}/tree/main"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/README.md"
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,lib}/**/*", "db/migrate/*.rb", "docs/**/*.md",
      "MIT-LICENSE", "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "CONNECTORS_FRAMEWORK.md", "MCP_CLIENT.md", "openapi.yaml"]
      .select { |path| File.file?(path) }.sort
  end
  spec.extra_rdoc_files = %w[README.md CHANGELOG.md CONNECTORS_FRAMEWORK.md MCP_CLIENT.md]
  spec.rdoc_options = [ "--main", "README.md" ]

  spec.add_dependency "rails", "~> 8.1.3"
  # Rails 8.1 passes a positional options hash to JSON.parse; JSON 3 requires keywords.
  spec.add_dependency "json", ">= 2.3", "< 3"
  spec.add_dependency "faraday", "~> 2.9"
  spec.add_dependency "faraday-retry", "~> 2.2"
  spec.add_dependency "oauth2", "~> 2.0"
  spec.add_dependency "mcp", "= 1.6.0"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "event_stream_parser", "~> 1.0"
end
