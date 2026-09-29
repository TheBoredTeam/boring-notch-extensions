# Development validation — 2026-09-29

The independent universal Debug bundle was signed with TheBoredTeam's existing
self-signed identity. Both arm64 and x86_64 slices passed signature verification.
The local execution checks below ran on Apple silicon; this is not an Intel
hardware certification or a notarized consumer release.

## Automated checks

- **44 bridge assertions:** 80 concurrent usage/question updates, 12 concurrent
  installs, original settings round-trip, preservation of status-line input,
  output and exit status, storage bounds, private file handling, redaction,
  symlink rejection, retention, and broker receipts without opening apps.
- **69 native ABI assertions** against the separately compiled `.bnplugin`:
  1,000 synthetic sessions, 200 unanswered questions, zero eager controllers,
  regular 578×132, compact 336×132, narrow 300×120, invalid contexts, selection
  and question preservation, remounts, per-display controller ownership,
  27 created/27 destroyed controllers, and no late callbacks.
- The bundled official Claude logo is the exact PNG published in tab metadata;
  resource lookup also resolves the relay within the loaded plugin bundle.
- A final local run loaded the 1,000 synthetic sessions in **285 ms**. An earlier
  cold run under concurrent compilation took 4,628 ms. These are observations,
  not performance guarantees. The bounded reader performs one directory scan.
- The host's **25 focused tests** passed, including PNG fallback/format/bounds,
  icon caching and content identity, 1,000 registered tabs, and 400 compact mounts.
- The native catalog's **30 tests** passed; the C ABI reference parses as C and C++.

Reproduce package checks with `bash scripts/test.sh <debug-bundle-path>`.
`BN_CLAUDE_KEEP_FIXTURES=1` retains the private fixture directory, render artifacts,
and JSON report for inspection. The harness refuses a non-Debug plugin before
creation so it cannot accidentally read a saved real relay connection.

## App and Claude integration

- Built the complete host at `ccb148a6ec253d83fd19a9016557137933b0c6b3`.
- Installed the development ZIP through the isolated host's Settings, selected
  its private relay folder through the native picker, and verified connection.
- Inspected live regular and compact session content, search, full question and
  options, aggregate activity, and the official logo in regular content and the
  floating tab strip. The original Focus Timer and Lock Screen packages remained
  independently installed alongside Claude Code.
- A fresh **Claude Code 2.1.283** noninteractive session used temporary settings
  and no session persistence. It returned the requested harmless response and
  the relay recorded its ended lifecycle with PID/start identity. Normal Claude
  settings and existing sessions were not changed.

## Limits

Question/permission and quota rendering used documented-schema synthetic events.
The noninteractive Claude check does not run a status line, so it did not verify
live account quota values. Terminal UI control was unavailable in the validation
environment; exact Terminal/iTerm focusing and a complete reply round-trip were
not verified. Desktop has no documented per-session deep link. Physical external
displays, Intel hardware, and every editor/terminal origin remain unverified.

The preview host and native plugin share a process. Local app validation used an
isolated development app, not a clean-Mac production/Gatekeeper acceptance test.
The public ZIP remains self-signed, not Developer ID signed or Apple notarized.
