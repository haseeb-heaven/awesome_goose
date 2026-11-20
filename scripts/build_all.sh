#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GOOSE="${GOOSE:-goose}"
mkdir -p builds

APPS=(
  "src/gui/calculator/calculator.goose:calculator"
  "src/gui/pomodoro/pomodoro.goose:pomodoro"
  "src/cli/devbox/devbox.goose:devbox"
  "src/cli/sysbench/sysbench.goose:sysbench"
  "src/console/term_snake/term_snake.goose:term_snake"
  "src/games2d/neon_breakout/neon_breakout.goose:neon_breakout"
  "src/games3d/voxel_runner/voxel_runner.goose:voxel_runner"
)

echo "Building all 7 Goose apps with $GOOSE -O2 ..."
for entry in "${APPS[@]}"; do
  src="${entry%%:*}"
  name="${entry##*:}"
  echo "  -> $name ($src)"
  "$GOOSE" build -O2 "$src" -o "builds/$name"
done

echo ""
echo "Built binaries in builds/:"
ls -lh builds/
