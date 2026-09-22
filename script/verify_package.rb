# Builds and installs in a temporary directory; never publishes or accesses a provider.
require "fileutils"
require "open3"
require "pathname"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

root = File.expand_path("..", __dir__)
dependency_paths = Gem.path

def run!(*command, **options)
  output, status = Open3.capture2e(*command, **options)
  abort output unless status.success?
  puts output unless output.empty?
end

Dir.mktmpdir("connectors-package-") do |temporary|
  archive = File.join(temporary, "connectors.gem")
  run!(Gem.ruby, "-S", "gem", "build", "connectors.gemspec", "--strict", "--output", archive, chdir: root)
  package = Gem::Package.new(archive)
  metadata = package.spec.metadata
  abort "Unexpected publishing destination" unless metadata["allowed_push_host"] == "https://rubygems.org"
  homepage = "https://github.com/jackhelio/connectors"
  abort "Incorrect repository homepage" unless package.spec.homepage == homepage
  %w[homepage_uri source_code_uri documentation_uri changelog_uri].each do |key|
    value = metadata.fetch(key, "")
    abort "Incorrect #{key}: #{value}" unless value == homepage || value.start_with?("#{homepage}/")
  end
  required = %w[README.md MIT-LICENSE CHANGELOG.md CONTRIBUTING.md CONNECTORS_FRAMEWORK.md MCP_CLIENT.md openapi.yaml
    docs/architecture.md docs/adding-connectors.md docs/releasing.md lib/connectors.rb
    lib/connectors/mcp/protocol/2026-07-28.json lib/connectors/mcp/protocol/LICENSE]
  missing = required - package.contents
  abort "Missing package files: #{missing.join(', ')}" unless missing.empty?
  unwanted = package.contents.grep(%r{\A(?:test|spec|tmp|log|internal-docs|\.git)/|(?:\A|/)(?:\.DS_Store|master\.key|credentials\.yml\.enc)\z})
  abort "Unexpected package files: #{unwanted.join(', ')}" unless unwanted.empty?

  installed = File.join(temporary, "installed")
  environment = ENV.keys.grep(/\ABUNDLE_/).to_h { |name| [ name, nil ] }.merge(
    "GEM_HOME" => installed, "GEM_PATH" => ([ installed ] + dependency_paths).join(File::PATH_SEPARATOR),
    "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil, "RAILS_ENV" => "test"
  )
  run!(environment, Gem.ruby, "-S", "gem", "install", archive, "--local", "--ignore-dependencies", "--no-document",
    "--install-dir", installed, chdir: temporary)
  gem_root = File.join(installed, "gems", package.spec.full_name)
  host_gemfile = File.join(temporary, "Gemfile")
  File.write(host_gemfile, "source 'https://rubygems.org'\ngem 'connectors', '= #{package.spec.version}'\ngem 'pg'\n")
  environment["BUNDLE_GEMFILE"] = host_gemfile
  run!(environment, Gem.ruby, "-S", "bundle", "lock", "--local", chdir: temporary)

  Dir.glob(File.join(gem_root, "**", "*.md")).each do |document|
    File.read(document).scan(/\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)/).flatten.each do |target|
      next if target.start_with?("#") || target.match?(/\A[a-z][a-z0-9+.-]*:/i)
      relative = target.split("#", 2).first
      destination = File.expand_path(relative, File.dirname(document))
      abort "Broken packaged link: #{document.delete_prefix(gem_root + '/')} -> #{target}" unless File.file?(destination)
    end
  end

  # Load the installed artifact in a fresh host, outside the source checkout.
  # Dependencies come from bundle install; the package itself cannot use the path source.
  smoke = <<~'CODE'
    require "rails"
    require "active_record/railtie"
    require "active_job/railtie"
    require "action_controller/railtie"
    require "connectors"
    require "tmpdir"
    require "logger"
    expected_root = File.realpath(ARGV.fetch(0))
    abort "Loaded source checkout instead of installed gem" unless File.realpath(Gem.loaded_specs.fetch("connectors").full_gem_path) == expected_root
    Dir.mktmpdir("connectors-host-") do |host|
      app_class = Class.new(Rails::Application) do
        config.root = host
        config.api_only = true
        config.eager_load = true
        config.secret_key_base = "package-smoke-test-only"
        config.logger = Logger.new(File::NULL)
      end
      Object.const_set(:PackageSmokeApplication, app_class)
      app_class.initialize!
      Rails.application.routes.draw { mount Connectors::Engine => "/integrations" }
      keys = Connectors::Registry.all.keys.map(&:to_s).sort
      abort "Missing shipped connectors: #{keys}" unless keys == %w[clickup gmail mcp resend]
      abort "Engine migrations missing" unless Rails.application.config.paths["db/migrate"].to_a.include?(File.join(expected_root, "db/migrate"))
      Connectors::MCP::ProtocolSchema.validate!("Tool", { "name" => "smoke", "inputSchema" => { "type" => "object" } })
      puts "Installed gem boots; connector registry, migrations and MCP schema load successfully"
    end
  CODE
  run!(environment, Gem.ruby, "-rbundler/setup", "-e", smoke, gem_root, chdir: temporary)
  puts "Package verified: #{package.contents.size} files; required documentation and local links present"
end
