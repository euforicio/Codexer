# AgentDock Documentation

The README is the user-facing entry point. These pages contain the deeper
implementation, contribution, and operations details needed for focused work.

## Project Guides

- [Architecture](architecture.md): runtime components, boundaries, and design
  constraints.
- [Code map](code-map.md): important source, test, workflow, and script
  locations.
- [Data flows](data-flows.md): profile lifecycle, transcript indexing, and
  release artifact flows.
- [Interfaces and contracts](apis.md): Swift modules, process contracts,
  environment variables, and persistent formats.
- [Development and testing](development.md): local setup, commands, validation,
  and opt-in installed-app checks.
- [Release operations](operations.md): packaging, signing, notarization,
  verification, and publication.
- [Security and privacy](security.md): trust boundaries, local data handling,
  secret handling, and disclosure guidance.
- [Profile isolation and quality audit](audit-2026-09-07.md): findings, fixes,
  validation evidence, and remaining acceptance gates.
- [Privacy policy](privacy.md): local-first and revocable analytics commitments.
- [Product analytics](analytics.md): event catalog, opt-in, PostHog operations,
  dashboards, funnels, cohorts, and retention.

## Community Guides

- [Contributing](../CONTRIBUTING.md)
- [Support](../SUPPORT.md)
- [Security policy](../SECURITY.md)
- [License](../LICENSE)

## Sources of Truth

When documentation and behavior differ, verify and update the documentation
against these repository sources:

- Package and target graph: [`Package.swift`](../Package.swift)
- Continuous integration and releases:
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) and
  [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- App packaging: [`script/build_app.sh`](../script/build_app.sh) and
  [`script/package_app.sh`](../script/package_app.sh)
- Profile lifecycle and launch safety:
  [`Sources/CodexerCore`](../Sources/CodexerCore)
- Chat integration: [`Sources/Codexer/ChatsView.swift`](../Sources/Codexer/ChatsView.swift),
  [`Sources/CodexerCore/LocalChatSession.swift`](../Sources/CodexerCore/LocalChatSession.swift),
  and [`Sources/TranscriptRenderer`](../Sources/TranscriptRenderer)
- Validation: [`Tests`](../Tests)

Documentation should change in the same pull request as any user-visible
behavior, persisted-data contract, security boundary, build command, or release
procedure it describes.
