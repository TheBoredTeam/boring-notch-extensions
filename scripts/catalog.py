#!/usr/bin/env python3
"""Validate native extension TOML and build the public JSON transport catalog.

Python 3.11+ is required for the standard-library TOML 1.0 parser. Legacy
release packs are validated separately and never become native install records.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import math
from pathlib import Path
import tomllib
import re
import sys
import unicodedata
from urllib.parse import urlsplit

MAX_SOURCE_BYTES = 65_536
MAX_ITEMS = 500
MAX_CATALOG_BYTES = 2_000_000
MAX_METADATA_DEPTH = 16
ROOT = Path(__file__).resolve().parents[1]
ID_PATTERN = re.compile(r"[a-z][a-z0-9]*(\.[a-z0-9-]+)+\Z")
SLUG_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")


class CatalogError(ValueError):
    pass


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise CatalogError(reason)


def text(value: object, limit: int) -> bool:
    return (isinstance(value, str) and bool(value.strip())
            and len(value.encode("utf-8")) <= limit
            and not any(unicodedata.category(char) in {"Cc", "Cf"}
                        and char not in "\n\r\u0085" for char in value))


def https(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        if len(value.encode("utf-8")) > 4_096:
            return False
    except UnicodeError:
        return False
    if ("#" in value or "\\" in value or re.search(r"%(?![0-9a-fA-F]{2})", value)
            or any(char.isspace() or unicodedata.category(char) in {"Cc", "Cf", "Cs"} for char in value)):
        return False
    try:
        parsed = urlsplit(value)
        # urlsplit leaves malformed/non-numeric ports lazy until this property
        # is read. Match Foundation's URL decoding before publishing records.
        port = parsed.port
        return (parsed.scheme.lower() == "https" and valid_hostname(parsed.hostname)
                and parsed.username is None and parsed.password is None
                and (port is None or 1 <= port <= 65_535))
    except (ValueError, UnicodeError):
        return False


def valid_hostname(host: str | None) -> bool:
    """Accept DNS/IDNA names and IP literals with no authority percent tricks.

    urlsplit alone accepts hosts that Foundation URL(string:) cannot decode,
    which would make one submitted link invalidate the complete native feed.
    """
    if not host or "%" in host:
        return False
    if ":" in host:
        try:
            return isinstance(ipaddress.ip_address(host), ipaddress.IPv6Address)
        except ValueError:
            return False
    # An apparent IPv4 address must actually be one, not a malformed numeric
    # address that another URL stack could interpret differently.
    if re.fullmatch(r"[0-9.]+", host):
        try:
            return isinstance(ipaddress.ip_address(host), ipaddress.IPv4Address)
        except ValueError:
            return False
    try:
        ascii_host = host.encode("idna").decode("ascii").removesuffix(".")
    except UnicodeError:
        return False
    return (0 < len(ascii_host) <= 253
            and all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                    is not None for label in ascii_host.split(".")))


def asset(value: object) -> bool:
    if https(value):
        return True
    return (isinstance(value, str) and value.startswith("assets/extensions/")
            and not any(char in value for char in "\\%?#")
            and not any(part in {"", ".", ".."} for part in value.split("/"))
            and value.rsplit(".", 1)[-1].lower() in {"svg", "png", "webp", "jpg", "jpeg"})


def validate_artifact(value: object, version: str) -> dict:
    require(isinstance(value, dict), "artifact must be a dictionary")
    canonical = value.get("downloadURL")
    legacy = value.get("url")
    require(canonical is None or legacy is None or canonical == legacy,
            "artifact.downloadURL and legacy artifact.url disagree")
    url = canonical if canonical is not None else legacy
    require(https(url) and urlsplit(url).path.lower().endswith(".zip"),
            "artifact.downloadURL must be a public HTTPS ZIP URL without credentials or fragments")
    require(isinstance(value.get("sha256"), str)
            and re.fullmatch(r"[A-Fa-f0-9]{64}", value["sha256"]) is not None,
            "artifact.sha256 must contain the exact ZIP's 64 hexadecimal digest characters")
    require(isinstance(value.get("publisherTeamID"), str)
            and re.fullmatch(r"[A-Z0-9]{10}", value["publisherTeamID"]) is not None,
            "artifact.publisherTeamID must be the publisher's 10-character signing Team ID")
    release_version = value.get("version")
    require(text(release_version, 64) and release_version == release_version.strip()
            and not any(unicodedata.category(char) in {"Cc", "Cf"} for char in release_version)
            and release_version == version, "artifact.version must exactly match the listing version")
    require(type(value.get("apiVersion")) is int and value["apiVersion"] == 1,
            "artifact.apiVersion must be 1")
    normalized = dict(value)
    normalized.pop("url", None)
    normalized["downloadURL"] = url
    normalized["sha256"] = value["sha256"].lower()
    return normalized


def validate_item(item: object, filename: str) -> dict:
    require(isinstance(item, dict), "source TOML root must be a dictionary")
    require(type(item.get("schemaVersion")) is int and item["schemaVersion"] == 1,
            "schemaVersion must be 1")
    identifier = item.get("id")
    require(isinstance(identifier, str) and len(identifier.encode("utf-8")) <= 128
            and ID_PATTERN.fullmatch(identifier) is not None, "id must be a lowercase reverse-domain manifest ID")
    require(filename == f"{identifier}.toml", "filename must exactly match <manifest-id>.toml")
    slug = item.get("slug")
    require(isinstance(slug, str) and len(slug.encode("utf-8")) <= 128
            and SLUG_PATTERN.fullmatch(slug) is not None, "slug must use lowercase letters, digits, and single hyphens")
    for key, limit in [("name", 128), ("tagline", 512), ("description", 16_384), ("version", 64)]:
        require(text(item.get(key), limit), f"{key} is missing, empty, too long, or contains control characters")
    developer = item.get("developer")
    require(isinstance(developer, dict) and text(developer.get("name"), 128)
            and https(developer.get("url")), "developer requires a name and public HTTPS URL")
    for key, maximum, limit in [("categories", 16, 64), ("requirements", 32, 1_024)]:
        values = item.get(key)
        require(isinstance(values, list) and len(values) <= maximum
                and all(text(value, limit) for value in values), f"{key} must be a bounded array of text")
    price = item.get("price")
    require(isinstance(price, dict), "price must be a dictionary")
    amount = price.get("amount")
    require(type(amount) in {int, float} and 0 <= amount <= 1_000_000 and math.isfinite(amount),
            "price.amount must be a finite nonnegative amount")
    require(isinstance(price.get("currency"), str) and re.fullmatch(r"[A-Z]{3}", price["currency"]) is not None,
            "price.currency must be three uppercase letters")
    require(isinstance(price.get("billing"), str) and price["billing"] in {"free", "one-time", "monthly", "yearly"}
            and ((amount == 0) == (price["billing"] == "free")), "free billing must have zero price, and paid billing a positive price")
    require(isinstance(item.get("status"), str) and item["status"] in {"coming-soon", "preview", "available"}, "unknown listing status")
    if "statusNote" in item:
        require(text(item["statusNote"], 4_096), "invalid statusNote")
    for key in ["websiteUrl", "sourceUrl", "supportUrl", "purchaseUrl", "downloadUrl"]:
        if key in item:
            require(https(item[key]), f"{key} must be a public HTTPS URL")
    for key in ["icon", "artwork"]:
        if key in item:
            require(asset(item[key]), f"{key} must be an HTTPS asset or valid legacy website asset path")
    validate_json_value(item)
    normalized = dict(item)
    normalized.pop("schemaVersion")
    if "artifact" in item:
        normalized["artifact"] = validate_artifact(item["artifact"], item["version"])
    require(item["status"] != "available" or "artifact" in normalized,
            "available listings require reviewed artifact metadata; keep unreleased products coming-soon/preview")
    return normalized


def validate_json_value(value: object, location: str = "record", depth: int = 0) -> None:
    """Preserve extra metadata only when it has a bounded JSON representation.

    TOML dates/times are real Python objects, and TOML accepts inf/nan. Neither
    belongs in the public transport format, even inside an otherwise unused key.
    """
    require(depth <= MAX_METADATA_DEPTH, f"{location}: metadata exceeds 16 nesting levels")
    if type(value) in {str, bool}:
        return
    if type(value) is int:
        require(-(2**63) <= value <= 2**63 - 1,
                f"{location}: integer must fit TOML's signed 64-bit interoperability range")
        return
    if type(value) is float:
        require(math.isfinite(value), f"{location}: nonfinite values are not supported")
        return
    if isinstance(value, list):
        for index, element in enumerate(value):
            validate_json_value(element, f"{location}[{index}]", depth + 1)
        return
    if isinstance(value, dict):
        for key, element in value.items():
            require(isinstance(key, str), f"{location}: metadata keys must be text")
            validate_json_value(element, f"{location}.{key}", depth + 1)
        return
    raise CatalogError(f"{location}: unsupported TOML value {type(value).__name__}; use JSON-compatible metadata")


def validate_legacy_item(item: object, filename: str) -> dict:
    """Recognize the existing pack format without granting native approval."""
    require(isinstance(item, dict) and "schemaVersion" not in item,
            "legacy packs cannot declare a native schemaVersion")
    require(not ({"slug", "status", "developer", "artifact", "price"} & item.keys()),
            "native records require schemaVersion = 1; mixed legacy/native records are not allowed")
    for key in ["id", "name", "version", "publisher", "repository"]:
        require(text(item.get(key), 4_096), f"unrecognized record: legacy pack requires {key}")
    identifier = item["id"]
    require(len(identifier) <= 128 and re.fullmatch(r"[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+", identifier) is not None,
            "legacy pack id must be a reverse-domain identifier")
    require(filename == f"{identifier}.toml", "legacy filename must exactly match <pack-id>.toml")
    require(https(item["repository"]), "legacy repository must be a public HTTPS URL")
    release = item.get("release")
    require(isinstance(release, dict) and https(release.get("url"))
            and urlsplit(release["url"]).path.lower().endswith(".zip"),
            "legacy pack requires [release] with an HTTPS ZIP url")
    require(isinstance(release.get("sha256"), str)
            and re.fullmatch(r"[A-Fa-f0-9]{64}", release["sha256"]) is not None,
            "legacy release.sha256 must be a 64-character hexadecimal digest")
    extensions = item.get("extensions")
    require(isinstance(extensions, list) and 0 < len(extensions) <= 64,
            "legacy pack requires a nonempty bounded [[extensions]] array")
    for index, extension in enumerate(extensions):
        require(isinstance(extension, dict) and text(extension.get("bundleID"), 256),
                f"legacy [[extensions]] #{index + 1} requires bundleID")
        scenes = extension.get("scenes")
        require(isinstance(scenes, list) and 0 < len(scenes) <= 64
                and all(text(scene, 128) for scene in scenes),
                f"legacy [[extensions]] #{index + 1} requires a nonempty scenes array")
    if "update" in item:
        require(isinstance(item["update"], dict) and text(item["update"].get("strategy"), 64),
                "legacy update requires a strategy")
    validate_json_value(item)
    return item


def read_record(path: Path) -> dict:
    require(not path.is_symlink() and path.is_file(), "source must be a regular file, not a link")
    with path.open("rb") as source:
        data = source.read(MAX_SOURCE_BYTES + 1)
    require(len(data) <= MAX_SOURCE_BYTES, "source TOML exceeds 64 KiB")
    try:
        # tomllib implements full TOML 1.0, including nested tables, multiline
        # strings, quoted keys, and arrays. It rejects duplicate keys/tables.
        return tomllib.loads(data.decode("utf-8"))
    except (ValueError, RecursionError) as error:
        raise CatalogError(f"invalid source TOML: {error}") from error


def record_kind(item: dict, filename: str) -> str:
    # The presence of this key always enters native validation. In particular,
    # unknown versions, wrong types, and omitted required keys must fail closed.
    if "schemaVersion" in item:
        validate_item(item, filename)
        return "native"
    validate_legacy_item(item, filename)
    return "legacy"


def read_source(path: Path) -> dict:
    """Read one native source; legacy callers must explicitly use read_records."""
    return validate_item(read_record(path), path.name)


def read_records(directory: Path) -> list[tuple[str, Path, dict]]:
    require(not directory.is_symlink() and directory.is_dir(),
            "extensions source directory must exist and must not be a link")
    entries = sorted(directory.rglob("*"))
    require(not any(path.is_symlink() for path in entries), "source must be a regular file, not a link")
    files = [path for path in entries if path.suffix == ".toml"]
    require(len(files) <= MAX_ITEMS, "catalog exceeds 500 extension records")
    records = []
    for path in files:
        try:
            require(path.parent == directory, "place source records directly in extensions/")
            item = read_record(path)
            kind = record_kind(item, path.name)
            records.append((kind, path, item))
        except CatalogError as error:
            raise CatalogError(f"{path.name}: {error}") from error
    return records


def generate(directory: Path) -> bytes:
    records = read_records(directory)
    items = [validate_item(item, path.name) for kind, path, item in records if kind == "native"]
    require(len({item["id"] for item in items}) == len(items), "duplicate extension id")
    require(len({item["slug"] for item in items}) == len(items), "duplicate extension slug")
    items.sort(key=lambda item: item["id"])
    try:
        aggregate = (json.dumps({"schemaVersion": 1, "extensions": items},
                                ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    except (ValueError, TypeError, OverflowError, RecursionError) as error:
        raise CatalogError(f"metadata cannot be represented in the JSON catalog: {error}") from error
    require(len(aggregate) <= MAX_CATALOG_BYTES, "aggregate catalog exceeds 2 MB")
    return aggregate


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "extensions")
    parser.add_argument("--output", type=Path, default=ROOT / "catalog.json")
    parser.add_argument("--check", action="store_true", help="Validate that the existing aggregate is current without changing files.")
    args = parser.parse_args()
    try:
        data = generate(args.source)
        if args.check:
            require(args.output.is_file() and args.output.read_bytes() == data,
                    "generated aggregate is stale; run python3 scripts/catalog.py")
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(data)
        count = len(json.loads(data)["extensions"])
        print(f"Validated {count} native extension records; deterministic catalog is {len(data)} bytes. Legacy packs remain separate.")
        return 0
    except (CatalogError, OSError) as error:
        print(f"Catalog validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
