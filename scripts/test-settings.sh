#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 Sources/Localization.swift Sources/Settings.swift Tests/SettingsTests.swift -o "$TEST_DIR/settings-tests"
"$TEST_DIR/settings-tests"
