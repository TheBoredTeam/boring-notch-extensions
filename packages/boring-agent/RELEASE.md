BoringAgent is the multi-agent successor to the Claude Code extension. It remains an independently built, free native extension for Boring Notch's developer preview.

- Shared Progress and Usage views with compact layouts.
- Provider rings and live quota popovers; account limits stay separate from session context.
- Claude sessions, questions, and handoff continue using the existing relay.
- Codex and Antigravity adapter slots are prepared and explicitly unavailable in this version.
- The installation ID is retained so upgrading preserves the Claude relay connection.

**This is a self-signed development preview, not an Apple-notarized production release. Use a compatible Debug host with `BN_ALLOW_DEVELOPMENT_EXTENSIONS=1`.** The Store listing remains preview. Missing Desktop usage stays unavailable; no quota is invented.

Source and setup: [packages/boring-agent](https://github.com/TheBoredTeam/boring-notch-extensions/tree/main/packages/boring-agent). See the package validation notes for real-session and automated evidence. The prior 0.1.0 release is unchanged.
