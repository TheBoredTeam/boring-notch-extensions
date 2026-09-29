An independently built, free Claude Code extension for Boring Notch's native-extension developer preview. Source is in `packages/claude-code` in this repository, licensed GPL-3.0-only.

- One searchable native session tab with regular and compact layouts.
- Questions and permission requests in the tab and one aggregate activity.
- Documented five-hour and seven-day subscription usage, with context remaining shown separately.
- An explicit, reversible relay installation that preserves existing hooks and status-line output.
- A session handoff to a verified terminal or existing Remote Control link when available. Desktop has no documented per-session deep link; app activation is labeled as a fallback. Answer in Claude.

**This ZIP is self-signed with TheBoredTeam's development identity. It is not Developer ID signed or Apple notarized. It requires a compatible Debug build of Boring Notch launched with `BN_ALLOW_DEVELOPMENT_EXTENSIONS=1`; production hosts deliberately reject it.** The Store listing remains `preview`.

The ZIP contains a universal arm64/x86_64 bundle for macOS 14+. Both slices are built and signature-verified; native ABI/rendering tests execute on the CI runner's architecture. Intel hardware, physical multi-display operation, and every Desktop/editor origin have not been verified.

See the [package README](https://github.com/TheBoredTeam/boring-notch-extensions/tree/main/packages/claude-code) for requirements, setup, privacy, tests, and uninstall. Current Claude Code is recommended (2.1.243+). Missing subscription usage is shown as unavailable; the extension does not scrape account APIs or infer a quota.

`SHA256SUMS` records the exact attached ZIP. The workflow tests concurrent relay updates, configuration round-trips, native controller ownership, regular/compact rendering, and 1,000 synthetic sessions. Synthetic stress data is not live account usage.
