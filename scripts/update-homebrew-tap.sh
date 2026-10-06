#!/usr/bin/env bash
# Bump Casks/<config-dir>.rb in the Homebrew tap when HOMEBREW_TAP_TOKEN is set.
# A missing tap repository is reported and skipped. A failed push fails the run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/macos/scripts/load-identity.sh"

TAP_REPO="${HOMEBREW_TAP_REPO:-exbtpy/homebrew-tap}"
CASK_NAME="$CONFIG_DIR_NAME"
TEMPLATE="$ROOT/Casks/${CASK_NAME}.rb"

if [[ $# -ne 2 ]]; then
    echo "Usage: update-homebrew-tap.sh <disk-image> <version>" >&2
    exit 1
fi

DMG="$1"
VERSION="$2"

if [[ -z "${HOMEBREW_TAP_TOKEN:-}" ]]; then
    echo "HOMEBREW_TAP_TOKEN is unset. Skipping the Homebrew tap bump."
    exit 0
fi

if [[ ! "$TAP_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Error: HOMEBREW_TAP_REPO must look like owner/name." >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must be x.y.z (got $VERSION)." >&2
    exit 1
fi
if [[ ! -f "$DMG" ]]; then
    echo "Error: disk image not found at $DMG" >&2
    exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: cask template not found at $TEMPLATE" >&2
    exit 1
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
if [[ ! "$SHA" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Error: unexpected sha256 for $DMG" >&2
    exit 1
fi

if ! git ls-remote "https://github.com/${TAP_REPO}.git" HEAD >/dev/null 2>&1; then
    echo "Homebrew tap ${TAP_REPO} is not reachable."
    echo "Create the repository, copy Casks/${CASK_NAME}.rb into it, and the next release will bump the version and sha256."
    exit 0
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-tap.XXXXXX")"
askpass="$workdir/askpass"
trap 'rm -rf "$workdir"' EXIT

cat > "$askpass" <<'EOF'
#!/bin/sh
case "$1" in
  *[Uu]sername*) printf '%s\n' "x-access-token" ;;
  *) printf '%s\n' "$HOMEBREW_TAP_TOKEN" ;;
esac
EOF
chmod 700 "$askpass"

export GIT_ASKPASS="$askpass"
export GIT_TERMINAL_PROMPT=0

git clone --depth 1 "https://github.com/${TAP_REPO}.git" "$workdir/tap"
cask_path="$workdir/tap/Casks/${CASK_NAME}.rb"
mkdir -p "$workdir/tap/Casks"
if [[ ! -f "$cask_path" ]]; then
    cp "$TEMPLATE" "$cask_path"
fi

python3 - "$cask_path" "$VERSION" "$SHA" <<'PY'
import pathlib, re, sys
path, version, sha = sys.argv[1:]
file = pathlib.Path(path)
text = file.read_text()
updated, version_count = re.subn(r'^(\s*)version\s+"[^"]*"', rf'\1version "{version}"', text, count=1, flags=re.M)
updated, sha_count = re.subn(r'^(\s*)sha256\s+"[^"]*"', rf'\1sha256 "{sha}"', updated, count=1, flags=re.M)
if version_count != 1 or sha_count != 1:
    sys.exit(f"cask is missing a version or sha256 line: {path}")
file.write_text(updated)
PY

git -C "$workdir/tap" config user.name "github-actions[bot]"
git -C "$workdir/tap" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$workdir/tap" add "Casks/${CASK_NAME}.rb"
if git -C "$workdir/tap" diff --cached --quiet; then
    echo "Homebrew cask is already at ${VERSION}."
    exit 0
fi
git -C "$workdir/tap" commit -m "${CASK_NAME} ${VERSION}"
git -C "$workdir/tap" push origin HEAD
echo "Updated ${TAP_REPO} Casks/${CASK_NAME}.rb to ${VERSION}."
