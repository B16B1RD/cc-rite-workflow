#!/bin/bash
# cleanup-wikichain-handoff-parity.test.sh
#
# `skills/cleanup/SKILL.md` (writer) と `hooks/stop-loop-continuation.sh` (consumer) の
# WIKICHAIN チェーン handoff 契約が同期していることを assert する meta-test。
#
# 背景 — implicit stop 累積再発:
#   cleanup → wiki-ingest → wiki-lint --auto の 2 段ネスト skill return 直後に LLM が turn を
#   閉じる事象は declarative wording / sentinel 命名の修正では再発を止められなかった
#   (AC-2/AC-4)。iterate ループの Stop-hook 継続保証と
#   同型の mechanical gate を移植した。本 test はその gate の writer / consumer 両側と
#   チェーン各段の return sentinel 宣言を機械検証する (Wiki
#   pages/patterns/mechanical-test-over-declarative-invariant.md 準拠)。
#
# 検出する drift:
#   (a) cleanup.md ステップ 9 の WIKICHAIN handoff set が削除/破損された (gate の writer 欠落)
#   (b) handoff set が `Skill: rite:wiki-ingest` invoke より後に移動された (gate が遅すぎて無効)
#   (c) stop-loop-continuation.sh の `WIKICHAIN:*` case arm が削除された (consumer 欠落 —
#       未知 prefix WARNING 経路へ縮退し、チェーン専用の継続 directive が失われる)
#   (d) cleanup.md ステップ 12 の terminal set に `--handoff` が付与された (default-clear 喪失
#       = 完走後も handoff が残存し、次の停止で誤 block する)
#   (e) チェーン各段 (lint / ingest / cleanup) の returned-to-caller sentinel 宣言の削除/rename 漏れ
#   (f) ステップ 9 の handoff set とステップ 12 の terminal set の間に `--handoff` なしの
#       executable な flow-state.sh set が追加された (handoff の premature default-clear —
#       gate が silent に外れる。prose の「制約」note のみが guard だった経路の機械化)
#
# 検出しない drift (本 test の scope 外、他 test が担当):
#   - hook の block / one-shot consume / reason 文面の runtime 挙動
#     → stop-loop-continuation.test.sh TC-11/12/13
#   - lint.md ↔ ingest.md の line-count 契約 → wiki-lint-ingest-contract-sync.test.sh
#   - sentinel disambiguator の adjacency → sentinel-disambiguator-adjacency.test.sh
#
# When this test fails:
#   cleanup.md ステップ 9 / 12 と stop-loop-continuation.sh の WIKICHAIN 契約のいずれかが
#   片側だけ変更された可能性が高い。両ファイルの該当セクションを確認し同期させる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CLEANUP_MD="$PLUGIN_ROOT/skills/cleanup/SKILL.md"
HOOK_SH="$PLUGIN_ROOT/hooks/stop-loop-continuation.sh"
LINT_MD="$PLUGIN_ROOT/skills/wiki-lint/SKILL.md"
INGEST_MD="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"

for f in "$CLEANUP_MD" "$HOOK_SH" "$LINT_MD" "$INGEST_MD"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

# ──────────────────────────────────────────────────────────────────────
# TC-1: cleanup.md が WIKICHAIN handoff を set する (writer 存在 + 単一 site)
# ──────────────────────────────────────────────────────────────────────
# placeholder `{pr_number}` を含む literal を assert する (実値 substitute は LLM 実行時)。
wikichain_set_count=$(grep -cF -- '--handoff "WIKICHAIN:cleanup:{pr_number}"' "$CLEANUP_MD" 2>/dev/null || true)

if [ "$wikichain_set_count" = "1" ]; then
  pass "TC-1 cleanup.md に WIKICHAIN handoff set が単一 site で存在"
elif [ "$wikichain_set_count" = "0" ]; then
  fail "TC-1 cleanup.md に '--handoff \"WIKICHAIN:cleanup:{pr_number}\"' が見つかりません (gate の writer 欠落: ステップ 9 の handoff set が削除/破損された可能性)"
else
  fail "TC-1 WIKICHAIN handoff set が複数 site に存在 (count=$wikichain_set_count)。ステップ 9 の単一 SoT を保ってください (複数 set は default-clear lifecycle の追跡を困難にします)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-2: handoff set が `Skill: rite:wiki-ingest` invoke より前に位置する
# ──────────────────────────────────────────────────────────────────────
# gate は ingest invoke 前に set されなければ premature turn close を catch できない。
handoff_line=$(grep -nF -- '--handoff "WIKICHAIN:cleanup:{pr_number}"' "$CLEANUP_MD" | head -1 | cut -d: -f1 || true)
ingest_invoke_line=$(grep -n '^Skill: rite:wiki-ingest$' "$CLEANUP_MD" | head -1 | cut -d: -f1 || true)

if [ -z "$ingest_invoke_line" ]; then
  fail "TC-2 cleanup.md に 'Skill: rite:wiki-ingest' invoke 行が見つかりません (ステップ 9 の構造変更を確認してください)"
elif [ -z "$handoff_line" ]; then
  skip "TC-2 skipped (TC-1 で handoff set 不在を検出済み)"
elif [ "$handoff_line" -lt "$ingest_invoke_line" ]; then
  pass "TC-2 WIKICHAIN handoff set (line $handoff_line) が ingest invoke (line $ingest_invoke_line) より前に位置"
else
  fail "TC-2 WIKICHAIN handoff set (line $handoff_line) が ingest invoke (line $ingest_invoke_line) より後にあります (gate が遅すぎて premature turn close を catch できません)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-3: stop-loop-continuation.sh に WIKICHAIN:* の明示 case arm が存在 (consumer)
# ──────────────────────────────────────────────────────────────────────
# 明示 arm が無い場合、WIKICHAIN handoff は未知 prefix の catch-all へ縮退し block 自体は
# 維持されるが、チェーン専用の継続 directive (ingest 残処理 → cleanup ステップ 10-12) が失われる。
if grep -qE '^[[:space:]]*WIKICHAIN:\*\)' "$HOOK_SH"; then
  pass "TC-3 stop-loop-continuation.sh に WIKICHAIN:* case arm が存在"
else
  fail "TC-3 stop-loop-continuation.sh に 'WIKICHAIN:*)' case arm が見つかりません (consumer 欠落: 未知 prefix WARNING 経路へ縮退し、チェーン継続 directive が失われます)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-4: cleanup.md ステップ 12 の terminal set が --handoff を持たない (default-clear 維持)
# ──────────────────────────────────────────────────────────────────────
# terminal set (--active false) に --handoff が付与されると、チェーン完走後も handoff が
# 残存し one-shot consume が次の無関係な停止を誤 block する。
terminal_set_line=$(grep -n -- '--phase "cleanup" --next "none" --active false' "$CLEANUP_MD" | head -1 || true)

if [ -z "$terminal_set_line" ]; then
  fail "TC-4 cleanup.md ステップ 12 の terminal set (--phase \"cleanup\" --next \"none\" --active false) が見つかりません (default-clear の anchor 行が変更された場合は本 test の grep も同期してください)"
elif printf '%s' "$terminal_set_line" | grep -q -- '--handoff'; then
  fail "TC-4 terminal set に --handoff が付与されています (default-clear 喪失: チェーン完走後も handoff が残存し誤 block します): $terminal_set_line"
else
  pass "TC-4 terminal set は --handoff を持たず default-clear が機能する"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-5: チェーン各段の returned-to-caller sentinel 宣言が存在 (sentinel 到達の機械検証)
# ──────────────────────────────────────────────────────────────────────
# チェーンの 3 段 (最深部 lint → 中間 ingest → 最外 cleanup) がそれぞれ return signal を
# 宣言していることを assert する。いずれかの rename / 削除は caller 側 parse / gate の
# 前提を破る (AC-4)。
declare -A _sentinels=(
  ["$LINT_MD"]="[lint:returned-to-caller:auto]"
  ["$INGEST_MD"]="[ingest:returned-to-caller]"
  ["$CLEANUP_MD"]="[cleanup:returned-to-caller]"
)
for f in "$LINT_MD" "$INGEST_MD" "$CLEANUP_MD"; do
  s="${_sentinels[$f]}"
  if grep -qF -- "$s" "$f"; then
    pass "TC-5 $(basename "$f") が return sentinel $s を宣言"
  else
    fail "TC-5 $(basename "$f") に return sentinel $s が見つかりません (rename / 削除はチェーン caller の parse / gate 前提を破ります)"
  fi
done

# ──────────────────────────────────────────────────────────────────────
# TC-6: ステップ 9〜12 間に --handoff なしの executable intervening set が存在しない
# ──────────────────────────────────────────────────────────────────────
# ステップ 9 直下の「制約」note (prose guard) の機械版。intervening
# `flow-state.sh set` (--handoff なし) が挟まると handoff が premature default-clear され
# gate が silent に外れる。anchor は TC-2 の handoff_line / TC-4 の terminal_set_line を
# 再利用し、新規 anchor 追加による drift コストを避ける (anchor 不在時は skip して
# TC-1/TC-4 の fail と重複させない)。
# 判定対象は executable 行のみ: prose の backtick 言及 (`flow-state.sh set`) は
# `{plugin_root}/hooks/` path prefix を持たないため、path 付き literal で区別する。
terminal_line=""
if [ -n "$terminal_set_line" ]; then
  terminal_line=$(printf '%s' "$terminal_set_line" | cut -d: -f1)
fi

if [ -z "$handoff_line" ] || [ -z "$terminal_line" ]; then
  skip "TC-6 skipped (TC-1/TC-4 で anchor 不在を検出済み)"
elif [ "$handoff_line" -ge "$terminal_line" ]; then
  fail "TC-6 handoff set (line $handoff_line) が terminal set (line $terminal_line) より後にあります (ステップ 9 → 12 の構造順序が崩れています)"
else
  # 行末 \ の継続行を join してから判定する (multi-line set の継続行に --handoff が
  # ある場合、行単位 grep では --handoff なしと誤判定されるため)
  intervening_sets=$(sed -n "$((handoff_line + 1)),$((terminal_line - 1))p" "$CLEANUP_MD" \
    | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
    | grep -F -- '/hooks/flow-state.sh set' \
    | grep -vF -- '--handoff' || true)

  if [ -z "$intervening_sets" ]; then
    pass "TC-6 ステップ 9〜12 間に --handoff なしの intervening flow-state.sh set は存在しない"
  else
    fail "TC-6 ステップ 9〜12 間に --handoff なしの executable flow-state.sh set が存在します (handoff が premature default-clear され gate が silent に外れます)。cleanup.md ステップ 9 の「制約」note によりステップ 10-11 への flow-state.sh set 追加自体が禁止です — 該当 set を削除してください (--handoff 再指定は TC-1 の単一 SoT 制約と矛盾するため不可。intervening set が必要な設計変更は制約 note と TC-1/TC-6 を同時に見直すこと): $intervening_sets"
  fi
fi

if ! print_summary "cleanup-wikichain-handoff-parity.test.sh" "drift hint: cleanup.md ステップ 9 (WIKICHAIN handoff set) / ステップ 12 (terminal set の default-clear) と stop-loop-continuation.sh の WIKICHAIN:* case arm、チェーン 3 段の return sentinel を同期させてください。ステップ 9〜12 間への新規 flow-state.sh set 追加は禁止です — --handoff 再指定は TC-1 の単一 SoT と矛盾するため不可 (cleanup.md ステップ 9 の制約 note)"; then
  exit 1
fi
