#!/bin/bash
set -euo pipefail
: "${CERTIFICATE_BASE64:?Missing MACOS_CERTIFICATE_BASE64}"
: "${CERTIFICATE_PASSWORD:?Missing MACOS_CERTIFICATE_PASSWORD}"
: "${CERTIFICATE_SHA1:?Missing MACOS_CERTIFICATE_SHA1}"
: "${RUNNER_TEMP:?Missing RUNNER_TEMP}"
[[ "$CERTIFICATE_SHA1" =~ ^[A-Fa-f0-9]{40}$ ]]
umask 077
keychain="$RUNNER_TEMP/hola-release.keychain-db"
certificate="$RUNNER_TEMP/hola-release.p12"
public_cert="$RUNNER_TEMP/hola-release.pem"
trap 'rm -f "$certificate" "$public_cert"' EXIT
log() { printf '[signing +%ss] %s\n' "$SECONDS" "$1"; }
keychain_password=$(openssl rand -hex 32)
echo "::add-mask::$keychain_password"
log 'Creating and unlocking temporary keychain'
printf '%s' "$CERTIFICATE_BASE64" | base64 --decode > "$certificate"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
python3 - "$keychain" <<'PY'
import shlex
import subprocess
import sys
existing = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *dict.fromkeys([*existing, sys.argv[1]])], check=True)
PY
log 'Importing certificate and private key'
security import "$certificate" -k "$keychain" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
log 'Configuring non-interactive private-key access'
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
log 'Checking certificate fingerprint'
security find-certificate -a -p "$keychain" > "$public_cert"
actual=$(openssl x509 -in "$public_cert" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
[[ "$actual" == "$CERTIFICATE_SHA1" ]]
# Signing by fingerprint does not require trusting this self-signed certificate.
# add-trusted-cert may wait for GUI authorization on headless macOS runners.
# Do not use find-identity -v: it filters out untrusted self-signed identities.
# build.sh verifies the resulting app signature after exercising the private key.
log 'Certificate ready; system trust settings unchanged'
