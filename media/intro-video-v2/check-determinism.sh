#!/usr/bin/env bash
# 同一シーンを 2 回独立にレンダし、mp4 の md5 が一致することを確かめる。
# frame-step 方式を採る理由そのものを検証する退路なので、不一致は必ず非ゼロ終了で知らせる。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scene="${1:-}"
fps="${2:-30}"
if [ -z "$scene" ]; then
  echo "usage: check-determinism.sh <scene.html> [fps]" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

node "$here/render/render.mjs" "$scene" "$work/pass-1.mp4" "$fps"
node "$here/render/render.mjs" "$scene" "$work/pass-2.mp4" "$fps"

sum1="$(md5sum "$work/pass-1.mp4" | cut -d' ' -f1)"
sum2="$(md5sum "$work/pass-2.mp4" | cut -d' ' -f1)"

if [ "$sum1" = "$sum2" ]; then
  echo "決定論 OK: 2 回のレンダで md5 が一致しました ($sum1) — $scene"
  exit 0
fi

echo "決定論 NG: 2 回のレンダで md5 が一致しません — $scene" >&2
echo "  pass-1: $sum1" >&2
echo "  pass-2: $sum2" >&2
exit 1
