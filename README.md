# Boring Notch extensions

The canonical extension registry for Boring Notch. Authors maintain one **TOML**
record per extension in `extensions/`. Maintainers review the records and CI
generates the native Store's `catalog.json`. Adding or updating an approved
listing does **not** require an app release.

```text
https://raw.githubusercontent.com/TheBoredTeam/boring-notch-extensions/main/catalog.json
```

TOML is the authoring format; JSON is the generated delivery format. The app
fetches one bounded catalog through its native JSON decoder, without listing a
GitHub directory or fetching every source file. This repository contains metadata,
tooling, an API reference, and independently built free extensions in `packages/`.
Extension code, native UI, business logic, and licensing stay in each publisher's
bundle; none of these packages is compiled into Boring Notch.

## Free extension packages

| Package | Purpose | Availability |
| --- | --- | --- |
| [BoringAgent](packages/boring-agent) | A multi-agent Progress and Usage dashboard; Claude connected, Codex and Antigravity adapters prepared | Self-signed development preview; requires a compatible Debug host |

Each package owns its source, license, standalone build, tests, and release.
Third-party publishers can use their own repositories. Store records under
`extensions/` contain only metadata, never extension source or compiled bundles.

## Build an extension with a coding assistant

Start with [LLM.txt](LLM.txt) for a copyable prompt and reading order.
[AGENTS.md](AGENTS.md) covers architecture, native view ownership, activities,
regular/compact tabs, lifecycle, testing, signing, packaging, and Store submission.
The [API reference](docs/README.md) includes the exact C ABI and its provenance.
The native activities/tabs APIs are a **developer preview**: verify the target
host build before promising compatibility with a released app.

## Register or update a native extension

1. Fork this repository and add `extensions/<manifest-id>.toml`. Set
   `schemaVersion = 1`; the filename and `id` must exactly match the bundle's
   lowercase manifest ID. Use the native records as examples.
2. Fill in truthful publisher, product, compatibility, privacy, and support
   information. Use `preview` or `coming-soon` until a release is ready.
3. An `available` release needs the actual final ZIP's public HTTPS download URL,
   SHA-256, publisher signing Team ID, exact version, and API version in
   `[artifact]`. Use immutable release URLs. Put checkout links in `purchaseUrl`.
4. With **Python 3.11 or later**, run:

   ```sh
   python3 -m unittest discover -s tests -v
   python3 scripts/catalog.py --output /tmp/boring-extension-catalog.json
   ```

5. Open a pull request with public publisher identity, release/source links,
   compatibility and signing/notarization evidence, and the changes being made.
   Maintainers review listings and release updates before merging.

Edit source TOML files, not `catalog.json`. PR automation validates the sources
and uploads a generated review artifact. After merge, the native catalog workflow
regenerates and commits the aggregate. Its publication job needs `contents: write`
on `main`; PR validation remains read-only. Native releases are curated through
these submissions, not automatically approved by a publisher's own manifest.
If a change explicitly edits `catalog.json`, CI requires those bytes to match
the generated output. Source-only changes can leave generation to the workflow.

## Native TOML schema

A source has top-level `schemaVersion = 1` and the fields below. TOML tables
represent nested records, and arrays of tables can represent richer product
information. The following is a complete **illustrative preview record**, using
an example identity and URLs. Replace them with real publisher information
before submitting; it does not advertise a downloadable release.

```toml
schemaVersion = 1
id = "org.example.focus"
slug = "focus"
name = "Focus"
tagline = "A focus timer in your notch."
description = "Start a session and follow its progress in a native tab or live activity."
version = "1.0.0-preview"
status = "preview"
statusNote = "Developer preview; no consumer download is available yet."
categories = ["Productivity"]
requirements = ["macOS 14 or later", "A compatible native-extension preview host"]
websiteUrl = "https://example.org/focus"
supportUrl = "https://example.org/support"

[developer]
name = "Example Developer"
url = "https://example.org"

[price]
amount = 0
currency = "USD"
billing = "free"

[[features]]
title = "One shared session"
description = "Progress stays in sync between the tab and activity."
```

Place top-level fields before table headers. For example, a `status` written
after `[price]` would belong to the price table. The generator uses Python's
standard TOML parser, including comments, escaped strings, multiline strings,
and nested tables; it rejects duplicate keys instead of silently choosing one.

| Field | Meaning |
| --- | --- |
| `id`, `slug`, `name` | Exact lowercase manifest ID, unique stable lowercase URL slug, and display name. |
| `tagline`, `description` | Short and full plain-text descriptions. |
| `[developer]` | `name` and public HTTPS `url`. |
| `categories`, `requirements` | Arrays of categories and concrete compatibility requirements. |
| `[price]` | Numeric `amount`, uppercase three-letter `currency`, and `billing`: `free`, `one-time`, `monthly`, or `yearly`. Free means zero; paid means a positive amount. |
| `status` | `coming-soon`, `preview`, or `available`. Available records require an artifact. |
| `version` | Exact manifest version for available releases; an honest preview label otherwise. |
| `statusNote` | Optional release-readiness explanation. |
| `websiteUrl` | Optional public HTTPS product page. The app falls back to `developer.url`. |
| `sourceUrl`, `supportUrl`, `purchaseUrl` | Optional public HTTPS source, support, and publisher checkout links. |
| `icon`, `artwork` | Optional public HTTPS images; existing `assets/extensions/...` website paths are also supported. |
| `[artifact]` | Required for an available release; fields below. |

Additional JSON-compatible metadata such as `features`, `privacy`, `installSteps`,
`previews`, and `artworkAlt` is preserved for consumers. Use strings for dates;
native TOML dates/times, nonfinite numbers, integers outside signed 64-bit range,
and values nested beyond 16 levels are not catalog data. Catalog text does not
execute HTML or extension code.

When a release is ready, use a top-level `version` matching its manifest, change
`status` to `available`, and add `[artifact]` with these **real** values:

| Artifact field | Value |
| --- | --- |
| `downloadURL` | Public HTTPS URL delivering the final `.zip`, without customer credentials or fragments. |
| `sha256` | The ZIP's exact 64-character hexadecimal SHA-256 digest. |
| `publisherTeamID` | The publisher's ten-character Apple signing Team ID. |
| `version` | Exactly the listing and packaged manifest version. |
| `apiVersion` | Integer `1`. |

The compatibility alias `artifact.url` is normalized to `downloadURL`; conflicting
aliases are rejected. Compute the hash after signing, notarization, and final
packaging:

```sh
shasum -a 256 /path/to/Extension-1.0.0.zip
```

Validation proves metadata consistency. Maintainers review the actual release,
and the host separately verifies the downloaded hash, archive structure,
manifest identity/version, all architecture signatures, notarization, and Team
ID. A catalog entry is neither a purchase receipt nor a substitute for those checks.

## Existing extension packs

The existing `com.personalteam.FocusBoard.toml` and `com.personalteam.TaskDeck.toml`
describe the older extension-pack system. Their IDs, paths, `[release]` data,
`[[extensions]]` declarations, and release assets are preserved. The legacy
release-discovery workflow continues to operate on that format.

These records have no `schemaVersion`. The validator recognizes their complete
legacy structure and keeps the release URL/hash checks. They are **excluded**
from the native `.bnplugin` catalog: a pack is not converted by changing its
filename, casing, or adding a schema key. A native release requires an actual
compatible bundle and its own verified publisher/artifact metadata.

Presence of `schemaVersion` always selects native validation; unsupported values
fail. Missing the field on an incomplete native record cannot silently turn it
into a legacy pack. The native feed initially contains the Now Playing preview
and Lock Screen coming-soon listings, with no approved consumer ZIP artifacts.

## Delivery, bounds, and checks

Native sources are UTF-8 TOML, at most 65,536 bytes each, directly under
`extensions/`, with no symbolic links or duplicate keys. The registry accepts
up to 500 source records across both formats; the native aggregate is limited
to 2,000,000 bytes. IDs and slugs are unique. The aggregate is
deterministically sorted and shaped as
`{"schemaVersion":1,"extensions":[full native listing records]}`; individual
source `schemaVersion` fields are removed from those listing objects.

```sh
python3 scripts/catalog.py          # Generate catalog.json locally.
python3 scripts/catalog.py --check  # Check that an existing aggregate is current.
```

The app refreshes on Store entry when its one-hour freshness window has elapsed,
and on manual Refresh. Conditional requests and a validated, source-bound cache
avoid unnecessary downloads. Failed refreshes preserve the last good catalog.
GitHub CDN propagation may delay a newly published revision briefly.

Publishers own pricing, checkout, licensing, accounts, refunds, and paid access.
Boring Notch handles discovery, delivery, installation, and native hosting. A
paid bundle can be publicly downloadable and enforce activation through its own
settings/service. Do not put secrets, purchase tokens, or customer data in TOML.

## Migration from boring.extensions

This repository replaces the separate `TheBoredTeam/boring.extensions` registry.
Its two native listings and authoring/API guides are carried forward here using
TOML. The former repository retains a frozen plist feed for existing preview
clients and points authors here. New submissions belong in this repository.

The change concerns catalog authoring and delivery. A bundle still contains the
macOS `Info.plist` and its JSON `manifest.json`, and the host may use a binary
plist for its private cache; these are separate contracts.
