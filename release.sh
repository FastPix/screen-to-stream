#!/bin/bash
# Build distributable ScreenToStream artifacts into dist/.
#
# Flags:
#   --notarize        submit to Apple and staple the ticket (requires a Developer ID)
#   --skip-notarize   default; produces unnotarized artifacts
#   --identity <name> signing identity (or set SIGN_IDENTITY)
#   --zip-only        skip the .dmg
#
# Notarization credentials (either form):
#   NOTARY_PROFILE=<name>                        # xcrun notarytool store-credentials profile
#   APPLE_ID=..., TEAM_ID=..., APP_PASSWORD=...  # app-specific password
#
# Gatekeeper reality (README → Distributing): only Developer ID + notarization opens cleanly on
# someone else's Mac. Ad-hoc/Development builds are tester-only and need a right-click → Open.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ScreenToStream"
BUNDLE_ID="com.fastpix.screen-to-stream"
VERSION="$(tr -d '[:space:]' < VERSION)"
DIST_DIR="dist"
STAGE_DIR="$DIST_DIR/stage"
APP_DIR="$STAGE_DIR/$APP_NAME.app"

NOTARIZE=0
MAKE_DMG=1
IDENTITY="${SIGN_IDENTITY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize) NOTARIZE=1 ;;
        --skip-notarize) NOTARIZE=0 ;;
        --zip-only) MAKE_DMG=0 ;;
        --identity) IDENTITY="$2"; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"

ASSEMBLE_ARGS=(--config release --output "$STAGE_DIR")
[[ -n "$IDENTITY" ]] && ASSEMBLE_ARGS+=(--identity "$IDENTITY")
scripts/assemble.sh "${ASSEMBLE_ARGS[@]}"

SIGNED_WITH="$(codesign -dv "$APP_DIR" 2>&1 | grep -E "^Signature" | head -1 || echo "Signature=unknown")"
IS_ADHOC=0
echo "$SIGNED_WITH" | grep -q "adhoc" && IS_ADHOC=1

ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

package_zip() {
    rm -f "$ZIP_PATH"
    # ditto preserves code signatures and extended attributes; plain `zip` does not.
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
    echo "==> $ZIP_PATH"
}

echo "==> Packaging zip"
package_zip

if [[ "$NOTARIZE" -eq 1 ]]; then
    if [[ "$IS_ADHOC" -eq 1 ]]; then
        echo "!!  Cannot notarize an ad-hoc signed app — a Developer ID Application certificate" >&2
        echo "    is required. Re-run with --identity \"Developer ID Application: …\"." >&2
        exit 1
    fi

    echo "==> Submitting to Apple notary service (this can take a few minutes)"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
        xcrun notarytool submit "$ZIP_PATH" \
            --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
    else
        echo "!!  No notary credentials. Set NOTARY_PROFILE, or APPLE_ID + TEAM_ID + APP_PASSWORD." >&2
        exit 1
    fi

    echo "==> Stapling the ticket to the app"
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"

    echo "==> Re-packaging zip with the stapled app"
    package_zip
fi

if [[ "$MAKE_DMG" -eq 1 ]]; then
    DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
    echo "==> Packaging dmg"
    DMG_SRC="$DIST_DIR/dmg-src"
    rm -rf "$DMG_SRC"; mkdir -p "$DMG_SRC"
    cp -R "$APP_DIR" "$DMG_SRC/"
    ln -s /Applications "$DMG_SRC/Applications"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_SRC" \
        -ov -format UDZO "$DMG_PATH" >/dev/null
    rm -rf "$DMG_SRC"
    echo "==> $DMG_PATH"
fi

# Honest Gatekeeper assessment — this is what another Mac will do with the artifact.
echo "==> Gatekeeper assessment"
if spctl --assess --type execute --verbose=2 "$APP_DIR" 2>&1 | tee /tmp/spctl.txt | grep -q "accepted"; then
    echo "    PASS — this app will open normally on other Macs."
else
    cat /tmp/spctl.txt | sed 's/^/    /'
    echo "    NOT accepted by Gatekeeper: testers must right-click → Open (or run"
    echo "    'xattr -dr com.apple.quarantine $APP_NAME.app'). Ship a notarized build for"
    echo "    friction-free distribution."
fi

echo "==> Done. Artifacts in $DIST_DIR/"
ls -lh "$DIST_DIR" | tail -n +2 | sed 's/^/    /'
