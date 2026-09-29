# Claude session messaging

BoringAgent uses Claude's documented integration boundaries. It does not type
into terminals, take over a terminal, resume an active transcript in a second
process, or modify a running session's credentials.

## Replies to questions

Inline question replies require explicit opt-in, the `AskUserQuestion`
`PreToolUse` hook, and a live BoringAgent client. The client publishes a process
identity and an eight-second lease; it refreshes that lease every two seconds.
Closing or disconnecting the client makes a waiting hook fall back to Claude.

For a future question, the hook retains the original tool input in its own
memory and publishes only bounded question metadata. A reply must match the
provider, native session, process identity, hook generation, tool-use request ID,
question IDs and freshness window. The hook preserves the original input and
adds Claude's documented `answers` object before returning
`permissionDecision: "allow"` with `updatedInput`.

The hook waits at most 90 seconds, so its configured command timeout is 95
seconds. During that interval Claude displays its running hook. Timeout,
disconnect, disable, stale ownership or unsupported question data produce no
stdout: Claude proceeds with its original question. A question already showing
in Claude's own UI cannot be retroactively intercepted. Tool permissions, plan
approval and MCP elicitation remain in Claude.

Explicit secret fields and recognizable credential prompts fall back to Claude.
`AskUserQuestion` currently has no standard secret-field contract, so natural
language detection cannot certify every possible question as non-sensitive.
Never use inline replies to submit credentials.

An `accepted` question receipt means **Reply passed to Claude**. It does not
claim that a tool executed, that another hook allowed it, or that a task finished.

Official contract:
[AskUserQuestion input](https://code.claude.com/docs/en/hooks#askuserquestion) and
[allow with updated input](https://code.claude.com/docs/en/hooks#allow-with-updatedinput).

## Ordinary prompts through Channels

The helper's `channel` subcommand is a local stdio MCP server. It declares only
`claude/channel`, exposes a `reply` acknowledgment tool and opens no network
listener. It does not declare the permission-relay capability. Channel content
is user input, not a trusted instruction source.

Claude must opt in when a new session starts. Merely installing the MCP config
does not enable messaging. The documented development-preview setup is:

```json
{
  "mcpServers": {
    "boringagent": {
      "command": "/absolute/path/to/boring-claude-bridge",
      "args": ["channel", "--data-dir", "/absolute/private/relay"]
    }
  }
}
```

```sh
/absolute/path/to/claude --mcp-config /absolute/path/to/channel.json \
  --dangerously-load-development-channels server:boringagent
```

The user must review Claude's development-channel confirmation. This flag is
the upstream preview mechanism, not a shipping allowlist approval. No permission
bypass is configured. Claude's normal MCP tool approval still applies to
`mcp__boringagent__reply`; allowing that acknowledgment tool does not approve
other tools. Organization policies and the installed Claude version can prevent
channel delivery.

A channel binds to an exact verified Claude ancestor process and the session
identity supplied by lifecycle hooks. It first sends a nonce-bearing connection
check. The app advertises prompting only after the same session echoes that
nonce through the MCP `reply` tool. MCP initialization alone is insufficient:
Claude documents that unregistered or blocked channels silently drop events.
Discovery must finish first. At most three connection checks use distinct
nonces, after 2, 7 and 17 seconds; any matching nonce for the same live endpoint
can confirm readiness. These checks have no task payload and stop after the
first acknowledgment. Ordinary user messages are never automatically retried.

Each user message has its own UUID, session revision and acknowledgment.
Commands are consumed once before transmission. A missing acknowledgment
becomes `unknown`, never success, and is not retried automatically. A later
matching acknowledgment can resolve it. An acknowledged message confirms
receipt, not task completion. Restarting, reconnecting or clearing a session
does not redirect old messages to a new session.

The server negotiates MCP revision `2025-11-25`, because the current Claude
documentation warns that negotiated revision `2026-07-28` does not register
Channels.

Official references:
[Channels](https://code.claude.com/docs/en/channels),
[notification acknowledgment limits](https://code.claude.com/docs/en/channels-reference#notification-format),
[reply tool](https://code.claude.com/docs/en/channels-reference#expose-a-reply-tool),
[development preview](https://code.claude.com/docs/en/channels-reference#test-during-the-research-preview).

## Validation scope

On 2026-09-29, an isolated Claude Code `2.1.283` session exercised the exact Swift
question implementation: client lease, control lookup, enqueue, waiting hook,
stdout answer and matching accepted receipt. Claude continued and reported the
selected answer, `Blue`. This used a disposable relay and per-session settings;
existing sessions, global hooks and credentials were not changed.

Focused Swift tests cover identity and request fencing, credential fallback,
timeout/disconnect behavior, input preservation, endpoint ownership, delayed
heartbeats, handshake gating, missing acknowledgments and no automatic retries.
They simulate the Channels peer and do not by themselves verify a real Claude
channel connection.

Initial noninteractive `-p` probes on `2.1.283` connected the MCP server but did
not deliver channel notifications, including with the documented development
flag and supported protocol revision. The app correctly remains unavailable in
that condition. An isolated interactive session did receive the same channel
event and echoed its nonce through the MCP reply tool. A subsequent Swift probe
identified the startup listener race addressed by delayed, bounded connection
checks. After that fix, the Swift implementation delivered an ordinary message
and persisted its exact acknowledged command ID. The final universal `0.3.0`
packaged helper also completed a real interactive connection check, publishing
`ready: true` only after Claude called its reply tool. Neither result means
arbitrary existing CLI or Desktop sessions support ordinary inline prompts
without opting in to a channel at launch.
