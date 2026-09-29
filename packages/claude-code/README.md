# Claude Code for Boring Notch

A free, independent native extension that brings Claude Code sessions, usage
reports, and questions into one Boring Notch tab. It ships as a separate
`.bnplugin` ZIP; no extension source is compiled into Boring Notch.

**0.1.0 is a development preview.** Self-signed or ad-hoc preview artifacts need
a compatible Debug host with explicit development-extension opt-in. They are
not Apple-notarized production releases and will not install in a Release host
that requires Developer ID and notarization.

## What it does

- One searchable, lazy session list, with waiting questions first and a waiting
  filter. Session identity and selection survive ordinary usage updates.
- A deliberate compact layout with session search, navigation, usage, and an
  open-session action inside the host's supplied bounds.
- One aggregate collapsed activity for recent sessions that need input. The
  host controls its priority, camera clearance, and placement.
- Question details and available option labels in a native popover. Choose
  **Reply in session** to return to Claude; the extension does not answer or
  approve permissions on your behalf.
- Five-hour and seven-day subscription allowance **when Claude supplies it**,
  with session context remaining shown separately.

The registry permits 2,000 stored session records. This extension creates one
tab, not one tab or controller per session. The package's stress harness uses
1,000 synthetic sessions; its results are development evidence, not a guarantee
that every terminal, Claude release, or machine behaves identically.

## Requirements and compatibility

| Component | Requirement |
| --- | --- |
| macOS | 14 or later. |
| Boring Notch | A host implementing the native extension ABI v1 with activities, tabs, and the additive `bn_extension_tab_view_v2` compact-layout factory. These APIs are a developer preview, not present in every released host. |
| Claude Code | Use a current Claude Code release. Version 2.1.243 or later is the recommended feature baseline; the development environment currently has 2.1.283. Older releases may omit events, quotas, or origin metadata. |
| Build tools | Xcode command-line tools and Python 3.11 or later. No third-party runtime packages. |

Claude's documented version milestones include context percentage in 2.1.6,
subscription rate-limit fields in 2.1.80, `CLAUDE_PID` in 2.1.214, and the idle
quota-reset correction in 2.1.243. Exact terminal focus requires the modern
origin metadata and a recognized Claude executable; otherwise use the explicit
app or resume-command fallback.

Claude Desktop's local Code sessions share the CLI's user hooks. A real running
Desktop session using its embedded Claude Code 2.1.281 was observed loading the
relay hooks without a restart, reporting activity, and opening its originating
Desktop app. This does not establish support for Chat, Cowork, cloud, or SSH
sessions. Desktop did not emit status-line usage during this check, so its quota
and context values remained unavailable in the extension. Editor integrations
must likewise load the hooks and emit the relevant events. The extension does
not discover existing sessions by reading their transcripts; sessions appear
after their first supported hook or status-line event.

See Claude's official [hooks](https://code.claude.com/docs/en/hooks),
[status line](https://code.claude.com/docs/en/statusline),
[environment variables](https://code.claude.com/docs/en/env-vars), and
[Remote Control](https://code.claude.com/docs/en/remote-control) documentation,
plus its [version changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md).

## Install and connect

1. Launch a compatible **Debug** Boring Notch host with
   `BN_ALLOW_DEVELOPMENT_EXTENSIONS=1` in its environment. This opt-in accepts an
   intact development signature; it does not bypass signature-integrity checks
   and is unavailable in Release builds. For an isolated host test,
   `BN_EXTENSION_TEST_DIRECTORY` can select a disposable installation folder.
2. In **Settings → Extensions**, install the development ZIP, then enable
   **Claude Code**. Restart the host if it requests a restart.
3. Open the extension's native settings and choose **Copy** beside the setup
   command. Paste and run it in Terminal. The command contains the actual,
   shell-quoted path to the helper inside your installed bundle, followed by
   `install`. It does not assume `boring-claude-bridge` is on your `PATH`.
4. Read the relay folder printed by the command. In the extension settings,
   choose **Choose relay folder…** and select that exact directory. The default
   is `~/Library/Application Support/BoringClaude`.
5. Open the **Claude** tab in the notch. Current Claude Code sessions
   [reload hooks when settings change](https://code.claude.com/docs/en/settings#when-edits-take-effect),
   including local Desktop Code sessions. They appear after their next supported
   event. An idle session may not appear immediately; older versions may need a
   restart when convenient.

For example, after building this package, setup can be run from this directory:

```sh
'./dist/theboringteam.boringnotch.claude-code.bnplugin/Contents/Helpers/boring-claude-bridge' install
```

The command you copy from the installed extension is preferable: it resolves
the actual bundle location and safely quotes spaces and apostrophes in paths.
Setup is never executed automatically by the native extension.

The explicit `install` command:

- Copies the helper to the private relay folder's stable `bin/` location.
- Adds observational hooks to `~/.claude/settings.json` and wraps an existing
  command-style status line while preserving its input, output, and exit status.
- Keeps unrelated settings and hooks, and records enough integration metadata
  to remove its own changes later.
- Creates and starts the per-user LaunchAgent
  `theboringteam.boringnotch.claude-code.bridge` for focus requests.

The native UI runs inside the sandboxed host. Selecting the relay folder grants
access through a macOS security-scoped bookmark; it does not grant access to
`~/.claude`. If folder access expires, choose the folder again.

To use another settings file or relay folder, pass `--settings /absolute/path`
and `--data-dir /absolute/path` to `install`, and select the same relay folder
in the UI. Use `--no-launch-agent` to install hooks without starting a login
broker. In that mode, exact terminal focus requires running the copied helper
with `serve --data-dir /absolute/path` yourself. A relay folder belongs to one
settings integration; do not reuse it for unrelated Claude configurations.

## Questions and opening a session

`AskUserQuestion` hooks provide the question and bounded option labels.
Permission hooks provide a safe tool-name summary; notification-only events may
show a generic request for input. Full permission arguments and transcripts
are not inspected. Concurrent status-line updates do not clear a pending
question. A resolving tool/session event clears it.

**Open session** uses an existing Remote Control URL when the relay recorded
one. It never enables Remote Control or starts a new remote session. Otherwise
it queues a request containing only a known session ID for the local broker.
The broker verifies the original Claude PID and process start time before
attempting to select the original Terminal or iTerm tab by its TTY. macOS may
request Automation permission for that explicit action.

If exact focus is unavailable, the UI offers **Open original app** and
**Copy resume command**. Claude Desktop has no supported exact-session deep
link used by this package: opening the app still requires choosing the session
there. Other supported terminal/editor apps can likewise require manual
selection. The extension never launches a duplicate CLI session or types an
answer into an arbitrary terminal.

Session status is the latest hook report, not a process-liveness guarantee.
After ten minutes without a report, the UI labels it stale and stops publishing
that session's aggregate urgency. Unanswered question text remains available.
An abrupt Claude exit may therefore leave a stale record until a later event;
the extension does not invent a successful ending.

## Usage reports

| Display | Source and meaning |
| --- | --- |
| **5h** | `rate_limits.five_hour.used_percentage`, converted to remaining subscription allowance. |
| **7d** | `rate_limits.seven_day.used_percentage`, converted to remaining subscription allowance. |
| **Context** | `context_window.remaining_percentage`, the current session's context capacity. |

Missing fields show **— / unavailable**. Context capacity is not a subscription
quota, and usage-limit error notifications do not reveal a remaining percentage.
Snapshots older than five minutes are labeled **Stale**. Reset times, when
provided, appear in the usage tooltip. The extension does not read credentials
or query an undocumented usage API to fill missing values.

## Disconnect, update, and uninstall

**Disconnect** in extension settings revokes the UI's saved folder connection.
It does not remove Claude hooks or stop the separately installed relay.

To remove the integration using the default relay location:

```sh
"$HOME/Library/Application Support/BoringClaude/bin/boring-claude-bridge" uninstall
```

For a custom setup, run its copied helper with the same `--data-dir` and
`--settings` arguments used during installation. Uninstall removes its own hook
commands and LaunchAgent, and restores the prior status-line configuration only
if the relay's wrapper is still installed. Later unrelated settings edits are
preserved. Current Claude Code sessions reload the hook removal automatically;
older versions may need a restart when convenient.

Then uninstall the extension in Boring Notch settings. Relay observations and
the copied helper remain in the private relay folder for your review; delete
that folder yourself after removing the integration if you want to erase them.
Removing the ZIP or native extension alone does not remove the hooks.

After updating the extension, restart the host when requested and run its newly
copied setup command again to update the stable relay helper. Reinstallation
does not append duplicate copies of its hooks.

## Privacy and storage

The relay receives hook payloads on standard input, discards prompt text and
unrelated tool arguments, and writes only normalized session metadata, project
paths, model/status, usage, bounded unanswered questions/options, and origin
metadata needed for focus. Origin metadata can include PID/start time, app
identity, TTY, and an existing Remote Control session ID. It never opens
transcript files or credential stores. A pre-existing user status-line command
continues receiving its original input.

Files stay in the chosen local relay folder. New directories use mode `0700` and
records use `0600`; file sizes, record counts, requests, and decoded fields are
bounded. Writes are atomic and serialized. At the 2,000-record limit, the oldest
ended record can be evicted; unanswered and working sessions are not silently
deleted to make space. Uninstall retains observations for explicit user cleanup.

There is no extension analytics service or background account request. Opening
Remote Control intentionally opens Claude's website. Native extension code
shares the host process and its crash fate; a bundle signature is not process
isolation. The relay runs separately and the UI reads only the folder you chose.

## Build and test

From this package directory:

```sh
./build.sh
bash scripts/test.sh dist/theboringteam.boringnotch.claude-code.bnplugin
```

The default build is Debug for the current architecture with an ad-hoc
signature. Output is under ignored `dist/`, including
`ClaudeCode-0.1.0-development.zip`. To compile both architecture slices:

```sh
./build.sh --architecture universal
```

Use `--identity 'Your local signing identity'` to sign with an installed
development identity, and `--keychain /absolute/path` to select a dedicated
keychain. `--output` and `--module-cache` let you choose build/cache locations.
Do not commit keychains, passwords, certificates with private keys, or generated
bundles. A universal build alone is not evidence of testing on Intel hardware.

The test runner exercises the shared relay and the actual independently loaded
bundle ABI with synthetic data. Debug-only `BN_CLAUDE_TEST_DIRECTORY` overrides
the saved UI folder connection; `BN_CLAUDE_TEST_LOG` enables bounded lifecycle
and state-metadata telemetry. Test fixtures do not need real transcripts,
credentials, or changes to the user's Claude settings. Tests should verify the
Debug protocol marker before constructing a plugin instance.

`--configuration release` removes the Debug hooks; it does **not** make a
production release. The build script does not perform Apple notarization and
uses no timestamp server. Consumer distribution needs a publisher-owned
Developer ID signature, notarization, final artifact verification, and a
compatible production host. Keep its Store record in preview until those
requirements are met.

## Source and license

`Sources/Shared` contains the normalized model and bounded storage;
`Sources/Bridge` contains hooks, setup, and the focus broker;
`Sources/Plugin` contains the independent C ABI adapter and native views.
See [IMPLEMENTATION.md](IMPLEMENTATION.md), the repository's
[extension-author guidelines](../../AGENTS.md), and the
[exact ABI header](../../docs/extension-api.h).

Original implementation, licensed **GPL-3.0-only**; see [LICENSE](LICENSE).
The authentic Claude logo is a third-party asset excluded from that code
license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for provenance and
trademark notices. This community extension is not an Anthropic product.

The compatible host source is available on
[`feat/live-activity-host`](https://github.com/TheBoredTeam/boring.notch/tree/feat/live-activity-host).
Build its Debug configuration and opt in to development extensions as described
above. This feature branch is not a production Boring Notch release.
See [VALIDATION.md](VALIDATION.md) for the tested behavior and remaining limits.
