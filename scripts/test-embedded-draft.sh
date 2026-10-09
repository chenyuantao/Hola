#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 Sources/Localization.swift Sources/EmbeddedDraft.swift Tests/EmbeddedDraftTests.swift -o "$test_dir/embedded-draft-tests"
"$test_dir/embedded-draft-tests"
