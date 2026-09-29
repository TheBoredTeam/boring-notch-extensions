# BoringAgent implementation contract

Product: **BoringAgent 0.2.0**. Stable installation ID:
`theboringteam.boringnotch.claude-code`. The existing ID, preference namespace,
relay folder, and Claude helper are retained for in-place upgrades from 0.1.0.
Swift/AppKit/SwiftUI, macOS 14+, GPL-3.0-only, built independently of Boring Notch.

## Boundaries

- `Sources/Shared/AgentModels.swift`: provider-neutral session, quota, connection,
  and presentation snapshots. Session IDs combine provider ID and native ID.
- `Sources/Plugin/AgentProviders.swift`: `AgentProviderAdapter`, provider
  descriptors, the composition registry, the working Claude adapter, and explicit
  unavailable placeholders for Codex and Antigravity.
- `Sources/Plugin/AgentDashboardState.swift`: one durable dashboard per extension
  instance, provider lifecycle, normalized snapshots, search/selection, shared
  clock, and action routing. Views never create provider services.
- `Sources/Plugin/AgentViews.swift`: shared Progress and Usage views, provider
  rings, live quota/question popovers, settings, and collapsed attention regions.
- `Sources/Plugin/ExtensionABI.swift`: the existing host C ABI, one stable tab
  (`sessions`, titled Agents), and one aggregate attention activity (`attention`).
- Existing `Claude*` shared/bridge files and `ClaudeState.swift`: the verified
  observational relay, security-scoped folder connection, normalized on-disk
  records, and local focus broker. They remain a Claude adapter implementation,
  rather than becoming requirements every future agent must imitate.

## Provider protocol

An adapter is a main-actor reference with a stable descriptor and current
`AgentProviderSnapshot`. It publishes `onChange` only after updating the snapshot.
It implements explicit lifecycle, refresh/connect/disconnect, session selection,
open-session/open-app, and copy-command actions. `AgentDashboardState` routes
commands using its current registered provider and native session ID; caller
snapshots cannot redirect a command to another provider.

Add an adapter in `AgentProviderRegistry.makeDefaultAdapters()`. The registry is
constructed once per extension instance. New provider code ships with a new
independent BoringAgent bundle; it requires no Boring Notch source changes. This
is not a second dynamic plugin loader inside the extension. Provider-neutral
components must not grow switches on provider names to implement behavior.
See [PROVIDERS.md](PROVIDERS.md) for implementation and validation conventions.

One dashboard clock handles freshness. Claude runs with its own timer disabled;
the adapter receives clock updates from the dashboard. Provider events are
coalesced before publication, and only changed session collections rebuild the
search index. Stop invalidates the clock, clears callbacks before stopping
adapters, cancels queued work, and fences late results with instance generations.

## Usage semantics

An account quota is distinct from session context. `AgentQuotaWindow` represents
an arbitrary named window with remaining percentage and an optional reset time.
The provider ring uses the lowest remaining valid window. Popover bars display
used percentage. Neither creates allowance from missing data or past reset times.

Claude selects one complete actual quota report by its own usage timestamp. It
does not sum sessions or stitch windows from different reports. A newer
context-only report cannot erase the last actual quota report; its original
timestamp remains and makes it stale after five minutes or a passed reset time.
Disconnecting the Claude source clears the cached account report.

Providers with no data show unavailable, including the current Codex and
Antigravity placeholders. A reported zero remains a real exhausted quota. Plan
labels appear only if the adapter supplies one. Context remaining is shown only
with its session in Progress details.

## Claude privacy and handoff

Explicit relay installation preserves unrelated Claude settings and hooks.
Current local Claude Code/Desktop Code sessions reload hooks while running.
The native extension reads only the chosen security-scoped relay folder. It
never reads transcripts or account credentials, and does not scrape quota APIs.
Only bounded session metadata, questions/options, documented usage, and process
origin data are stored. Tests use isolated private folders and fake adapters.

Question hooks are observational. Open an existing Remote Control link when
present, otherwise ask the local broker to verify the original process identity
and focus its app/terminal. Desktop's fallback activates the app and is labeled
as such. Never start a duplicate agent session or inject a reply/permission.

## Validation

Exercise nil/zero quota, freshness and reset expiry, identical native IDs across
providers, action routing, duplicate registrations, provider failures, preserved
selection, late callbacks, 1,000 sessions, and 100 provider descriptors. Separately
load the actual bundle through the host ABI, render both dashboard sections in
regular/compact/narrow bounds, verify controller ownership, and reconnect the
real Claude source without a synthetic override. Physical multi-display and
Intel execution require their own evidence.
