#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")


def github_json(url: str):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "boring-notch-registry"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.load(response)


def version_key(value: str) -> tuple[int, ...]:
    match = re.search(r"\d+(?:\.\d+)*$", value)
    return tuple(int(part) for part in match.group(0).split(".")) if match else (0,)


def field(text: str, key: str, section: str | None = None) -> str | None:
    active = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            active = stripped.strip("[]")
        if section is not None and active != section:
            continue
        match = re.match(rf"^{re.escape(key)}\s*=\s*\"([^\"]*)\"", stripped)
        if match:
            return match.group(1)
    return None


def replace_field(text: str, key: str, value: str, section: str | None = None) -> str:
    lines = text.splitlines(keepends=True)
    active = None
    pattern = re.compile(rf"^(\s*{re.escape(key)}\s*=\s*)\"[^\"]*\"(.*)$")
    for index, line in enumerate(lines):
        if line.lstrip().startswith("["):
            active = line.strip().strip("[]")
        if (section is None or active == section) and pattern.match(line):
            lines[index] = pattern.sub(rf'\g<1>"{value}"\g<2>', line, count=1)
            return "".join(lines)
    raise RuntimeError(f"missing {key} in {section or 'top-level'}")


def download_hash(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "boring-notch-registry"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=300) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


updates: list[str] = []
for path in sorted((ROOT / "extensions").glob("*.toml")):
    text = path.read_text(encoding="utf-8")
    if field(text, "strategy", "update") != "github-release":
        continue
    repository = field(text, "repository")
    release_url = field(text, "url", "release")
    current = field(text, "version") or "0.0.0"
    if not repository or not repository.startswith("https://github.com/") or not release_url:
        continue
    slug = repository.removeprefix("https://github.com/").removesuffix(".git").rstrip("/")
    releases = github_json(f"https://api.github.com/repos/{slug}/releases?per_page=100")
    candidates = [release for release in releases if release.get("tag_name") and not release.get("draft") and not release.get("prerelease")]
    if not candidates:
        continue
    latest = max(candidates, key=lambda release: version_key(release["tag_name"]))
    latest_version = latest["tag_name"].removeprefix("v")
    if version_key(latest_version) <= version_key(current):
        continue
    asset_name = Path(release_url).name
    assets = [asset for asset in latest.get("assets", []) if asset["name"] == asset_name]
    if len(assets) != 1:
        raise RuntimeError(f"{path.name}: release {latest['tag_name']} must contain exactly one {asset_name}")
    asset = assets[0]
    updated = replace_field(text, "version", latest_version)
    updated = replace_field(updated, "url", asset["browser_download_url"], "release")
    updated = replace_field(updated, "sha256", download_hash(asset["browser_download_url"]), "release")
    path.write_text(updated, encoding="utf-8")
    updates.append(f"{path.name}: {current} -> {latest_version}")

if not updates:
    print("No release updates found.")
    raise SystemExit(0)

print("\n".join(updates))
branch = f"automation/update-extensions-{os.environ['GITHUB_RUN_ID']}"
subprocess.run(["git", "config", "user.name", "extension-update-bot"], check=True)
subprocess.run(["git", "config", "user.email", "actions@users.noreply.github.com"], check=True)
subprocess.run(["git", "checkout", "-b", branch], check=True)
subprocess.run(["git", "add", "extensions"], check=True)
subprocess.run(["git", "commit", "-m", "Update extension releases"], check=True)
subprocess.run(["git", "push", "--set-upstream", "origin", branch], check=True)
subprocess.run([
    "gh", "pr", "create", "--base", "main", "--head", branch,
    "--title", "Update extension releases",
    "--body", "Automated update from a registered publisher release.",
], check=True)
