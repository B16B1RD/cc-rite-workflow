#!/bin/bash
# review-result-state-root.test.sh
#
# Pin the state-path-resolve based default of review-result-save.sh and the
# matching read side (review-source-resolve.sh Priority 2). A regression back
# to the cwd-relative default would silently split the save/read/delete paths
# between a session worktree and the main checkout (multi_session), making
# cleanup a no-op and cross-session fix reads miss the findings.
#
# The scripts resolve state-path-resolve.sh relative to their own location, so
# the sandbox mirrors the plugin layout (hooks/ + scripts/) inside a real git
# repo with a linked worktree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/.."
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  # linked worktree を先に外さないと rm -rf 後の git 参照が残る
  git -C "$TEST_DIR/repo" worktree remove --force "$TEST_DIR/repo/.rite/worktrees/issue-99" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- sandbox: git repo + plugin layout + linked worktree ---
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
mkdir -p "$REPO/hooks" "$REPO/scripts"
cp "$HOOKS_DIR/review-result-save.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/state-path-resolve.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/control-char-neutralize.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/gitignore-ensure.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/../scripts/review-source-resolve.sh" "$REPO/scripts/"
# review-cycle-scope.sh は同じ state-root 契約の 3 番目の参加者 (書込 = review-result-save.sh /
# 読取 = review-source-resolve.sh Priority 2 / 読取 = 本 helper の既定 results dir)。
# tempfile lib を source するためレイアウトごと複製する。
cp "$HOOKS_DIR/../scripts/review-cycle-scope.sh" "$REPO/scripts/"
mkdir -p "$REPO/hooks/scripts/lib"
cp "$HOOKS_DIR/scripts/lib/tempfile.sh" "$REPO/hooks/scripts/lib/"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
git -C "$REPO" worktree add -q "$REPO/.rite/worktrees/issue-99" -b test-branch main

# commit_sha は sandbox repo の HEAD に一致させる (Priority 2 は commit_sha 不一致を
# stale と判定し Priority 3 へ routing するため、不一致だと TC-2 が読取経路を検証できない)
REPO_HEAD=$(git -C "$REPO" rev-parse HEAD)
# TC-2 の期待パスは git が返す正規化済み toplevel から導出する。macOS では mktemp が
# /var (→ /private/var symlink) を返すため、literal $REPO との文字列比較は不一致になる
# (review-source-resolve.test.sh の SANDBOX_ROOT と同じ理由)
MAIN_ROOT=$(git -C "$REPO" rev-parse --show-toplevel)
json_body() {
  cat <<JSON
{
  "schema_version": "1.1.0",
  "pr_number": 99,
  "timestamp": "__RITE_TS_PLACEHOLDER_7f3a9b2c__",
  "commit_sha": "$REPO_HEAD",
  "overall_assessment": "mergeable",
  "findings": []
}
JSON
}

echo "=== review-result state-root tests ==="
echo ""

# ─── TC-1 (AC-1): worktree 内保存が main checkout の state ルートに載る ───
echo "TC-1: save from linked worktree lands under main checkout root"
content1="$TEST_DIR/body1.json"
json_body > "$content1"
( cd "$REPO/.rite/worktrees/issue-99" && \
  bash "$REPO/hooks/review-result-save.sh" --pr 99 --content-file "$content1" ) 2>/dev/null
main_hits=$({ find "$REPO/.rite/review-results" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
wt_hits=$({ find "$REPO/.rite/worktrees/issue-99/.rite/review-results" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$main_hits" -eq 1 ] && [ "$wt_hits" -eq 0 ]; then
  pass "TC-1: JSON saved at main root (main=$main_hits, worktree=$wt_hits)"
else
  fail "TC-1: expected main=1/worktree=0, got main=$main_hits worktree=$wt_hits"
fi
echo ""

# ─── TC-2 (AC-2): worktree cwd からの読取が main root の JSON を拾う ───
echo "TC-2: review-source-resolve Priority 2 reads main-root JSON from worktree cwd"
out2=$(cd "$REPO/.rite/worktrees/issue-99" && \
  bash "$REPO/scripts/review-source-resolve.sh" \
    --pr-number 99 --review-file-path "__RITE_UNSET__" \
    --conversation-decision none --p1-scan-turns 0 --p1-scan-found false 2>&1) || true
if printf '%s' "$out2" | grep -q 'REVIEW_SOURCE=local_file' && \
   printf '%s' "$out2" | grep -q "review_source_path=$MAIN_ROOT/.rite/review-results/99-"; then
  pass "TC-2: Priority 2 resolved to main-root local file"
else
  fail "TC-2: expected local_file at main root. out: $(printf '%s' "$out2" | grep REVIEW_SOURCE | head -2)"
fi
echo ""

# TC-2b 以降のための追い commit。cycle scope helper は `commit_sha..HEAD` が差分ゼロ行のとき
# `empty_diff` で full へ倒す（accept-only cycle 相当）。TC-2b が検証したいのは results dir の
# **既定解決**であって empty_diff 分岐ではないため、起点 commit の後ろに実 commit を 1 本置き
# incremental が成立する前提を作る。TC-2 は既に上で完了しているので影響しない。
# TC-2b は worktree の cwd で helper を実行するため、追い commit も **worktree 側**へ置く
# (helper の `git diff base_sha..HEAD` は cwd のリポジトリ = worktree の HEAD を見る)。
echo "advance" > "$REPO/.rite/worktrees/issue-99/advance.txt"
git -C "$REPO/.rite/worktrees/issue-99" add -A
git -C "$REPO/.rite/worktrees/issue-99" commit -qm "advance"

# ─── TC-2b: review-cycle-scope の既定 results dir が worktree cwd から main root を指す ───
# production の呼び出しは `--pr {n}` のみで --results-dir を渡さない。この既定解決が壊れると
# session worktree 内の reviewer が main checkout 側の保存先を見失い、WARNING を出さない唯一の
# reason である no_prev_json に落ちて差分スコープが恒久的に無音で不発になる (AC-1 が一度も成立しない)。
echo "TC-2b: review-cycle-scope default results dir resolves to main root from worktree cwd"
out2b=$(cd "$REPO/.rite/worktrees/issue-99" && \
  bash "$REPO/scripts/review-cycle-scope.sh" --pr 99 2>&1) || true
if printf '%s' "$out2b" | grep -q 'REVIEW_CYCLE_SCOPE=incremental' && \
   printf '%s' "$out2b" | grep -q "prev_json=$MAIN_ROOT/.rite/review-results/99-"; then
  pass "TC-2b: default results dir resolved to main root"
else
  fail "TC-2b: expected incremental with main-root prev_json. out: $(printf '%s' "$out2b" | grep REVIEW_CYCLE_SCOPE | head -2)"
fi
echo ""

# ─── TC-2c: state-path-resolve 解決失敗時は cwd 相対へフォールバックし WARNING を出す ───
# TC-5 (review-result-save 側) と同型。silent に別ディレクトリを見に行かせない。
echo "TC-2c: review-cycle-scope falls back to cwd-relative when state-path-resolve is unavailable"
FALLBACK_DIR="$TEST_DIR/rcs-fallback"
mkdir -p "$FALLBACK_DIR/scripts" "$FALLBACK_DIR/hooks/scripts/lib"
cp "$HOOKS_DIR/../scripts/review-cycle-scope.sh" "$FALLBACK_DIR/scripts/"
cp "$HOOKS_DIR/scripts/lib/tempfile.sh" "$FALLBACK_DIR/hooks/scripts/lib/"
# state-path-resolve.sh を意図的に置かない (解決失敗経路)
out2c=$(cd "$FALLBACK_DIR" && bash "$FALLBACK_DIR/scripts/review-cycle-scope.sh" --pr 99 2>&1) || true
if printf '%s' "$out2c" | grep -q 'state-path-resolve.sh の解決に失敗'; then
  pass "TC-2c: fallback emitted a loud WARNING"
else
  fail "TC-2c: expected fallback WARNING. out: $(printf '%s' "$out2c" | head -3)"
fi
echo ""

# ─── TC-3 (AC-4): --results-dir 明示指定は state-root 既定を上書きする ───
echo "TC-3: explicit --results-dir overrides the state-root default"
content3="$TEST_DIR/body3.json"
json_body > "$content3"
explicit_dir="$TEST_DIR/explicit-results"
( cd "$REPO/.rite/worktrees/issue-99" && \
  bash "$REPO/hooks/review-result-save.sh" --pr 99 --content-file "$content3" \
    --results-dir "$explicit_dir" ) 2>/dev/null
explicit_hits=$({ find "$explicit_dir" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$explicit_hits" -eq 1 ]; then
  pass "TC-3: JSON saved to explicit dir"
else
  fail "TC-3: expected 1 file in $explicit_dir, got $explicit_hits"
fi
echo ""

# ─── TC-4 (AC-5): 単一 checkout (main root cwd) では従来と同じパスに保存 ───
echo "TC-4: single-checkout save path is unchanged (repo root)"
content4="$TEST_DIR/body4.json"
json_body > "$content4"
rm -f "$REPO/.rite/review-results"/99-*.json
( cd "$REPO" && bash "$REPO/hooks/review-result-save.sh" --pr 99 --content-file "$content4" ) 2>/dev/null
root_hits=$({ find "$REPO/.rite/review-results" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$root_hits" -eq 1 ]; then
  pass "TC-4: JSON saved at repo root as before"
else
  fail "TC-4: expected 1 file at repo root, got $root_hits"
fi
echo ""

# ─── TC-5: state-path-resolve 解決失敗時は cwd 相対へフォールバック ───
echo "TC-5: falls back to cwd-relative dir when resolver is unavailable"
nogit_dir="$TEST_DIR/nogit"
mkdir -p "$nogit_dir/hooks"
cp "$HOOKS_DIR/review-result-save.sh" "$nogit_dir/hooks/"
cp "$HOOKS_DIR/control-char-neutralize.sh" "$nogit_dir/hooks/"
cp "$HOOKS_DIR/gitignore-ensure.sh" "$nogit_dir/hooks/"
# state-path-resolve.sh を意図的に置かない (解決失敗経路)
content5="$TEST_DIR/body5.json"
json_body > "$content5"
out5=$( cd "$nogit_dir" && bash "$nogit_dir/hooks/review-result-save.sh" --pr 99 --content-file "$content5" 2>&1 ) || true
cwd_hits=$({ find "$nogit_dir/.rite/review-results" -maxdepth 1 -name '99-*.json' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$cwd_hits" -eq 1 ] && printf '%s' "$out5" | grep -q 'state-path-resolve.sh の解決に失敗'; then
  pass "TC-5: cwd fallback + WARNING emitted"
else
  fail "TC-5: expected cwd save + WARNING. hits=$cwd_hits warning=$(printf '%s' "$out5" | grep -c '解決に失敗' || true)"
fi
echo ""

# ─── TC-6: 保存先に `*` だけの .gitignore が同梱される ───
# 保存される JSON は非実測指摘の description / suggestion 全文を持ち、`/rite:cleanup` は
# 非空のものを削除せず archive/ に残す。除外が無いと `git add -A` で公開リポジトリへ入る。
echo "TC-6: co-located .gitignore excludes the results dir"
content6="$TEST_DIR/body6.json"
json_body > "$content6"
rm -f "$REPO/.rite/review-results/.gitignore"
( cd "$REPO" && bash "$REPO/hooks/review-result-save.sh" --pr 99 --content-file "$content6" ) 2>/dev/null
gi6=$(cat "$REPO/.rite/review-results/.gitignore" 2>/dev/null || true)
# 実効を git 自身に確認させる (ファイルの中身だけを見ると `*` 以外へ書き換える退行を通す)
tracked6=$(git -C "$REPO" status --porcelain -- .rite/review-results | wc -l | tr -d ' ')
if [ "$gi6" = "*" ] && [ "$tracked6" -eq 0 ]; then
  pass "TC-6: .gitignore written and git reports the dir as excluded"
else
  fail "TC-6: expected '*' + 0 porcelain entries, got gitignore='$gi6' entries=$tracked6"
fi
echo ""

# ─── TC-7: 0 バイトの .gitignore 残骸 (ENOSPC で redirect が truncate だけした形) を治す ───
# 存在 guard (`[ ! -f ]`) へ退行すると空ファイルを「作成済み」と読んで以降の全 cycle が
# 無音で skip し、除外は効いていないのに marker も二度と出ない。
echo "TC-7: a 0-byte .gitignore residue is rewritten on the next save"
content7="$TEST_DIR/body7.json"
json_body > "$content7"
: > "$REPO/.rite/review-results/.gitignore"
( cd "$REPO" && bash "$REPO/hooks/review-result-save.sh" --pr 99 --content-file "$content7" ) 2>/dev/null
gi7=$(cat "$REPO/.rite/review-results/.gitignore" 2>/dev/null || true)
tracked7=$(git -C "$REPO" status --porcelain -- .rite/review-results | wc -l | tr -d ' ')
if [ "$gi7" = "*" ] && [ "$tracked7" -eq 0 ]; then
  pass "TC-7: 0-byte residue healed"
else
  fail "TC-7: expected '*' + 0 porcelain entries, got gitignore='$gi7' entries=$tracked7"
fi
echo ""

# ─── TC-8: .gitignore を書けないとき、原因が捨てられず列 0 にも素通ししない ───
# 単純コマンドの `printf ... > f 2>&1` は bash が redirect 自身の失敗 (EACCES) を 2>&1 適用**前**に
# 報告するため、原因が最も要る側だけが捕捉から漏れて列 0 へ出る。`{ ...; } 2>&1` のグループ
# スコープへの退行を落とす。root は chmod a-w で書き込みを止められないため skip (TC-4-rm と同型)。
echo "TC-8: gitignore write failure keeps its cause (captured + indented)"
if [ "$(id -u)" -eq 0 ]; then
  pass "TC-8: skipped (root cannot be blocked by chmod a-w)"
else
  content8="$TEST_DIR/body8.json"
  json_body > "$content8"
  ro_dir="$TEST_DIR/ro-results"
  mkdir -p "$ro_dir"
  chmod a-w "$ro_dir"
  out8=$( cd "$REPO" && bash "$REPO/hooks/review-result-save.sh" --pr 99 \
    --content-file "$content8" --results-dir "$ro_dir" 2>&1 ) || true
  chmod u+w "$ro_dir"
  marker8=$(printf '%s\n' "$out8" | grep -c 'LOCAL_SAVE_GITIGNORE_FAILED=1' || true)
  # 捕捉された診断は helper の `sed 's/^/  /'` 由来の先頭 2 スペースを持つ。
  # 列 0 の裸の診断行 (= 捕捉漏れ) が 1 本でもあれば退行。
  # anchor は bash の診断本文 (`<path>/.gitignore: <理由>`) の**構造**に取る — 理由の文言は
  # locale 依存 (ja_JP では「許可がありません」) で、`Permission denied` に依存すると
  # 日本語環境では列 0 への漏れを 1 件も捕捉できない。WARNING 行は `/.gitignore を…` で
  # コロンを持たないため、`: ` まで含めれば誤 match しない。
  # `LC_ALL=C` は必須: helper は診断を neutralize_ctrl に通すため 0x80-0x9f がバイト単位で
  # `?` に潰れ、多バイト文字の途中が壊れて行全体が invalid UTF-8 になる。UTF-8 locale の
  # grep はその行への match を諦めるので、C locale (バイト指向) にしないと ASCII の
  # anchor まで 1 件も拾えない (実測: ja_JP.UTF-8 で indented=0 bare=0 となり pin が空振りする)。
  indented8=$(printf '%s\n' "$out8" | LC_ALL=C grep -cE '^  .*/\.gitignore: ' || true)
  bare8=$(printf '%s\n' "$out8" | LC_ALL=C grep -cE '^[^ ].*/\.gitignore: ' || true)
  if [ "$marker8" -ge 1 ] && [ "$indented8" -ge 1 ] && [ "$bare8" -eq 0 ]; then
    pass "TC-8: marker emitted and cause captured with indent (no column-0 leak)"
  else
    fail "TC-8: expected marker>=1 indented>=1 bare=0, got marker=$marker8 indented=$indented8 bare=$bare8"
  fi
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
