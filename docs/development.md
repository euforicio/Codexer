# Development and Testing

## Prerequisites

- Apple silicon Mac
- macOS 26 or newer
- Swift 6.2 or newer
- Xcode command-line tools

The official provider apps are optional for normal tests. Installed-app and
live-lifecycle checks are explicitly opt in.

Package targets and dependency versions are defined in
[Package.swift](../Package.swift) and [Package.resolved](../Package.resolved).

## Build and Run

```bash
swift build
swift test
./script/build_and_run.sh
```

Local ad-hoc builds leave `SUPublicEDKey` empty and disable update checks. To
exercise the configured updater with an existing public key, run:

```bash
AGENTDOCK_SPARKLE_PUBLIC_KEY='<base64-public-key>' ./script/build_app.sh
./script/package_app.sh
```

The public key is not secret. Never place the private Sparkle key in a command
argument, tracked file, build artifact, or ordinary development environment.

Use `./script/build_and_run.sh --verify` to build, launch, and verify that the
app process exists. Build products and packages are written under ignored
`.build/` and `dist/` directories.

## Marketing Site

The dependency-free static site is stored under [`site/`](../site). Validate
it locally with:

```bash
./script/validate_site.sh
AGENTDOCK_SITE_NETWORK_VALIDATION=1 ./script/validate_site.sh
python3 -m http.server 8080 --directory site
```

The first command validates local HTML, JavaScript, assets, release-link
fallbacks, accessibility hooks, and repository hygiene. The opt-in network
check resolves the current GitHub release and verifies that its DMG is
reachable. The local server exposes the site at `http://localhost:8080` for
responsive browser testing.

Run the repository-wide privacy audit before a release or after changing build,
packaging, or publication behavior:

```bash
brew install gitleaks # one-time prerequisite
./script/audit_privacy.sh
```

The audit scans the complete Git history with redacted output, rejects tracked
machine-specific home paths and sensitive file formats, and runs the website
privacy checks. Release packaging separately rejects private build paths in the
signed ZIP and DMG without echoing the matched path into logs.

[`Assets/AppIcon.png`](../Assets/AppIcon.png) is the source of truth for both
the macOS app icon and the website icon. After changing that artwork, regenerate
the tracked `.icns` and website copy with:

```bash
./script/generate_app_icon.sh
./script/validate_site.sh
```

GitHub Pages serves the contents of the `gh-pages` branch. Website publication
is manual; do not add a push-to-main, pull-request, or dispatch workflow. The
release workflow preserves the existing website and publishes only the signed
Stable or Alpha appcast plus `.nojekyll` update metadata after immutable
release assets are available.

## Test Suites

```bash
swift test
```

The package includes
[core tests](../Tests/CodexerCoreTests),
[app-model tests](../Tests/CodexerAppTests/CodexerModelTests.swift),
[transcript-renderer tests](../Tests/TranscriptRendererTests), and vendored
parser tests. Tests must use real repository-native behavior; do not add mocks
or stubs. App-model fixtures must supply a temporary `officialDataRootURL` so
standard-provider reads stay inside the fixture as well as managed-profile
reads.

Synthetic UI acceptance images can be rendered without reading signed-in
accounts or launching provider applications:

```bash
AGENTDOCK_VISUAL_AUDIT_DIR=/tmp/agentdock-visual-audit swift test \
  --filter ProfileSelectionIsolationTests/testSyntheticVisualAudit
```

This opt-in harness uses real temporary profile files and isolated preferences
to render the overview and chat surfaces in light and dark appearances at
regular and compact sizes, including long profile names. It briefly presents
synthetic windows and requires Screen Recording access for native window
capture. Inspect the resulting images for hierarchy, clipping, contrast, and source identity;
render completion alone is not visual acceptance.

The two-profile lifecycle check uses temporary profiles and verifies separate
processes, persistence through restart, and preservation of the other profile
and existing provider instances. Failed checks preserve temporary data for
manual diagnosis and can leave test instances running; verify exact process
ownership before cleanup. It opens installed provider applications:

```bash
AGENTDOCK_LIVE_ISOLATION_TEST=1 swift test --filter LiveProfileIsolationTests
```

The Claude check also inspects bounded open-file metadata for each verified
process tree before and after restart. It requires files under that profile's
UserData and none under the default or sibling root; output contains counts
only. A vanished startup helper triggers a fresh inventory, while a changed
main process identity fails the check.


Installed-app checks:

```bash
AGENTDOCK_LIVE_LIFECYCLE=1 swift test \
  --filter CodexLauncherTests/testLiveProfileCanOpenAndCloseWithoutTouchingStockInstance

AGENTDOCK_LIVE_EXISTING_CODEX_PROFILE=/path/to/active/profile swift test \
  --filter CodexLauncherTests/testLiveExistingCodexProfileClosesAllOwnedProcessesWithoutTouchingStock

AGENTDOCK_INSTALLED_CLAUDE_TEST=1 swift test \
  --filter ClaudeDesktopTests/testInstalledClaudeSignatureAndStartupContract

AGENTDOCK_CLAUDE_LIVE_LIFECYCLE=1 swift test \
  --filter ClaudeDesktopTests/testLiveClaudeProfileCanOpenAndCloseWithoutTouchingStock
```

These checks can open installed provider applications or terminate the exact
active managed profile named in the environment. Run them only on a Mac where
that interaction is expected.

## Change Expectations

- Keep provider-specific discovery and parsing in `CodexerCore`.
- Keep transcript presentation provider-neutral and capability-gated.
- Preserve stable event identities and exact source order.
- Bound file inventories, subprocess output, transcript pages, and layout work.
- Validate paths and signatures immediately before security-sensitive actions.
- Update README or focused docs with user-visible behavior and contract changes.
- Never commit profiles, chats, logs, databases, credentials, screenshots with
  real data, or build artifacts.

See [Contributing](../CONTRIBUTING.md) for the pull-request workflow.
Release builds use [build_app.sh](../script/build_app.sh) and
[package_app.sh](../script/package_app.sh).
