#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 ]]; then
    echo "Usage: bash scripts/test.sh /path/to/debug-extension.bnplugin [--module-cache /path/to/cache]" >&2
    exit 2
fi
bundle_path="$1"
shift
module_cache="${BN_CLAUDE_MODULE_CACHE:-$package_root/dist/.module-cache}"
if [[ $# -eq 2 && "$1" == "--module-cache" ]]; then
    module_cache="$2"
elif [[ $# -ne 0 ]]; then
    echo "Unrecognized test arguments" >&2
    exit 2
fi
if [[ ! -f "$bundle_path/Contents/MacOS/BoringAgent" ]]; then
    echo "A complete debug .bnplugin bundle is required" >&2
    exit 2
fi
bundle_path="$(cd "$bundle_path" && pwd)"
mkdir -p "$module_cache"
module_cache="$(cd "$module_cache" && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/boring-claude-test-build.XXXXXX")"
trap 'rm -r "$test_output"' EXIT
cd "$package_root"

# Build tests separately from the plugin. The ABI harness loads the real binary.
xcrun swiftc -swift-version 5 -parse-as-library -module-name BoringClaudeBridgeTests \
    -module-cache-path "$module_cache" Sources/Shared/*.swift Sources/Bridge/Claude*.swift Sources/Bridge/AgentBridgeInstaller.swift \
    Tests/BridgeTests.swift -framework AppKit -o "$test_output/bridge-tests"
"$test_output/bridge-tests"

# Account transport and scheduling use injected credentials, HTTP, and clocks.
# These tests never query a real Keychain item or Anthropic account.
xcrun swiftc -swift-version 5 -parse-as-library -module-name BoringAgentAccountUsageTests \
    -module-cache-path "$module_cache" Sources/Shared/*.swift Sources/Bridge/ClaudeAccountUsageService.swift \
    Tests/ClaudeAccountUsageTests.swift -o "$test_output/account-usage-tests"
"$test_output/account-usage-tests"

xcrun swiftc -swift-version 5 -parse-as-library -module-name BoringAgentClaudeMessagingTests \
    -module-cache-path "$module_cache" Sources/Shared/*.swift Sources/Bridge/ClaudeChannel.swift \
    Sources/Bridge/ClaudeQuestionBridge.swift Sources/Bridge/ClaudeOriginResolver.swift \
    Tests/ClaudeMessagingTests.swift -framework AppKit -o "$test_output/claude-messaging-tests"
"$test_output/claude-messaging-tests"

xcrun swiftc -swift-version 5 -parse-as-library -module-name BoringAgentCodexTests \
    -module-cache-path "$module_cache" Sources/Shared/*.swift Sources/Bridge/Codex*.swift \
    Tests/CodexBridgeTests.swift -o "$test_output/codex-tests"
"$test_output/codex-tests"

xcrun swiftc -swift-version 5 -parse-as-library -module-name BoringAgentRelayTests \
    -module-cache-path "$module_cache" Sources/Shared/*.swift Tests/AgentRelayStorageTests.swift \
    -o "$test_output/relay-storage-tests"
"$test_output/relay-storage-tests"

# Inject memory-only adapters: this test never starts the real Claude backend,
# reads saved preferences, or touches the user's relay/configuration.
xcrun swiftc -swift-version 5 -parse-as-library -module-name BoringAgentDashboardTests \
    -module-cache-path "$module_cache" Sources/Shared/*.swift \
    Sources/Plugin/AgentDashboardState.swift Sources/Plugin/AgentProviders.swift \
    Sources/Plugin/AgentRelayClient.swift \
    Sources/Plugin/ClaudeState.swift Sources/Plugin/DirectoryMonitor.swift \
    Tests/AgentDashboardTests.swift -framework AppKit -o "$test_output/dashboard-tests"
"$test_output/dashboard-tests"

# Native picker stress checks use offscreen windows without app activation,
# global key events, real providers, or user input. Keep them in release CI.
xcrun swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -module-name BoringAgentSessionPickerTests -module-cache-path "$module_cache" \
    Sources/Plugin/AgentSessionPicker.swift Tests/SessionPickerTests.swift \
    -framework AppKit -framework SwiftUI -o "$test_output/session-picker-tests"
"$test_output/session-picker-tests"

xcrun swiftc -swift-version 5 -parse-as-library -module-name BoringClaudeABITests \
    -module-cache-path "$module_cache" Sources/Shared/*.swift Tests/ABITests.swift \
    -framework AppKit -o "$test_output/abi-tests"
"$test_output/abi-tests" "$bundle_path"
