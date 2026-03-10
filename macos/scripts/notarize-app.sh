#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_PATH="${1:-}"

if [[ -z "$ARTIFACT_PATH" ]]; then
    echo "Usage: $0 /path/to/ClaudeUsageBar.app|/path/to/ClaudeUsageBar.dmg"
    exit 1
fi

case "$ARTIFACT_PATH" in
    *.app)
        [[ -d "$ARTIFACT_PATH" ]] || { echo "Error: app bundle not found at $ARTIFACT_PATH"; exit 1; }
        ;;
    *.dmg)
        [[ -f "$ARTIFACT_PATH" ]] || { echo "Error: disk image not found at $ARTIFACT_PATH"; exit 1; }
        ;;
    *)
        echo "Error: unsupported notarization target '$ARTIFACT_PATH'"
        exit 1
        ;;
esac

: "${APPLE_ID:?Missing APPLE_ID}"
: "${APPLE_TEAM_ID:?Missing APPLE_TEAM_ID}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Missing APPLE_APP_SPECIFIC_PASSWORD}"

echo "==> Submitting $(basename "$ARTIFACT_PATH") for notarization..."
xcrun notarytool submit \
    "$ARTIFACT_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$ARTIFACT_PATH"
xcrun stapler validate "$ARTIFACT_PATH"

echo "==> Notarization complete"
