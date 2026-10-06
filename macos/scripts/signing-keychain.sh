#!/usr/bin/env bash
# Source from build.sh and notarize.sh.
# Imports a Developer ID certificate when both secrets are set.
# With neither secret, signing stays ad-hoc. A partial pair is an error.

SIGN_MODE="${SIGN_MODE:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
SIGNING_TMP="${SIGNING_TMP:-}"
ORIGINAL_KEYCHAINS="${ORIGINAL_KEYCHAINS:-}"

signing_cleanup() {
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
        security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
        SIGNING_KEYCHAIN=""
    fi
    if [[ -n "${ORIGINAL_KEYCHAINS:-}" ]]; then
        # shellcheck disable=SC2086
        security list-keychains -d user -s $ORIGINAL_KEYCHAINS >/dev/null 2>&1 || true
        ORIGINAL_KEYCHAINS=""
    fi
    if [[ -n "${SIGNING_TMP:-}" ]]; then
        rm -rf "$SIGNING_TMP"
        SIGNING_TMP=""
    fi
}

signing_prepare() {
    if [[ -n "${SIGN_MODE:-}" ]]; then
        return 0
    fi

    local have_p12=0
    local have_pw=0
    [[ -n "${APPLE_CERTIFICATE_P12:-}" ]] && have_p12=1
    [[ -n "${APPLE_CERTIFICATE_PASSWORD:-}" ]] && have_pw=1
    if [[ "$have_p12" -ne "$have_pw" ]]; then
        echo "Error: set both APPLE_CERTIFICATE_P12 and APPLE_CERTIFICATE_PASSWORD, or neither." >&2
        return 1
    fi
    if [[ "$have_p12" -eq 0 ]]; then
        SIGN_MODE="adhoc"
        echo "==> No Developer ID certificate. Using an ad-hoc signature."
        return 0
    fi

    SIGNING_TMP="$(mktemp -d "${TMPDIR:-/tmp}/signing.XXXXXX")"
    local p12="$SIGNING_TMP/cert.p12"
    if ! printf '%s' "$APPLE_CERTIFICATE_P12" | tr -d '[:space:]' | base64 -D > "$p12"; then
        echo "Error: APPLE_CERTIFICATE_P12 is not valid base64." >&2
        return 1
    fi
    if [[ ! -s "$p12" ]]; then
        echo "Error: APPLE_CERTIFICATE_P12 decoded to an empty file." >&2
        return 1
    fi

    local kc_pass
    kc_pass="$(openssl rand -base64 32)"
    SIGNING_KEYCHAIN="$SIGNING_TMP/signing.keychain-db"
    security create-keychain -p "$kc_pass" "$SIGNING_KEYCHAIN"
    security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
    security unlock-keychain -p "$kc_pass" "$SIGNING_KEYCHAIN"
    security import "$p12" \
        -k "$SIGNING_KEYCHAIN" \
        -P "$APPLE_CERTIFICATE_PASSWORD" \
        -T /usr/bin/codesign \
        -T /usr/bin/security
    rm -f "$p12"
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s \
        -k "$kc_pass" \
        "$SIGNING_KEYCHAIN" >/dev/null

    ORIGINAL_KEYCHAINS="$(security list-keychains -d user \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' \
        | tr '\n' ' ')"
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$SIGNING_KEYCHAIN" $ORIGINAL_KEYCHAINS

    SIGN_IDENTITY="$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | head -n 1)"
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "Error: the imported certificate has no Developer ID Application identity." >&2
        security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" >&2 || true
        return 1
    fi
    SIGN_MODE="developer-id"
    echo "==> Developer ID identity: $SIGN_IDENTITY"
}

# preserve=1 keeps the entitlements Sparkle already ships on its helpers.
sign_path() {
    local target="$1"
    local preserve="${2:-0}"
    if [[ "$SIGN_MODE" == "developer-id" ]]; then
        local -a args=(--force --sign "$SIGN_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --options runtime --timestamp)
        if [[ "$preserve" == "1" ]]; then
            args+=(--preserve-metadata=identifier,entitlements,flags)
        fi
        codesign "${args[@]}" "$target"
    else
        codesign --force --sign - "$target"
    fi
}

sign_disk_image() {
    local target="$1"
    if [[ "$SIGN_MODE" != "developer-id" ]]; then
        return 0
    fi
    codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --timestamp "$target"
}
