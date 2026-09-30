#!/bin/bash
# Tests for wiki-branch-init.sh
#
# 旧 skills/wiki-init/SKILL.md ステップ 3.1 inline block (~95 行) の委譲先 helper。
# 動作保持は differential equivalence test (TC-D 系) で機械的に立証する:
# 旧 inline block を参照実装として verbatim 再現し、同一構成の sandbox git repo
# (bare origin 付き) で実行して、正規化済み出力と end state (ブランチ構成 /
# wiki tree / commit subject / stash / dirty 変更の復元) を比較する。
# stash の扱い (自分の entry を SHA で特定して pop する) は参照実装と意図的に異なり、
# 共有 stash を再現する TC-11〜TC-15 で pin する。
#
# Usage: bash plugins/rite/hooks/tests/wiki-branch-init.test.sh
set -uo pipefail

# _timeout <seconds> <command...> — portable timeout(1) for this test.
# GNU `timeout` is absent on macOS (BSD / no coreutils); fall back to a perl
# fork/waitpid shim reproducing timeout(1)'s exit-code contract: 124 on timeout,
# 128+N on signal death, the child's status otherwise (a naive
# `perl -e 'alarm; exec'` would exit 142 and defeat hang-detection assertions).
# This file does not source _test-helpers.sh, so the shim is inlined here — keep
# it byte-identical with _test-helpers.sh (timeout-shim.test.sh asserts no drift).
_timeout() {
  local _d="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_d" "$@"
  else
    perl -e '
      my $d = shift;
      # alarm truncates to an integer, so a fractional deadline silently becomes
      # alarm 0 — no timeout at all, and waitpid blocks until the CI job limit.
      # Reject rather than degrade, and exit 125 rather than die: die exits 255,
      # which every caller reads as "not 124, so no hang" — the same silent pass
      # the rejection exists to prevent. GNU timeout accepts fractions, so this
      # shim only claims the contract for integer seconds.
      if ($d !~ /^[0-9]+$/) {
        print STDERR "_timeout: fractional seconds are not supported by the perl fallback: $d\n";
        exit 125;
      }
      my $pid = fork;
      exit 127 unless defined $pid;
      # setpgrp puts the child in its own process group so the alarm handler can
      # signal the whole tree with a negative pid. GNU timeout does the same; without
      # it the deadline only reaches the direct child, and a grandchild holding the
      # captured stdout keeps the caller blocked long past the timeout (measured 30s
      # against a 1s deadline). The runners capture output with $( ), so that stall
      # would consume the CI job limit instead of failing at 124.
      if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", -$pid; waitpid($pid, 0); exit 124; };
      alarm $d; waitpid $pid, 0;
      my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$_d" "$@"
  fi
}

# Fail closed when no backend exists. Every `_timeout` caller reads a non-124 rc
# as "no hang", so a missing backend would silently turn each hang assertion into
# a pass. Abort at source time rather than degrade.
if ! command -v timeout >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: neither timeout(1) nor perl(1) is available — _timeout cannot detect" >&2
  echo "  hangs, and every hang assertion in this suite would silently pass." >&2
  echo "  Install GNU coreutils (timeout) or perl before running the test suite." >&2
  exit 1
fi

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
# helper は stash@{n} を名指しで pop するため、引数なし pop の "Dropped refs/stash@{0}" と
# 表記だけが異なる。同じ entry の drop なので揃えて比較する
normalize_output() {
  sed -E 's/[0-9a-f]{7,40}/HASH/g' \
    | sed -E 's#Dropped refs/stash@#Dropped stash@#' \
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
    # `wc -l` right-justifies its count with leading spaces on BSD/macOS, which
    # would make the `^stash_count=0$` assertions fail; strip it.
    echo "stash_count=$(git stash list | wc -l | tr -d ' ')"
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
init_tmp=$(mktemp -d)
leftover_repo=$(make_sandbox tc1-leftover)
( cd "$leftover_repo" && TMPDIR="$init_tmp" bash "$TARGET" --branch-strategy separate_branch --wiki-branch wiki >/dev/null )
leftover_init=$(find "$init_tmp" -name 'rite-wiki-init-*' | wc -l | tr -d '[:space:]')
if [ "$leftover_init" = "0" ]; then
  pass "separate_branch success leaves no rite-wiki-init tempfiles"
else
  fail "leftover rite-wiki-init files: $(find "$init_tmp" -name 'rite-wiki-init-*')"
fi
rm -rf "$init_tmp"

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

# --------------------------------------------------------------------------
# TC-9: CLAUDE.md があるのに --message-file 未渡し → fail-loud
# TC-10: --message-file の件名・本文が実コミットに残る（引用符・バッククォート）
# --------------------------------------------------------------------------
echo "TC-9: convention file without --message-file is fail-loud"
repo=$(make_sandbox tc9)
printf 'English commits only.\n' > "$repo/CLAUDE.md"
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"--message-file"* ]]; then
  pass "CLAUDE.md present without --message-file → ERROR + exit 1"
else
  fail "expected fail-loud --message-file (rc=$HELPER_RC): $HELPER_OUTPUT"
fi

echo "TC-9b: --message-file without a value is fail-loud"
repo=$(make_sandbox tc9b)
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki --message-file
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"requires a value"* ]]; then
  pass "--message-file missing value → ERROR + exit 1"
else
  fail "expected missing-value fail-loud (rc=$HELPER_RC): $HELPER_OUTPUT"
fi
echo "TC-9c: --message-file empty value is fail-loud"
repo=$(make_sandbox tc9c)
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki --message-file ""
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"requires a value"* ]]; then
  pass "--message-file empty value → ERROR + exit 1"
else
  fail "expected empty-value fail-loud (rc=$HELPER_RC): $HELPER_OUTPUT"
fi

echo "TC-10: --message-file contents land in the commit"
repo=$(make_sandbox tc10)
printf 'English commits only.\n' > "$repo/CLAUDE.md"
msgf="$TEST_DIR/tc10-msg"
printf 'feat(wiki): custom with `date`\n\nwhy from file\n' > "$msgf"
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki --message-file "$msgf"
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "0" ] && grep -q "main_subject=feat(wiki): custom with \`date\`" <<<"$state"; then
  pass "--message-file subject is the commit subject"
else
  fail "unexpected (rc=$HELPER_RC) state=$state output=$HELPER_OUTPUT"
fi
if grep -qF 'why from file' <<<"$state"; then
  pass "--message-file body is in the commit"
else
  fail "body missing: $state"
fi

# --------------------------------------------------------------------------
# TC-11〜TC-14: stash は全 worktree で共有される。別の worktree（並行セッション）の
# 退避が混ざっても、自分が積んだ entry だけを SHA で特定して戻す
# --------------------------------------------------------------------------
REAL_GIT=$(command -v git)

# make_shared_stash_sandbox <name> — 自分の dirty 変更と、変更を持つ linked worktree を用意する
make_shared_stash_sandbox() {
  local repo other
  repo=$(make_sandbox "$1")
  other="$repo-other"
  git -C "$repo" worktree add -q -b other "$other" main
  echo "other" > "$other/base.txt"
  echo "modified" > "$repo/base.txt"
  # global の core.hooksPath があっても sandbox の hook が発火するよう local で固定する
  git -C "$repo" config core.hooksPath "$repo/.git/hooks"
  echo "$repo"
}

# install_pre_push <repo> <body> — push の直前（wiki ブランチ上、自分の退避は積まれた後）に body を実行する
install_pre_push() {
  printf '#!/bin/bash\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE\n%s\n' "$2" > "$1/.git/hooks/pre-push"
  chmod +x "$1/.git/hooks/pre-push"
}

stash_shas() { git -C "$1" stash list --format='%H'; }

echo "TC-11: another session's stash on top — only our own entry is popped"
repo=$(make_shared_stash_sandbox tc11)
rec="$TEST_DIR/tc11-rec"
install_pre_push "$repo" "git -C '$repo-other' stash push -q -m other-session && git -C '$repo-other' rev-parse refs/stash > '$rec'"
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ -s "$rec" ] && [ "$HELPER_RC" = "0" ] && grep -q "^base_content=modified$" <<<"$state" \
   && [ "$(stash_shas "$repo")" = "$(cat "$rec")" ] && [ "$(cat "$repo-other/base.txt")" = "base" ]; then
  pass "own change restored, other session's entry left intact"
else
  fail "rec=$(cat "$rec" 2>/dev/null) stash=$(stash_shas "$repo") other=$(cat "$repo-other/base.txt") rc=$HELPER_RC state=$state output=$HELPER_OUTPUT"
fi

echo "TC-12: cleanup trap pops only our own entry after a failed push"
repo=$(make_shared_stash_sandbox tc12)
rec="$TEST_DIR/tc12-rec"
install_pre_push "$repo" "git -C '$repo-other' stash push -q -m other-session && git -C '$repo-other' rev-parse refs/stash > '$rec'; exit 1"
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ -s "$rec" ] && [ "$HELPER_RC" = "1" ] && grep -q "^current=main$" <<<"$state" \
   && grep -q "^base_content=modified$" <<<"$state" && [ "$(stash_shas "$repo")" = "$(cat "$rec")" ]; then
  pass "trap restores own change, other session's entry left intact"
else
  fail "rec=$(cat "$rec" 2>/dev/null) stash=$(stash_shas "$repo") rc=$HELPER_RC state=$state output=$HELPER_OUTPUT"
fi

echo "TC-13: own entry gone — ERROR and the other entries are untouched"
repo=$(make_shared_stash_sandbox tc13)
git -C "$repo-other" stash push -q -m other-session
before=$(stash_shas "$repo")
rec="$TEST_DIR/tc13-rec"
install_pre_push "$repo" "ref=\$(git -C '$repo-other' stash list --format='%gd %gs' | awk '/rite-wiki-init-stash/ {print \$1; exit}') && git -C '$repo-other' stash drop -q \"\$ref\" && echo dropped > '$rec'"
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
if [ -s "$rec" ] && [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"ERROR: 退避した変更"*"見つかりません"* ]] \
   && [ "$(stash_shas "$repo")" = "$before" ]; then
  pass "missing own entry → ERROR + exit 1, stash unchanged"
else
  fail "rec=$(cat "$rec" 2>/dev/null) before=$before stash=$(stash_shas "$repo") rc=$HELPER_RC output=$HELPER_OUTPUT"
fi

echo "TC-14: stash push that creates no entry stops before touching branches"
repo=$(make_shared_stash_sandbox tc14)
git -C "$repo-other" stash push -q -m other-session
before=$(stash_shas "$repo")
fakebin="$TEST_DIR/tc14-bin"
mkdir -p "$fakebin"
printf '#!/bin/bash\n[ "$1 $2" = "stash push" ] && exit 0\nexec %q "$@"\n' "$REAL_GIT" > "$fakebin/git"
chmod +x "$fakebin/git"
PATH="$fakebin:$PATH" run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"新しい entry を作りませんでした"* ]] \
   && grep -q "^current=main$" <<<"$state" && grep -q "^wiki_tree=<none>$" <<<"$state" \
   && [ "$(stash_shas "$repo")" = "$before" ]; then
  pass "no new stash entry → ERROR + exit 1 before orphan checkout, stash unchanged"
else
  fail "before=$before stash=$(stash_shas "$repo") rc=$HELPER_RC state=$state output=$HELPER_OUTPUT"
fi

echo "TC-16: a submodule-only change stops with its cause and keeps the submodule edit"
# git stash does not save submodule changes, so the helper stops before stashing. The stop must
# name the cause and leave the submodule edit in place.
repo=$(make_sandbox tc16)
sub="$TEST_DIR/tc16-sub"
git init -q -b main "$sub"
(cd "$sub" && git config user.email t@e && git config user.name t && echo a > a && git add a && git commit -qm s)
(cd "$repo" && git -c protocol.file.allow=always submodule add -q "$sub" sub >/dev/null 2>&1 && git commit -qm sub && git push -q origin main 2>/dev/null)
echo "edited" > "$repo/sub/a"
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"submodule"* ]] \
   && [ "$(cat "$repo/sub/a")" = "edited" ] && ! git -C "$repo" rev-parse --verify -q wiki >/dev/null; then
  pass "submodule-only change → ERROR names submodule, edit kept, no wiki branch"
else
  fail "rc=$HELPER_RC sub/a=$(cat "$repo/sub/a" 2>/dev/null) output=$HELPER_OUTPUT"
fi
# The printed remedy must actually unblock a rerun: commit inside the submodule, then the pointer in the parent
(cd "$repo/sub" && git config user.email t@e && git config user.name t && git commit -qam edit)
(cd "$repo" && git add sub && git commit -qm "sub pointer")
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
if [ "$HELPER_RC" = "0" ] && git -C "$repo" rev-parse --verify -q wiki >/dev/null; then
  pass "following the printed remedy lets the rerun succeed"
else
  fail "rerun after remedy: rc=$HELPER_RC output=$HELPER_OUTPUT"
fi
# Each of these four submodule-only states stops the helper, and once git status no longer shows the submodule
# (the exit condition the message names) the rerun proceeds
(cd "$sub" && echo b > a && git commit -qam s2)
for kind in content pointer staged-pointer staged-in-sub; do
  repo=$(make_sandbox "tc16-$kind")
  (cd "$repo" && git -c protocol.file.allow=always submodule add -q "$sub" sub >/dev/null 2>&1 && git commit -qm sub && git push -q origin main 2>/dev/null)
  case "$kind" in
    content) echo edited > "$repo/sub/a" ;;
    pointer) git -C "$repo/sub" checkout -q HEAD~1 ;;
    staged-pointer) git -C "$repo/sub" checkout -q HEAD~1; git -C "$repo" add sub ;;
    staged-in-sub) echo edited > "$repo/sub/a"; git -C "$repo/sub" add a ;;
  esac
  run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
  first_rc=$HELPER_RC first_output=$HELPER_OUTPUT
  git -C "$repo" reset -q -- sub
  git -C "$repo" submodule update -q --force
  status_sub=$(git -C "$repo" status --porcelain -- sub)
  run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
  if [ "$first_rc" = "1" ] && [[ "$first_output" == *"git status"* ]] && [ -z "$status_sub" ] \
     && [ "$HELPER_RC" = "0" ] && git -C "$repo" rev-parse --verify -q wiki >/dev/null; then
    pass "$kind: stops, and proceeds once git status no longer shows the submodule"
  else
    fail "$kind: first rc=$first_rc status=[$status_sub] rerun rc=$HELPER_RC first_output=$first_output output=$HELPER_OUTPUT"
  fi
done

echo "TC-15: no argument-less stash pop remains in the helper or its reference pattern"
PATTERNS_DOC="$SCRIPT_DIR/../../references/wiki-patterns.md"
for f in "$TARGET" "$PATTERNS_DOC"; do
  if [ ! -f "$f" ]; then
    fail "missing target: $f"
    continue
  fi
  bare=$(grep -nE 'git stash pop( +[^" ]| *$| *2>|;|\|)' "$f")
  if [ -z "$bare" ]; then
    pass "$(basename "$f"): no argument-less stash pop"
  else
    fail "$(basename "$f"): argument-less stash pop: $bare"
  fi
done
# 正の件数: 自 entry を指す pop の呼び出し箇所 (helper は関数 1 箇所、参照 doc は 2 ブロックに 1 箇所ずつ)
if [ "$(grep -c 'git stash pop "\$ref"' "$TARGET")" = "1" ] && [ "$(grep -c 'git stash pop "\$ref"' "$PATTERNS_DOC")" = "2" ]; then
  pass "SHA-resolved pop sites: helper 1, reference doc 2"
else
  fail "SHA-resolved pop sites: helper=$(grep -c 'git stash pop "\$ref"' "$TARGET") doc=$(grep -c 'git stash pop "\$ref"' "$PATTERNS_DOC")"
fi

# --------------------------------------------------------------------------
# TC-17〜TC-23: separate_branch は submodule の作業ツリーと未追跡ファイルを失わない
# --------------------------------------------------------------------------
# make_submodule_sandbox <name> — 展開済みの submodule `sub` を持つ sandbox
make_submodule_sandbox() {
  local repo
  repo=$(make_sandbox "$1")
  (cd "$repo" && git -c protocol.file.allow=always submodule add -q "$sub" sub >/dev/null 2>&1 && git commit -qm sub && git push -q origin main 2>/dev/null)
  echo "$repo"
}

# sub_snapshot <repo> — submodule の展開状態と、作業ツリーの全ファイルの内容
sub_snapshot() {
  (
    cd "$1" || exit 1
    git submodule status
    git status --porcelain --ignore-submodules=none -- sub .gitmodules
    [ -d sub ] && find sub -type f ! -name .git | sort | while IFS= read -r f; do echo "$f=$(cat "$f")"; done
  )
}

# add_ignored_file <repo> — submodule 内に、git status に現れない ignored ファイルを置く
add_ignored_file() {
  echo "cache.tmp" >> "$1/.git/modules/sub/info/exclude"
  echo "cached" > "$1/sub/cache.tmp"
}

# assert_clean_submodule <label> <repo> — 前提: submodule が展開済みで、追跡ファイルと ignored ファイルがあり、変更として現れない
assert_clean_submodule() {
  if [[ "$(git -C "$2" submodule status)" == " "*" sub "* ]] && [ -f "$2/sub/a" ] && [ -f "$2/sub/cache.tmp" ] \
     && [ -z "$(git -C "$2" status --porcelain --ignore-submodules=none -- sub .gitmodules)" ]; then
    pass "$1: precondition — populated clean submodule with an ignored file"
  else
    fail "$1: precondition not met: $(sub_snapshot "$2")"
  fi
}

echo "TC-17: untracked file inside a submodule stops before anything changes"
repo=$(make_submodule_sandbox tc17)
echo "new" > "$repo/sub/new.txt"
before=$(stash_shas "$repo")
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"ERROR: submodule に変更または未追跡ファイルがあります"* ]] \
   && [[ "$HELPER_OUTPUT" == *"対象: sub"* ]] && [[ "$HELPER_OUTPUT" != *"WARNING: 未コミットの変更があります"* ]] \
   && [ "$(cat "$repo/sub/new.txt" 2>/dev/null)" = "new" ] && grep -q "^wiki_tree=<none>$" <<<"$state" \
   && grep -q "^current=main$" <<<"$state" && [ "$(stash_shas "$repo")" = "$before" ]; then
  pass "untracked-only submodule → ERROR names it, file kept, no wiki branch, no stash"
else
  fail "rc=$HELPER_RC new.txt=$(cat "$repo/sub/new.txt" 2>/dev/null) state=$state output=$HELPER_OUTPUT"
fi

echo "TC-18: a parent change alongside a submodule change stops before the stash"
repo=$(make_submodule_sandbox tc18)
echo "modified" > "$repo/base.txt"
echo "edited" > "$repo/sub/a"
before=$(stash_shas "$repo")
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"対象: sub"* ]] \
   && [[ "$HELPER_OUTPUT" != *"WARNING: 未コミットの変更があります"* ]] \
   && [ "$(cat "$repo/sub/a")" = "edited" ] && grep -q "^base_content=modified$" <<<"$state" \
   && grep -q "^wiki_tree=<none>$" <<<"$state" && grep -q "^current=main$" <<<"$state" \
   && [ "$(stash_shas "$repo")" = "$before" ]; then
  pass "parent + submodule change → ERROR, both edits kept, no wiki branch, no stash"
else
  fail "rc=$HELPER_RC sub/a=$(cat "$repo/sub/a" 2>/dev/null) state=$state output=$HELPER_OUTPUT"
fi

echo "TC-19: a clean submodule keeps its working tree, ignored files included"
repo=$(make_submodule_sandbox tc19)
add_ignored_file "$repo"
assert_clean_submodule "TC-19" "$repo"
snap_before=$(sub_snapshot "$repo")
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "0" ] && [ "$(sub_snapshot "$repo")" = "$snap_before" ] \
   && grep -q "^wiki_tree=.rite/wiki/index.md,.rite/wiki/log.md,$" <<<"$state" && grep -q "^current=main$" <<<"$state"; then
  pass "submodule tree identical after init, wiki branch holds only .rite/wiki"
else
  fail "rc=$HELPER_RC before=[$snap_before] after=[$(sub_snapshot "$repo")] state=$state output=$HELPER_OUTPUT"
fi

echo "TC-20: a failed push leaves the submodule working tree as it was"
repo=$(make_submodule_sandbox tc20)
add_ignored_file "$repo"
assert_clean_submodule "TC-20" "$repo"
snap_before=$(sub_snapshot "$repo")
(cd "$repo" && git remote set-url origin "$TEST_DIR/nonexistent-origin.git")
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"ERROR: git push failed"* ]] \
   && [ "$(sub_snapshot "$repo")" = "$snap_before" ] && grep -q "^current=main$" <<<"$state"; then
  pass "push failure → back on main, submodule tree identical"
else
  fail "rc=$HELPER_RC before=[$snap_before] after=[$(sub_snapshot "$repo")] state=$state output=$HELPER_OUTPUT"
fi

echo "TC-21: same_branch does not switch branches, so a submodule's untracked file does not stop it"
repo=$(make_submodule_sandbox tc21)
echo "new" > "$repo/sub/new.txt"
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "0" ] && grep -q "^main_subject=feat(wiki): initialize Wiki structure$" <<<"$state" \
   && [ "$(cat "$repo/sub/new.txt" 2>/dev/null)" = "new" ]; then
  pass "same_branch commits as before, untracked file kept"
else
  fail "rc=$HELPER_RC state=$state output=$HELPER_OUTPUT"
fi

echo "TC-22: failures of the submodule checks stop with an ERROR"
repo=$(make_sandbox tc22a)
before=$(stash_shas "$repo")
fakebin="$TEST_DIR/tc22a-bin"
mkdir -p "$fakebin"
printf '#!/bin/bash\n[ "$1" = "status" ] && exit 1\nexec %q "$@"\n' "$REAL_GIT" > "$fakebin/git"
chmod +x "$fakebin/git"
PATH="$fakebin:$PATH" run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"ERROR: git status failed"* ]] \
   && grep -q "^current=main$" <<<"$state" && grep -q "^wiki_tree=<none>$" <<<"$state" \
   && [ "$(stash_shas "$repo")" = "$before" ]; then
  pass "git status failure → ERROR + exit 1 before touching branches or stash"
else
  fail "rc=$HELPER_RC state=$state output=$HELPER_OUTPUT"
fi
repo=$(make_submodule_sandbox tc22b)
fakebin="$TEST_DIR/tc22b-bin"
mkdir -p "$fakebin"
# 2 回目以降の `git submodule status` は、submodule が展開されていない状態を返す
printf '#!/bin/bash\nif [ "$1 $2" = "submodule status" ]; then\n  if [ -e %q ]; then echo "-0000000 sub"; exit 0; fi\n  : > %q\nfi\nexec %q "$@"\n' \
  "$fakebin/called" "$fakebin/called" "$REAL_GIT" > "$fakebin/git"
chmod +x "$fakebin/git"
PATH="$fakebin:$PATH" run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"ERROR: submodule の状態が実行前と一致しません"* ]] \
   && [[ "$HELPER_OUTPUT" == *"git submodule update"* ]] && [[ "$HELPER_OUTPUT" != *"✅"* ]] \
   && grep -q "^current=main$" <<<"$state"; then
  pass "submodule state differs after returning → ERROR + exit 1 with the recovery command"
else
  fail "rc=$HELPER_RC state=$state output=$HELPER_OUTPUT"
fi

echo "TC-23: the reference doc's init block behaves like the helper"
DOC_INIT="$TEST_DIR/doc-init.sh"
awk '/^#### Wiki ブランチの作成（初期化時）/ {h=1; next} h && /^```bash/ {f=1; next} f && /^```/ {exit} f' "$PATTERNS_DOC" \
  | sed "s#{plugin_root}#$SCRIPT_DIR/../..#g" > "$DOC_INIT"
if [ -s "$DOC_INIT" ] && grep -q -- '--ignore-submodules=none' "$DOC_INIT" && grep -q 'update-index --force-remove' "$DOC_INIT"; then
  pass "init block extracted with the submodule check and the index-only removal"
else
  fail "init block missing or out of sync with the helper: $(wc -c < "$DOC_INIT") bytes"
fi
doc_msg="$TEST_DIR/doc-init-msg"
printf 'feat(wiki): initialize Wiki structure\n' > "$doc_msg"
run_doc_init() {
  local rc=0
  HELPER_OUTPUT=$( (cd "$1" && wiki_init_msg_file="$doc_msg" _timeout 20 bash "$DOC_INIT") 2>&1 ) || rc=$?
  HELPER_RC=$rc
}
repo=$(make_submodule_sandbox tc23a)
echo "new" > "$repo/sub/new.txt"
run_doc_init "$repo"
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "1" ] && [[ "$HELPER_OUTPUT" == *"対象: sub"* ]] && [ "$(cat "$repo/sub/new.txt" 2>/dev/null)" = "new" ] \
   && grep -q "^wiki_tree=<none>$" <<<"$state" && grep -q "^current=main$" <<<"$state"; then
  pass "doc block: untracked-only submodule → ERROR, file kept, no wiki branch"
else
  fail "doc block: rc=$HELPER_RC state=$state output=$HELPER_OUTPUT"
fi
repo=$(make_submodule_sandbox tc23b)
add_ignored_file "$repo"
assert_clean_submodule "TC-23" "$repo"
snap_before=$(sub_snapshot "$repo")
run_doc_init "$repo"
state=$(dump_state "$repo")
if [ "$HELPER_RC" = "0" ] && [ "$(sub_snapshot "$repo")" = "$snap_before" ] \
   && grep -q "^wiki_tree=.rite/wiki/index.md,.rite/wiki/log.md,$" <<<"$state" && grep -q "^current=main$" <<<"$state"; then
  pass "doc block: submodule tree identical after init"
else
  fail "doc block: rc=$HELPER_RC before=[$snap_before] after=[$(sub_snapshot "$repo")] state=$state output=$HELPER_OUTPUT"
fi

run_differential "separate-clean" separate_branch wiki 0 0
run_differential "separate-dirty" separate_branch wiki 1 0
run_differential "same-branch" same_branch wiki 0 0
run_differential "unknown-strategy" bogus_strategy wiki 0 0
run_differential "push-fail" separate_branch wiki 0 1

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
