#!/usr/bin/env python3
"""Validate both TOML schema families, optionally checking legacy release assets."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys
import urllib.request

from catalog import CatalogError, ROOT, https, read_records, require

MAX_LEGACY_ARCHIVE_BYTES = 512 * 1024 * 1024


def check_legacy_artifact(record: dict, opener=None) -> None:
    """Retain the existing pack gate: reachable URL and exact published hash."""
    fetch = opener or urllib.request.urlopen
    release = record["release"]
    request = urllib.request.Request(release["url"], method="HEAD")
    with fetch(request, timeout=30) as response:
        require(response.status == 200, f"legacy release URL returned HTTP {response.status}")
        require(https(response.geturl()), "legacy release redirected to an unsafe URL")
        size = response.headers.get("Content-Length")
        if size is not None:
            require(size.isdigit() and int(size) <= MAX_LEGACY_ARCHIVE_BYTES,
                    "legacy release exceeds the 512 MiB archive limit or has invalid size")
    digest = hashlib.sha256()
    total = 0
    with fetch(release["url"], timeout=120) as response:
        require(response.status == 200 and https(response.geturl()), "legacy release download failed or redirected unsafely")
        while chunk := response.read(512 * 1024):
            total += len(chunk)
            require(total <= MAX_LEGACY_ARCHIVE_BYTES, "legacy release exceeds the 512 MiB archive limit")
            digest.update(chunk)
    require(total > 0, "legacy release archive is empty")
    require(digest.hexdigest() == release["sha256"].lower(),
            f"legacy sha256 mismatch: recorded {release['sha256']}, asset is {digest.hexdigest()}")


def validate_registry(directory: Path, check_artifacts: bool = False) -> tuple[int, int]:
    native = legacy = 0
    for kind, path, record in read_records(directory):
        if kind == "native":
            native += 1
            continue
        legacy += 1
        if check_artifacts:
            try:
                check_legacy_artifact(record)
            except (CatalogError, OSError, ValueError) as error:
                raise CatalogError(f"{path.name}: {error}") from error
    return native, legacy


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "extensions")
    parser.add_argument("--check-legacy-artifacts", action="store_true",
                        help="Download existing legacy pack releases and verify their SHA-256 digests.")
    args = parser.parse_args()
    try:
        native, legacy = validate_registry(args.source, args.check_legacy_artifacts)
        print(f"Validated {native} native records and {legacy} legacy packs."
              + (" Legacy release assets verified." if args.check_legacy_artifacts else ""))
        return 0
    except (CatalogError, OSError) as error:
        print(f"Registry validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
