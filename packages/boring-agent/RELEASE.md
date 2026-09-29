BoringAgent 0.2.1 fixes Claude account usage for Desktop sessions while keeping Claude as an adapter inside the single BoringAgent extension.

- A separate **Connect usage** flow reads the existing default Claude Code sign-in through the relay helper and fetches shared plan quotas from Anthropic.
- Five-hour, weekly, and model-specific windows have correct used/remaining semantics. Scoped model quotas do not constrain the overall ring.
- Usage errors and refresh state are independent of the session relay; session-opening messages no longer appear in Usage.
- Account requests are bounded and rate-limited, with explicit opt-in, disconnect, account identity checks, and no token storage or refresh.

Update the relay by running the newly installed bundle's setup command, then choose Connect usage. Use the same account in Claude Code and Desktop. Account endpoints are undocumented and may change. Cloud-session credit balances and missing session context are not inferred.

**Self-signed development preview. Requires the compatible Debug host with development extensions enabled; not Apple-notarized.** Source and setup: [packages/boring-agent](https://github.com/TheBoredTeam/boring-notch-extensions/tree/main/packages/boring-agent).
