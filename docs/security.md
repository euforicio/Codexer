# Security and Privacy

## Trust Model

AgentDock coordinates local provider applications. It does not make an
untrusted provider process safe and is not an operating-system sandbox.

Security-sensitive operations validate:

- expected provider bundle identifiers and publisher signing teams;
- code signatures and executable paths;
- exact managed profile roots and ownership markers;
- process ancestry, PIDs, and profile arguments;
- path containment and symlink rejection;
- bounded file counts, bytes, subprocess output, and transcript pages.

If those checks fail, managed launch, focus, close, restore, delete, or
transcript reads fail closed.

These boundaries are implemented in
[DesktopAppRegistry.swift](../Sources/CodexerCore/DesktopAppRegistry.swift),
[DesktopInstanceController.swift](../Sources/CodexerCore/DesktopInstanceController.swift),
[ProfileStore.swift](../Sources/CodexerCore/ProfileStore.swift), and
[LocalChatSession.swift](../Sources/CodexerCore/LocalChatSession.swift).

## Shared Host Resources

Managed profiles retain access to normal user resources, including:

- files and project directories;
- shell environment and developer tools;
- network;
- Keychain;
- Git and SSH configuration;
- macOS permissions and provider updater state.

Use separate macOS accounts or stronger operating-system isolation when those
resources must not be shared.

## Local Data

AgentDock stores profile metadata and bounded chat indexes under
`~/Library/Application Support/AgentDock/`. New shortcuts live under
`~/Applications/AgentDock/`.

Chat indexes contain bounded titles, previews, timestamps, provider metadata,
and relative source paths. They do not contain full transcript bodies, tool
output, or absolute working directories. Transcript bodies are read on demand
from validated supported local sources.

AgentDock does not provide cloud synchronization, scrape browser cookies, or
read ordinary web-chat caches.

Custom Codex usage refresh is a separate provider egress boundary. AgentDock
reads only the active provider id and its matching provider definition from a
bounded, regular, non-symlink `config.toml`. Custom usage requests permit HTTPS
or loopback-only HTTP, reject URL credentials and unsafe schemes, and allow
redirects only within the same safe origin. Configured header values,
environment-backed values, and bearer tokens exist only on the request; they
are not persisted, logged, surfaced in raw errors, or included in analytics.
Responses are time- and size-bounded. A failed custom-provider request fails
closed instead of exposing the profile's unrelated OpenAI account quota.

Provider launches discard inherited app-profile, app-server routing, and
Electron/Node runtime overrides before supplying the selected profile's paths.
Managed Codex launches pin both `CODEX_HOME` and
`CODEX_ELECTRON_USER_DATA_PATH`, as well as the matching `--user-data-dir`.
The Electron variable also activates the installed app's preservation of
`CODEX_HOME` across its login-shell environment reload. Stock launches clear
managed profile selectors. Managed Claude launches also pair their verified
`CLAUDE_USER_DATA_DIR` override with a matching `--user-data-dir` argument,
covering Chromium session storage from process startup.

The native OpenAI quota reader additionally removes inherited account, API
credential, and endpoint overrides so they cannot redirect the selected
account's usage request. Custom-provider usage requests retain the explicit
environment-backed authentication configured for that provider.

Ordinary shell variables and shared shell startup files remain host resources.
The provider can reload that shell environment after startup; launch-time
sanitization is not an operating-system enforcement boundary.

Provider namespace directories cannot be registered as individual profiles or
replayed as profile deletions. Persisted shortcuts must be distinct `.app`
paths whose normalized name matches the owning profile slug. Recovery journals
cannot claim another profile's directory or shortcut.
Process discovery rejects ambiguous profile arguments and bundle-prefix
lookalikes before lifecycle operations revalidate the process identity. Profile
locks resolve path aliases to one physical root and reject symlinked,
nonregular, multiply linked, or foreign-owned lock files.

Built-in Codex launches set
`CODEX_CLI_PATH` to the validated Codex app's bundled
`Contents/Resources/codex` executable. Named config-profile launches point it
to AgentDock's signed proxy, which validates the profile-local bounded regular
`<name>.config.toml`, converts its assignments to `--config` arguments accepted
by the desktop app-server, and then executes that same bundled CLI. Managed
named-profile launches set the managed profile's exact `CODEX_HOME`; official
named-profile launches set `~/.codex`; built-in stock launches remove
`CODEX_HOME`. User-selected executables cannot replace the bundled CLI through
AgentDock's parent environment. Settings that would place bearer tokens, API
keys, or direct HTTP headers in process arguments are rejected; custom
providers should reference credentials through environment-backed settings.

## Product Analytics

Analytics are a separate explicit-opt-in, immediately revocable boundary implemented in
[`ProductAnalytics.swift`](../Sources/CodexerCore/ProductAnalytics.swift).
Only closed typed events can be batched to the configured regional PostHog
endpoint. Events never carry source content or local identifiers; GeoIP and
person-profile processing are disabled, and queues exist only in bounded
memory. Explicit choices persist across upgrades; opt-out clears the queue and
random identifier. The public project
token is release configuration, not a credential; no private PostHog key
belongs in the app. See the [complete catalog](analytics.md).

Local Claude usage summaries do not require credentials. Live subscription
limits are an explicit provider-access boundary: AgentDock reads Claude Code or
Claude Desktop OAuth access tokens and the active Desktop organization from
provider-owned Keychain and local state, then calls Anthropic's OAuth profile
and usage endpoints. Tokens are held only for the request; AgentDock never
copies them into its own storage, refreshes or rotates them, includes them in
analytics, or logs them. Background reads forbid Keychain interaction; a manual
refresh may show the system access prompt. Managed profiles resolve credentials
only from their own Desktop user-data roots. Desktop usage requires a valid
account and organization identity, and responses are verified against that
identity before display. An explicit identity mismatch clears the corresponding
cached quota instead of showing stale data. Active-organization cookie database
reads enforce the same root containment and symlink checks as other databases.

## Repository and Release Hygiene

Do not commit:

- credentials, tokens, certificates, provisioning profiles, or environment
  files;
- provider profiles, chats, transcript exports, logs, databases, crash reports,
  or generated indexes;
- screenshots containing real account, project, device, or session data;
- build products or notarization material.

The [release workflow](../.github/workflows/release.yml) uses ephemeral
credentials, removes temporary keychains and key files, rejects filesystem
metadata sidecars and build paths, and publishes checksums for the notarized
artifacts.

Sparkle updates require HTTPS, a Developer ID signature, notarization, and an
Ed25519 signature. The public verification key is embedded in AgentDock. The
private key exists only as the environment-protected
`SPARKLE_PRIVATE_ED_KEY` GitHub Actions secret and is streamed to Sparkle's
tool over standard input. Release assets are published before the signed
appcast, so a client cannot discover an enclosure that is not yet available.

## Reporting a Vulnerability

Follow the [security policy](../SECURITY.md). Use a private GitHub security
advisory instead of a public issue when a report could expose a vulnerability,
credential, private transcript, or local path.
