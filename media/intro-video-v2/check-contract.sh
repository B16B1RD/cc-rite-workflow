#!/usr/bin/env bash
# シーン契約のガードが実際に発火することを確かめる。
# fixture を置くだけでは、ガードを消しても決定論チェックは green のまま通る（実測: 契約ガードを
# 「既定尺 2000ms で続行」へ変異させても check-determinism.sh は成功した）。Issue #2240 の
# AC-3 / T-03 に対応する唯一の自動検証。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0

# 契約違反シーンを render に渡し、非ゼロ終了と契約違反メッセージの両方を要求する。
# 片方だけでは不十分 — 非ゼロ終了だけなら別の原因（Chrome 不在等）で通ってしまい、
# メッセージだけなら既定尺で続行して mp4 を吐く経路を見逃す。
if out="$(node "$here/render/render.mjs" "$here/render/fixtures/no-scene-decl.html" "$work/out.mp4" 30 2>&1)"; then
  echo "契約 NG: window.SCENE 未宣言のシーンが正常終了しました（既定尺で続行しています）" >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  failures=$((failures + 1))
elif ! printf '%s' "$out" | grep -q '既定尺で続行しません'; then
  echo "契約 NG: 非ゼロ終了しましたが契約違反メッセージが出ていません" >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  failures=$((failures + 1))
elif [ -e "$work/out.mp4" ]; then
  echo "契約 NG: エラー終了したのに出力 mp4 が生成されています: $work/out.mp4" >&2
  failures=$((failures + 1))
else
  echo "契約 OK: window.SCENE 未宣言のシーンはエラー終了しました（AC-3 / T-03）"
fi

if [ "$failures" -ne 0 ]; then
  echo "契約チェック: $failures 件失敗" >&2
  exit 1
fi
