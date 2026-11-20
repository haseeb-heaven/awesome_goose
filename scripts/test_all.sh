#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GOOSE="${GOOSE:-goose}"

SOURCES=(
  "src/gui/calculator/calculator.goose"
  "src/gui/pomodoro/pomodoro.goose"
  "src/cli/devbox/devbox.goose"
  "src/cli/sysbench/sysbench.goose"
  "src/console/term_snake/term_snake.goose"
  "src/games2d/neon_breakout/neon_breakout.goose"
  "src/games3d/voxel_runner/voxel_runner.goose"
)

echo "[1/4] Typechecking all 7 apps with goose check..."
for src in "${SOURCES[@]}"; do
  "$GOOSE" check "$src"
done
echo "All 7 sources typechecked cleanly."

echo ""
echo "[2/4] Running built-in --test suites on all 7 apps..."
for bin in calculator pomodoro devbox sysbench term_snake neon_breakout voxel_runner; do
  "./builds/$bin" --test
done

echo ""
echo "[3/4] Verifying CLI functional outputs..."
UUID4_OUT="$(./builds/devbox --no-color uuid --v4)"
UUID7_OUT="$(./builds/devbox --no-color uuid --v7)"
PASS_OUT="$(./builds/devbox --no-color pass -l 24)"
B64_ENC="$(./builds/devbox b64 encode 'heaven_goose')"
B64_DEC="$(./builds/devbox b64 decode "$B64_ENC")"
if [[ "$B64_DEC" != "heaven_goose" ]]; then
  echo "ERROR: devbox b64 roundtrip mismatch: $B64_DEC" >&2
  exit 1
fi
echo "  devbox ok (uuid4=$UUID4_OUT, uuid7=$UUID7_OUT, b64=$B64_ENC, pass=${#PASS_OUT} chars)"

./builds/sysbench --quick --json > /tmp/heaven_sysbench.json
python3 -c '
import json
d = json.load(open("/tmp/heaven_sysbench.json"))
assert len(d["results"]) == 4, d
print("  sysbench JSON ok:", [r["name"] for r in d["results"]])
'
rm -f /tmp/heaven_sysbench.json

ANSI_BYTES="$(./builds/term_snake --ansi-dump | wc -c | tr -d ' ')"
if [[ "$ANSI_BYTES" -lt 500 ]]; then
  echo "ERROR: term_snake --ansi-dump output unexpectedly small ($ANSI_BYTES bytes)" >&2
  exit 1
fi
echo "  term_snake --ansi-dump ok ($ANSI_BYTES bytes)"

echo ""
echo "[4/4] Smoke-testing headless GPU rendering for GUI/2D/3D apps..."
TMP_SHOT_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_SHOT_DIR"' EXIT
GOOSE_GFX_HEADLESS=1 ./builds/calculator --demo --frames 5 --screenshot "$TMP_SHOT_DIR/calculator.png"
GOOSE_GFX_HEADLESS=1 ./builds/pomodoro --demo --frames 5 --screenshot "$TMP_SHOT_DIR/pomodoro.png"
GOOSE_GFX_HEADLESS=1 ./builds/neon_breakout --demo --frames 25 --screenshot "$TMP_SHOT_DIR/neon_breakout.png"
GOOSE_GFX_HEADLESS=1 ./builds/voxel_runner --demo --frames 65 --screenshot "$TMP_SHOT_DIR/voxel_runner.png"

for shot in calculator.png pomodoro.png neon_breakout.png voxel_runner.png; do
  if [[ ! -s "$TMP_SHOT_DIR/$shot" ]]; then
    echo "ERROR: missing or empty screenshot $shot" >&2
    exit 1
  fi
done
echo "  All 4 headless GPU screenshots rendered successfully."
echo ""
echo "ALL TESTS PASSED!"
