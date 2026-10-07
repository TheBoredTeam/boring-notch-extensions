#!/usr/bin/env python3
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import sys
import tomllib
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
failures: list[str] = []

for path in sorted((ROOT / "extensions").glob("*.toml")):
    try:
        record = tomllib.loads(path.read_text(encoding="utf-8"))
        for key in ("id", "name", "version", "description", "publisher", "repository"):
            if not isinstance(record.get(key), str) or not record[key].strip():
                raise ValueError(f"missing {key}")
        if path.name != f"{record['id']}.toml":
            raise ValueError("filename must match id")
        release = record.get("release")
        if not isinstance(release, dict):
            raise ValueError("missing [release]")
        url = release.get("url", "")
        digest = release.get("sha256", "")
        if not isinstance(url, str) or not url.startswith("https://") or not url.endswith(".zip"):
            raise ValueError("release.url must be a public HTTPS ZIP")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            raise ValueError("release.sha256 must be 64 hexadecimal characters")
        extensions = record.get("extensions")
        if not isinstance(extensions, list) or not extensions:
            raise ValueError("at least one [[extensions]] entry is required")
        for extension in extensions:
            if not extension.get("bundleID") or not extension.get("scenes"):
                raise ValueError("each extension requires bundleID and scenes")
        request = urllib.request.Request(url, headers={"User-Agent": "boring-notch-registry"})
        with urllib.request.urlopen(request, timeout=120) as response:
            actual = hashlib.sha256(response.read()).hexdigest()
        if actual != digest.lower():
            raise ValueError(f"SHA-256 mismatch: expected {digest}, got {actual}")
    except Exception as error:
        failures.append(f"{path}: {error}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    raise SystemExit(1)
print("Registry records and locked release hashes are valid.")
