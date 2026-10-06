#!/usr/bin/env bash
# Append install instructions to a Markdown file.
# Ad-hoc and signed-but-unstapled builds include the Gatekeeper steps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/load-identity.sh"

if [[ $# -ne 2 ]]; then
    echo "Usage: append-install-notes.sh <App.app> <notes.md>" >&2
    exit 1
fi

APP_BUNDLE="$1"
NOTES="$2"
[[ -d "$APP_BUNDLE" ]] || { echo "Error: app not found at $APP_BUNDLE" >&2; exit 1; }
[[ -f "$NOTES" ]] || { echo "Error: notes not found at $NOTES" >&2; exit 1; }

signature="$(codesign -dv "$APP_BUNDLE" 2>&1 || true)"
mode="adhoc"
if grep -q "Authority=Developer ID Application" <<<"$signature"; then
    if xcrun stapler validate "$APP_BUNDLE" >/dev/null 2>&1; then
        mode="notarized"
    else
        mode="developer-id"
    fi
fi

mkdir -p dist
printf '%s\n' "$mode" > dist/signing-mode.txt
echo "==> Signing mode: $mode"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'Signing mode: `%s`\n' "$mode" >> "$GITHUB_STEP_SUMMARY"
fi

{
    echo
    echo "## Install"
    echo
    echo "Download the \`.dmg\`, open it, and drag **${APP_DISPLAY_NAME}** onto the Applications folder. The \`.zip\` is the archive Sparkle uses once auto-update is configured."
    echo
    case "$mode" in
        notarized)
            echo "This build is signed with a Developer ID and notarized. Open it from the Applications folder."
            ;;
        developer-id)
            echo "## First launch"
            echo
            echo "This build is signed with a Developer ID. The notarization ticket is not stapled, so Gatekeeper asks for a one-time confirmation."
            echo
            echo "1. Move **${APP_DISPLAY_NAME}** to the Applications folder, then eject the disk image."
            echo "2. Control-click \`/Applications/${APP_PRODUCT_NAME}.app\` and choose Open, then Open."
            echo "3. When that control is absent, open System Settings → Privacy & Security and choose Open Anyway."
            ;;
        *)
            echo "## First launch"
            echo
            echo "This build is ad-hoc signed. Gatekeeper quarantines the download and will refuse the first open until that flag is cleared."
            echo
            echo "1. Move **${APP_DISPLAY_NAME}** to the Applications folder, then eject the disk image."
            echo "2. In Terminal, clear the quarantine flag:"
            echo
            echo "   \`\`\`sh"
            echo "   xattr -dr com.apple.quarantine \"/Applications/${APP_PRODUCT_NAME}.app\""
            echo "   \`\`\`"
            echo
            echo "3. Open the app from the Applications folder."
            echo
            echo "Control-click → Open, or System Settings → Privacy & Security → Open Anyway, is enough on macOS versions that still offer that control for an ad-hoc signature."
            ;;
    esac
} >> "$NOTES"
