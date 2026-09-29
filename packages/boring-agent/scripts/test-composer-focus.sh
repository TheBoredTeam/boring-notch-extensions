#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

# Opt-in GUI integration test: briefly takes keyboard focus, opens disposable
# native windows, then restores the previous app. Run without concurrent UI tests.
package_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/boring-agent-composer-focus.XXXXXX")"
trap 'rm -r "$test_output"' EXIT
cd "$package_root"
xcrun swiftc -swift-version 5 -parse-as-library -module-name BoringAgentComposerFocusTests \
    -module-cache-path "$test_output/ModuleCache" Sources/Plugin/AgentComposerFocus.swift \
    Tests/ComposerFocusTests.swift -framework AppKit -framework SwiftUI -o "$test_output/composer-focus-tests"
"$test_output/composer-focus-tests"
