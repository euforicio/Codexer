<p align="center">
  <img src="docs/assets/agentdock-icon.png" width="128" height="128" alt="AgentDock app icon">
</p>

# AgentDock

[![Quality](https://github.com/euforicio/AgentDock/actions/workflows/ci.yml/badge.svg)](https://github.com/euforicio/AgentDock/actions/workflows/ci.yml)
[![Build and Release](https://github.com/euforicio/AgentDock/actions/workflows/release.yml/badge.svg)](https://github.com/euforicio/AgentDock/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/euforicio/AgentDock?display_name=tag)](https://github.com/euforicio/AgentDock/releases/latest)
[![License: FSL-1.1-MIT](https://img.shields.io/badge/license-FSL--1.1--MIT-6f5cff)](LICENSE)

AgentDock is a native macOS app for running multiple isolated profiles of the
official OpenAI Codex and Anthropic Claude desktop apps. Each profile receives
separate application state, can run alongside the stock app and other profiles,
and can have its own Dock-pinnable shortcut.

[Download the latest notarized release](https://github.com/euforicio/AgentDock/releases/latest)
· [Visit the website](https://euforicio.github.io/AgentDock/)
· [Read the documentation](docs/index.md)
· [Report a bug](https://github.com/euforicio/AgentDock/issues/new?template=bug_report.yml)
· [Contribute](CONTRIBUTING.md)
· [Security](SECURITY.md)
· [License](LICENSE)

> [!IMPORTANT]
> AgentDock isolates supported application state; it is not an operating-system
> sandbox. Managed instances retain normal access to your files, shell,
> network, Keychain, Git configuration, and SSH credentials.

## Highlights

- Run multiple app profiles side by side with separate local state.
- Open or focus the normal official installation independently of managed
  profiles.
- Focus and close an exact profile without quitting another running instance.
- Select a named Codex config profile such as Ollama for each managed profile,
  switch a running profile with an automatic restart, and return to the
  managed profile's own default or Built-in Codex OAuth at any time.
- Install native, profile-specific shortcuts under
  `~/Applications/AgentDock/`.
- Check for, download, and install signed AgentDock updates with Sparkle.
- Browse supported local chat histories with safe links, tables, selectable
  prose, syntax-highlighted code, and bounded tool output.
- View supported local activity, storage, usage-limit, and lifecycle
  information for official installations and managed profiles.
- Verify official app identity and code signatures before managed operations.
- Preserve profile data by default when removing a profile from the app.

## Requirements

- An Apple silicon Mac running macOS 26 or newer.
- The official Codex app, the official Claude app, or both.
- Swift 6.2 or newer only when building from source.

AgentDock does not redistribute or modify either provider app. If an app is not
installed in `/Applications`, select its signed `.app` bundle in AgentDock
settings.

## Install

1. Download the DMG from the
   [latest release](https://github.com/euforicio/AgentDock/releases/latest).
2. Open it and drag AgentDock onto the Applications shortcut.
3. Launch AgentDock. The release is Developer ID signed, hardened, notarized,
   and stapled for Gatekeeper verification.

AgentDock releases that include Sparkle update themselves from the signed
Stable channel by default. Settings also offers an opt-in Alpha channel for
signed prerelease builds after changes merge; users can return to Stable at
any time. Installations from before Sparkle support require this one
final manual download; automatic updates begin after that version is installed.

Release pages also provide a ZIP and SHA-256 checksums. See
[Release operations](docs/operations.md) for verification and maintainer
release procedures.

## Quick Start

1. Open AgentDock and choose **Add Profile**.
2. Select the provider and give the profile a descriptive name.
3. Select the profile and choose **Open**.
4. Sign in inside that managed provider window.
5. Optionally choose **Install Shortcut** for a Dock-pinnable launcher.
6. Repeat for another account or provider.

For Codex, the compact Provider row beneath Usage discovers native
`CODEX_HOME/<name>.config.toml` profiles for that account. Choose **Use
Default**, **Built-in Codex (OAuth)**, or a named profile such as Ollama.
**Make Default** changes the provider default only for the selected managed or
official account. Changing the selection while Codex is running closes and
reopens only that account with the selected profile applied as desktop
app-server configuration overrides.

Drag managed profiles within their provider section to keep the sidebar in the
order you prefer. The order persists across launches; official provider rows
remain fixed.

The action changes to **Focus** while a profile is running. **Close** targets
only the selected profile. **Remove From List** preserves its local data;
permanent deletion is a separate confirmed action.

Use **Command-F** to search the current profile or chat list,
**Command-Shift-F** to search profiles from anywhere, and **Command-R** to
refresh. The selected profile remains visible above each detail section.

## Local Data and Privacy

AgentDock is local-first. It does not provide cloud synchronization or upload
managed profile data. Optional pseudonymous product analytics remain off until
you explicitly allow them and can be disabled immediately in Settings. They never
include profile, account, path, command, prompt, chat, transcript, session,
configuration, log, or crash content. AgentDock stores profile metadata and indexes under
`~/Library/Application Support/AgentDock/` and creates shortcuts under
`~/Applications/AgentDock/`.

Local transcript support is source-dependent:

- Codex uses supported local databases and session JSONL fallbacks.
  Native OpenAI profiles read account limits through the bundled Codex
  app-server. When a profile selects a custom `model_provider`, AgentDock tries
  that provider's configured `GET /usage` quota endpoint instead and shows its
  percentage-based allowance windows and reset times. A custom provider is
  never shown with an unrelated OpenAI quota.
- Claude uses supported local Cowork/agent-session data. The Official Claude
  view can also include the lightweight Claude Code history index and matching
  local session files. Official and managed Claude sources expose the same
  source-backed session, model, and token summaries. When a signed-in OAuth
  credential grants profile access, AgentDock also reads Anthropic's live
  session, weekly, model-scoped, reset, and extra-usage status. The cross-source
  card keeps the official installation visible alongside every managed account.
  Local rate-limit events remain a clearly separate last-observed fallback.
- Ordinary synced claude.ai web chats are unavailable because Claude Desktop
  does not expose a stable local transcript contract. AgentDock reads only the
  provider-owned OAuth cache and active-organization cookie required to resolve
  live usage; it does not index ordinary web-chat content.

Indexes contain bounded list metadata, not full transcript bodies or absolute
working directories. See [Security and privacy](docs/security.md),
[Data flows](docs/data-flows.md), and the exact optional
[Product analytics event catalog](docs/analytics.md).

## Documentation

- [Documentation index](docs/index.md)
- [Architecture](docs/architecture.md)
- [Code map](docs/code-map.md)
- [Data flows](docs/data-flows.md)
- [Interfaces and contracts](docs/apis.md)
- [Development and testing](docs/development.md)
- [Release operations](docs/operations.md)
- [Security and privacy](docs/security.md)

## Contributing and Support

Bug reports, focused fixes, tests, documentation improvements, and feature
proposals are welcome. Start with:

- [Contributing guide](CONTRIBUTING.md)
- [Support guide](SUPPORT.md)
- [Security policy](SECURITY.md)
- [Issue tracker](https://github.com/euforicio/AgentDock/issues)

Please do not post credentials, account data, private transcript content,
absolute home-directory paths, or unredacted logs in public issues or pull
requests.

## Project Status

AgentDock is an early release. Provider integration is version-sensitive and
fails closed when a signed installed app no longer exposes its expected local
launch contract. Existing shortcuts may need to be reinstalled after launcher
or profile-identity changes.

AgentDock is an independent project. It is not an OpenAI or Anthropic product.

## License

AgentDock is licensed under the
[Functional Source License 1.1 with an MIT future grant](LICENSE). The MIT grant
becomes effective on July 29, 2028. Until then, the FSL permitted-purpose and
competing-use restrictions apply.

The vendored Streamdown subset retains its own FSL-1.1-MIT license and its
separate March 16, 2028 MIT grant date in
[`Vendor/streamdown-swift/LICENSE`](Vendor/streamdown-swift/LICENSE).
See [Third-party notices](THIRD_PARTY_NOTICES.md) for dependency licenses.
