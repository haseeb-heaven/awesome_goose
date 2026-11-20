#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-v1.0.0}"
UNAME_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
UNAME_ARCH="$(uname -m)"
if [[ "$UNAME_OS" == "darwin" ]]; then UNAME_OS="macos"; fi
if [[ "$UNAME_ARCH" == "x86_64" ]]; then UNAME_ARCH="x64"; fi
PLATFORM="${UNAME_OS}-${UNAME_ARCH}"

OUT_DIR="$ROOT/release_assets"
STAGE_DIR="$OUT_DIR/heaven_goose-${VERSION}-${PLATFORM}"
rm -rf "$OUT_DIR"
mkdir -p "$STAGE_DIR"

APPS=(calculator pomodoro devbox sysbench term_snake neon_breakout voxel_runner)

for app in "${APPS[@]}"; do
  if [[ ! -x "$ROOT/builds/$app" ]]; then
    echo "ERROR: builds/$app not found; run scripts/build_all.sh first" >&2
    exit 1
  fi
  cp "$ROOT/builds/$app" "$OUT_DIR/${app}-${PLATFORM}"
  cp "$ROOT/builds/$app" "$STAGE_DIR/${app}"
done

cp "$ROOT/LICENSE" "$ROOT/README.md" "$STAGE_DIR/"
tar -czf "$OUT_DIR/heaven_goose-${VERSION}-${PLATFORM}.tar.gz" -C "$OUT_DIR" "heaven_goose-${VERSION}-${PLATFORM}"
rm -rf "$STAGE_DIR"

(
  cd "$OUT_DIR"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 * > SHA256SUMS.txt
  else
    sha256sum * > SHA256SUMS.txt
  fi
)

echo "Packaged release assets in $OUT_DIR:"
ls -lh "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS.txt"
