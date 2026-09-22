# Distribution, RubyGems requirements and release checks

This is a private, pre-release checkout. `allowed_push_host` is deliberately `https://rubygems.invalid`, which blocks ordinary publication to RubyGems.org. This document prepares a distributable Ruby gem; it does not authorize publication or assert ownership of a public gem name.

## Requirements reviewed

Checked against the official [RubyGems specification](https://guides.rubygems.org/specification-reference/) and [publishing guide](https://guides.rubygems.org/publishing/) on 2026-09-22.

| Area | Requirement or convention | Project handling |
| --- | --- | --- |
| Required metadata | Name, version, authors, summary and package files | Defined in `connectors.gemspec`; strict build validates them |
| Recommended metadata | Description, contact, homepage, SPDX license, Ruby requirement | Present; MIT license text shipped |
| Dependencies | Declare consumer requirements in the gemspec | Runtime dependencies bounded; Rails limited to 8.1.3+ within 8.1; MCP SDK pinned |
| External requirements | Explain dependencies outside RubyGems | PostgreSQL, UUID identity, encryption and host integration documented |
| Documentation | README and useful metadata links are conventions, not a RubyGems demand for a particular directory structure | Installation, architecture, DSL, MCP, development, authoring and release guides included |
| Package contents | Runtime code, migrations, data files and licenses must be present | Strict build plus installed-artifact smoke test; test application and credentials excluded |
| Source/development | Reproducible dependencies and verification | Gemfile/lockfile, RSpec, RuboCop and CI in source checkout |
| Publishing | Unique/owned name, authorized account and valid destination | Not verified; private push guard retained |

Ruby 3.2 is the declared minimum and matches the [Rails 8.1.3 gem requirement](https://rubygems.org/gems/rails/versions/8.1.3). The exercised baseline is Ruby 3.4.8 and Rails 8.1.3, with PostgreSQL 16 in CI. Broader compatibility must be tested before advertising a support matrix. The gem uses pure Ruby packaging; no project-specific native extension is built.

## Build and verify locally

```sh
bundle install
bundle exec ruby script/verify_package.rb
bundle exec gem build connectors.gemspec --strict
```

The verification script installs only the built artifact into a temporary directory, reuses already installed dependencies, checks required packaged files and relative Markdown links, and boots a fresh Rails host outside the repository. It checks the real installed registry, engine migration discovery and MCP schema loading. It never publishes or invokes a provider. `spec/packaging_spec.rb` runs it in CI as part of RSpec.

Before a release, also run the full randomized RSpec suite against a disposable PostgreSQL database and RuboCop as described in [contributing](../CONTRIBUTING.md). Inspect the artifact itself:

```sh
gem specification connectors-0.1.0.gem files
```

Update that filename when changing `lib/connectors/version.rb`. The package includes runtime files and consumer documentation. It intentionally omits development-only files such as the dummy application, test fixtures, repository Rakefile, CI workflows and lockfile. Develop from the source checkout, not the installed gem directory.

## Current private distribution

Local host development uses:

```ruby
gem "connectors", path: "../connectors"
```

Once a private repository is configured and accessible to consumers, pin a reviewed commit:

```ruby
gem "connectors", git: ENV.fetch("CONNECTORS_GIT_URL"), ref: ENV.fetch("CONNECTORS_GIT_REF")
```

These environment variables are example deployment inputs, not automatically provided by the gem. Commit/tag the reviewed source and configure repository access before using Git distribution. This checkout had no commits or Git remote at review time; metadata alone does not make its source URL available.

For a private gem server, configure its actual URL as `allowed_push_host` and configure Bundler's source credentials outside committed files. Do not substitute a public push destination merely to make packaging pass.

## Before a public release

1. Confirm a repository with the reviewed commit and accessible homepage, source, documentation and changelog URLs. The current `https://github.com/fineo/connectors` base URL is inherited configuration, not verified publication. Ensure the contact email is appropriate; the current author address is a GitHub noreply address.
2. Check ownership/availability of the `connectors` name on RubyGems.org. No availability or ownership claim is made here. If unavailable, choose a permitted distribution name and update packaging/installation instructions.
3. Choose the release version, convert the relevant `Unreleased` changelog into a dated release, and check upgrade notes. No release tag or published version was verified during this review.
4. Configure the maintainer's authorized RubyGems account and release authentication. Follow the current [MFA guide](https://guides.rubygems.org/setting-up-multifactor-authentication/) and, for automated releases, [Trusted Publishing](https://guides.rubygems.org/trusted-publishing/). These are account/repository operations; adding a local metadata flag does not configure them.
5. Only after public distribution is selected, change/remove the private push guard. Run package, test and lint checks against the exact commit and inspect its contents. Publishing and pushing release tags are separate explicit release actions.

Do not run `bundle exec rake release` as a validation command: Bundler's release task can tag, push and publish. No automatic publishing workflow is included.

## Scope of this review

The review corrects missing packaged guides, the absent changelog, ambiguous installation, stale reference claims, duplicate metadata URLs and the open-ended Rails dependency. It adds a repeatable installed-artifact check. Package readiness does not certify the connector architecture for every production host; provider interoperability, host authorization and operational validation remain separate.
