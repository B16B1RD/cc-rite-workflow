#!/bin/bash
# Tests for wiki-branch-init.sh
#
# 旧 skills/wiki-init/SKILL.md ステップ 3.1 inline block (~95 行) の委譲先 helper。
# 動作保持は differential equivalence test (TC-D 系) で機械的に立証する:
# 旧 inline block を参照実装として verbatim 再現し、同一構成の sandbox git repo
# (bare origin 付き) で実行して、正規化済み出力と end state (ブランチ構成 /
# wiki tree / commit subject / stash / dirty 変更の復元) を比較する。
#
# Usage: bash plugins/rite/hooks/tests/wiki-branch-init.test.sh
set -uo pipefail

# _timeout <seconds> <command...> — portable timeout(1) for this test (Issue #2008).
# GNU `timeout` is absent on macOS (BSD / no coreutils); fall back to a perl
# fork/waitpid shim reproducing timeout(1)'s 124-on-timeout contract (a naive
# `perl -e 'alarm; exec'` would exit 142 and defeat hang-detection assertions).
# This file does not source _test-helpers.sh, so the shim is inlined here.
_timeout() {
  local _d="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_d" "$@"
  else
    perl -e '
      my $d = shift; my $pid = fork;
      exit 127 unless defined $pid;
      if ($pid == 0) { exec @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", $pid; waitpid($pid, 0); exit 124; };
      alarm $d; waitpid $pid, 0; exit($? >> 8);
    ' "$_d" "$@"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/wiki-branch-init.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

if [ ! -f "$TARGET" ]; then
  echo "ERROR: $TARGET not found" >&2
  exit 1
fi

# --- sandbox builder: main ブランチ + bare origin + 展開済み .rite/wiki/ ---
make_sandbox() {
  local name="$1"
  local repo="$TEST_DIR/$name"
  local origin="$TEST_DIR/$name-origin.git"
  git init -q --bare "$origin"
  git init -q -b main "$repo"
  (
    cd "$repo" || exit 1
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "base" > base.txt
    git add base.txt
    git commit -qm "init"
    git remote add origin "$origin"
    git push -qu origin main 2>/dev/null
    mkdir -p .rite/wiki/pages/patterns .rite/wiki/raw/reviews
    echo "# index" > .rite/wiki/index.md
    echo "# log" > .rite/wiki/log.md
  )
  echo "$repo"
}

# --- 参照実装: 旧 wiki/init.md ステップ 3.1 inline block の verbatim 再現 ---
# {branch_strategy} / {wiki_branch} は旧 block で LLM が literal substitute していた
# 契約のため、ここでは sed で同じ substitution を行ってから実行する。
REF_TEMPLATE="$TEST_DIR/reference-step31.sh.tmpl"
cat > "$REF_TEMPLATE" <<'REF_EOF'
# ステップ 1.2 の値をリテラルで埋め込む（例: branch_strategy="separate_branch", wiki_branch="wiki"）
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  current_branch=$(git branch --show-current)

  # cleanup trap: 異常終了時に元のブランチに復帰を保証
  # canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
  _rite_wiki_init_cleanup() {
    git checkout "$current_branch" 2>/dev/null || true
    if [ "${stash_needed:-false}" = true ]; then
      git stash pop 2>/dev/null || echo "WARNING: git stash pop failed in cleanup — manual recovery needed: git stash list" >&2
    fi
  }
  trap 'rc=$?; _rite_wiki_init_cleanup; exit $rc' EXIT
  trap '_rite_wiki_init_cleanup; exit 130' INT
  trap '_rite_wiki_init_cleanup; exit 143' TERM
  trap '_rite_wiki_init_cleanup; exit 129' HUP

  # dirty tree チェック（未コミットの変更を保護）
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
    echo "WARNING: 未コミットの変更があります。git stash で退避します。"
    git stash push -m "rite-wiki-init-stash"
    stash_needed=true
  else
    stash_needed=false
  fi

  # orphan ブランチを作成
  git checkout --orphan "$wiki_branch" || {
    echo "ERROR: git checkout --orphan '$wiki_branch' failed" >&2
    exit 1
  }
  git rm -rf . 2>/dev/null || true

  # Wiki ファイルのみをステージング
  git add .rite/wiki/ || {
    echo "ERROR: git add .rite/wiki/ failed" >&2
    exit 1
  }

  git commit -m "feat(wiki): initialize Wiki structure

- 3-layer structure: Raw Sources / Wiki Pages / Schema
- Templates: SCHEMA.md, index.md, log.md
- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}" || {
    echo "ERROR: git commit failed" >&2
    exit 1
  }

  git push origin "$wiki_branch" || {
    echo "ERROR: git push failed for branch '$wiki_branch'" >&2
    echo "  対処: gh auth status / ネットワーク接続 / リモートリポジトリの権限を確認してください" >&2
    exit 1
  }

  # 元のブランチに戻る
  git checkout "$current_branch" || {
    echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
    exit 1
  }

  # stash した場合のみ pop
  if [ "$stash_needed" = true ]; then
    git stash pop
    stash_needed=false  # EXIT trap での二重 pop を防止
  fi

  # cleanup trap を解除（正常完了時は不要）
  trap - EXIT INT TERM HUP

  echo "✅ Wiki ブランチ '$wiki_branch' を作成しました"

elif [ "$branch_strategy" = "same_branch" ]; then
  git add .rite/wiki/ || {
    echo "ERROR: git add .rite/wiki/ failed" >&2
    exit 1
  }

  git commit -m "feat(wiki): initialize Wiki structure

- 3-layer structure: Raw Sources / Wiki Pages / Schema
- Templates: SCHEMA.md, index.md, log.md
- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}" || {
    echo "ERROR: git commit failed" >&2
    exit 1
  }

  echo "✅ Wiki を現在のブランチに初期化しました"

else
  echo "ERROR: 未知の branch_strategy: '$branch_strategy'" >&2
  echo "  受け付け可能な値: separate_branch / same_branch" >&2
  echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください" >&2
  exit 1
fi
REF_EOF

# 参照実装に placeholder substitution を施した実行ファイルを生成する
render_reference() {
  local strategy="$1" wiki="$2" out="$3"
  sed -e "s/{branch_strategy}/$strategy/" -e "s/{wiki_branch}/$wiki/" "$REF_TEMPLATE" > "$out"
}

# git 出力の commit hash と sandbox 固有 path (ref-* / new-* の origin 名差) を
# 正規化して比較可能にする
normalize_output() {
  sed -E 's/[0-9a-f]{7,40}/HASH/g' \
    | sed -E 's#/(ref|new)-([A-Za-z-]+)-origin\.git#/SANDBOX-origin.git#g' \
    | sed -E 's#nonexistent-(ref|new)\.git#nonexistent-SANDBOX.git#g'
}

# end state を構造化ダンプする (repo path を受けて stdout に吐く)
dump_state() {
  local repo="$1"
  (
    cd "$repo" || exit 1
    echo "current=$(git branch --show-current)"
    echo "branches=$(git for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ',')"
    echo "origin_branches=$(git ls-remote --heads origin 2>/dev/null | awk '{print $2}' | sort | tr '\n' ',')"
    if git rev-parse --verify -q wiki >/dev/null; then
      echo "wiki_tree=$(git ls-tree -r --name-only wiki | sort | tr '\n' ',')"
      echo "wiki_subject=$(git log -1 --format=%s wiki)"
      # subject (%s) だけでは commit message body (verbatim 契約の一部) の drift を
      # 検出できないため、%B (full message) も '|' 区切りの 1 行に正規化して捕捉する
      echo "wiki_body=$(git log -1 --format=%B wiki | tr '\n' '|')"
    else
      echo "wiki_tree=<none>"
      echo "wiki_subject=<none>"
      echo "wiki_body=<none>"
    fi
    echo "main_subject=$(git log -1 --format=%s main 2>/dev/null || echo '<none>')"
    echo "main_body=$( (git log -1 --format=%B main 2>/dev/null || echo '<none>') | tr '\n' '|')"
    echo "stash_count=$(git stash list | wc -l)"
    echo "base_content=$(cat base.txt 2>/dev/null || echo '<missing>')"
  )
}

run_helper() {
  local repo="$1"; shift
  local rc=0
  HELPER_OUTPUT=$( (cd "$repo" && _timeout 20 bash "$TARGET" "$@") 2>&1 ) || rc=$?
  HELPER_RC=$rc
  return 0
}

run_reference() {
  local repo="$1" strategy="$2" wiki="$3"
  local script="$TEST_DIR/ref-rendered-$$.sh"
  render_reference "$strategy" "$wiki" "$script"
  local rc=0
  REF_OUTPUT=$( (cd "$repo" && _timeout 20 bash "$script") 2>&1 ) || rc=$?
  REF_RC=$rc
  return 0
}

echo "=== wiki-branch-init.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-1: separate_branch (clean tree) — wiki ブランチ作成 + 復帰 + push
# --------------------------------------------------------------------------
echo "TC-1: separate_branch clean tree"
repo=$(make_sandbox tc1)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "0" ] && [[ "$HELPER_OUTPUT" == *"✅ Wiki ブランチ 'wiki' を作成しました"* ]]; then
  pass "exit 0 + success message"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_OUTPUT"
fi
if grep -q "^current=main$" <<<"$state" \
   && grep -q "wiki_subject=feat(wiki): initialize Wiki structure" <<<"$state" \
   && grep -q "origin_branches=refs/heads/main,refs/heads/wiki," <<<"$state" \
   && grep -q "^stash_count=0$" <<<"$state"; then
  pass "wiki branch pushed, returned to main, no stash residue"
else
  fail "end state mismatch: $state"
fi
if grep -q "wiki_tree=.rite/wiki/index.md,.rite/wiki/log.md," <<<"$state"; then
  pass "wiki branch tree contains only .rite/wiki files"
else
  fail "wiki tree mismatch: $state"
fi
# commit message の full body (subject + body) を verbatim contract として pin する。
# subject のみの比較では helper 側 WIKI_INIT_COMMIT_MSG の body drift が素通りするため
expected_wiki_body="wiki_body=feat(wiki): initialize Wiki structure||- 3-layer structure: Raw Sources / Wiki Pages / Schema|- Templates: SCHEMA.md, index.md, log.md|- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}||"
if grep -qF "$expected_wiki_body" <<<"$state"; then
  pass "wiki commit full message (subject + body) matches verbatim contract"
else
  fail "wiki commit body mismatch: $state"
fi

# --------------------------------------------------------------------------
# TC-2: separate_branch (dirty tree) — stash 退避/復帰で変更を保護
# --------------------------------------------------------------------------
echo "TC-2: separate_branch dirty tree"
repo=$(make_sandbox tc2)
echo "modified" > "$repo/base.txt"
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "0" ] && [[ "$HELPER_OUTPUT" == *"WARNING: 未コミットの変更があります"* ]]; then
  pass "dirty tree detected with WARNING"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_OUTPUT"
fi
if grep -q "^base_content=modified$" <<<"$state" && grep -q "^stash_count=0$" <<<"$state" && grep -q "^current=main$" <<<"$state"; then
  pass "dirty change restored after stash pop"
else
  fail "dirty change lost: $state"
fi

# --------------------------------------------------------------------------
# TC-3: same_branch — 現在ブランチにコミット
# --------------------------------------------------------------------------
echo "TC-3: same_branch"
repo=$(make_sandbox tc3)
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "0" ] && [[ "$HELPER_OUTPUT" == *"✅ Wiki を現在のブランチに初期化しました"* ]]; then
  pass "exit 0 + success message"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_OUTPUT"
fi
if grep -q "main_subject=feat(wiki): initialize Wiki structure" <<<"$state" && grep -q "wiki_tree=<none>" <<<"$state"; then
  pass "committed on current branch, no wiki branch created"
else
  fail "end state mismatch: $state"
fi
# same_branch 経路でも commit message full body を verbatim contract として pin する
# (wiki_body assert と対称 — 片側のみの pin は対称位置の drift を素通りさせる)
expected_main_body="main_body=feat(wiki): initialize Wiki structure||- 3-layer structure: Raw Sources / Wiki Pages / Schema|- Templates: SCHEMA.md, index.md, log.md|- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}||"
if grep -qF "$expected_main_body" <<<"$state"; then
  pass "same_branch commit full message (subject + body) matches verbatim contract"
else
  fail "same_branch commit body mismatch: $state"
fi

# --------------------------------------------------------------------------
# TC-4: 未知の branch_strategy (placeholder 残留含む) → exit 1
# --------------------------------------------------------------------------
echo "TC-4: unknown branch_strategy"
repo=$(make_sandbox tc4)
run_helper "$repo" --branch-strategy "{branch_strategy}" --wiki-branch wiki
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"ERROR: 未知の branch_strategy: '{branch_strategy}'"* ]]; then
  pass "placeholder residue → unknown strategy error + exit 1"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-5: push 失敗 — trap が元ブランチ復帰を保証し exit 1
# --------------------------------------------------------------------------
echo "TC-5: push failure restores current branch"
repo=$(make_sandbox tc5)
(cd "$repo" && git remote set-url origin "$TEST_DIR/nonexistent-origin.git")
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"ERROR: git push failed for branch 'wiki'"* ]]; then
  pass "push failure → ERROR + exit 1"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_OUTPUT"
fi
if grep -q "^current=main$" <<<"$state"; then
  pass "trap restored current branch to main"
else
  fail "left on wrong branch: $state"
fi

# --------------------------------------------------------------------------
# TC-6: separate_branch で --wiki-branch 欠落 → 明示エラー + exit 1
# --------------------------------------------------------------------------
echo "TC-6: missing wiki-branch for separate_branch"
repo=$(make_sandbox tc6)
run_helper "$repo" --branch-strategy separate_branch
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"--wiki-branch is required"* ]]; then
  pass "missing wiki-branch caught"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-7: 値なしフラグ末尾 → no-hang (shift; shift hardening)
# --------------------------------------------------------------------------
echo "TC-7: value-less trailing flag no-hang"
repo=$(make_sandbox tc7)
run_helper "$repo" --branch-strategy same_branch --wiki-branch
if [ "$HELPER_RC" != "124" ]; then
  pass "no hang (rc=$HELPER_RC)"
else
  fail "hang detected (timeout)"
fi

# --------------------------------------------------------------------------
# TC-8: leading-`-` の wiki_branch → fail-fast gate + exit 1
#   `--force` が `git push origin` の option として解釈される argument injection
#   経路を git 操作到達前に遮断することの検証。gate は git 操作より前に発火するため
#   ブランチ未作成・main 滞在の end state も pin する。
# --------------------------------------------------------------------------
echo "TC-8: leading-dash wiki-branch rejected"
repo=$(make_sandbox tc8)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch "--force"
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"ERROR: --wiki-branch が '-' で始まる値は受け付けられません"* ]]; then
  pass "leading-dash value → ERROR + exit 1"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_OUTPUT"
fi
if grep -q "^current=main$" <<<"$state" && grep -q "^branches=main,$" <<<"$state" && grep -q "wiki_tree=<none>" <<<"$state"; then
  pass "no branch created, still on main"
else
  fail "unexpected end state: $state"
fi

# --------------------------------------------------------------------------
# TC-D: differential equivalence — 旧 inline block (参照実装) と出力 / end state 一致
# --------------------------------------------------------------------------
echo "TC-D: differential equivalence vs original inline block"

# シナリオ: <label> <strategy> <wiki_branch> <dirty:0|1> <break_origin:0|1>
run_differential() {
  local label="$1" strategy="$2" wiki="$3" dirty="$4" break_origin="$5"
  local repo_ref repo_new
  repo_ref=$(make_sandbox "ref-$label")
  repo_new=$(make_sandbox "new-$label")
  if [ "$dirty" = "1" ]; then
    echo "modified" > "$repo_ref/base.txt"
    echo "modified" > "$repo_new/base.txt"
  fi
  if [ "$break_origin" = "1" ]; then
    (cd "$repo_ref" && git remote set-url origin "$TEST_DIR/nonexistent-ref.git")
    (cd "$repo_new" && git remote set-url origin "$TEST_DIR/nonexistent-new.git")
  fi
  run_reference "$repo_ref" "$strategy" "$wiki"
  run_helper "$repo_new" --branch-strategy "$strategy" --wiki-branch "$wiki"
  local ref_norm new_norm
  ref_norm=$(normalize_output <<<"$REF_OUTPUT")
  new_norm=$(normalize_output <<<"$HELPER_OUTPUT")
  if [ "$REF_RC" = "$HELPER_RC" ] && [ "$ref_norm" = "$new_norm" ]; then
    pass "[$label] rc + normalized output identical (rc=$HELPER_RC)"
  else
    fail "[$label] output diverged: ref(rc=$REF_RC)='$ref_norm' new(rc=$HELPER_RC)='$new_norm'"
  fi
  # end state 比較 (origin path 差を除去するため origin_branches は refs 名のみで比較済み)
  local ref_state new_state
  ref_state=$(dump_state "$repo_ref")
  new_state=$(dump_state "$repo_new")
  if [ "$ref_state" = "$new_state" ]; then
    pass "[$label] end state identical"
  else
    fail "[$label] end state diverged: ref='$ref_state' new='$new_state'"
  fi
}

run_differential "separate-clean" separate_branch wiki 0 0
run_differential "separate-dirty" separate_branch wiki 1 0
run_differential "same-branch" same_branch wiki 0 0
run_differential "unknown-strategy" bogus_strategy wiki 0 0
run_differential "push-fail" separate_branch wiki 0 1

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
