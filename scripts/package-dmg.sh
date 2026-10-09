#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'DMG packaging requires macOS.' >&2
  exit 1
fi

app="${1:-$PWD/build/Hola.app}"
output="${2:-$PWD/build/Hola-macOS.dmg}"
if [[ ! -d "$app" ]]; then
  echo "App not found: $app" >&2
  exit 1
fi
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swift scripts/make-dmg-background.swift "$work/background.png"

venv="$PWD/build/.dmg-venv"
if [[ ! -x "$venv/bin/dmgbuild" ]]; then
  python3 -m venv "$venv"
  "$venv/bin/python" -m pip install --disable-pip-version-check 'dmgbuild==1.6.7'
fi

export HOLA_DMG_APP="$app" HOLA_DMG_BACKGROUND="$work/background.png"
"$venv/bin/dmgbuild" -s scripts/dmg-settings.py 'Hola' "$output"
hdiutil verify "$output"
echo "Packaged: $output"
