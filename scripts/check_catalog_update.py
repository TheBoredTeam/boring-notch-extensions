#!/usr/bin/env python3
"""Require explicitly edited catalog.json files to match their TOML sources.

Source-only changes may leave the aggregate for main's publication job. A change
that edits/deletes the aggregate itself must pass this stronger check before it
can be merged, so a hand-edited public feed cannot bypass source validation.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys

from catalog import CatalogError, MAX_CATALOG_BYTES, ROOT, generate, require


def enforce_explicit_update(repository: Path, base: str) -> bool:
    require(re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", base) is not None,
            "base must be the complete event commit SHA")
    if set(base) == {"0"}:
        # A new branch has no before commit. Its initial aggregate is explicit.
        changed = True
    else:
        result = subprocess.run(["git", "diff", "--quiet", base, "HEAD", "--", "catalog.json"],
                                cwd=repository, capture_output=True, text=True)
        require(result.returncode in {0, 1}, "cannot compare catalog.json against the event base commit")
        changed = result.returncode == 1
    if changed:
        aggregate = repository / "catalog.json"
        require(not aggregate.is_symlink() and aggregate.is_file()
                and aggregate.stat().st_size <= MAX_CATALOG_BYTES,
                "catalog.json must be a regular file no larger than 2 MB")
        require(aggregate.read_bytes() == generate(repository / "extensions"),
                "catalog.json was explicitly changed but does not match TOML sources; run python3 scripts/catalog.py")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=ROOT)
    parser.add_argument("--base", required=True, help="PR base SHA or push event before SHA; never shell-expanded source content.")
    args = parser.parse_args()
    try:
        changed = enforce_explicit_update(args.repository, args.base)
        print("Explicit catalog.json update matches TOML sources." if changed
              else "Aggregate was not edited; main may generate it from source-only changes.")
        return 0
    except (CatalogError, OSError) as error:
        print(f"Catalog update check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
