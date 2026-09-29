# Sessions and messages

BoringAgent 0.3.0 uses one native composer for both adapters. Select a session in
Progress and choose **Message** or **Reply**. The popover keeps the provider and
project visible, offers the current questions/options or a prompt field, and
requires an explicit Send. Drafts live in memory per session and survive tab
remounts. They are cleared after an exact accepted receipt or extension shutdown.
Changing session selection cannot retarget an already-open composer.

| Adapter | Sessions and prompting | Question replies | Usage |
| --- | --- | --- | --- |
| Claude | User hooks observe CLI/local Desktop Code; an opted-in interactive CLI Channel receives ordinary prompts. | Future AskUserQuestion calls can wait for a notch reply when enabled and the host is connected. Already-open questions stay in Claude. | Separate opt-in Claude account helper, or available CLI status-line quotas. |
| Codex | An existing local app-server control socket exposes loaded sessions. The helper rejoins that same owner and uses turn/start or turn/steer with expectedTurnId. | Exact pending server-request IDs; permissions remain in Codex. | account/rateLimits/read through an independently authenticated account-only CLI process, with owner fallback. Missing ChatGPT login has an explicit sign-in action. API billing remains separate. |

A private Desktop process with no documented control endpoint cannot receive
messages through this adapter. BoringAgent does not inject terminal keystrokes,
start a second owner for an active session, or treat an app-level open as exact
session selection. Pre-turn or ephemeral Codex threads that cannot be rejoined
remain handoff-only. Codex currently exposes no atomic expected-idle condition
for turn/start; the helper checks the latest state before sending. Active
steering uses the API's expectedTurnId guard.

## Claude setup

1. Update the installed helper with **Copy setup** in BoringAgent's Claude
   settings. This preserves unrelated hooks and adds a disabled-by-default
   AskUserQuestion hook.
2. Turn on **Answer questions from the notch**. A live client lease prevents
   a closed/disconnected host from holding Claude's questions. A waiting hook
   falls back to Claude after at most 90 seconds.
3. For ordinary prompts, copy and run **Prompting sessions** setup. It writes a
   private MCP config and prints the command for a new interactive Claude CLI
   session with the development Channel enabled. Review Claude's own channel
   and MCP confirmations. Noninteractive `-p` runs did not deliver Channels in
   the tested Claude version; do not use them for this connection.

A nonce echoed by Claude through the MCP reply tool proves connection. Merely
starting an MCP server never enables the Message button. Channel notifications
and replies carry exact request/session/revision identities. See
[the full Claude contract](CLAUDE_MESSAGING.md).

## Codex setup

Run **Copy setup** from BoringAgent's Codex settings, then choose the printed
private relay folder. This installs an independent user LaunchAgent. It does
not change Claude settings or create an agent conversation. A custom existing
socket can be selected when running setup:

```sh
/path/to/boring-claude-bridge codex-install --codex-socket /absolute/control.sock
```

The helper's legacy filename and private-folder name remain for upgrade
compatibility. Both adapters belong to the single BoringAgent package.
`--codex-executable /absolute/codex` chooses the official CLI used by the
account-only subprocess. That subprocess has a fixed outgoing method allowlist
and cannot perform any thread or turn operation. Credentials remain owned by
Codex; neither the plugin nor its report files receive them.

The helper prefers an installed native Codex executable. For npm installations,
it resolves the launcher's Node runtime in the child environment so account
reads also work under launchd's minimal PATH. The parent environment is unchanged.

Cold account-process initialization has a 30-second bound on a separate utility
queue. Existing-owner initialization and ordinary RPCs retain their eight-second
deadlines. Account startup cannot block session prompts or question replies;
stopping cancels only the account child and discards its late result.

Successful same-owner polling grants a 30-second control lease, independent of
the session's last activity timestamp. An idle conversation can remain available
without appearing recently active. Polling renews the lease without changing the
draft revision; disconnect, removal or expiry blocks stale sends.

The account subprocess uses a process-local OpenAI provider override and removes
inherited API credentials/provider variables. The session owner's Azure/API
configuration is untouched. Its first account choice is the private usage login
under `~/Library/Application Support/BoringAgent/CodexAccount`; otherwise it reads
the existing official CLI login. A selected authenticated account does not fall
back to another account when its quota request fails.

When no ChatGPT login exists, the usage view provides the explicit
`codex-login-usage` helper command. It runs official `codex login --device-auth`
against that separate `CODEX_HOME`, using Codex's file credential store outside
the UI-selected relay. The user completes authentication. Background reads have
no login capability. `codex-logout-usage` invokes official logout only in that
private home, preserving the normal CLI login and configuration. See
[account setup and revocation](README.md#codex-subscription-usage).

Manual refresh is a bounded private request carrying a UUID and creation time.
The account report acknowledges that UUID and marks pending/completed work.
Requests within 30 seconds of the last attempt are coalesced until the minimum
interval ends; reconnecting the session socket cannot bypass it. Requests during
an in-flight fetch coalesce into one subsequent read, so a just-completed login
cannot be acknowledged using an older account read. Automatic
reads run every five minutes. Sign-in/logout request the same refresh path.

The default socket is Codex's existing app-server-control socket under its home
folder. Its same-user socket ownership and file permissions are checked. The
adapter never exposes a network listener. See the official
[Codex app-server protocol](https://developers.openai.com/codex/app-server/).
Its WebSocket transport remains experimental upstream.

Remove the login helper with `boring-claude-bridge codex-uninstall`. Uninstall
preserves private records for review. Disconnecting the provider in the native
UI releases its selected folder and disables sends; use helper uninstall to
stop background observation too.

## Delivery and privacy

The host renders sanitized metadata. Helpers own provider connections. Sending
writes one mode-0600 bounded command into the selected private folder. A helper
claims it once, removes its text from the queue, verifies the current target,
and writes a status-only receipt. Undelivered commands expire after two minutes;
queue capacity, reports and receipts are bounded. A malformed/stale command
never authorizes a side effect.

An accepted prompt means the provider acknowledged receipt, not task completion.
Claude question acceptance means the answer was passed into Claude's hook pipe.
Codex question replies have no separate JSON-RPC result: if delivery cannot be
proved, the UI reports **delivery unknown** and directs the user to check the
session. A timeout or lost connection never triggers automatic retry or clears
the draft. Tool permissions and secret input remain in the originating app.
