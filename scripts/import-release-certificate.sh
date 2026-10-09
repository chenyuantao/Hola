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
keychain_password=$(openssl rand -hex 32)
echo "::add-mask::$keychain_password"
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
security import "$certificate" -k "$keychain" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security find-certificate -a -p "$keychain" > "$public_cert"
actual=$(openssl x509 -in "$public_cert" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
[[ "$actual" == "$CERTIFICATE_SHA1" ]]
# Trust only on the ephemeral CI runner; users do not install this certificate.
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$public_cert"
security find-identity -v -p codesigning "$keychain" | grep -F "$CERTIFICATE_SHA1" > /dev/null
rm -f "$certificate" "$public_cert"
