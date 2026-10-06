#!/usr/bin/env bash
# Source from the other macOS scripts. Do not execute for its own sake.
# macos/identity.env is the build-time source of truth for the app's names.

_identity_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$_identity_root/identity.env"
unset _identity_root

: "${APP_PRODUCT_NAME:?APP_PRODUCT_NAME is missing from macos/identity.env}"
: "${APP_EXECUTABLE_NAME:?APP_EXECUTABLE_NAME is missing from macos/identity.env}"
: "${APP_DISPLAY_NAME:?APP_DISPLAY_NAME is missing from macos/identity.env}"
: "${APP_MENU_TITLE:?APP_MENU_TITLE is missing from macos/identity.env}"
: "${APP_BUNDLE_ID:?APP_BUNDLE_ID is missing from macos/identity.env}"
: "${DMG_NAME:?DMG_NAME is missing from macos/identity.env}"
: "${CONFIG_DIR_NAME:?CONFIG_DIR_NAME is missing from macos/identity.env}"
