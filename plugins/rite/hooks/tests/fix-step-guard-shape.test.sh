#!/bin/bash
# /rite:fix のシェルブロックが、native 入場した session worktree の隔離ガードを通る形
# （top-level の単一 `bash <file> <literal args>` 呼び出し）に留まっていることを固定する。
# ステップ本体は scripts/fix-step.sh が持ち、SKILL.md は 1 行呼び出しと marker 分岐表だけを持つ。
# 形の規則は references/git-worktree-patterns.md の「入場後に実行されるシェルブロックの書き方」が SoT。
#
# 例外は commit の 1 ブロックだけ。PreToolUse の commit ガードは Bash コマンド文字列に現れる
# `git commit` を検査するため、commit を helper の中へ移すとガードが掛からなくなる。
#
# 検査対象は fix/SKILL.md と、fix が途中で読む skills/fix/references/ 配下の手順
# （対象コメント・NB sweep・Wiki 記録・accept・非 fatal 記録）の ```bash ブロック。
# 散文の中に書かれたコマンド（target-comment.md の confidence override ファイルへの追記）は
# ```bash ブロックではないので対象外。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$SCRIPT_DIR/../.."
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
STEP="$PLUGIN_ROOT/scripts/fix-step.sh"

assert_file_exists_or_fail "fix/SKILL.md exists" "$FIX" || exit 1
assert_file_exists_or_fail "fix-step.sh exists" "$STEP" || exit 1

# fix が読む reference と、それぞれの ```bash ブロック数（移設時点の数。抽出の空振りと削除を fail にする）。
REF_DIR="$PLUGIN_ROOT/skills/fix/references"
REF_BLOCKS="target-comment.md:3 nb-sweep.md:5 wiki-recording.md:4 accept-finding.md:1 non-fatal-record.md:1"
for entry in $REF_BLOCKS; do
  assert_file_exists_or_fail "${entry%%:*} exists" "$REF_DIR/${entry%%:*}" || exit 1
done

# ```bash ブロック（リスト内のインデントされたものを含む）ごとに、コメント行を除き `\` 継続を
# 連結した 1 論理行を出す（ブロック間は空行）。
blocks_of() {
  awk '
    function flush() { if (cur != "") { out = out (out == "" ? "" : "\n") cur }; cur = "" }
    /^[[:space:]]*```bash$/ { inb = 1; out = ""; cur = ""; cont = 0; next }
    inb && /^[[:space:]]*```$/ { flush(); print (out == "" ? "<empty>" : out); print ""; inb = 0; next }
    inb && (/^[[:space:]]*#/ || /^[[:space:]]*$/) { next }
    inb {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (cont) { cur = cur line } else { flush(); cur = line }
      cont = 0
      if (cur ~ /\\$/) { sub(/[[:space:]]*\\$/, " ", cur); cont = 1 }
    }
  ' "$1"
}

# 1 ブロックを 1 行（文の区切りは " ; "）にする。
joined_blocks() {
  blocks_of "$1" | awk 'BEGIN { RS = ""; FS = "\n" } { n = NF; gsub(/\n/, " ; "); print n "\t" $0 }'
}

# 1 行 = 1 呼び出し。引数は空白を含まない literal / 単一引用符 / `$`・backquote を含まない二重引用符に限る。
SHAPE='^bash \{plugin_root\}/[A-Za-z0-9_./-]+\.sh( ([^ ;&|$()`<>'"'"'"]+|'"'"'[^'"'"']*'"'"'|"[^"$`]*"))*( 2>&1)?( \|\| (true|exit [0-9]+))?$'
COMMIT_EXCEPTION='git add {changed_files} ; git commit -F "{commit_message_file}"'

# 形に合わないブロックを 1 行ずつ出す（0 行なら全ブロック適合）。commit の例外ブロックは除く。
shape_violations() {
  joined_blocks "$1" | while IFS=$'\t' read -r nlines body; do
    [ "$body" = "$COMMIT_EXCEPTION" ] && continue
    if [ "$nlines" -ne 1 ] || ! grep -qE "$SHAPE" <<< "$body"; then
      printf '%s\n' "$body" | head -1
    fi
  done
}

commit_exception_count() {
  joined_blocks "$1" | awk -F '\t' -v want="$COMMIT_EXCEPTION" '$2 == want { n++ } END { print n + 0 }'
}

block_count() {
  blocks_of "$1" | awk 'BEGIN { RS = "" } END { print NR }'
}

skill_subcommands() {
  grep -hoE '^[[:space:]]*bash \{plugin_root\}/scripts/fix-step\.sh [a-z0-9-]+' "$@" | awk '{ print $3 }' | sort -u
}

ref_paths() {
  local entry
  for entry in $REF_BLOCKS; do printf '%s\n' "$REF_DIR/${entry%%:*}"; done
}

step_subcommands() {
  awk '/^case "\$subcommand" in$/ { s = 1; next } s && /^esac$/ { exit }
       s && /^  [a-z0-9-]+\)/ { sub(/^  /, ""); sub(/\).*/, ""); print }' "$1" | sort -u
}

# helper の中の commit / merge は PreToolUse の commit ガードから見えない。コメント行を除いて数える。
helper_commit_calls() {
  grep -vE '^[[:space:]]*#' "$1" | grep -cE '(^|[;&|({[:space:]])git[[:space:]]+(commit|merge)([[:space:]]|$)' || true
}

# helper が emit する `[fix:…]` sentinel のうち、sentinel-contract.md の一覧に宣言されていないもの。
# sentinel-contract-check.sh は scripts/ を走査しないため、helper 側はここで固定する。
CONTRACT="$PLUGIN_ROOT/references/sentinel-contract.md"
declared_fix_sentinels() {
  grep -oE '^\| `\[fix:[a-z-]+\]`' "$CONTRACT" | grep -oE '\[fix:[a-z-]+\]' | sort -u
}
undeclared_sentinels() {
  comm -23 <(grep -oE '\[fix:[a-z-]+\]' "$1" | sort -u) <(declared_fix_sentinels)
}

# --- 現行ファイルの形 ------------------------------------------------------------

n_blocks=$(block_count "$FIX")
# 下限は移設時点の ```bash ブロック数。0 件（抽出の空振り）や大量削除を fail にする。
if [ "$n_blocks" -ge 50 ]; then
  pass "fix/SKILL.md has all bash blocks ($n_blocks)"
else
  fail "fix/SKILL.md bash blocks dropped below 50 ($n_blocks)"
fi

violations=$(shape_violations "$FIX")
assert "every fix bash block is a single top-level bash call" "" "$violations"

# commit は literal のまま 1 ブロックだけ残る。helper 経由にするとガードが素通りし、0 件になる。
assert "the commit block stays a literal git commit (exactly one)" "1" "$(commit_exception_count "$FIX")"

# reference のブロックも同じ形に留まる。commit の例外は SKILL.md の 1 ブロックだけで、reference には無い。
for entry in $REF_BLOCKS; do
  ref="${entry%%:*}"
  assert "$ref has all bash blocks" "${entry##*:}" "$(block_count "$REF_DIR/$ref")"
  assert "every $ref bash block is a single top-level bash call" "" "$(shape_violations "$REF_DIR/$ref")"
  assert "$ref has no literal commit block" "0" "$(commit_exception_count "$REF_DIR/$ref")"
  # ```sh / ```shell の fence に移したシェルは形の検査から外れる。
  assert "$ref has no sh / shell fence" "0" "$(grep -cE '^[[:space:]]*```(sh|shell)$' "$REF_DIR/$ref" || true)"
done

mapfile -t REF_PATHS < <(ref_paths)
skill_subs=$(skill_subcommands "$FIX" "${REF_PATHS[@]}")
step_subs=$(step_subcommands "$STEP")
if [ -n "$step_subs" ]; then
  pass "fix-step.sh dispatch lists subcommands"
else
  fail "fix-step.sh dispatch lists subcommands (case \"\$subcommand\" の抽出が空)"
fi
assert "SKILL.md and its references call exactly the subcommands fix-step.sh dispatches" "$step_subs" "$skill_subs"

assert "fix-step.sh runs no git commit / git merge" "0" "$(helper_commit_calls "$STEP")"

assert_file_exists_or_fail "sentinel-contract.md exists" "$CONTRACT" || exit 1
if [ -n "$(declared_fix_sentinels)" ]; then
  pass "sentinel-contract.md declares fix sentinels"
else
  fail "sentinel-contract.md declares fix sentinels (一覧の抽出が空)"
fi
assert "every fix sentinel in fix-step.sh is declared in sentinel-contract.md" "" "$(undeclared_sentinels "$STEP")"

# --- mutation: 検査が空振りしていないこと ----------------------------------------

MUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-fix-shape-XXXXXX") || MUT_DIR=""
if [ -n "$MUT_DIR" ]; then
  trap 'rm -rf "$MUT_DIR"' EXIT

  # 2 文のブロック（source + 呼び出し）を注入すると形の違反になる。
  awk '{ print } /^bash \{plugin_root\}\/scripts\/fix-step\.sh commit-guard$/ { print "source {plugin_root}/hooks/scripts/lib/context-marker.sh" }' \
    "$FIX" > "$MUT_DIR/two-statements.md"
  if assert_mutant_changed "two-statement block" "$FIX" "$MUT_DIR/two-statements.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/two-statements.md")" ]; then
      pass "a two-statement block is reported"
    else
      fail "a two-statement block is reported"
    fi
  fi

  # 1 行でもコマンド置換を含めば違反になる。
  sed 's#^bash {plugin_root}/scripts/fix-step\.sh commit-guard$#x=$(bash {plugin_root}/scripts/fix-step.sh commit-guard)#' \
    "$FIX" > "$MUT_DIR/substitution.md"
  if assert_mutant_changed "command substitution" "$FIX" "$MUT_DIR/substitution.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/substitution.md")" ]; then
      pass "a command substitution is reported"
    else
      fail "a command substitution is reported"
    fi
  fi

  # リスト内にインデントされたブロックも検査の対象になる。
  sed 's#^   bash {plugin_root}/scripts/fix-step\.sh impact-scan #   x=1; bash {plugin_root}/scripts/fix-step.sh impact-scan #' \
    "$FIX" > "$MUT_DIR/indented.md"
  if assert_mutant_changed "indented block" "$FIX" "$MUT_DIR/indented.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/indented.md")" ]; then
      pass "an indented block is checked"
    else
      fail "an indented block is checked"
    fi
  fi

  # commit の例外ブロックに文を足すと、例外から外れて違反になる。
  awk '{ print } /^git commit -F "\{commit_message_file\}"$/ { print "git push origin HEAD" }' \
    "$FIX" > "$MUT_DIR/commit-extra.md"
  if assert_mutant_changed "commit block with an extra statement" "$FIX" "$MUT_DIR/commit-extra.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/commit-extra.md")" ]; then
      pass "a commit block with an extra statement is reported"
    else
      fail "a commit block with an extra statement is reported"
    fi
  fi

  # reference のブロックに文を足すと、reference 側でも形の違反になる。
  awk '{ print } /^bash \{plugin_root\}\/scripts\/fix-step\.sh nb-sweep-finish / { print "rm -f \"$entries_file\"" }' \
    "$REF_DIR/nb-sweep.md" > "$MUT_DIR/ref-two-statements.md"
  if assert_mutant_changed "reference two-statement block" "$REF_DIR/nb-sweep.md" "$MUT_DIR/ref-two-statements.md"; then
    if [ -n "$(shape_violations "$MUT_DIR/ref-two-statements.md")" ]; then
      pass "a two-statement block in a reference is reported"
    else
      fail "a two-statement block in a reference is reported"
    fi
  fi

  # reference のブロックを ```sh に移すと、ブロック数が減って検出される。
  sed 's#^```bash$#```sh#' "$REF_DIR/accept-finding.md" > "$MUT_DIR/ref-sh-fence.md"
  if assert_mutant_changed "reference sh fence" "$REF_DIR/accept-finding.md" "$MUT_DIR/ref-sh-fence.md"; then
    assert "a block moved to a sh fence drops the bash block count" "0" "$(block_count "$MUT_DIR/ref-sh-fence.md")"
  fi

  # reference だけが呼ぶサブコマンドを消すと集合が一致しない（SKILL.md だけでは dispatch を覆えない）。
  if [ "$(skill_subcommands "$FIX")" != "$step_subs" ]; then
    pass "SKILL.md alone does not cover the subcommands its references call"
  else
    fail "SKILL.md alone does not cover the subcommands its references call"
  fi

  # dispatch に無いサブコマンドを呼ぶと集合が一致しない。
  sed 's#^bash {plugin_root}/scripts/fix-step\.sh commit-guard$#bash {plugin_root}/scripts/fix-step.sh commit-guard-typo#' \
    "$FIX" > "$MUT_DIR/unknown-sub.md"
  if assert_mutant_changed "unknown subcommand" "$FIX" "$MUT_DIR/unknown-sub.md"; then
    if [ "$(skill_subcommands "$MUT_DIR/unknown-sub.md" "${REF_PATHS[@]}")" != "$step_subs" ]; then
      pass "an unregistered subcommand is reported"
    else
      fail "an unregistered subcommand is reported"
    fi
  fi

  # helper に commit を持ち込むと検出される。
  awk '{ print } /^step_push\(\) \{$/ { print "git commit -F \"$message_file\"" }' "$STEP" > "$MUT_DIR/step-commit.sh"
  if assert_mutant_changed "helper with a commit" "$STEP" "$MUT_DIR/step-commit.sh"; then
    assert "a git commit in fix-step.sh is reported" "1" "$(helper_commit_calls "$MUT_DIR/step-commit.sh")"
  fi

  # 宣言されていない sentinel を helper に足すと検出される。
  sed 's#^echo "\[fix:cancelled-by-user\]"$#echo "[fix:cancelled-by-typo]"#' "$STEP" > "$MUT_DIR/step-sentinel.sh"
  if assert_mutant_changed "helper with an undeclared sentinel" "$STEP" "$MUT_DIR/step-sentinel.sh"; then
    assert "an undeclared sentinel in fix-step.sh is reported" "[fix:cancelled-by-typo]" "$(undeclared_sentinels "$MUT_DIR/step-sentinel.sh")"
  fi
else
  fail "mutant workspace could not be created (mktemp -d)"
fi

# --- fix-step.sh の fail-loud ----------------------------------------------------

run_step() {
  bash "$STEP" "$@" >/dev/null 2>&1
}

run_step; assert "no subcommand exits 2" "2" "$?"
run_step no-such-step; assert "unknown subcommand exits 2" "2" "$?"
run_step triage-state --pr; assert "option without a value exits 2" "2" "$?"
run_step triage-state --pr '{pr_number}' --non-fatal-moved-count 0 --triage-review-path /x; assert "unsubstituted placeholder exits 2" "2" "$?"
run_step triage-state --pr 12a --non-fatal-moved-count 0 --triage-review-path /x; assert "non-numeric --pr exits 2" "2" "$?"

# 拒否の理由まで確かめる。exit 2 だけでは、別の必須オプションの不足で止まった場合と区別できない。
# 他の必須を満たした呼び出し（または必須を持たないサブコマンド）で、名乗る理由の stderr を検査する。
assert_rejects() {
  local name=$1 want=$2 err
  shift 2
  err=$(bash "$STEP" "$@" 2>&1 >/dev/null)
  assert "$name exits 2" "2" "$?"
  case "$err" in
    *"$want"*) pass "$name names the reason" ;;
    *) fail "$name names the reason (stderr: $err)" ;;
  esac
}
assert_rejects "missing required --pr" "triage-state requires --pr" \
  triage-state --non-fatal-moved-count 0 --triage-review-path /x
assert_rejects "unknown option" "unknown option: --bogus" cancelled-by-user --bogus x
# 空の issue は受け付けるが、--issue 自体を省いた呼び出しは止める。
assert_rejects "missing --issue for local-wm-sync" "local-wm-sync requires --issue" local-wm-sync
# 数値検査の対象外の値は placeholder 検査だけが止める。
placeholder_err=$(bash "$STEP" scope-check --fix-plan-file '{fix_plan_file}' --fix-issue-file /x 2>&1 >/dev/null)
assert "unsubstituted placeholder in a non-numeric option exits 2" "2" "$?"
case "$placeholder_err" in
  *"--fix-plan-file received an unsubstituted placeholder"*) pass "the placeholder check names the option" ;;
  *) fail "the placeholder check names the option (stderr: $placeholder_err)" ;;
esac
# Skill loader が展開しなかった引数文字列は placeholder と同じく止める。
run_step parse-args --arguments '$ARGUMENTS'; assert "unexpanded \$ARGUMENTS exits 2" "2" "$?"
run_step fallback-abort --reason bogus; assert "unknown fallback-abort reason exits 2" "2" "$?"
run_step output-handoff --pr 1 --result bogus; assert "unknown output-handoff result exits 2" "2" "$?"

# --- 空値・出力を失わない経路 -----------------------------------------------------
# fixture の plugin_root で hook を stub にし、実環境の作業メモリや review 結果に触れない。

if [ -n "$MUT_DIR" ]; then
  FIXTURE="$MUT_DIR/plugin"
  mkdir -p "$FIXTURE/scripts" "$FIXTURE/hooks/scripts"
  cp "$STEP" "$FIXTURE/scripts/fix-step.sh"
  ln -s "$(cd "$PLUGIN_ROOT/hooks" && pwd)/control-char-neutralize.sh" "$FIXTURE/hooks/control-char-neutralize.sh"
  ln -s "$(cd "$PLUGIN_ROOT/hooks/scripts" && pwd)/review-schema-version-check.sh" "$FIXTURE/hooks/scripts/review-schema-version-check.sh"

  # Issue 番号を特定できない PR では issue が空で届く。hook が branch から解決し、
  # 解決できなければ WARNING で続けるため、dispatcher で止めると結果 marker が出ないまま fix が止まる。
  printf '%s\n' '#!/bin/bash' 'echo "WM_ISSUE_NUMBER=[$WM_ISSUE_NUMBER]"' > "$FIXTURE/hooks/local-wm-update.sh"
  wm_out=$(bash "$FIXTURE/scripts/fix-step.sh" local-wm-sync --issue '' 2>/dev/null)
  assert "local-wm-sync accepts an empty --issue" "0" "$?"
  assert "an empty --issue reaches the work memory hook" "WM_ISSUE_NUMBER=[]" "$wm_out"
  # 空値でも 1 引数として届くよう、SKILL.md は placeholder を引用符で囲んで渡す。
  if grep -qxF "bash {plugin_root}/scripts/fix-step.sh local-wm-sync --issue '{issue_number}'" "$FIX"; then
    pass "SKILL.md quotes the issue number passed to local-wm-sync"
  else
    fail "SKILL.md quotes the issue number passed to local-wm-sync"
  fi

  # drift を検出したら対象ファイルを出力する。SKILL.md の Exit 表はこの行から直す対象を読む。
  DRIFT_ROOT="$MUT_DIR/drift-root"
  mkdir -p "$DRIFT_ROOT/.rite/review-results"
  git init -q "$DRIFT_ROOT"
  printf '%s\n' '{"schema_version":"9.9","pr_number":1,"findings":[]}' > "$DRIFT_ROOT/.rite/review-results/1-20260101000000.json"
  # checker は state-path-resolve.sh を直接実行するので実行権が要る。
  printf '%s\n' '#!/bin/bash' "echo \"$DRIFT_ROOT\"" > "$FIXTURE/hooks/state-path-resolve.sh"
  chmod +x "$FIXTURE/hooks/state-path-resolve.sh"
  drift_out=$(cd "$DRIFT_ROOT" && bash "$FIXTURE/scripts/fix-step.sh" schema-drift-check 2>&1)
  case "$drift_out" in
    *"REVIEW_SCHEMA_VERSION_DRIFT=1; file=$DRIFT_ROOT/.rite/review-results/1-20260101000000.json"*)
      pass "schema-drift-check names the drifted file" ;;
    *) fail "schema-drift-check names the drifted file (output: $drift_out)" ;;
  esac
  case "$drift_out" in
    *"PRE_COMMIT_DRIFT_CHECK exit=1"*) pass "schema-drift-check reports the drift exit" ;;
    *) fail "schema-drift-check reports the drift exit (output: $drift_out)" ;;
  esac

  # owner/repo を解決できないときは止める。空の値の marker を成功として渡すと、
  # 後続の gh 呼び出しが解決失敗とは別の形式エラーで止まる。
  mkdir -p "$FIXTURE/hooks/scripts/lib" "$MUT_DIR/bin"
  printf '%s\n' '#!/bin/bash' 'exit 1' > "$FIXTURE/hooks/scripts/lib/git-remote.sh"
  printf '%s\n' '#!/bin/bash' 'exit 1' > "$MUT_DIR/bin/gh"
  chmod +x "$MUT_DIR/bin/gh"
  owner_out=$(PATH="$MUT_DIR/bin:$PATH" bash "$FIXTURE/scripts/fix-step.sh" resolve-owner-repo 2>&1)
  assert "resolve-owner-repo stops when owner/repo cannot be resolved" "1" "$?"
  case "$owner_out" in
    *"FIX_OWNER_REPO="*) fail "no owner/repo marker is emitted on failure (output: $owner_out)" ;;
    *"owner/repo を解決できませんでした"*) pass "no owner/repo marker is emitted on failure" ;;
    *) fail "the failure names the unresolved owner/repo (output: $owner_out)" ;;
  esac

  # wiki-trigger は caller の本文ファイルを写さずに trigger へ渡す。写しを挟むと trigger の
  # symlink 拒否とパス allowlist が写しに対して評価され、caller のパスに効かなくなる。
  printf '%s\n' '#!/bin/bash' "printf '%s\n' \"\$@\" > \"$MUT_DIR/trigger-args\"" > "$FIXTURE/hooks/wiki-ingest-trigger.sh"
  printf '%s\n' 'body' > "$MUT_DIR/rite-wiki-body.md"
  printf '%s\n' 'title' > "$MUT_DIR/wiki-title.txt"
  wiki_out=$(bash "$FIXTURE/scripts/fix-step.sh" wiki-trigger --pr 7 \
    --content-file "$MUT_DIR/rite-wiki-body.md" --title-file "$MUT_DIR/wiki-title.txt" 2>/dev/null)
  assert "wiki-trigger runs the trigger" "trigger_exit=0" "$(grep '^trigger_exit=' <<< "$wiki_out")"
  assert "wiki-trigger hands the caller's content file to the trigger" "$MUT_DIR/rite-wiki-body.md" \
    "$(grep -A1 -xF -- '--content-file' "$MUT_DIR/trigger-args" | tail -n 1)"
  rm -f "$MUT_DIR/trigger-args"
  wiki_out=$(bash "$FIXTURE/scripts/fix-step.sh" wiki-trigger --pr 7 \
    --content-file "$MUT_DIR/absent.md" --title-file "$MUT_DIR/wiki-title.txt" 2>&1)
  case "$wiki_out" in
    *"reason=input_file_missing"*"content_write_failed=1"*) pass "a missing content file skips the trigger with input_file_missing" ;;
    *) fail "a missing content file skips the trigger with input_file_missing (output: $wiki_out)" ;;
  esac
  if [ -e "$MUT_DIR/trigger-args" ]; then
    fail "a missing content file does not run the trigger"
  else
    pass "a missing content file does not run the trigger"
  fi
fi

if ! print_summary "$(basename "$0")" \
  "fix のシェルブロック形の契約。ステップ本体は plugins/rite/scripts/fix-step.sh、形の規則は plugins/rite/references/git-worktree-patterns.md が SoT。"; then
  exit 1
fi
