#!/bin/bash
# rite workflow - review⇄fix ループが「収束中」かの判定 (max_review_cycles の延長可否)
#
# Responsibility: safety.max_review_cycles に達した cycle で、上限停止を見送ってよい収束中の
# run かを決定論的に判定する。切るべきは発散・空転であって収束に向かう実サイクルではない。
#
# Called from:
#   - scripts/iterate-step.sh (cycle-gate) — 発火理由 max-cycles の評価
#   - hooks/scripts/lib/review-stagnation.py (existing_breaker) — 完了 review の停止判定
#
# Usage:
#   bash review-converging.sh --pr N --trend c1,c2,...,cn [--fix-state PATH]
#
# 判定 (定数。config キーにしない):
#   yes  ⇔ 直近 3 値が狭義単調減少 (c[n-2] > c[n-1] > c[n]) かつ
#          fix-cycle-state の「計測済み」最新 cycle (findings_total を持つ entry) の
#          findings_new_from_fix が 0。fix が cycle を追加した直後の初期値 0 は未計測なので読まない
#   no   それ以外 (計測済み entry が無い = fix_state_unmeasured を含む)。判定できない入力 (列不足 / state 不在 / 値が非整数) も no に倒す —
#        no は従来どおり上限で止まる側であり、silent にはせず reason= に理由を載せる。
#   狭義単調減少は非負整数列では有限回で終わるため、延長に別の上限は要らない。
#
# 出力 (stdout, 1 行): [CONTEXT] REVIEW_CONVERGING=yes|no; reason=<...>
# Exit codes: 0 判定完了 / 2 呼び出しエラー

set -u

pr_number=""
trend=""
fix_state=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr|--trend|--fix-state)
      [ $# -ge 2 ] || { echo "ERROR: $1 には値が必要です" >&2; exit 2; }
      case "$1" in --pr) pr_number="$2" ;; --trend) trend="$2" ;; *) fix_state="$2" ;; esac
      shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$pr_number" in ''|*[!0-9]*) echo "ERROR: --pr は数値で必須です" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq が見つかりません" >&2; exit 2; }

verdict() { echo "[CONTEXT] REVIEW_CONVERGING=$1; reason=$2"; exit 0; }

IFS=, read -r -a series <<< "$trend"
n=${#series[@]}
[ "$n" -ge 3 ] || verdict no need_3_cycles
for v in "${series[@]}"; do
  case "$v" in ''|*[!0-9]*) echo "WARNING: trend が不正です ('$trend')。収束中とは判定せず上限で止めます" >&2; verdict no trend_malformed ;; esac
done
a=${series[n-3]}; b=${series[n-2]}; c=${series[n-1]}
{ [ "$a" -gt "$b" ] && [ "$b" -gt "$c" ]; } || verdict no not_descending

if [ -z "$fix_state" ]; then
  root=$(bash "$(dirname "${BASH_SOURCE[0]}")/../state-path-resolve.sh") || root=""
  [ -n "$root" ] || { echo "WARNING: state root を解決できませんでした。収束中とは判定せず上限で止めます" >&2; verdict no state_root_unresolved; }
  fix_state="$root/.rite/fix-cycle-state/${pr_number}.json"
fi
[ -f "$fix_state" ] || { echo "WARNING: fix-cycle-state がありません ($fix_state)。収束中とは判定せず上限で止めます" >&2; verdict no fix_state_missing; }
# fix は cycle 追加時に findings_new_from_fix=0 を置き、実測値は次の review の attribution が
# findings_total とともに書く。初期値の 0 を計測値と取り違えないよう findings_total を持つ entry だけ読む。
measured=$(jq -r '[.cycles[]? | select(has("findings_total"))] | length' "$fix_state" 2>/dev/null)
case "$measured" in ''|*[!0-9]*) echo "WARNING: fix-cycle-state を読めません ($fix_state)。収束中とは判定せず上限で止めます" >&2; verdict no fix_state_unreadable ;; esac
[ "$measured" -ge 1 ] || { echo "WARNING: fix-cycle-state に計測済みの cycle がありません ($fix_state)。収束中とは判定せず上限で止めます" >&2; verdict no fix_state_unmeasured; }
new_from_fix=$(jq -r '[.cycles[] | select(has("findings_total"))][-1].findings_new_from_fix | select(type == "number" and . >= 0 and floor == .)' "$fix_state" 2>/dev/null)
case "$new_from_fix" in ''|*[!0-9]*) echo "WARNING: findings_new_from_fix を読み出せません ($fix_state)。収束中とは判定せず上限で止めます" >&2; verdict no fix_state_unreadable ;; esac
[ "$new_from_fix" -eq 0 ] || verdict no fix_introduced_findings
verdict yes descending_without_fix_regressions
