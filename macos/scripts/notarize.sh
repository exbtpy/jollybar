#!/usr/bin/env bash
# Notarize an app (via a temporary zip, then staple the app) or a DMG.
# Skips when no notarization secrets are set. Fails when the set is partial,
# or when notarization secrets exist without a Developer ID certificate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/signing-keychain.sh"

NOTARY_KEY_FILE=""
cleanup_notary() {
    [[ -n "${NOTARY_KEY_FILE:-}" ]] && rm -f "$NOTARY_KEY_FILE"
    signing_cleanup
}
trap cleanup_notary EXIT

usage() {
    echo "Usage: notarize.sh app <App.app> | notarize.sh dmg <App.dmg>" >&2
    exit 1
}

[[ $# -eq 2 ]] || usage
KIND="$1"
TARGET="$2"
[[ -e "$TARGET" ]] || { echo "Error: not found: $TARGET" >&2; exit 1; }

count_set() {
    local n=0
    local value
    for value in "$@"; do
        [[ -n "$value" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
}

APPLE_N="$(count_set "${APPLE_ID:-}" "${APPLE_TEAM_ID:-}" "${APPLE_APP_SPECIFIC_PASSWORD:-}")"
API_N="$(count_set "${APP_STORE_CONNECT_API_KEY_ID:-}" "${APP_STORE_CONNECT_API_ISSUER_ID:-}" "${APP_STORE_CONNECT_API_KEY:-}")"

if [[ "$APPLE_N" != "0" && "$APPLE_N" != "3" ]]; then
    echo "Error: set APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD together, or leave all three empty." >&2
    exit 1
fi
if [[ "$API_N" != "0" && "$API_N" != "3" ]]; then
    echo "Error: set APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID, and APP_STORE_CONNECT_API_KEY together, or leave all three empty." >&2
    exit 1
fi
if [[ "$APPLE_N" == "0" && "$API_N" == "0" ]]; then
    echo "==> No notarization secrets. Skipping notarization."
    exit 0
fi

signing_prepare
if [[ "$SIGN_MODE" != "developer-id" ]]; then
    echo "Error: notarization secrets are set, but the Developer ID certificate secrets are missing." >&2
    exit 1
fi

NOTARY_ARGS=()
if [[ "$API_N" == "3" ]]; then
    NOTARY_KEY_FILE="$(mktemp)"
    chmod 600 "$NOTARY_KEY_FILE"
    printf '%s' "$APP_STORE_CONNECT_API_KEY" > "$NOTARY_KEY_FILE"
    if [[ -n "$(tail -c 1 "$NOTARY_KEY_FILE" | tr -d '\n')" ]]; then
        printf '\n' >> "$NOTARY_KEY_FILE"
    fi
    NOTARY_ARGS=(--key "$NOTARY_KEY_FILE" --key-id "$APP_STORE_CONNECT_API_KEY_ID" --issuer "$APP_STORE_CONNECT_API_ISSUER_ID")
    echo "==> Notarizing with an App Store Connect API key."
else
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
    echo "==> Notarizing with an Apple ID app-specific password."
fi

submit_artifact() {
    local artifact="$1"
    local log id
    log="$(mktemp)"
    echo "==> Submitting $(basename "$artifact") to the notary service..."
    if ! xcrun notarytool submit "$artifact" "${NOTARY_ARGS[@]}" --wait >"$log" 2>&1; then
        echo "Error: notarytool submit failed." >&2
        cat "$log" >&2
        exit 1
    fi
    cat "$log"
    if ! grep -Eq 'status: Accepted' "$log"; then
        echo "Error: notarization did not finish with status Accepted." >&2
        id="$(sed -n 's/^  id: //p' "$log" | head -n 1)"
        if [[ -n "$id" ]]; then
            xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
        fi
        exit 1
    fi
    rm -f "$log"
}

case "$KIND" in
    app)
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/notarize-app.XXXXXX")"
        ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$tmp/notarize.zip"
        submit_artifact "$tmp/notarize.zip"
        rm -rf "$tmp"
        xcrun stapler staple "$TARGET"
        xcrun stapler validate "$TARGET"
        ;;
    dmg)
        sign_disk_image "$TARGET"
        codesign --verify "$TARGET"
        submit_artifact "$TARGET"
        xcrun stapler staple "$TARGET"
        xcrun stapler validate "$TARGET"
        ;;
    *)
        usage
        ;;
esac

echo "==> Stapled $TARGET"
