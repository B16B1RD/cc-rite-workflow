#!/usr/bin/env bash
# シーン契約のガードが実際に発火することを確かめる。
# fixture を置くだけでは、ガードを消しても決定論チェックは green のまま通る（実測: 契約ガードを
# 「既定尺 2000ms で続行」へ変異させても check-determinism.sh は成功した）。Issue #2240 の
# AC-3 / T-03 に対応する自動検証で、各 fail-loud ガードに 1 ケースずつ対応させる。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0

# 契約違反シーンを render に渡し、3 点を要求する:
#   (1) 非ゼロ終了      — 既定値で続行していないこと
#   (2) 期待メッセージ  — 別の原因（環境不足等）で落ちたのではないこと
#   (3) 成果物が無い    — エラー終了なのに mp4 が残っていないこと
# (1) だけでは Chrome 不在でも通り、(2) だけでは既定尺で続行して mp4 を吐く経路を見逃す。
# (1) を満たすが (2) を満たさない場合は「契約が壊れた」ではなく「契約を検証できなかった」——
# sandbox 内では Chrome の Unix socket 制約で必ずここに落ちるため、見出しを分けないと
# 初回実行者が誤った原因を読む。
expect_contract_failure() {
  local label="$1" fixture="$2" expected="$3"
  local out mp4="$work/$label.mp4"

  if out="$(node "$here/render/render.mjs" "$here/render/fixtures/$fixture" "$mp4" 30 2>&1)"; then
    echo "契約 NG [$label]: $fixture が正常終了しました（ガードが発火していません）" >&2
    printf '%s\n' "$out" | tail -3 | sed 's/^/  /' >&2
    return 1
  fi
  if ! printf '%s' "$out" | grep -q -- "$expected"; then
    echo "契約チェック不能 [$label]: 非ゼロ終了しましたが期待メッセージ「$expected」が出ていません" >&2
    echo "  環境不足（sandbox 内では Chrome が起動できません）か、render.mjs 側の文言変更を疑ってください" >&2
    printf '%s\n' "$out" | tail -3 | sed 's/^/  /' >&2
    return 1
  fi
  if [ -e "$mp4" ]; then
    echo "契約 NG [$label]: エラー終了したのに出力 mp4 が残っています: $mp4" >&2
    return 1
  fi
  echo "契約 OK [$label]: $fixture"
}

# ガードごとに 1 ケース。render.mjs にガードを足したらここにも 1 行足すこと
# （fixture を置くだけでは pin にならない、が本スクリプトの存在理由）。
expect_contract_failure scene-missing   no-scene-decl.html    '既定尺で続行しません'        || failures=$((failures + 1))
expect_contract_failure duration-invalid invalid-duration.html '正の数値ではありません'      || failures=$((failures + 1))
expect_contract_failure zero-frames     zero-frames.html      'フレームが 0 枚になります'   || failures=$((failures + 1))
expect_contract_failure page-error      page-error.html       'シーン内で未捕捉の例外'      || failures=$((failures + 1))

if [ "$failures" -ne 0 ]; then
  echo "契約チェック: $failures 件失敗" >&2
  exit 1
fi
