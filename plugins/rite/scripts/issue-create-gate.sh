#!/bin/bash
# rite workflow - issue-create gate
#
# /rite:issue-create の手順（重複検出・Issue 情報の確認・本文のファクトチェック）を通ったことを
# session 単位で記録し、create-issue-with-projects.sh が起票の前に照合する。SKILL.md を読んで
# helper だけを直接呼ぶ経路には記録が無いため、Issue を作らずに止まる。
#
# Usage:
#   bash issue-create-gate.sh record --step <duplicate_check|confirm|fact_check>
#   bash issue-create-gate.sh verify
#   bash issue-create-gate.sh consume
#
# record:  duplicate_check は記録を作り直す（中断した前回の実行の記録を持ち越さない）。
#          confirm / fact_check は duplicate_check の後にだけ記録できる。両者の順序は問わない
#          （単一 Issue は confirm → fact_check、分解は fact_check → confirm）。
# verify:  3 step が揃えば exit 0。欠けていれば欠けた step を stderr に出して exit 1。
# consume: 記録を消す。1 回の記録で起票を繰り返させないため、起票した側が呼ぶ。
#
# 記録先: {state_root}/.rite/state/issue-create-gate-{session_id}（1 行 1 step）。
# session_id は flow-state.sh path、state_root は state-path-resolve.sh で解決する。
# 解決できないときは記録の有無を判断できないため exit 1 で止まる。
# 成功時は何も出力しない。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
REQUIRED_STEPS=(duplicate_check confirm fact_check)

gate_path() {
  local fs_path state_root
  fs_path=$(bash "$PLUGIN_ROOT/hooks/flow-state.sh" path) || {
    echo "ERROR: issue-create gate: session_id を解決できません" >&2
    return 1
  }
  state_root=$(bash "$PLUGIN_ROOT/hooks/state-path-resolve.sh") || {
    echo "ERROR: issue-create gate: state root を解決できません" >&2
    return 1
  }
  printf '%s/.rite/state/issue-create-gate-%s\n' "$state_root" "$(basename "$fs_path" .flow-state)"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  record)
    step=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --step) step="${2:-}"; shift 2 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
      esac
    done
    case " ${REQUIRED_STEPS[*]} " in
      *" $step "*) ;;
      *) echo "ERROR: unknown step: '$step' (expected: ${REQUIRED_STEPS[*]})" >&2; exit 1 ;;
    esac
    gate=$(gate_path)
    mkdir -p "$(dirname "$gate")"
    if [ "$step" = "duplicate_check" ]; then
      printf '%s\n' "$step" > "$gate"
    elif [ ! -f "$gate" ]; then
      echo "ERROR: issue-create gate: 重複検出（ステップ 2）の記録がないため '$step' を記録できません。/rite:issue-create をステップ 2 から実行してください" >&2
      exit 1
    elif ! grep -qx "$step" "$gate"; then
      printf '%s\n' "$step" >> "$gate"
    fi
    ;;
  verify)
    gate=$(gate_path)
    missing=()
    for s in "${REQUIRED_STEPS[@]}"; do
      grep -qx "$s" "$gate" 2>/dev/null || missing+=("$s")
    done
    if [ ${#missing[@]} -gt 0 ]; then
      echo "ERROR: issue-create gate: /rite:issue-create の手順を通った記録がありません（不足: ${missing[*]}）" >&2
      exit 1
    fi
    ;;
  consume)
    gate=$(gate_path)
    rm -f "$gate"
    ;;
  *)
    echo "Usage: issue-create-gate.sh {record --step <step>|verify|consume}" >&2
    exit 1
    ;;
esac
