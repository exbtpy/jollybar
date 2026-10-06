#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/load-identity.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/signing-keychain.sh"

BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/$APP_PRODUCT_NAME.app"
ZIP_PATH="$PROJECT_DIR/$APP_PRODUCT_NAME.zip"
DMG_PATH="$PROJECT_DIR/$DMG_NAME.dmg"
CREATE_DMG_VERSION="v1.2.3"
CREATE_DMG_TARBALL_URL="https://github.com/create-dmg/create-dmg/archive/refs/tags/${CREATE_DMG_VERSION}.tar.gz"
# Update this hash whenever CREATE_DMG_VERSION is changed
CREATE_DMG_SHA256="8cf7b4ae540801171f4f630f1f2956913aaa87483b7ac03458f52b6cd0c48953"
# Scratch dir for the create-dmg download. Script-scoped, not local: a RETURN
# trap fires after a function's locals are popped, so the path would already be
# empty by the time it ran.
CREATE_DMG_TMP_DIR=""
# Keep in sync with AppUpdater.upstreamSparklePublicKey and publicKeyPlaceholder.
UPSTREAM_SPARKLE_PUBLIC_KEY="kz41beMlVBUNq3/1hFCroklkNk5aGZGJlLcFxaukDPQ="
SPARKLE_PUBLIC_KEY_PLACEHOLDER="REPLACE_WITH_SPARKLE_PUBLIC_KEY"

cleanup_create_dmg_tmp() {
    [[ -n "${CREATE_DMG_TMP_DIR:-}" ]] && rm -rf "$CREATE_DMG_TMP_DIR"
    return 0
}
cleanup_all() {
    cleanup_create_dmg_tmp
    signing_cleanup
}
trap cleanup_all EXIT

DMG_RESOURCES_DIR="$PROJECT_DIR/Resources/dmg"
DMG_BACKGROUND_SOURCE="$DMG_RESOURCES_DIR/background.png"
APP_ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.icns"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
PLUTIL="/usr/bin/plutil"
CREATE_ZIP=0
CREATE_DMG=0
SKIP_BUILD=0

cd "$PROJECT_DIR"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zip)
            CREATE_ZIP=1
            ;;
        --dmg)
            CREATE_DMG=1
            ;;
        --skip-build)
            SKIP_BUILD=1
            ;;
        *)
            echo "Error: unknown option '$1'"
            exit 1
            ;;
    esac
    shift
done

version_to_build_number() {
    local version="$1"
    version="${version#v}"

    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        printf '%d' "$((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]}))"
        return
    fi

    if [[ "$version" =~ ^[0-9]+$ ]]; then
        printf '%s' "$version"
        return
    fi

    printf '%s' "$version"
}

first_existing() {
    local candidate
    for candidate in "$@"; do
        if [[ -e "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

build_release_binary() {
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
    if [[ "${UNIVERSAL:-0}" == "1" ]]; then
        echo "==> Building universal release binary (arm64 + x86_64)..."
        if ! swift build -c release --arch arm64 --arch x86_64; then
            echo "==> Multi-arch swift build failed. Building each architecture separately."
            swift build -c release --triple arm64-apple-macosx14.0
            swift build -c release --triple x86_64-apple-macosx14.0
        fi
    else
        echo "==> Building release binary..."
        swift build -c release
    fi
}

locate_binary() {
    local name="$1"
    local found=""
    if found="$(first_existing \
        "$BUILD_DIR/apple/Products/Release/$name" \
        "$BUILD_DIR/release/$name")"; then
        printf '%s' "$found"
        return 0
    fi
    found="$(find "$BUILD_DIR" -type f -name "$name" \
        ! -path '*.dSYM/*' \
        ! -path '*/Intermediates/*' \
        ! -path '*/Intermediates.noindex/*' \
        2>/dev/null | head -n 1 || true)"
    if [[ -n "$found" ]]; then
        printf '%s' "$found"
        return 0
    fi
    return 1
}

ensure_universal_binary() {
    local name="$1"
    local binary="$2"
    [[ "${UNIVERSAL:-0}" == "1" ]] || {
        printf '%s' "$binary"
        return 0
    }

    local arches
    arches="$(lipo -archs "$binary" 2>/dev/null || true)"
    if grep -qw arm64 <<<"$arches" && grep -qw x86_64 <<<"$arches"; then
        echo "==> Universal binary: $arches" >&2
        printf '%s' "$binary"
        return 0
    fi

    echo "==> Product is not universal (${arches:-unknown}). Building each architecture and combining." >&2
    swift build -c release --triple arm64-apple-macosx14.0 >&2
    swift build -c release --triple x86_64-apple-macosx14.0 >&2

    local arm intel
    arm="$(find "$BUILD_DIR" -type f -path '*arm64*' -name "$name" ! -path '*.dSYM/*' | head -n 1 || true)"
    intel="$(find "$BUILD_DIR" -type f -path '*x86_64*' -name "$name" ! -path '*.dSYM/*' | head -n 1 || true)"
    if [[ -z "$arm" || -z "$intel" ]]; then
        echo "Error: could not find both architecture builds of $name" >&2
        echo "  arm64: ${arm:-missing}" >&2
        echo "  x86_64: ${intel:-missing}" >&2
        exit 1
    fi
    mkdir -p "$BUILD_DIR/release"
    lipo -create -output "$BUILD_DIR/release/$name" "$arm" "$intel"
    arches="$(lipo -archs "$BUILD_DIR/release/$name")"
    echo "==> Combined binary: $arches" >&2
    printf '%s' "$BUILD_DIR/release/$name"
}

locate_sparkle_framework() {
    local candidate
    while IFS= read -r candidate; do
        case "$candidate" in
            *macos-arm64_x86_64*/Sparkle.framework)
                printf '%s' "$candidate"
                return 0
                ;;
        esac
    done < <(find "$BUILD_DIR" -type d -name 'Sparkle.framework' 2>/dev/null || true)

    candidate="$(find "$BUILD_DIR" -type d -name 'Sparkle.framework' | head -n 1 || true)"
    if [[ -n "$candidate" ]]; then
        printf '%s' "$candidate"
        return 0
    fi
    return 1
}

stamp_identity() {
    "$PLUTIL" -replace CFBundleIdentifier -string "$APP_BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
    "$PLUTIL" -replace CFBundleName -string "$APP_PRODUCT_NAME" "$APP_BUNDLE/Contents/Info.plist"
    "$PLUTIL" -replace CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$APP_BUNDLE/Contents/Info.plist"
    "$PLUTIL" -replace CFBundleExecutable -string "$APP_EXECUTABLE_NAME" "$APP_BUNDLE/Contents/Info.plist"
}

apply_sparkle_metadata() {
    local public_key="${SPARKLE_PUBLIC_KEY:-}"
    if [[ -z "$public_key" ]]; then
        public_key="$("$PLIST_BUDDY" -c 'Print :SUPublicEDKey' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    fi
    public_key="$(printf '%s' "$public_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ "$public_key" == "$UPSTREAM_SPARKLE_PUBLIC_KEY" ]]; then
        echo "Error: refusing the upstream Claude Usage Bar Sparkle public key."
        exit 1
    fi

    if [[ -z "$public_key" || "$public_key" == "$SPARKLE_PUBLIC_KEY_PLACEHOLDER" ]]; then
        "$PLUTIL" -remove SUPublicEDKey "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
        echo "==> Sparkle public key is unset. Auto-update stays off until SUPublicEDKey is filled in."
    else
        "$PLUTIL" -replace SUPublicEDKey -string "$public_key" "$APP_BUNDLE/Contents/Info.plist"
    fi

    if [[ -n "${SU_FEED_URL:-}" ]]; then
        local feed_lower
        feed_lower="$(printf '%s' "$SU_FEED_URL" | tr '[:upper:]' '[:lower:]')"
        case "$feed_lower" in
            *blimp-labs*|*claude-usage-bar*)
                echo "Error: refusing SU_FEED_URL that points at the upstream Claude Usage Bar appcast."
                exit 1
                ;;
        esac
        "$PLUTIL" -replace SUFeedURL -string "$SU_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
    else
        "$PLUTIL" -remove SUFeedURL "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    fi
}

sign_app_bundle() {
    signing_prepare
    local framework="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$framework" ]]; then
        if [[ "$SIGN_MODE" == "developer-id" ]]; then
            echo "==> Codesigning Sparkle and $APP_PRODUCT_NAME (Developer ID)..."
            local item
            while IFS= read -r item; do
                [[ -n "$item" ]] || continue
                sign_path "$item" 1
            done < <(find "$framework/Versions/B" \( -name '*.app' -o -name '*.xpc' -o -name 'Autoupdate' \) -print 2>/dev/null \
                | awk '{ print length($0), $0 }' | sort -nr | cut -d' ' -f2-)
            sign_path "$framework" 1
            sign_path "$APP_BUNDLE" 0
        else
            echo "==> Codesigning (ad-hoc)..."
            while IFS= read -r nested_bundle; do
                codesign --force --sign - "$nested_bundle"
            done < <(find "$framework" \( -name '*.app' -o -name '*.xpc' \) -type d | sort)
            codesign --force --sign - "$framework"
            codesign --force --sign - "$APP_BUNDLE"
        fi
    else
        echo "==> Codesigning ($SIGN_MODE)..."
        sign_path "$APP_BUNDLE" 0
    fi

    codesign -v "$APP_BUNDLE"
    echo "==> Codesign verified OK ($SIGN_MODE)"
}

build_app_bundle() {
    build_release_binary

    local binary
    if ! binary="$(locate_binary "$APP_EXECUTABLE_NAME")"; then
        echo "Error: binary not found for $APP_EXECUTABLE_NAME"
        exit 1
    fi
    binary="$(ensure_universal_binary "$APP_EXECUTABLE_NAME" "$binary")"
    if [[ ! -f "$binary" ]]; then
        echo "Error: binary not found at $binary"
        exit 1
    fi

    echo "==> Creating $APP_PRODUCT_NAME.app bundle..."
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"

    cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    cp "$binary" "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE_NAME"
    chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE_NAME"
    stamp_identity

    local app_version="${APP_VERSION:-$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")}"
    local app_build="${APP_BUILD:-$(version_to_build_number "$app_version")}"

    "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $app_version" "$APP_BUNDLE/Contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleVersion $app_build" "$APP_BUNDLE/Contents/Info.plist"
    apply_sparkle_metadata

    local bundle_name="${APP_PRODUCT_NAME}_${APP_PRODUCT_NAME}.bundle"
    local resource_bundle
    resource_bundle="$(dirname "$binary")/$bundle_name"
    if [[ ! -d "$resource_bundle" ]]; then
        resource_bundle="$(find "$BUILD_DIR" -type d -name "$bundle_name" \
            ! -path '*/Intermediates/*' \
            ! -path '*/Intermediates.noindex/*' \
            | head -n 1 || true)"
    fi
    if [[ -z "$resource_bundle" || ! -d "$resource_bundle" ]]; then
        echo "Error: SwiftPM resource bundle not found for $APP_PRODUCT_NAME"
        exit 1
    fi

    echo "==> Bundling SwiftPM resources..."
    ditto "$resource_bundle" "$APP_BUNDLE/Contents/Resources/$(basename "$resource_bundle")"

    echo "==> Compiling Asset Catalog..."
    actool --compile "$APP_BUNDLE/Contents/Resources" \
           --platform macosx \
           --minimum-deployment-target 14.0 \
           --app-icon AppIcon \
           --output-partial-info-plist /dev/null \
           "$PROJECT_DIR/Resources/Assets.xcassets" > /dev/null

    local sparkle_framework=""
    if sparkle_framework="$(locate_sparkle_framework)"; then
        echo "==> Bundling Sparkle.framework..."
        mkdir -p "$APP_BUNDLE/Contents/Frameworks"
        ditto "$sparkle_framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi

    if [[ "${UNIVERSAL:-0}" == "1" && -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
        local sparkle_bin sparkle_arches
        sparkle_bin="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
        sparkle_arches="$(lipo -archs "$sparkle_bin" 2>/dev/null || true)"
        echo "==> Sparkle architectures: ${sparkle_arches:-unknown}"
        if ! grep -qw arm64 <<<"$sparkle_arches" || ! grep -qw x86_64 <<<"$sparkle_arches"; then
            echo "Error: Sparkle.framework is not a universal binary."
            exit 1
        fi
    fi

    sign_app_bundle
    echo "==> Built $APP_BUNDLE"
}

create_zip() {
    echo "==> Creating $ZIP_PATH..."
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    echo "==> Done: $ZIP_PATH"
}

create_dmg() {
    local staging_dir
    local create_dmg_root
    local create_dmg_tool
    local -a create_dmg_args
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/${CONFIG_DIR_NAME}-dmg.XXXXXX")"
    create_dmg_root="$(mktemp -d "${TMPDIR:-/tmp}/create-dmg.XXXXXX")"
    create_dmg_tool="$create_dmg_root/create-dmg"

    echo "==> Creating $DMG_PATH..."
    rm -f "$DMG_PATH"

    ditto "$APP_BUNDLE" "$staging_dir/$APP_PRODUCT_NAME.app"
    # mktemp only substitutes trailing X's, so a template like
    # "name.XXXXXX.tar.gz" creates that filename literally — it then survives a
    # failed download and every later build dies on "File exists".
    local tarball
    CREATE_DMG_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/create-dmg.XXXXXX")"
    tarball="$CREATE_DMG_TMP_DIR/create-dmg.tar.gz"
    curl -fsSL "$CREATE_DMG_TARBALL_URL" -o "$tarball"

    local actual_sha256
    actual_sha256="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$CREATE_DMG_SHA256" ]]; then
        echo "Error: create-dmg tarball SHA256 mismatch!"
        echo "  expected: $CREATE_DMG_SHA256"
        echo "  actual:   $actual_sha256"
        echo "  Note: this URL is a GitHub auto-generated source tarball, which is"
        echo "  not byte-stable — GitHub has changed its gzip settings before. A"
        echo "  mismatch may mean recompression rather than tampering. Verify the"
        echo "  contents before updating CREATE_DMG_SHA256."
        exit 1
    fi

    if ! tar -xzf "$tarball" -C "$create_dmg_root" --strip-components=1; then
        echo "Error: failed to extract create-dmg tarball"
        exit 1
    fi
    chmod +x "$create_dmg_tool"

    # Finder lays out the window. Waking it avoids a cold-start failure on CI.
    osascript -e 'tell application "Finder" to get name of startup disk' >/dev/null 2>&1 || true

    create_dmg_args=(
        "$create_dmg_tool"
        --volname "$APP_DISPLAY_NAME"
        --window-pos 160 140
        --window-size 680 420
        --text-size 12
        --icon-size 96
        --icon "$APP_PRODUCT_NAME.app" 110 225
        --hide-extension "$APP_PRODUCT_NAME.app"
        --app-drop-link 385 225
        --format UDZO
        --hdiutil-quiet
    )
    if [[ -f "$APP_ICON_SOURCE" ]]; then
        create_dmg_args+=(--volicon "$APP_ICON_SOURCE")
    fi
    # Drop a 680×420 PNG at Resources/dmg/background.png to fill the window.
    # With the file absent, the image still has the app and an Applications symlink.
    if [[ -f "$DMG_BACKGROUND_SOURCE" ]]; then
        create_dmg_args+=(--background "$DMG_BACKGROUND_SOURCE")
    else
        echo "==> DMG background slot is empty ($DMG_BACKGROUND_SOURCE)."
    fi

    # create-dmg sometimes exits non-zero after it has already written a usable image.
    set +e
    "${create_dmg_args[@]}" "$DMG_PATH" "$staging_dir"
    create_dmg_status=$?
    set -e
    if [[ "$create_dmg_status" -ne 0 && ! -f "$DMG_PATH" ]]; then
        echo "Error: create-dmg failed with status $create_dmg_status"
        exit "$create_dmg_status"
    fi
    if [[ "$create_dmg_status" -ne 0 ]]; then
        echo "==> create-dmg exited $create_dmg_status; keeping the disk image it wrote."
    fi

    rm -rf "$create_dmg_root"
    rm -rf "$staging_dir"
    echo "==> Done: $DMG_PATH"
}

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    build_app_bundle
elif [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Error: app bundle not found at $APP_BUNDLE"
    exit 1
fi

if [[ "$CREATE_ZIP" -eq 1 ]]; then
    create_zip
fi

if [[ "$CREATE_DMG" -eq 1 ]]; then
    create_dmg
fi
