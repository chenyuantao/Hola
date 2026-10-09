#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP_PATH:-$PWD/build/HolaDev.app}"
if [[ ! -d "$APP" ]]; then
  echo 'Build first: bash build.sh' >&2
  exit 1
fi
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 Sources/Localization.swift Tests/LocalizationTests.swift -o "$TEST_DIR/localization-tests"
"$TEST_DIR/localization-tests" "$PWD" "$APP"
