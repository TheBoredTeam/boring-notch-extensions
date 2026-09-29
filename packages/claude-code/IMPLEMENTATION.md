# Claude Code extension implementation contract

Independent package ID: `theboringteam.boringnotch.claude-code`; version `0.1.0`.
Swift/AppKit/SwiftUI, macOS 14+, GPL-3.0-only. No host implementation dependency.
The plugin and command-line relay compile separately from shared Foundation
types. Runtime artifacts go in ignored `dist/`.

## Components

- `Sources/Shared`: normalized Codable session/usage/origin records and bounded
  storage. Shared module compiled into both binaries; no host Swift types.
- `Sources/Bridge`: executable `boring-claude-bridge`; observational Claude hooks,
  status-line forwarding, reversible hook installation, and optional local
  focus-request broker outside the host sandbox.
- `Sources/Plugin`: one Claude tab with intentional regular/compact layouts,
  native extension settings, directory access via security-scoped bookmark,
  shared observable state, and leading/trailing attention activity.

User consent connects one private relay folder. The host is sandboxed: do not
assume it can read `~/.claude` or change Claude configuration. Setup is an explicit
CLI helper command; the UI selects the relay folder. No transcript or credential
scraping. Only sanitized session metadata, requested questions, and documented
usage fields are retained. Synthetic test records stay isolated from real data.

## Shared Swift interface

The bridge owner defines these types promptly and informs the UI owner of any
necessary changes:

- `ClaudeSession: Codable, Identifiable, Sendable`: `schemaVersion: Int`,
  `id: String`, `project: String`, `directory: String`, `phase: SessionPhase`,
  `createdAt: Double`, `updatedAt: Double`, `model: String?`, `question: String?`,
  `questionOptions: [String]`, `attentionKind: String?`, `toolName: String?`,
  `usage: ClaudeUsage?`, `origin: ClaudeOrigin`.
- `SessionPhase: String, Codable, Sendable`: `working`, `needsInput`, `idle`, `ended`.
- `ClaudeUsage: Codable, Sendable`: `updatedAt: Double`,
  `fiveHour: ClaudeQuotaWindow?`, `sevenDay: ClaudeQuotaWindow?`,
  `contextRemaining: Double?`.
- `ClaudeQuotaWindow: Codable, Sendable`: `remainingPercent: Double`, `resetsAt: Double?`.
- `ClaudeOrigin: Codable, Sendable`: `claudePID: Int32?`, `processStartTime: Double?`,
  `appBundleID: String?`, `appPath: String?`, `tty: String?`, `remoteSessionID: String?`.
- `ClaudeStorage.loadSessions(directory: URL) throws -> [ClaudeSession]`:
  read bounded, regular, nonsymlink session JSON records under `sessions/`;
  at most 2,000 records, bounded file sizes; reject malformed individual records.
- `ClaudeStorage.requestFocus(sessionID: String, directory: URL) throws`:
  queue a bounded request keyed only by an existing session identity. A broker
  may focus its verified original terminal; no arbitrary shell command payload.

Store records atomically with private directory/file permissions. Serialize
concurrent updates so a status-line usage snapshot cannot clear an unanswered
question. Ignore subagent events for the primary-session model. Never retain
prompts, tool arguments (except bounded AskUserQuestion fields), transcripts,
authorization tokens, or raw stdin in logs.

## Behavior

At most one tab (`sessions`) and one aggregate attention activity (`attention`).
Show waiting questions first; include a searchable lazy session list and usage
details. Compact prioritizes the most urgent session and essential actions within
the host-supplied viewport. Do not create one tab/controller/timer per session.
If quota data is missing, show unavailable rather than inventing remaining usage.
Keep context remaining distinct from five-hour/seven-day subscription allowance.

The relay observes documented Claude hooks. `PreToolUse` for `AskUserQuestion`
shows the question; `PermissionRequest` shows a safe tool-name summary. Events
advance/resolve state without replying or approving on behalf of the user.
Status-line integration preserves and forwards any pre-existing user command.

Prefer an already-active Remote Control link or exact Terminal/iTerm TTY focus.
Validate PID identity/start time before focusing. Desktop has no documented
per-session URI; use explicit app activation fallback and copyable CLI recovery
instructions. Never start a duplicate session automatically or feed an answer
into an arbitrary terminal. If using a broker, it is event-driven, installed
explicitly, removable, and accepts only known session IDs in its private folder.

CLI expected subcommands: `hook`, `statusline`, `install`, `uninstall`, `serve`.
Use `--data-dir` and `--settings` overrides for isolated tests. The UI may use
`BN_CLAUDE_TEST_DIRECTORY` only in a DEBUG build for synthetic stress runs.

## Stress criteria

Exercise 1,000 synthetic sessions, concurrent usage/question events, malicious
or oversized input, reconnect/remount, regular/compact bounds, search/filter,
one native controller per mount, and zero callbacks after destruction. Use the
real built bundle via C ABI and the running isolated Boring Notch app. An actual
new Claude test session may use explicit temporary settings; preserve the user's
existing Claude configuration and active sessions.
