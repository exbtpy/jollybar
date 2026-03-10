#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ClaudeUsageBar"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ZIP_PATH="$PROJECT_DIR/$APP_NAME.zip"
DMG_PATH="$PROJECT_DIR/$APP_NAME.dmg"
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

build_app_bundle() {
    echo "==> Building release binary..."
    swift build -c release

    local binary="$BUILD_DIR/release/$APP_NAME"
    if [[ ! -f "$binary" ]]; then
        echo "Error: binary not found at $binary"
        exit 1
    fi

    echo "==> Creating $APP_NAME.app bundle..."
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"

    cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    cp "$binary" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

    local app_version="${APP_VERSION:-$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")}"
    local app_build="${APP_BUILD:-$(version_to_build_number "$app_version")}"

    "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $app_version" "$APP_BUNDLE/Contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleVersion $app_build" "$APP_BUNDLE/Contents/Info.plist"

    if [[ -n "${SU_FEED_URL:-}" ]]; then
        "$PLUTIL" -replace SUFeedURL -string "$SU_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
    else
        "$PLUTIL" -remove SUFeedURL "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    fi

    local resource_bundle="$BUILD_DIR/release/${APP_NAME}_${APP_NAME}.bundle"
    if [[ ! -d "$resource_bundle" ]]; then
        resource_bundle="$(find "$BUILD_DIR" -path "*/release/${APP_NAME}_${APP_NAME}.bundle" -type d | head -n 1 || true)"
    fi

    if [[ -z "$resource_bundle" || ! -d "$resource_bundle" ]]; then
        echo "Error: SwiftPM resource bundle not found for $APP_NAME"
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

    local sparkle_framework
    sparkle_framework="$(find "$BUILD_DIR" -path '*/Sparkle.framework' -type d | head -n 1 || true)"
    if [[ -n "$sparkle_framework" ]]; then
        echo "==> Bundling Sparkle.framework..."
        mkdir -p "$APP_BUNDLE/Contents/Frameworks"
        ditto "$sparkle_framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi

    echo "==> Codesigning (ad-hoc)..."
    if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
        while IFS= read -r nested_bundle; do
            codesign --force --sign - "$nested_bundle"
        done < <(find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" \
            \( -name '*.app' -o -name '*.xpc' \) -type d | sort)
        codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi
    codesign --force --sign - "$APP_BUNDLE"

    echo "==> Built $APP_BUNDLE"
    codesign -v "$APP_BUNDLE"
    echo "==> Codesign verified OK"
}

create_zip() {
    echo "==> Creating $ZIP_PATH..."
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    echo "==> Done: $ZIP_PATH"
}

create_dmg() {
    local staging_dir
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-bar-dmg.XXXXXX")"

    echo "==> Creating $DMG_PATH..."
    rm -f "$DMG_PATH"

    ditto "$APP_BUNDLE" "$staging_dir/$APP_NAME.app"
    ln -s /Applications "$staging_dir/Applications"
    cat > "$staging_dir/Drag $APP_NAME to Applications.txt" <<EOF
Drag $APP_NAME.app into the Applications folder alias to install.
Launch the app from /Applications after copying it over.
EOF

    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$staging_dir" \
        -format UDZO \
        -ov \
        "$DMG_PATH" > /dev/null

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
