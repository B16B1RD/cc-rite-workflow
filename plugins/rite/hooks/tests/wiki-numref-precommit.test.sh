#!/bin/bash
# Tests for wiki-numref-precommit.sh (ingest 5.0.n / wiki-worktree-commit gate body).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HELPER="$PLUGIN_ROOT/hooks/scripts/wiki-numref-precommit.sh"
INGEST_MD="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"

if [ ! -f "$HELPER" ]; then
  echo "ERROR: helper not found: $HELPER" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local p
  # read-only にした .git が残っていても消せるよう、書込権限を戻してから削除する
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && { chmod -R u+w "$p" 2>/dev/null; rm -rf "$p"; }; done
}
trap cleanup EXIT

echo "=== wiki-numref-precommit.sh tests ==="

# --- static: helper is the check body; ingest 5.0.n only calls it ---
assert_grep "helper は number-reference-check.sh --diff HEAD --path .rite/wiki を呼ぶ" \
  "$HELPER" 'bash "\$check" --repo-root "\$numref_tree" --diff HEAD --path \.rite/wiki --quiet'
assert_grep "helper は新規ページを intent-to-add してから検査する" \
  "$HELPER" 'git -C "\$numref_tree" add -N -- \.rite/wiki'
assert_grep "helper の intent-to-add 失敗は stage_failed" \
  "$HELPER" 'WIKI_INGEST_NUMREF=error; reason=stage_failed'
assert_grep "helper の ignore 残存 rc 失敗は ignored_check_failed" \
  "$HELPER" 'WIKI_INGEST_NUMREF=error; reason=ignored_check_failed'
assert_grep "helper の委譲先不在は helper_missing" \
  "$HELPER" 'WIKI_INGEST_NUMREF=error; reason=helper_missing'
assert_not_grep "helper の check-ignore は stderr を併合しない" \
  "$HELPER" 'check-ignore -v --stdin 2>&1'
assert_grep "helper の check-ignore は rc を捕捉する" \
  "$HELPER" '\|\| numref_ci_rc=\$\?'
assert_grep "helper hit は exit 1" \
  "$HELPER" 'echo "\[CONTEXT\] WIKI_INGEST_NUMREF=hit"'
assert_grep "ingest 5.0.n は wiki-numref-precommit.sh を呼ぶ" \
  "$INGEST_MD" 'wiki-numref-precommit\.sh'
assert_grep "ingest 5.0.n は hit を tool 失敗に倒さない (rc=1 → exit 0)" \
  "$INGEST_MD" '1\) exit 0 ;;'

run_helper() {
  local tree="$1" out="$2"
  bash "$HELPER" --repo-root "$tree" >"$out" 2>&1
}

# --- execution: same 8 paths as the former ingest 5.0.n block ---
pdir=$(mktemp -d "${TMPDIR:-/tmp}/rite-numref-precommit-XXXXXX")
cleanup_dirs+=("$pdir")
ptree=$(mktemp -d "${TMPDIR:-/tmp}/rite-numref-tree-XXXXXX")
cleanup_dirs+=("$ptree")
(
  cd "$ptree" || exit 1
  git init -q . || exit 1
  git config user.email t@e.st || exit 1
  git config user.name t || exit 1
  mkdir -p .rite/wiki/pages/x || exit 1
  printf '# t\n\n番号なしの本文\n' > .rite/wiki/pages/x/p.md || exit 1
  printf '番号なしのコード側ファイル\n' > outside.md || exit 1
  git add -A || exit 1
  git commit -qm init || exit 1
) > "$pdir/setup.out" 2>&1 || { fail "sandbox セットアップ失敗"; print_summary "wiki-numref-precommit.sh"; exit 1; }

(cd "$ptree" && printf '# t\n\n番号なしの本文\n追記した番号なし行\n' > .rite/wiki/pages/x/p.md)
run_helper "$ptree" "$pdir/clean.out"
assert_grep "番号なしの差分は clean" "$pdir/clean.out" 'WIKI_INGEST_NUMREF=clean'
assert_not_grep "clean は hit を名乗らない" "$pdir/clean.out" 'WIKI_INGEST_NUMREF=hit'

(cd "$ptree" && printf '# t\n\n番号なしの本文\nPR #1300 を参照\n' > .rite/wiki/pages/x/p.md)
run_helper "$ptree" "$pdir/hit.out"
assert_grep "番号を含む差分は hit" "$pdir/hit.out" 'WIKI_INGEST_NUMREF=hit'
assert_not_grep "hit は clean を名乗らない" "$pdir/hit.out" 'WIKI_INGEST_NUMREF=clean'
assert_grep "hit は file:line で名指しする" "$pdir/hit.out" '\.rite/wiki/pages/x/p\.md:[0-9]+:'

(cd "$ptree" && git checkout -q -- .rite/wiki/pages/x/p.md && mkdir -p .rite/wiki/pages/new \
   && printf '# new\n\nPR #1301 を参照\n' > .rite/wiki/pages/new/n.md)
run_helper "$ptree" "$pdir/untracked.out"
assert_grep "未追跡の新規ページに番号があれば hit" "$pdir/untracked.out" 'WIKI_INGEST_NUMREF=hit'
assert_not_grep "untracked hit は clean を名乗らない" "$pdir/untracked.out" 'WIKI_INGEST_NUMREF=clean'
assert_grep "新規ページの hit も file:line" "$pdir/untracked.out" '\.rite/wiki/pages/new/n\.md:[0-9]+:'

(cd "$ptree" && rm -rf .rite/wiki/pages/new && printf '番号なしのコード側ファイル\nPR #1302 を参照\n' > outside.md)
run_helper "$ptree" "$pdir/outside.out"
assert_grep ".rite/wiki 外の番号は hit にしない" "$pdir/outside.out" 'WIKI_INGEST_NUMREF=clean'
(cd "$ptree" && git checkout -q -- outside.md)

p18b_bare=$(mktemp -d "${TMPDIR:-/tmp}/rite-numref-bare-XXXXXX")
cleanup_dirs+=("$p18b_bare")
( cd "$p18b_bare" && git init -q . && mkdir -p .rite/wiki/pages ) > "$pdir/bare.out" 2>&1
run_helper "$p18b_bare" "$pdir/failed.out"
assert_not_grep "HEAD 不在で clean を名乗らない" "$pdir/failed.out" 'WIKI_INGEST_NUMREF=clean'
assert_grep "委譲先の実行失敗は check_failed" "$pdir/failed.out" 'reason=check_failed'

p18b_ign=$(mktemp -d "${TMPDIR:-/tmp}/rite-numref-ign-XXXXXX")
cleanup_dirs+=("$p18b_ign")
(
  cd "$p18b_ign" || exit 1
  git init -q . || exit 1
  git config user.email t@e.st || exit 1
  git config user.name t || exit 1
  printf '.rite/wiki/\n' > .gitignore || exit 1
  git add -A || exit 1
  git commit -qm init || exit 1
  mkdir -p .rite/wiki/pages || exit 1
  printf '# t\n\nPR #1303 を参照\n' > .rite/wiki/pages/p.md || exit 1
) > "$pdir/ign.out" 2>&1
run_helper "$p18b_ign" "$pdir/stage.out"
assert_not_grep "gitignore された Wiki で clean を名乗らない" "$pdir/stage.out" 'WIKI_INGEST_NUMREF=clean'
assert_grep "intent-to-add の失敗は stage_failed" "$pdir/stage.out" 'reason=stage_failed'
assert_grep "stage_failed は intent-to-add の失敗として報告する" \
  "$pdir/stage.out" 'intent-to-add に失敗しました'
assert_grep "stage_failed は root .gitignore への negation 追加を案内する" \
  "$pdir/stage.out" "root .gitignore に '!\.rite/wiki/' と '!\.rite/wiki/\*\*' を追記"
assert_grep "positive control: stage_failed 側には root anchor 案内が出る" \
  "$pdir/stage.out" 'gitignore-wiki-section-end'
(cd "$p18b_ign" && printf '.rite/wiki/\n!.rite/wiki/\n!.rite/wiki/**\n' > .gitignore)
run_helper "$p18b_ign" "$pdir/stage-fixed.out"
assert_not_grep "案内どおり直すと stage_failed が消える" "$pdir/stage-fixed.out" 'reason=stage_failed'
assert_grep "案内どおり直すと番号を検出できる" "$pdir/stage-fixed.out" 'WIKI_INGEST_NUMREF=hit'

p18b_drift=$(mktemp -d "${TMPDIR:-/tmp}/rite-numref-drift-XXXXXX")
cleanup_dirs+=("$p18b_drift")
(
  cd "$p18b_drift" || exit 1
  git init -q . || exit 1
  git config user.email t@e.st || exit 1
  git config user.name t || exit 1
  mkdir -p .rite/wiki/pages || exit 1
  printf '*\n!wiki/\n' > .rite/.gitignore || exit 1
  printf 'seed\n' > seed.md || exit 1
  git add -A || exit 1
  git commit -qm init || exit 1
  printf '# t\n\nPR #1304 を参照\n' > .rite/wiki/pages/p.md || exit 1
  printf '# t\n\nPR #1306 を参照\n' > .rite/wiki/pages/日本語ページ.md || exit 1
  mkdir -p .rite/wiki/other || exit 1
  printf '# t\n\nPR #1307 を参照\n' > .rite/wiki/other/q.md || exit 1
) > "$pdir/drift.out" 2>&1
run_helper "$p18b_drift" "$pdir/ignored.out"
assert_not_grep "配下だけ ignore のドリフトで clean を名乗らない" "$pdir/ignored.out" 'WIKI_INGEST_NUMREF=clean'
assert_grep "ignore 残存は ignored_paths" "$pdir/ignored.out" 'reason=ignored_paths'
assert_grep "ignored_paths は check-ignore で名指しする" "$pdir/ignored.out" '\.gitignore:[0-9]+:'
assert_grep "残存一覧が非 ASCII のページ名を生のまま出す" \
  "$pdir/ignored.out" '^    \.rite/wiki/pages/日本語ページ\.md$'
assert_grep "原因行の path 欄も非 ASCII を生で出す" \
  "$pdir/ignored.out" '\.gitignore:[0-9]+:.*[[:space:]]\.rite/wiki/pages/日本語ページ\.md$'
p18b_ig_shown=$(grep -cE '^    \.rite/wiki/[^:]+$' "$pdir/ignored.out")
p18b_ig_causes=$(grep -cE '^    [^ ]*\.gitignore:[0-9]+:' "$pdir/ignored.out")
assert "表示した残存ファイル全件について原因を名指しする" "$p18b_ig_shown" "$p18b_ig_causes"
assert_not_grep "ignored_paths は stage_failed 用の root anchor 案内へ戻っていない" \
  "$pdir/ignored.out" 'gitignore-wiki-section-end'

p18b_shim="$pdir/shim"
mkdir -p "$p18b_shim"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ "$a" = "check-ignore" ]; then\n'
  printf '    echo "fatal: shimmed check-ignore failure" >&2\n'
  printf '    exit 128\n'
  printf '  fi\n'
  printf 'done\n'
  printf 'exec %s "$@"\n' "$(command -v git)"
} > "$p18b_shim/git"
chmod +x "$p18b_shim/git"
PATH="$p18b_shim:$PATH" bash "$HELPER" --repo-root "$p18b_drift" > "$pdir/shim.out" 2>&1
assert_grep "check-ignore が落ちても ignored_paths で止まる" "$pdir/shim.out" 'reason=ignored_paths'
assert_grep "check-ignore 失敗時は rc を添えて報告する" "$pdir/shim.out" '一致を返しませんでした \(rc=128\)'
assert_grep "check-ignore 失敗時は手動再現コマンドを案内する" "$pdir/shim.out" '手動: git -C .* check-ignore -v'
assert_grep "git の診断自体は surface される" "$pdir/shim.out" 'fatal: shimmed check-ignore failure'
assert_not_grep "git の診断を原因欄へ字下げして載せない" \
  "$pdir/shim.out" '^    fatal: shimmed check-ignore failure'
assert_grep "名指しできた件数が表示件数に満たないことを明示する" \
  "$pdir/shim.out" '注意: 表示 [0-9]+ 件のうち 0 件しか原因を名指しできていません'

# git dir が read-only（sandbox マスク）なら intent-to-add の前に sandbox-mask で止まる
if [ "$(id -u)" = "0" ]; then
  skip "git dir read-only ケース（root は書込権限を無視するため再現できない）"
else
  (cd "$ptree" && mkdir -p .rite/wiki/pages/ro && printf '# ro\n\nPR #1308 を参照\n' > .rite/wiki/pages/ro/r.md)
  chmod a-w "$ptree/.git"
  mask_rc=0
  run_helper "$ptree" "$pdir/mask.out" || mask_rc=$?
  chmod u+w "$ptree/.git"
  assert "git dir read-only は exit 2" "2" "$mask_rc"
  assert_grep "git dir read-only は sandbox-mask" "$pdir/mask.out" 'WIKI_INGEST_NUMREF=error; reason=sandbox-mask'
  assert_grep "sandbox-mask は書き込めない git dir を名指しする" "$pdir/mask.out" '管理ディレクトリ（.*\.git）に書き込めません'
  assert_not_grep "sandbox-mask は stage_failed の .gitignore 案内を出さない" "$pdir/mask.out" 'reason=stage_failed'
  assert "sandbox-mask は intent-to-add しない" ".rite/wiki/pages/ro/r.md" \
    "$(git -C "$ptree" ls-files --others --exclude-standard -- .rite/wiki/pages/ro)"
  rm -rf "$ptree/.rite/wiki/pages/ro"
fi

print_summary "wiki-numref-precommit.sh"
