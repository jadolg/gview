#!/usr/bin/env bash
# Build gview for release, sign it with a local self-signed identity and wrap
# it in a DMG.
#
# Usage:   ./package.sh [OPTIONS]
#
# Options:
#   -i, --install   Also copy the app to /Applications (quits a running gview)
#   -h, --help      Show this help
#
# Environment:
#   GVIEW_SIGN_IDENTITY  Code signing identity name (default: "gview Local Signing").
#                        Created as a self-signed certificate in the login
#                        keychain on first run; macOS asks for your password
#                        once to trust it for code signing.
#
# A stable identity keeps the keychain "Always Allow" grant valid across
# updates. It does NOT satisfy Gatekeeper on other Macs: recipients must
# allow the app once via System Settings > Privacy & Security > Open Anyway.
#
# Output: build/gview-<version>.dmg
#
# Examples:
#   ./package.sh
#   ./package.sh --install
#
# Exit codes:
#   0  success
#   1  usage error
#   2  missing dependency or signing failure

set -euo pipefail

INSTALL=false
IDENTITY="${GVIEW_SIGN_IDENTITY:-gview Local Signing}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/macos/Build/Products/Release/gview.app"

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '1d'
    exit "${1:-0}"
}

die() { echo "error: $1" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--install) INSTALL=true ;;
        -h|--help) usage 0 ;;
        *) die "unknown option: $1" 1 ;;
    esac
    shift
done

command -v mise >/dev/null || die "mise not found" 2

have_identity() {
    security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""
}

create_identity() {
    echo "==> Creating self-signed code signing identity \"$IDENTITY\""
    local tmp pass
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    pass="$(uuidgen)"
    # /usr/bin/openssl is LibreSSL; its default PKCS#12 ciphers are the ones
    # `security import` understands (OpenSSL 3 output needs -legacy).
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$IDENTITY" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$IDENTITY" -passout "pass:$pass" -out "$tmp/id.p12"
    security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db \
        -P "$pass" -T /usr/bin/codesign >/dev/null
    security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$tmp/cert.pem"
    have_identity || die "identity \"$IDENTITY\" still not valid for code signing" 2
}

have_identity || create_identity

echo "==> Building release"
(cd "$ROOT" && mise exec -- flutter build macos --release)

echo "==> Signing with \"$IDENTITY\""
# No hardened runtime: its library validation needs an Apple Team ID, which a
# self-signed identity lacks, so FlutterMacOS.framework would fail to load.
codesign --force --deep --timestamp=none -s "$IDENTITY" "$APP"
codesign --force --timestamp=none \
    --entitlements "$ROOT/macos/Runner/Release.entitlements" \
    -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

version="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
dmg="$ROOT/build/gview-$version.dmg"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/gview.app"
ln -s /Applications "$stage/Applications"

echo "==> Creating $dmg"
hdiutil create -volname gview -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
codesign --force -s "$IDENTITY" --timestamp=none "$dmg"

if [[ "$INSTALL" == true ]]; then
    echo "==> Installing to /Applications"
    osascript -e 'tell application "gview" to quit' >/dev/null 2>&1 || true
    while pgrep -xq gview; do sleep 0.5; done
    rm -rf /Applications/gview.app
    ditto "$APP" /Applications/gview.app
fi

echo "Done: $dmg"
