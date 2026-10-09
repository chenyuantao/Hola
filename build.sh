#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This build requires macOS and Xcode Command Line Tools.' >&2
  exit 1
fi
SIGN_ID="${SIGN_ID:-Hola Local}"
BUILD_CHANNEL="${BUILD_CHANNEL:-dev}"
case "$BUILD_CHANNEL" in
  dev) APP_NAME="HolaDev"; BUNDLE_ID="local.holadev" ;;
  release) APP_NAME="Hola"; BUNDLE_ID="local.hola" ;;
  *) echo "Unsupported BUILD_CHANNEL: $BUILD_CHANNEL" >&2; exit 1 ;;
esac
APP="${APP_PATH:-$PWD/build/$APP_NAME.app}"

# 复用签名身份有助于系统识别更新；权限是否保留仍由 macOS 决定。
ensure_signing_identity() {
  if security find-identity -v -p codesigning | grep -q "\"${SIGN_ID}\""; then
    return
  fi
  local work keychain
  work="$(mktemp -d)"
  keychain="$HOME/Library/Keychains/login.keychain-db"
  cat > "$work/codesign.cnf" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = codesign_ext

[ dn ]
CN = ${SIGN_ID}

[ codesign_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -config "$work/codesign.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/cert.p12" -passout pass:hola -name "$SIGN_ID" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
  security import "$work/cert.p12" -k "$keychain" -P hola -f pkcs12 -A \
    -T /usr/bin/codesign -T /usr/bin/security
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
  rm -rf "$work"
  echo "Created stable signing identity: ${SIGN_ID}"
  echo "Grant Accessibility for Hola after this build; macOS may request it again after updates."
}

if [[ "$SIGN_ID" == "Hola Local" ]]; then
  ensure_signing_identity
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
read -r -a architectures <<< "${ARCHS:-$(uname -m)}"
work_build="$(mktemp -d)"
trap 'rm -rf "$work_build"' EXIT
binaries=()
for arch in "${architectures[@]}"; do
  case "$arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac
  xcrun --sdk macosx swiftc -swift-version 5 -O -target "$arch-apple-macos12.0" \
    -framework AppKit -framework ApplicationServices -framework Carbon -framework ServiceManagement -framework JavaScriptCore \
    Sources/Localization.swift Sources/Settings.swift Sources/EmbeddedDraft.swift Sources/Commands.swift Sources/main.swift -o "$work_build/$APP_NAME-$arch"
  binaries+=("$work_build/$APP_NAME-$arch")
done
xcrun lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :HolaBuildChannel string $BUILD_CHANNEL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$APP/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns Resources/MenuBarIcon.pdf "$APP/Contents/Resources/"
sign_options=(--force --sign "$SIGN_ID" --identifier "$BUNDLE_ID")
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
  sign_options+=(--keychain "$SIGN_KEYCHAIN")
fi
codesign "${sign_options[@]}" "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
echo "Run: open \"$APP\""
