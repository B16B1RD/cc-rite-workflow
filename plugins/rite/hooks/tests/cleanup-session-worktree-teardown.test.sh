#!/usr/bin/env bash
# cleanup-session-worktree-teardown.sh の単体テスト（T-01 worktree 削除 / T-02 対象外 cwd で no-op / T-06 dry-run）。
#
# 対応 AC:
#   AC-1 worktree teardown helper が単独で動作する（削除 + main checkout パスの marker）
#   AC-2 対象外の cwd で何もせず exit 0
#   AC-6 --dry-run が削除しない
#
# marker は行まるごと固定する。呼び出し側（cleanup/SKILL.md ステップ 12）は marker 名 +
# フィールドで判定するため、フィールドが 1 つ落ちても helper 単体では動いて見える。
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPER="$SCRIPT_DIR/../scripts/cleanup-session-worktree-teardown.sh"
PLUGIN_HOOKS="$SCRIPT_DIR/.."
pass=0 fail=0
TMP_ROOT=$(mktemp -d)
# 物理パスへ正規化する。macOS の $TMPDIR は /var/folders/... の symlink で、git は
# rev-parse --show-toplevel / worktree list のいずれでも実体側 (/private/var/folders/...) を
# 返すため、mktemp の値をそのまま assert すると helper の出力と一致しない。
TMP_ROOT=$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
ok(){ pass=$((pass+1)); echo "  ✅ $1"; }
bad(){ fail=$((fail+1)); echo "  ❌ $1"; }
assert_contains(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 (出力: $2)";; esac; }
assert_not_contains(){ case "$2" in *"$3"*) bad "$1 (出力: $2)";; *) ok "$1";; esac; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected='$3' actual='$2')"; fi; }

# multi_session 有効なリポジトリ + セッション worktree を作る。
# worktree パスは helper が物理判定に使う `<worktree_base leaf>/issue-{N}` の形にする。
make_repo(){
  d=$(mktemp -d "$TMP_ROOT/repo.XXXXXX")
  # run-tests.sh は suite 実行時に CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID を unset し、
  # 各 sandbox の session-id ファイルへフォールバックさせる。これを置かないと flow-state の
  # set と get が別の session_id を解決しうる（単体では env 由来で一致するため suite でだけ落ちる）。
  # 書き込み先は canonical な `.rite/session-id`（legacy の `.rite-session-id` は relocated-state
  # -migrate.sh の移送元）。fixture の .gitignore が `.rite/` を無視するので追跡もされない。
  mkdir -p "$d/.rite"
  echo "550e8400-e29b-41d4-a716-446655440000" > "$d/.rite/session-id"
  git -C "$d" init -q -b develop
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  printf 'base\n' > "$d/README.md"
  printf '.rite/\n' > "$d/.gitignore"
  printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > "$d/rite-config.yml"
  git -C "$d" add . && git -C "$d" commit -qm base
  git -C "$d" branch feat/test
  git -C "$d" worktree add -q "$d/.rite/worktrees/issue-1" feat/test
  printf '%s\n' "$d"
}

echo "=== cleanup-session-worktree-teardown: detect ==="

# AC-1 前半: worktree 内から呼ぶと main checkout の絶対パスが marker で得られる。
# flow-state に記録が無くても物理 cwd から導出する（in_worktree_unrecorded）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
main_root=$(git -C "$r" rev-parse --show-toplevel)
out=$(cd "$wt" && bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
assert_contains "detect: worktree 内は in_worktree_unrecorded に分類する" "$out" \
  "[CONTEXT] CLEANUP_WT=in_worktree_unrecorded; worktree=$wt; main_root=$main_root"
assert_contains "detect: 退出不能な入場は委譲 marker を出す" "$out" \
  "[CONTEXT] CLEANUP_DELEGATED=1; reason=exit_worktree_unavailable"

# AC-2: 対象外の cwd（main checkout）では worktree を触らず none を返して exit 0。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out=$(cd "$r" && bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null); rc=$?
assert_eq "detect: 対象外 cwd でも exit 0" "$rc" "0"
assert_contains "detect: 対象外 cwd は none" "$out" "[CONTEXT] CLEANUP_WT=none;"
assert_not_contains "detect: none では委譲 marker を出さない" "$out" "CLEANUP_DELEGATED"
[ -d "$wt" ] && ok "detect: worktree を削除しない（read-only）" || bad "detect が worktree を削除した"

# multi_session 無効な config では分類自体が none（4-W 全体 no-op）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
printf 'multi_session:\n  enabled: false\n' > "$r/rite-config.yml"
out=$(cd "$wt" && bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
assert_contains "detect: multi_session 無効は none" "$out" "[CONTEXT] CLEANUP_WT=none;"

# flow-state が worktree を記録している状態 = in_worktree arm（/rite:batch-run 経由の主経路）。
# この arm だけが dirty フィールドと --- dirty files begin/end --- ブロックを組み立て、
# SKILL.md 4-W 手順 1 の AskUserQuestion（dirty なら stash か中止）を駆動する。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
main_root=$(git -C "$r" rev-parse --show-toplevel)
# flow-state は state-path-resolve.sh（git toplevel、linked worktree は main checkout へ unify）
# が決める場所に書かれる。set を temp repo の中で実行しないと、このセッションの実 state を
# 書き換えたうえ suite 実行順に依存する non-hermetic なテストになる。
( cd "$r" && bash "$PLUGIN_HOOKS/flow-state.sh" set \
  --phase branch --issue 1 --branch feat/test --pr 0 --worktree "$wt" --next "test" ) >/dev/null 2>&1
out=$(cd "$wt" && bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
assert_contains "detect: flow-state 記録ありは in_worktree（主経路）" "$out" \
  "[CONTEXT] CLEANUP_WT=in_worktree; worktree=$wt; dirty=no; main_root=$main_root"
assert_not_contains "detect: clean な in_worktree は dirty ブロックを出さない" "$out" "--- dirty files begin ---"

# 未追跡ファイルがあれば dirty=yes になり、生パス一覧がデリミタ内に出る
# （AskUserQuestion の説明文はこの一覧を引用する契約）。
printf 'x\n' > "$wt/untracked-probe.txt"
out=$(cd "$wt" && bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
assert_contains "detect: 未追跡ファイルで dirty=yes" "$out" \
  "[CONTEXT] CLEANUP_WT=in_worktree; worktree=$wt; dirty=yes; main_root=$main_root"
assert_contains "detect: dirty 一覧をデリミタで囲んで出す" "$out" "--- dirty files begin ---"
assert_contains "detect: dirty 一覧に当該パスが載る" "$out" "?? untracked-probe.txt"
assert_contains "detect: dirty 一覧の終端デリミタ" "$out" "--- dirty files end ---"

# `--issue` の空値・省略は usage error にしない（関連 Issue 未識別は cleanup の正規経路）。
# 落とすと marker が 1 本も出ず、消費側が marker 不在を「削除成功」と読む。
# marker の **値** まで固定する。prefix だけの pin は「空 issue では physical derivation が
# 働かず none に落ちる」という実挙動を隠し、docstring の過大な主張を素通しする。
# 対照として、同じ fixture で issue 番号を渡せば in_worktree_unrecorded に分類される。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out=$(cd "$wt" && bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
assert_contains "detect: 対照 — issue 番号ありは physical derivation が効く" "$out" \
  "[CONTEXT] CLEANUP_WT=in_worktree_unrecorded; worktree=$wt"
out=$(cd "$wt" && bash "$HELPER" detect --issue --config "$r/rite-config.yml" 2>/dev/null); rc=$?
assert_eq "detect: --issue の値欠落でも exit 0" "$rc" "0"
assert_contains "detect: --issue 値欠落でも CLEANUP_WT marker を必ず出す（値は none）" "$out" \
  "[CONTEXT] CLEANUP_WT=none;"
out=$(cd "$wt" && bash "$HELPER" detect --config "$r/rite-config.yml" 2>/dev/null); rc=$?
assert_eq "detect: --issue 省略でも exit 0" "$rc" "0"
assert_contains "detect: --issue 省略でも CLEANUP_WT marker を必ず出す（値は none）" "$out" \
  "[CONTEXT] CLEANUP_WT=none;"
# 明示的な空文字列トークン。値として消費しないと次の周回で "unknown option" の usage error に
# 落ち、marker なしで exit 2 する（トークンの形を変えた同じ欠陥）。
out=$(cd "$wt" && bash "$HELPER" detect --issue "" --config "$r/rite-config.yml" 2>/dev/null); rc=$?
assert_eq "detect: --issue \"\" (明示的な空文字列) でも exit 0" "$rc" "0"
assert_contains "detect: --issue \"\" でも CLEANUP_WT marker を必ず出す（値は none）" "$out" \
  "[CONTEXT] CLEANUP_WT=none;"
# 引数順を入れ替えた形（末尾が空文字列）でも同じ。
out=$(cd "$wt" && bash "$HELPER" detect --config "$r/rite-config.yml" --issue "" 2>/dev/null); rc=$?
assert_eq "detect: 末尾 --issue \"\" でも exit 0" "$rc" "0"
assert_contains "detect: 末尾 --issue \"\" でも CLEANUP_WT marker を必ず出す（値は none）" "$out" \
  "[CONTEXT] CLEANUP_WT=none;"

# detect は read-only なので --dry-run を受理して no-op（AC-6 の「各 helper」を満たす）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out_plain=$(cd "$wt" && bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
out_dry=$(cd "$wt" && bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" --dry-run 2>/dev/null); rc=$?
assert_eq "detect --dry-run: exit 0" "$rc" "0"
assert_eq "detect --dry-run: 出力が通常実行と同一（no-op）" "$out_dry" "$out_plain"

# 内側の分類 helper が起動できないとき、`none` へ落とすと消費側が「行ごと省略」に routing し、
# live で dirty な worktree が報告から完全に消える。`unknown` へ寄せて未確認扱いにすること。
# stub plugin root から呼び、cleanup-worktree-detect.sh だけを欠いて再現する。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
( cd "$r" && bash "$PLUGIN_HOOKS/flow-state.sh" set \
  --phase branch --issue 1 --branch feat/test --pr 0 --worktree "$wt" --next "test" ) >/dev/null 2>&1
stub=$(mktemp -d "$TMP_ROOT/stub.XXXXXX")
mkdir -p "$stub/hooks/scripts/lib"
cp "$HELPER" "$stub/hooks/scripts/"
cp "$PLUGIN_HOOKS/flow-state.sh" "$stub/hooks/"
cp "$PLUGIN_HOOKS/_resolve-session-id.sh" "$stub/hooks/" 2>/dev/null || true
cp "$PLUGIN_HOOKS/_resolve-session-id-from-file.sh" "$stub/hooks/" 2>/dev/null || true
cp "$PLUGIN_HOOKS/state-path-resolve.sh" "$stub/hooks/"
cp "$PLUGIN_HOOKS/scripts/lib/git-status-filtered.sh" "$stub/hooks/scripts/lib/"
# cleanup-worktree-detect.sh は意図的に置かない → 内側 rc=127
out=$(cd "$wt" && bash "$stub/hooks/scripts/cleanup-session-worktree-teardown.sh" \
  detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null); rc=$?
assert_eq "detect: 内側 helper 不在でも exit 0（非ブロッキング）" "$rc" "0"
# rc は prefix ではなく値で pin する。prefix 一致だと `if ! var=$(cmd); then rc=$?` のように
# 実 rc を取り落とす実装（常に rc=0）を素通しし、原因候補 127 / 126 / 2 の切り分けが壊れても
# 赤くならない。sibling の cleanup-pr-state-purge.test.sh が rc=127 を値で pin しているのと同形。
# 分類値は契約で決まる。Issue の Decision Log D-07 が「分類 helper を起動できなかったときは
# `none` ではなく `unknown`」を §3.3 / AC-8 の振る舞い不変の例外として定めており、`none` は
# 消費側が唯一「行ごと省略」に routing する値なので、そこへ落とすと live で dirty な worktree が
# 完了報告から消える。以下 2 本はその契約の非回帰 pin。
assert_contains "detect: 分類失敗時の分類値は契約どおり unknown になる（D-07）" "$out" \
  "[CONTEXT] CLEANUP_WT=unknown; reason=detect_classify_failed; rc=127"
assert_not_contains "detect: 分類失敗を none へ落とさない（D-07 が禁じる silent fallback）" "$out" "[CONTEXT] CLEANUP_WT=none"

echo "=== cleanup-session-worktree-teardown: remove ==="

# AC-1 後半: worktree を削除する。cwd は main checkout に置く（自己削除を避ける実運用と同じ）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out=$(cd "$r" && bash "$HELPER" remove --worktree "$wt" --pr-merged true --self-root "$$" 2>&1); rc=$?
assert_eq "remove: exit 0" "$rc" "0"
[ -d "$wt" ] && bad "remove: worktree が残っている" || ok "remove: worktree を削除する"
# 削除成功時は marker を出さない契約（ステップ 12 は marker family 不在を削除成功と読む）。
assert_not_contains "remove: 成功時は WORKTREE_REMOVE_* marker を出さない" "$out" "WORKTREE_REMOVE_"

# AC-6: --dry-run は削除せず対象を stdout に報告する。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out=$(cd "$r" && bash "$HELPER" remove --worktree "$wt" --pr-merged true --self-root "$$" --dry-run 2>/dev/null); rc=$?
assert_eq "remove --dry-run: exit 0" "$rc" "0"
[ -d "$wt" ] && ok "remove --dry-run: worktree を削除しない" || bad "remove --dry-run が worktree を削除した"
assert_eq "remove --dry-run: 対象を stdout の marker で報告する" "$out" \
  "[CONTEXT] DRY_RUN_WORKTREE_REMOVE=1; path=$wt; action=remove_worktree"
# dry-run marker は消費側 (SKILL.md ステップ 12 の {session_worktree_check}) が scope する
# glob `WORKTREE_REMOVE_*` の外に居ること。family 内だと「marker 不在 = 削除成功」の判定を
# dry-run の 1 行が壊す。
assert_not_contains "remove --dry-run: 本番 marker family に入らない" "$out" "WORKTREE_REMOVE_"

# 既に消えている worktree への再実行は非ブロッキングで続行するが、**成功ではない** —
# helper は WORKTREE_REMOVE_FAILED を出し、ステップ 12 はそれを「削除に失敗」として報告する。
# 名乗る性質・検証内容・実挙動を一致させる（rc だけを見ると 3 者がずれる）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
git -C "$r" worktree remove "$wt" >/dev/null 2>&1
out=$(cd "$r" && bash "$HELPER" remove --worktree "$wt" --pr-merged true --self-root "$$" 2>&1); rc=$?
assert_eq "remove: 既に不在でも exit 0（非ブロッキング）" "$rc" "0"
assert_contains "remove: 既に不在の再実行は失敗 marker を出す" "$out" \
  "[CONTEXT] WORKTREE_REMOVE_FAILED=1; path=$wt"
if grep -qxF "session_worktree	$wt" "$r/.rite/tmp-artifacts.tsv" 2>/dev/null; then
  ok "remove: 既に不在の再実行は reap manifest へ記録する（--pr-merged true）"
else
  bad "remove: reap manifest に session_worktree エントリが無い"
fi

echo "=== cleanup-session-worktree-teardown: usage ==="

# --pr-merged / --self-root は呼び出し側の判断でしか決まらない。既定値を置くと
# 「未マージ作業を強制削除する」「self-exclusion が効かない」経路ができるため必須。
out=$(bash "$HELPER" remove --worktree /nonexistent --self-root "$$" 2>&1); rc=$?
assert_eq "remove: --pr-merged 欠落は usage error" "$rc" "2"
out=$(bash "$HELPER" remove --worktree /nonexistent --pr-merged true 2>&1); rc=$?
assert_eq "remove: --self-root 欠落は usage error" "$rc" "2"
out=$(bash "$HELPER" bogus 2>&1); rc=$?
assert_eq "未知の subcommand は usage error" "$rc" "2"

echo "PASS: $pass"
echo "FAIL: $fail"
[ "$fail" -eq 0 ]
