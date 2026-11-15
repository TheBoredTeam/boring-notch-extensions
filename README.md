# Boring Notch extensions

The extension registry for Boring Notch. Each file in `extensions/` is one pack record. The host lists that directory, downloads the TOML records, and reads the release URL and SHA-256 directly from each record.

Extension source and build output stay in the publisher's repository. This repository contains registry metadata and the workflows that validate records and open release-update pull requests.

## Record format

```toml
id = "com.example.extension"
name = "Example"
version = "1.0.0"
description = "A short description."
publisher = "Example Team"
developerID = "example-team"
repository = "https://github.com/example/extension"
license = "MIT"

[release]
url = "https://github.com/example/extension/releases/download/v1.0.0/Example.zip"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

[update]
strategy = "github-release"

[[extensions]]
bundleID = "com.example.extension.tab"
scenes = ["com.example.extension.tab"]
```

`kind` is optional and defaults to `"extensionkit"`: an app that carries ExtensionKit extensions, each listed with its `bundleID` and `scenes`, as above.

## Native bundle records

Boring Notch also loads native `.bnplugin` bundles. A record for one sets `kind = "bnplugin"`, names the Apple Developer Team ID that signs the bundle, and has a single `[[extensions]]` entry whose `bundleID` is the record `id`. `scenes` is not used.

```toml
id = "com.example.focus"
kind = "bnplugin"
name = "Focus Timer"
version = "1.0.0"
description = "A short description."
publisher = "Example Team"
developerID = "example-team"
repository = "https://github.com/example/focus"
license = "MIT"

[release]
url = "https://github.com/example/focus/releases/download/v1.0.0/Focus.zip"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
teamID = "ABCDE12345"

[update]
strategy = "github-release"

[[extensions]]
bundleID = "com.example.focus"
```

The release ZIP holds exactly one `.bnplugin` bundle at its root, and the `id` in its `Contents/Resources/manifest.json` matches the record. The validator checks both.

The release hash is the lock for the exact package bytes. There is no generated catalog aggregate, pricing data, or purchase metadata.

Run `python3 scripts/validate_registry.py` to validate the records and their release hashes.
