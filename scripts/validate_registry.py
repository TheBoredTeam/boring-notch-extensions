#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import re
import sys
import tomllib
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
KINDS = ("extensionkit", "bnplugin")
failures: list[str] = []


def check_bnplugin_zip(data: bytes, record_id: str) -> None:
    """The release must hold exactly one .bnplugin bundle whose manifest id matches the record."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = [n for n in archive.namelist() if not n.startswith("__MACOSX/") and "/._" not in "/" + n]
        roots = {n.split("/", 1)[0] for n in names}
        if len(roots) != 1 or not next(iter(roots)).endswith(".bnplugin"):
            raise ValueError(f"release ZIP must contain exactly one .bnplugin bundle at its root, found {sorted(roots)}")
        manifest = json.loads(archive.read(f"{next(iter(roots))}/Contents/Resources/manifest.json"))
        if manifest.get("id") != record_id:
            raise ValueError("bundle manifest id must match the record id")

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
        kind = record.get("kind", "extensionkit")
        if kind not in KINDS:
            raise ValueError(f"kind must be one of {', '.join(KINDS)}")
        extensions = record.get("extensions")
        if not isinstance(extensions, list) or not extensions:
            raise ValueError("at least one [[extensions]] entry is required")
        if kind == "extensionkit":
            for extension in extensions:
                if not extension.get("bundleID") or not extension.get("scenes"):
                    raise ValueError("each extension requires bundleID and scenes")
        else:
            # One native bundle per record; the host checks its signature against this team.
            if len(extensions) != 1 or extensions[0].get("bundleID") != record["id"]:
                raise ValueError("a bnplugin record has one [[extensions]] entry whose bundleID equals id")
            if not re.fullmatch(r"[A-Z0-9]{10}", str(release.get("teamID", ""))):
                raise ValueError("a bnplugin release requires teamID, the 10-character Apple Developer Team ID")
        request = urllib.request.Request(url, headers={"User-Agent": "boring-notch-registry"})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
        actual = hashlib.sha256(data).hexdigest()
        if actual != digest.lower():
            raise ValueError(f"SHA-256 mismatch: expected {digest}, got {actual}")
        if kind == "bnplugin":
            check_bnplugin_zip(data, record["id"])
    except Exception as error:
        failures.append(f"{path}: {error}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    raise SystemExit(1)
print("Registry records and locked release hashes are valid.")
