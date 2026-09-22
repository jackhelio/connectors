# Releasing Connectors

The public source repository is [jackhelio/connectors](https://github.com/jackhelio/connectors). The gemspec permits publishing only to `https://rubygems.org`. Releases use GitHub Actions and RubyGems Trusted Publishing; no permanent RubyGems API token is stored in GitHub.

## Account and repository setup

Enable [multi-factor authentication](https://guides.rubygems.org/setting-up-multifactor-authentication/) on the maintainer's RubyGems account. Save recovery codes outside the repository.

For the first release, create a [pending trusted publisher](https://rubygems.org/profile/oidc/pending_trusted_publishers):

| Field | Value |
| --- | --- |
| Gem name | `connectors` |
| Repository owner | `jackhelio` |
| Repository | `connectors` |
| Workflow filename | `release.yml` |
| GitHub environment | `release` |

Leave the optional workflow repository fields blank: publication runs directly in this repository's workflow. Pending publishers support the first upload and become regular trusted publishers after publication; an initial manual upload is unnecessary. Creating a pending publisher does not reserve a gem name. See the official [Trusted Publishing guide](https://guides.rubygems.org/trusted-publishing/).

Create the matching GitHub environment `release`, with a deployment tag policy allowing `v*`. Keep `main` protected with the `lint` and `test` checks required. Only maintainers with repository write access should create release tags. The release job additionally checks that the tagged commit is on `main` and that the tag matches the gem version.

## Verify a release candidate

1. Update `lib/connectors/version.rb` and the lockfile when changing versions. Finalize the corresponding version's changelog and compatibility notes.
2. Run the randomized RSpec suite and RuboCop against a disposable PostgreSQL database as described in [contributing](../CONTRIBUTING.md).
3. Verify the distributable package:

   ```sh
   bundle exec ruby script/verify_package.rb
   bundle exec gem build connectors.gemspec --strict
   gem specification connectors-0.1.0.gem files
   ```

   Replace the artifact version when preparing a later release. The verification script checks public metadata, required files and documentation links, installs the gem into a temporary directory, and boots a fresh Rails host outside the checkout. It checks the shipped connector registry, migration discovery and MCP schema loading. It neither publishes nor invokes a provider. RSpec runs this same check in CI.

4. Merge the reviewed release changes through a pull request after its required checks pass. Confirm CI on the merged `main` commit also passes.
5. Confirm the RubyGems account and publisher configuration above are complete before pushing a tag.

The package includes runtime code, migrations, protocol data/licenses and consumer documentation. Tests, the dummy host, development tooling, lockfile and workflows remain outside the gem. Develop from the source repository, not the installed package.

## Publish the verified commit

Fetch the merged commit, confirm its version and green CI, then create an annotated tag pointing to that exact commit:

```sh
git fetch origin --tags
git tag -a v0.1.0 <verified-main-commit-sha> -m "Release 0.1.0"
git push origin v0.1.0
```

Replace the SHA placeholder and version. Pushing the tag starts `.github/workflows/release.yml`. It reuses the normal CI workflow to run lint and the full RSpec suite before the publishing job starts. The publishing job verifies the tag, ancestry and package, builds the gem strictly, exchanges GitHub OIDC identity for short-lived RubyGems credentials using the official credentials action, then pushes the package. Only this job has `id-token: write`; neither job needs repository write permission.

Watch the Release workflow and verify the version, metadata and artifact on [RubyGems](https://rubygems.org/gems/connectors). Install the published version into a clean host before announcing it. A successful test run alone is not proof of publication.

If authentication fails before upload, fix the account/publisher configuration and rerun the workflow for the same tag. If upload may have succeeded, check RubyGems before retrying. Published versions cannot be overwritten; subsequent code changes require a new version and tag. Do not move a published release tag. Do not use `bundle exec rake release` as a validation command: it can tag, push and publish outside this workflow.

## Supported baseline

The gem declares Ruby 3.2+ and Rails 8.1.3+ within the 8.1 series. CI exercises Ruby 3.4.8 with PostgreSQL 16. Broader compatibility needs its own validation. Host authentication, encryption configuration, provider interoperability and production operations remain separate from package verification.
