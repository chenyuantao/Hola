#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repo_dir/build/HolaDev.app"

# Build before touching the running app, so a compile or signing failure leaves it running.
APP_PATH="$app_path" bash "$repo_dir/build.sh"
swift "$repo_dir/scripts/app-control.swift" quit "$app_path"
open -n "$app_path" --args --show-commands
swift "$repo_dir/scripts/app-control.swift" verify "$app_path"
