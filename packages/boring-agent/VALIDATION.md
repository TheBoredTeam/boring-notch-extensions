# BoringAgent 0.2.1 account usage validation — 2026-09-29

- Built and signature-verified the independent universal arm64/x86_64 bundle.
- **44 relay**, **39 account-service**, **1,147 dashboard**, and **83 native ABI**
  assertions passed locally. The dashboard stress case uses 1,000 sessions across
  100 injected providers. All 27 controller lifetimes balanced; no eager views
  or late callbacks were observed.
- Account-service tests inject credentials, HTTP, and clocks. They cover quota
  and profile parsing, scoped windows, zero/missing data, opt-in, durable revoke,
  request acknowledgements, throttling, Retry-After, account changes, and late
  completion. They never access a real Keychain item or account endpoint.
- The binary ABI test independently writes an account report into the private
  relay and renders the mounted compact view with 11% remaining, while retaining
  all 1,000 session records. Those values are synthetic test data.
- **30 catalog tests** passed; generated TOML catalog validates.
- Installed the final ZIP through Settings and verified the installed plugin,
  helper, and manifest match the tested build. Updated the separate relay helper;
  Claude settings remained byte-equivalent as parsed JSON. The new account source
  starts disabled and exposes an explicit Connect usage disclosure.

After explicit user approval, enabled account usage through the native Connect
usage button. The separate helper returned a real Max 5x account report. Compared
the native quota rows against Claude Desktop's opened usage popover at the same
time: five-hour **61% used**, weekly all-model **92% used**, Fable **0% used**.
BoringAgent showed **8% left**, with matching reset windows. These are observed
values from that check, not fixed fixtures or permanent account values. Session
work continued in Desktop without a restart or test prompt. The account source
was enabled before the live request, and no token appeared in the relay record.

Reopened the installed extension in compact mode and verified the live quota
popover stays within its layout. The scheduled refresh advanced the report time
without a manual request; five-hour usage increased to 63%, while the binding
weekly allowance remained 8% left. No synthetic relay override was active.

The version remains an unnotarized development preview. Cloud credit balances
are outside the account OAuth source and were not implemented or inferred.

# BoringAgent 0.2.0 development validation — 2026-09-29

## BoringAgent dashboard

- Built and signature-verified the independent universal arm64/x86_64 bundle
  with the existing development identity. Local execution ran on Apple silicon.
- **1,143 dashboard assertions:** 1,000 sessions across 100 injected providers,
  duplicate registration, namespaced identities, action routing, selection,
  membership changes, actual versus missing/zero quota, latest account reports,
  context separation, stale/reset handling, and late callback/action fencing.
- **44 relay assertions:** preserved the existing Claude integration checks.
- **77 native ABI assertions:** loaded the separately compiled bundle, rendered
  Usage and Progress in regular 578×132 and compact 336×132 bounds, exercised
  narrow 300×120 bounds, preserved selection through updates, and balanced all
  27 controller lifetimes with zero eager controllers and zero late callbacks.
- **30 catalog tests** passed. Workflow YAML and embedded shell scripts parse.
- Installed the ZIP through the isolated host's Settings as an in-place update
  from the Claude Code preview. The stable bundle ID and saved relay bookmark
  were preserved; the restarted BoringAgent Progress view displayed the real
  Claude Desktop sessions without selecting a new folder.
- Visually inspected the Usage rings, selected section, native quota popover,
  session list, and full question/options popover in the host. Isolated sample
  reports exercised 56% remaining with 28% and 44% used quota rows. These values
  were synthetic layout checks, never presented as live account usage.
- Reinstalled the final signed ZIP and verified the installed executable,
  relay, and manifest match the build. Temporarily moved a private fixture relay
  after loading quota: the card showed **Needs attention**, the popover retained
  both quota rows and displayed the access error. Restoring the fixture and
  refreshing cleared the error. Restored the real relay in compact mode.

Claude is the only connected provider in this version. Codex and Antigravity
use explicit unavailable adapters. Their neutral cards expose no fake quotas
or inactive connect/refresh actions. Their adapters require implementation and
real-provider validation before being advertised as connected.

The real Desktop source still supplies session events but no status-line quota
values. The dashboard preserves this as unavailable. It retains the existing
app-level handoff fallback and does not auto-answer or approve agent requests.
No production-host/Gatekeeper acceptance, notarization, Intel execution, or
physical multi-display claim is made by these local development checks.

## Earlier Claude 0.1.0 baseline

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
