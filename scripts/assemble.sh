#!/bin/bash
# Builds both products and assembles a signed ScreenToStream.app bundle.
# Sourced/called by run.sh (dev) and release.sh (distribution) so the two can never drift.
#
# Usage: scripts/assemble.sh [--config debug|release] [--identity <name>] [--output <dir>]
# Env:   SIGN_IDENTITY  same as --identity (Xcode-style convenience)
#
# Signing ladder (ADR-7): explicit identity -> Developer ID -> Apple Development -> ad-hoc.
# Hardened runtime is enabled ONLY for real identities: it is required for notarization but
# breaks entitlement-free ad-hoc builds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="ScreenToStream"
CONFIG="debug"
IDENTITY="${SIGN_IDENTITY:-}"
OUTPUT_DIR=".build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="$2"; shift ;;
        --identity) IDENTITY="$2"; shift ;;
        --output) OUTPUT_DIR="$2"; shift ;;
        *) echo "assemble.sh: unknown flag $1" >&2; exit 1 ;;
    esac
    shift
done

VERSION="$(tr -d '[:space:]' < VERSION)"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG (v$VERSION)"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/App" "$APP_DIR/Contents/MacOS/App"
# The read-only MCP server ships inside the app so any AI agent can be pointed at it.
cp "$BIN_DIR/mcp-server" "$APP_DIR/Contents/MacOS/mcp-server"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# VERSION is the single source of truth; stamp it into the bundle.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_DIR/Contents/Info.plist" >/dev/null

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" >/dev/null
fi

if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if echo "$IDENTITIES" | grep -q "Developer ID Application"; then
        IDENTITY="Developer ID Application"
    elif echo "$IDENTITIES" | grep -q "Apple Development"; then
        IDENTITY="Apple Development"
    fi
fi

if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing with identity: $IDENTITY (hardened runtime)"
    # Sign nested binaries before the bundle, or the outer signature won't validate.
    codesign --force --options runtime --timestamp \
        --entitlements Resources/App.entitlements \
        --sign "$IDENTITY" "$APP_DIR/Contents/MacOS/mcp-server"
    codesign --force --options runtime --timestamp \
        --entitlements Resources/App.entitlements \
        --sign "$IDENTITY" "$APP_DIR"
else
    echo "==> Signing ad-hoc (no signing identity found)"
    echo "    Ad-hoc builds re-prompt for screen/camera/mic permission after every rebuild,"
    echo "    and other Macs will refuse to open the app. See README → Code Signing."
    codesign --force --sign - "$APP_DIR/Contents/MacOS/mcp-server"
    codesign --force --sign - "$APP_DIR"
fi

codesign -dv "$APP_DIR" 2>&1 | grep -E "^(Identifier|Signature|TeamIdentifier)" || true
echo "==> Assembled: $APP_DIR"
