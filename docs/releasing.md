# Releasing

This guide is for maintainers preparing a release of `slack_bot_ws`.

## Pre-release Checklist

### 1. Run the Test Suite

```bash
mix deps.get
mix test
```

All tests must pass. If any fail, fix them before proceeding.

### 2. Check Formatting

```bash
mix format --check-formatted
```

If this fails, run `mix format` and commit the changes.

### 3. Run Static Analysis (optional)

If Credo or Dialyzer are configured:

```bash
mix credo --strict
mix dialyzer
```

Address any warnings that indicate real issues.

### 4. Verify Documentation Builds

```bash
mix docs
open doc/index.html
```

Spot-check:

- README renders correctly
- All guides appear in the sidebar
- Module docs have `@doc` coverage
- Links between guides work

### 5. Smoke Test the Example Bot

```bash
cd examples/basic_bot
mix deps.get
export SLACK_APP_TOKEN="xapp-..."
export SLACK_BOT_TOKEN="xoxb-..."
iex -S mix
```

Run a few slash commands (`/demo blocks`, `/demo telemetry`) and verify the bot responds.

### 6. Update CHANGELOG

Move items from `## Unreleased` to a new versioned section:

```markdown
## [0.2.0] - 2025-01-15

### Added
- ...

### Changed
- ...

### Fixed
- ...
```

### 7. Bump Version

In `mix.exs`, update the version:

```elixir
version: "0.2.0",
```

### 8. Commit and Tag

```bash
git add -A
git commit -m "Release v0.2.0"
git tag v0.2.0
git push origin master --tags
```

## Publishing to Hex

### 1. Authenticate (first time only)

```bash
mix hex.user auth
```

### 2. Build and Publish

```bash
mix hex.publish
```

Review the package contents and confirm. Hex will upload the package and generate docs.

### 3. Verify on HexDocs

Visit `https://hexdocs.pm/slack_bot_ws` and confirm:

- Version number is correct
- README appears on the main page
- Guides appear in the sidebar
- Module docs are present

## Post-release

1. Announce the release (if applicable)
2. Start a new `## Unreleased` section in CHANGELOG.md
3. Consider updating the example bot if new features should be demonstrated

## Hotfix Releases

For urgent fixes:

1. Create a branch from the release tag: `git checkout -b hotfix/0.2.1 v0.2.0`
2. Apply the fix, add tests
3. Update version to `0.2.1`, update CHANGELOG
4. Tag and push: `git tag v0.2.1 && git push origin hotfix/0.2.1 --tags`
5. Publish: `mix hex.publish`
6. Merge the fix back to master

## Yanking a Release

If a release has a critical bug:

```bash
mix hex.publish --revert 0.2.0
```

This removes the version from Hex. Users who already fetched it will keep their copy, but new installs will skip it.
