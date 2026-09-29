#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
package_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/boring-agent-session-picker.XXXXXX")"
trap 'rm -r "$test_output"' EXIT
cd "$package_root"
xcrun swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -module-name BoringAgentSessionPickerTests -module-cache-path "$test_output/ModuleCache" \
    Sources/Plugin/AgentSessionPicker.swift Tests/SessionPickerTests.swift \
    -framework AppKit -framework SwiftUI -o "$test_output/session-picker-tests"
"$test_output/session-picker-tests"
