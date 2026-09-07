# Interfaces and Contracts

AgentDock does not expose a network service or public HTTP API. Its stable
interfaces are Swift package products, local process contracts, persisted
formats, and release scripts.

## Swift Package Products

`Package.swift` declares:

- `AgentDock`: the macOS app executable.
- `AgentDockShortcutLauncher`: the generated shortcut helper.
- `TranscriptRendererShowcase`: the synthetic renderer showcase.
- `CodexerCore`: profile, process, scanner, and shortcut logic.
- `TranscriptRenderer`: provider-neutral transcript models and views.

The two library products are integration surfaces inside this repository. They
do not carry a semantic-versioning compatibility promise independent of the app.

## Provider Launch Contracts

Codex profiles use:

```text
CODEX_HOME=<profile>/CODEX_HOME
CODEX_ELECTRON_USER_DATA_PATH=<profile>/ElectronUserData
--user-data-dir=<profile>/ElectronUserData
[generated] --config <dotted-key=toml-value> ... app-server
```

Named profiles are discovered from an account's own
`CODEX_HOME/<name>.config.toml` files. AgentDock stores whether each managed
profile and the official account use their own default, force the built-in
configuration, or select one named profile. The launch helper reads only the
selected profile file and translates its bounded TOML assignments into
app-server-supported `--config` overrides while keeping
`CODEX_CLI_PATH` pinned to AgentDock's bundled proxy and, ultimately, the CLI
bundled inside the validated Codex app. Codex's `--profile` flag is not used
because the desktop app-server command rejects it.

Claude profiles use:

```text
CLAUDE_USER_DATA_DIR=<profile>/UserData
--user-data-dir=<profile>/UserData
```

Claude launches proceed only when the installed signed app still exposes the
verified early environment-variable and `app.setPath` behavior. The matching
argument also pins Chromium session storage from process startup. The signed
app and exact process/root attribution remain mandatory; the argument alone
is not evidence of a supported isolation contract.

## Persistent Formats

- `profiles.json`: AgentDock-owned profile metadata. Array order preserves the
  user-defined managed-profile order within each provider section.
- Profile ownership markers: bind managed directories to persisted profiles.
- Shortcut configuration plist: binds a generated shortcut to one provider,
  profile root, and ownership identity.
- Chat indexes: versioned, bounded summary metadata with relative source paths
  and a source-root fingerprint. Readers reject a different source root or
  duplicate cached paths. Unchanged indexes are not rewritten.
- Analytics state: `undecided`, `denied`, or `granted` in UserDefaults. The
  analytics boundary never promotes `undecided` without a user action. A random
  installation UUID exists only while granted and is deleted on opt-out;
  explicit choices persist across launches and upgrades.

Readers validate containment, type, ownership, and size before using persisted
paths or provider records.

Codex usage resolution follows the active user-level provider configuration:

- An omitted `model_provider`, or `model_provider = "openai"`, uses the bundled
  Codex app-server's `account/rateLimits/read` method.
- A selected custom provider with a matching
  `model_providers.<id>.base_url` uses `GET <base_url>/usage`. AgentDock applies
  configured static headers, environment-backed headers, bearer-token
  environment keys, and query parameters without persisting or logging their
  values.
- A selected non-OpenAI provider without a usable custom-provider definition
  reports usage as unavailable. It does not fall back to an unrelated OpenAI
  account limit.
- A present but unsupported `model_provider` value, or an unsafe configuration
  file, also reports usage as unavailable. Missing and malformed configuration
  are not interchangeable.

The quota response is a normalized meter document containing an optional plan
and `meters`. Each meter may provide `id`, `label`, `used_percent`,
`window_seconds`, `resets_at`, and optional amount fields. AgentDock validates
counts and numeric ranges before mapping those values into `ProfileRateLimits`;
a `credits` meter maps its remaining amount into the existing credit display.

Claude activity and token summaries for official installations and managed
profiles are derived at runtime from validated local Cowork audit records and
are not a new persisted format. Both source types expose the same summary
contract, including model mix, token coverage, and the latest locally emitted
rate-limit event. Coverage prevents partially available token data from being
mistaken for complete usage.

Live Claude limits use `GET https://api.anthropic.com/api/oauth/usage` with the
selected provider login's in-memory access token. The response maps five-hour,
weekly, model-scoped, reset, and extra-usage fields into `ProfileRateLimits`.
AgentDock verifies account and organization identity through the sibling OAuth
profile endpoint before assigning a response to an account-scoped source. It
does not persist, rotate, refresh, or log provider credentials.

## Build and Release Environment

The build scripts accept namespaced environment variables including:

- `AGENTDOCK_VERSION`
- `AGENTDOCK_BUILD_NUMBER`
- `AGENTDOCK_SIGNING_IDENTITY`
- `AGENTDOCK_SIGNING_KEYCHAIN`
- `AGENTDOCK_NOTARY_KEY_PATH`
- `AGENTDOCK_NOTARY_KEY_ID`
- `AGENTDOCK_NOTARY_ISSUER_ID`
- `AGENTDOCK_POSTHOG_PROJECT_TOKEN` (public `phc_` project token only)
- `AGENTDOCK_POSTHOG_HOST` (`https://us.i.posthog.com` or
  `https://eu.i.posthog.com`)

Notarization variables must be supplied together. Release credentials belong in
GitHub Actions secrets or an ephemeral local process environment, never in
tracked files.

## MCP Callback Configuration

Managed Codex profiles reserve a unique localhost callback port and retain
profile-local OAuth credential storage settings. AgentDock does not route the
shared provider URL scheme between simultaneous instances.

Compatibility validation runs the selected Codex bundle against the exact
profile config through an isolated temporary home. It does not load or refresh
the profile's account credentials, so expired authentication cannot be
misreported as an invalid config.
