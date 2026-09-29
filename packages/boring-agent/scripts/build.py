#!/usr/bin/env python3
"""Build an independent plugin and relay. No host build or third-party packages."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*arguments: str) -> None:
    subprocess.run(arguments, cwd=ROOT, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--architecture", choices=["current", "universal", "arm64", "x86_64"], default="current")
    parser.add_argument("--identity", default="-", help="codesign identity; '-' is local ad-hoc signing")
    parser.add_argument("--keychain", help="Optional isolated keychain containing the signing identity")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--module-cache", type=Path, help="Reuse an existing Xcode module cache")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Building native macOS extensions requires macOS and Xcode command-line tools.")
    manifest = json.loads((ROOT / "manifest.json").read_text())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    architectures = ["arm64", "x86_64"] if args.architecture == "universal" else [
        platform.machine() if args.architecture == "current" else args.architecture]
    module_cache = (args.module_cache or output / ".module-cache").resolve()
    module_cache.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix=".claude-build-", dir=output) as temporary:
        stage = Path(temporary)
        bundle = stage / (manifest["id"] + ".bnplugin")
        executable = bundle / "Contents/MacOS/BoringAgent"
        helper = bundle / "Contents/Helpers/boring-claude-bridge"
        resources = bundle / "Contents/Resources"
        for folder in [executable.parent, helper.parent, resources]:
            folder.mkdir(parents=True, exist_ok=True)
        shared = sorted((ROOT / "Sources/Shared").glob("*.swift"))
        plugin = sorted((ROOT / "Sources/Plugin").glob("*.swift"))
        bridge = sorted((ROOT / "Sources/Bridge").glob("*.swift"))
        if not shared or not plugin or not bridge:
            raise SystemExit("Missing extension or bridge sources")
        helper_info = stage / "bridge-info.plist"
        helper_info.write_bytes(plistlib.dumps({
            "CFBundleIdentifier": manifest["id"] + ".bridge",
            "CFBundleName": "Claude Code Relay",
            "CFBundleVersion": manifest["version"],
            "NSAppleEventsUsageDescription": "Select the original terminal tab when you choose to open a Claude session.",
        }))
        entitlement = stage / "bridge-entitlements.plist"
        entitlement.write_bytes(plistlib.dumps({"com.apple.security.automation.apple-events": True}))
        slices = {"plugin": [], "bridge": []}
        for architecture in architectures:
            flags = ["-swift-version", "5", "-strict-concurrency=complete", "-O", "-sdk", sdk,
                     "-target", f"{architecture}-apple-macos14.0", "-module-cache-path", str(module_cache)]
            if args.configuration == "debug":
                flags += ["-D", "DEBUG"]
            plugin_slice = stage / f"plugin-{architecture}"
            helper_slice = stage / f"bridge-{architecture}"
            run("xcrun", "swiftc", *flags, "-emit-library", "-module-name", "BoringAgent",
                *map(str, shared + plugin), "-o", str(plugin_slice))
            run("xcrun", "swiftc", *flags, "-parse-as-library", "-module-name", "BoringClaudeBridge",
                *map(str, shared + bridge), "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", str(helper_info), "-o", str(helper_slice))
            slices["plugin"].append(plugin_slice)
            slices["bridge"].append(helper_slice)
        for name, destination in [("plugin", executable), ("bridge", helper)]:
            if len(slices[name]) == 1:
                shutil.copy2(slices[name][0], destination)
            else:
                run("xcrun", "lipo", "-create", *map(str, slices[name]), "-output", str(destination))
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": manifest["id"], "CFBundleName": manifest["name"],
            "CFBundleExecutable": executable.name, "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": manifest["version"], "CFBundleVersion": "4",
            "LSMinimumSystemVersion": "14.0",
        }))
        shutil.copyfile(ROOT / "manifest.json", resources / "manifest.json")
        for asset in sorted((ROOT / "Resources").glob("*")):
            if asset.is_file() and not asset.is_symlink():
                shutil.copyfile(asset, resources / asset.name)
        for filename in ["README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "VALIDATION.md"]:
            if (ROOT / filename).is_file():
                shutil.copyfile(ROOT / filename, resources / filename)
        signing = ["--force", "--sign", args.identity]
        if args.keychain:
            signing += ["--keychain", args.keychain]
        # Self-signed preview artifacts have no Apple notarization ticket.
        run("codesign", *signing, "--options", "runtime", "--timestamp=none",
            "--entitlements", str(entitlement), str(helper))
        run("codesign", *signing, "--timestamp=none", str(bundle))
        run("codesign", "--verify", "--deep", "--strict", "--all-architectures", str(bundle))
        label = "development" if args.configuration == "debug" else "release-candidate"
        archive_name = f"BoringAgent-{manifest['version']}-{label}.zip"
        archive = stage / archive_name
        run("ditto", "-c", "-k", "--keepParent", str(bundle), str(archive))
        final_bundle = output / bundle.name
        if final_bundle.is_symlink():
            raise SystemExit("Refusing to replace a symlink in build output")
        if final_bundle.exists():
            shutil.rmtree(final_bundle)
        shutil.move(str(bundle), final_bundle)
        shutil.move(str(archive), output / archive_name)
        print(f"Built {manifest['name']} {manifest['version']} ({', '.join(architectures)}): {final_bundle}")
        print(f"ZIP: {output / archive_name}")


if __name__ == "__main__":
    main()
