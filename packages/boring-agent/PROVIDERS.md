# Adding an agent provider

Implement feature behavior in an `AgentProviderAdapter`, then register it in
`AgentProviderRegistry.makeDefaultAdapters()`. Keep the Progress and Usage views
shared. Claude and Codex are working examples; Antigravity remains an explicitly
unavailable adapter.

1. Choose a stable provider ID without a colon and a descriptor with a title,
   short name, accent, accessible SF Symbol fallback, and authentic artwork or
   native application bundle ID. Do not rename an ID after sessions depend on it.
2. Observe a documented provider interface. Own authentication, connection,
   scheduling, parsing, and cleanup inside the adapter. Keep expensive work off
   the main actor, bound input and retries, and publish a coherent snapshot back
   on the main actor. Do not read private transcripts or scrape credentials to
   disguise an unsupported integration as connected.
3. Publish each session using its native identity and provider ID. Preserve
   identity across title, progress, model, question, and quota updates. Normalize
   phase into working, needsInput, idle, or ended; report what the source knows.
4. Publish account usage independently of sessions. Use dynamic quota windows;
   validate percentages and timestamps. Do not substitute session context for
   subscription limits, add percentages across sessions, or fabricate reset
   behavior. Missing data is nil; zero means an actual exhausted quota.
5. Implement session actions against verified original identities. Opening an
   app is a labeled fallback, not proof the exact session was selected. Never
   auto-answer questions, approve tools, or start duplicate sessions.
6. For inline input, publish an `AgentSessionControl` only when a supported live
   owner is known. Bind each command to the provider, native session, connection
   revision and exact question/turn. Use `AgentMessageCommand` and shared
   `AgentRelayStorage`; consume once and return an exact UUID receipt. Never
   retry an ambiguous send, infer acceptance from a socket write, auto-approve
   tool permissions, or resume a running thread in a second owner.
7. Update `snapshot` before calling `onChange`. On `stop`, clear callbacks,
   cancel work, close resources, and reject all late asynchronous completions.
   Use the dashboard's shared clock for freshness instead of per-row timers.
8. Inject a fake adapter in tests: `AgentDashboardState(adapters: [...],
   clock: ..., schedulesClock: false)`. Verify namespaces, command routing,
   real 0 versus unavailable, stale/reset behavior, provider removal of sessions,
   selection, and safety after stop. Tests must not instantiate the default
   registry when they are meant to be isolated.
9. Test the independent bundle in the real host, including compact bounds,
   many providers, questions, reconnect/disable/restart, and native handoff.
   Record the exact provider versions and what remained unverified.

The dashboard bounds provider count and retained session/window collections;
respect those limits and surface provider-specific omissions where relevant.
A hidden view never owns an adapter or starts a provider service. New capabilities
that do not fit the shared model should extend the protocol deliberately and
include a real vertical slice, rather than adding arbitrary view factories to
provider descriptors.
