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
  settings and existing sessions were not changed during that isolated check.

### Real Desktop session

- Connected the same isolated host to a real local Claude Desktop Code session
  using the embedded Claude Code **2.1.281**. Removed the synthetic relay override
  and chose the real relay folder through the native folder picker.
- Installed the observational relay into user settings with a private backup;
  verified that unrelated values and both existing hook groups were preserved.
  The running Desktop session loaded the new hooks without being restarted.
- Observed genuine working and idle reports. The compact tab displayed the real
  session, and process ancestry identified Claude Desktop with PID/start identity.
- Clicking **Open session** produced an `appOpened` broker receipt and brought
  Claude Desktop forward. This verifies the labeled app fallback, not exact
  selection of an arbitrary Desktop session.
- Created a separate Desktop session in an empty temporary folder for a harmless
  `AskUserQuestion` check. The relay captured the exact question and two option
  labels, and the collapsed notch displayed the Claude logo with one session
  needing input. After the question was answered in Desktop, the relay cleared
  attention and the compact tab showed the test session as ready. The original
  working conversation was not given test prompts or restarted.
- Desktop's own UI displayed usage, but no status-line usage reached the relay.
  The extension correctly displayed unavailable quota/context values. No account
  API, credentials, or transcript files were read to fill those values.

## Limits

The complete question/options popover, permission prompts, and quota rendering
used documented-schema synthetic events. The real Desktop test verified the
question relay, collapsed attention, and clearing after a Desktop reply; the
question was answered before its full popover was visually captured. Live quota
values remain unverified: the noninteractive CLI check does not run a status
line and Desktop supplied none. Terminal UI control was unavailable in the
validation environment; exact Terminal/iTerm focusing and its complete reply
round-trip were not verified. Desktop has no documented native per-session deep
link; an already enabled Remote Control session can provide a web link. Physical
external displays, Intel hardware, and every editor/terminal origin remain
unverified.

The preview host and native plugin share a process. Local app validation used an
isolated development app, not a clean-Mac production/Gatekeeper acceptance test.
The public ZIP remains self-signed, not Developer ID signed or Apple notarized.
