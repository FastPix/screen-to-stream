#!/bin/bash
# Build, bundle, sign, and launch ScreenToStream for development. SwiftPM only — no Xcode project.
#
# Flags:
#   --no-launch        assemble only, don't open the app
#   --release          build with -c release
#   --reset-tcc        revoke screen/camera/mic grants (useful after ad-hoc rebuilds)
#   --reset-keychain   delete the stored FastPix credentials
#   --identity <name>  sign with a specific identity (or set SIGN_IDENTITY)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ScreenToStream"
BUNDLE_ID="com.fastpix.screen-to-stream"
KEYCHAIN_SERVICE="com.fastpix.screen-to-stream"
LOG_FILE="$HOME/Library/Logs/$APP_NAME/app.log"

LAUNCH=1
CONFIG="debug"
IDENTITY="${SIGN_IDENTITY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-launch) LAUNCH=0 ;;
        --release) CONFIG="release" ;;
        --identity) IDENTITY="$2"; shift ;;
        --reset-tcc)
            echo "Resetting TCC grants for $BUNDLE_ID"
            tccutil reset ScreenCapture "$BUNDLE_ID" || true
            tccutil reset Camera "$BUNDLE_ID" || true
            tccutil reset Microphone "$BUNDLE_ID" || true
            ;;
        --reset-keychain)
            echo "Deleting Keychain items for $KEYCHAIN_SERVICE"
            security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
            security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

ASSEMBLE_ARGS=(--config "$CONFIG")
[[ -n "$IDENTITY" ]] && ASSEMBLE_ARGS+=(--identity "$IDENTITY")
scripts/assemble.sh "${ASSEMBLE_ARGS[@]}"

APP_DIR=".build/$APP_NAME.app"

if [[ "$LAUNCH" -eq 1 ]]; then
    echo "==> Launching $APP_NAME (Ctrl-C stops the log tail, not the app)"
    open "$APP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    tail -f "$LOG_FILE"
else
    echo "==> Done: $APP_DIR"
fi
