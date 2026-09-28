#!/bin/bash
# rite workflow - /rite:pr-review step bodies
#
# Responsibility: hold the shell body of every step in skills/pr-review/SKILL.md so
# that the skill calls each step as one top-level
# `bash {plugin_root}/scripts/pr-review-step.sh <subcommand> --opt value ...`.
# A session worktree entered natively isolates the host shell, and the host refuses
# blocks that source files or mix command substitution, loops and git with other
# statements. A single top-level `bash <file> <literal args>` passes
# (see ../references/git-worktree-patterns.md#host-worktree-execution).
#
# The skill keeps the routing tables for every marker emitted here. This file only
# moves where the shell text lives; marker names, values and exit codes are the
# contract the skill reads.
#
# Usage (options not listed are optional for that subcommand):
#   bash pr-review-step.sh parse-args
#   bash pr-review-step.sh branch-issue
#   bash pr-review-step.sh wm-comment --owner-repo OWNER_REPO --issue ISSUE_NUMBER
#   bash pr-review-step.sh pr-view --owner-repo OWNER_REPO --pr PR_NUMBER
#   bash pr-review-step.sh pr-view-current --owner-repo OWNER_REPO
#   bash pr-review-step.sh ensure-worktree --head-ref HEAD_REF
#   bash pr-review-step.sh prev-review-comment --owner-repo OWNER_REPO --pr PR_NUMBER
#   bash pr-review-step.sh head-sha
#   bash pr-review-step.sh ci-snapshot --owner-repo OWNER_REPO --pr PR_NUMBER --commit-sha COMMIT_SHA
#   bash pr-review-step.sh numstat --base BASE_BRANCH
#   bash pr-review-step.sh issue-spec --owner-repo OWNER_REPO --issue ISSUE_NUMBER
#   bash pr-review-step.sh e2e-detect
#   bash pr-review-step.sh review-start --pr PR_NUMBER --head-ref HEAD_REF --selection SELECTION
#   bash pr-review-step.sh wiki-query-config
#   bash pr-review-step.sh wiki-apply-check --keywords KEYWORDS
#   bash pr-review-step.sh shared-principles
#   bash pr-review-step.sh spawn-at
#   bash pr-review-step.sh rejected-ledger --owner-repo OWNER_REPO --pr PR_NUMBER
#   bash pr-review-step.sh tmp-dir
#   bash pr-review-step.sh post-review-verify
#   bash pr-review-step.sh completion-gate --manifest MANIFEST
#   bash pr-review-step.sh fingerprints-load
#   bash pr-review-step.sh fingerprint-check --finding-id FINDING_ID --severity SEVERITY --finding-file FINDING_FILE
#   bash pr-review-step.sh quality-signal --file-line FILE_LINE --reviewers REVIEWERS --gap GAP
#   bash pr-review-step.sh number-ref-diff --base BASE_BRANCH
#   bash pr-review-step.sh spawn-timings-check --file SPAWN_FILE
#   bash pr-review-step.sh measured-gate --pr PR_NUMBER --input INPUT
#   bash pr-review-step.sh recommendations-register --base BASE_BRANCH --input INPUT --items ITEMS
#   bash pr-review-step.sh attribution-gate
#   bash pr-review-step.sh attribution-files --base BASE_BRANCH
#   bash pr-review-step.sh attribution-write --pr PR_NUMBER --total TOTAL --fix-introduced FIX_INTRODUCED --critical CRITICAL --high HIGH --medium MEDIUM --low-medium LOW_MEDIUM --low LOW
#   bash pr-review-step.sh cycle-id --pr PR_NUMBER
#   bash pr-review-step.sh review-finish --manifest MANIFEST --content-file CONTENT_FILE
#   bash pr-review-step.sh review-observe --observation OBSERVATION --issue-file ISSUE_FILE
#   bash pr-review-step.sh ledger-preserve --owner-repo OWNER_REPO --pr PR_NUMBER --cycle-id CYCLE_ID --tmp-dir TMP_DIR
#   bash pr-review-step.sh wm-phase-local
#   bash pr-review-step.sh wm-phase-sync
#   bash pr-review-step.sh wm-record --next-file NEXT_FILE
#   bash pr-review-step.sh wiki-ingest-config
#   bash pr-review-step.sh state-update --pr PR_NUMBER --result RESULT --next NEXT_ACTION
#   bash pr-review-step.sh nonblocking-gate
#   bash pr-review-step.sh save-gate --pr PR_NUMBER --commit-sha COMMIT_SHA
#
# Exit 2: unknown subcommand, unknown option, missing required argument, an argument
# value still carrying an unsubstituted `{placeholder}`, or a non-numeric count / PR /
# Issue number. Options whose step reports its own residue or empty value
# (--args, --orig-*, --pending-marker, --save-pending-marker, and --pr of the two
# fingerprint steps) skip this check so that step keeps its documented reason.

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage_error() {
  echo "ERROR: pr-review-step.sh: $1" >&2
  exit 2
}

# 外部コマンドの stderr を表示する診断スニペットは制御文字を中和してから出す
# （`head -N ... | neutralize_ctrl --keep-newline | sed ... >&2` が canonical idiom。SoT は
# control-char-neutralize.sh の header）。不在時は素通しへ縮退させるが、縮退は必ず告知する。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$plugin_root"/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi

# --- parse-args ------------------------------------------------------------------
step_parse_args() {
# ============================================================================
# ステップ 1.0: Argument parsing + conflict check + config read (unified block)
# ============================================================================
# 本 block は Step 0 (bash 4+ compat guard) 〜 Step 4 ({post_comment_mode} 決定 + [CONTEXT] emit) を
# 単一 Bash tool invocation で実行する。各 Step の責務は下記の `# --- Step N: ... ---` 見出しを参照。

# --- Step 0: bash 4+ compat guard (C-3: inlined from ../references/bash-compat-guard.md) ---
# rationale: ../skills/pr-review/references/design-rationale.md#argument-parsing-notes
if ! command -v mapfile >/dev/null 2>&1; then
 bash_version=$("$BASH" --version 2>/dev/null | head -1)
 echo "ERROR: bash 4.0+ が必要ですが、現在のシェルは mapfile builtin を持っていません" >&2
 echo " 検出: $bash_version" >&2
 echo " 対処: macOS では brew install bash で 4+ をインストールし、PATH の先頭に追加してください" >&2
 echo "[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=bash_version_incompatible" >&2
 echo "[review:error]"
 exit 1
fi

# --- Step 1: flag 抽出 + remaining_args 生成 ---
# 未置換のまま届いた loader トークンは、旧ブロックで空に展開されていたのと同じく空として扱う。
# shellcheck disable=SC2016
case "$args" in '$ARGUMENTS') args="" ;; esac
original_args="$args"
flag_post="false"
flag_no_post="false"

# フラグ検出 (順序問わず、space/tab 両対応 — `[[:space:]]` を sed 側除去処理と揃える)
if [[ " $original_args " =~ [[:space:]]--no-post-comment[[:space:]] ]]; then
 flag_no_post="true"
fi
if [[ " $original_args " =~ [[:space:]]--post-comment[[:space:]] ]]; then
 flag_post="true"
fi

# フラグトークンを remaining_args から除去 (sed -E で `(^|space)--flag(space|$)` を空文字置換)
remaining_args=$(printf '%s' "$original_args" \
 | sed -E 's/(^|[[:space:]])--no-post-comment([[:space:]]|$)/\1\2/g' \
 | sed -E 's/(^|[[:space:]])--post-comment([[:space:]]|$)/\1\2/g' \
 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

# --- Step 2: --post-comment / --no-post-comment conflict check ---
# 単一 block 化により Claude literal substitution が不要になった (C-4 対応)。
# flag_post / flag_no_post は Step 1 の bash 変数としてそのまま参照できる。
if [ "$flag_post" = "true" ] && [ "$flag_no_post" = "true" ]; then
 echo "エラー: --post-comment と --no-post-comment を同時に指定することはできません" >&2
 echo " 受信した引数: $args" >&2
 echo "" >&2
 echo "対処:" >&2
 echo " 1. どちらか一方のみを指定してください" >&2
 echo " 2. 永続化するには rite-config.yml の pr_review.post_comment を設定:" >&2
 echo " - true: 常に PR コメントを投稿 (チームレビュー向け)" >&2
 echo " - false: デフォルトで投稿しない (個人ワークフロー向けの既定値)" >&2
 echo " 3. コマンドライン引数は rite-config.yml の値を常に上書きします" >&2
 echo "[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=post_and_no_post_conflict" >&2
 echo "[review:error]"
 exit 1
fi

# --- Step 3: rite-config.yml の pr_review.post_comment 読取 (C-2: SIGPIPE-safe) ---
# 多段 pipeline は禁止 (SIGPIPE rc=141 で config が silent false 化する)
# rationale: ../skills/pr-review/references/design-rationale.md#argument-parsing-notes
# config の場所は helper が決める（worktree 自身のもの、無ければ main checkout のもの）
config_rc=0
config_file=$(bash "$plugin_root"/hooks/scripts/lib/rite-config-path.sh 2>&1) || config_rc=$?
config_post_comment="false"

if [ "$config_rc" -eq 1 ]; then
 echo "WARNING: ${config_file}。post_comment=false (default) で続行します" >&2
elif [ "$config_rc" -ne 0 ]; then
 echo "ERROR: $config_file" >&2
 echo "[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=config_unreadable" >&2
 echo "[review:error]"
 exit 1
else
 # 抽出は helper (実ファイル) に委譲する。skill 本文の fenced bash に awk を書くと、
 # Skill loader が位置パラメータを起動引数へ展開して行参照が壊れ、値が silent に空へ倒れる
 # (静的検出: hooks/scripts/dollar-zero-check.sh)。単一 awk / SIGPIPE 禁止契約は helper 側で維持
 helper_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-helper-err-XXXXXX" 2>/dev/null) || helper_err=""
 if raw=$(bash "$plugin_root"/hooks/scripts/pr-review-post-comment-read.sh "$config_file" 2>"${helper_err:-/dev/null}"); then
 config_post_comment="$raw"
 else
 helper_rc=$?
 echo "WARNING: rite-config.yml の post_comment 読取 helper が失敗しました (rc=$helper_rc)" >&2
 echo " 原因候補: helper 解決不能 (rc=127、plugin path の解決失敗 / plugin 未配置) / 引数・ファイル不正 (rc=2) / awk バイナリ異常 / IO エラー" >&2
 [ -n "$helper_err" ] && [ -s "$helper_err" ] && head -3 "$helper_err" | neutralize_ctrl --keep-newline | sed 's/^/ /' >&2
 [ -z "$helper_err" ] && echo " (stderr 退避用 tempfile の mktemp に失敗したため helper の stderr は失われています)" >&2
 echo " default の false を使用します" >&2
 config_post_comment=""
 fi
 [ -n "$helper_err" ] && rm -f "$helper_err"
 # 不正値は WARNING 表示 (silent false 化禁止)。空文字のみ legitimate fallback として silent OK
 case "$config_post_comment" in
 true|yes|1) config_post_comment="true" ;;
 false|no|0) config_post_comment="false" ;;
 "") config_post_comment="false" ;;
 *)
 echo "WARNING: rite-config.yml の pr_review.post_comment に不正な値: '$config_post_comment'" >&2
 echo " 認識可能: true / yes / 1 / false / no / 0 (大文字小文字無視)" >&2
 echo " default の false を使用します" >&2
 config_post_comment="false"
 ;;
 esac
fi

# --- Step 4: Final decision + [CONTEXT] emit ---
# Precedence: --no-post-comment > --post-comment > config > default(false)
post_comment_mode="false"
if [ "$flag_no_post" = "true" ]; then
 post_comment_mode="false"
elif [ "$flag_post" = "true" ]; then
 post_comment_mode="true"
elif [ "$config_post_comment" = "true" ]; then
 post_comment_mode="true"
fi

echo "[CONTEXT] POST_COMMENT_MODE=$post_comment_mode" >&2
echo "[CONTEXT] REMAINING_ARGS=$remaining_args" >&2
}

# --- branch-issue ----------------------------------------------------------------
step_branch_issue() {
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
printf '%s\n' "$issue_number"
}

# --- wm-comment ------------------------------------------------------------------
step_wm_comment() {
gh api repos/"${owner_repo}"/issues/"${issue_number}"/comments \
--jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body'
}

# --- pr-view ---------------------------------------------------------------------
step_pr_view() {
gh pr view "${pr_number}" -R "${owner_repo}" --json number,title,body,state,isDraft,additions,deletions,changedFiles,files,headRefName,baseRefName,url
}

# --- pr-view-current -------------------------------------------------------------
step_pr_view_current() {
git branch --show-current
# -R 指定時は selector が必須のため、現在のブランチ名を selector に渡す（従来どおり「現在ブランチの PR」を特定する）
gh pr view "$(git branch --show-current)" -R "${owner_repo}" --json number,title,body,state,isDraft,additions,deletions,changedFiles,files,headRefName,baseRefName,url
}

# --- ensure-worktree -------------------------------------------------------------
step_ensure_worktree() {
issue_number=$(printf '%s' "${head_ref}" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
if [ -n "$issue_number" ]; then
  claim_state=$(bash "$plugin_root"/hooks/issue-claim.sh check --issue "$issue_number") || exit $?
  if [ "$claim_state" != own ]; then
    bash "$plugin_root"/hooks/issue-claim.sh claim --issue "$issue_number" || exit $?
  fi
  bash "$plugin_root"/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue "$issue_number" --branch "${head_ref}"
else
  # head_ref が issue ブランチでない（session worktree の対象外）→ 従来どおり単一ツリーで続行
  echo "[CONTEXT] WT_ENSURE=skip (head_ref が issue ブランチでないため worktree 対象外: ${head_ref})"
fi
}

# --- prev-review-comment ---------------------------------------------------------
step_prev_review_comment() {
gh api repos/"${owner_repo}"/issues/"${pr_number}"/comments \
 --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | last | .body'
}

# --- head-sha --------------------------------------------------------------------
step_head_sha() {
git rev-parse HEAD
}

# --- ci-snapshot -----------------------------------------------------------------
step_ci_snapshot() {
ci_state=unknown
ci_note=""
ci_result='{"state":"unknown","checks":[],"failed":[]}'
if ci_pr=$(gh pr view "${pr_number}" -R "${owner_repo}" --json headRefOid,statusCheckRollup); then
  if ci_head=$(printf '%s' "$ci_pr" | jq -er '.headRefOid | select(type == "string" and length > 0)'); then
    if [ "$ci_head" = "${commit_sha}" ]; then
      if ci_classified=$(printf '%s' "$ci_pr" | bash "$plugin_root"/hooks/scripts/pr-checks-classify.sh); then
        ci_result="$ci_classified"
        ci_state=$(printf '%s' "$ci_result" | jq -er '.state') || { echo "[review:error]"; exit 1; }
        [ "$ci_state" != unknown ] || ci_note="check の形式または状態を分類できません"
      else
        ci_note="CI 分類に失敗しました（直前の診断を参照）"
      fi
    else
      ci_note="PR HEAD とレビュー対象 SHA が一致しないため CI を採用しません"
    fi
  else
    ci_note="PR HEAD を取得できません"
  fi
else
  ci_note="CI 取得に失敗しました（直前の診断を参照）"
fi
[ -z "$ci_note" ] || printf 'WARNING: %s\n' "$ci_note" >&2
printf '%s' "$ci_result" | jq -c --arg sha "${commit_sha}" --arg note "$ci_note" '. + {commit_sha:$sha,note:$note}' || { echo "[review:error]"; exit 1; }
ci_failed=$(printf '%s' "$ci_result" | jq -r '[.failed[] | (.name // "(unnamed)") | gsub("[\u0000-\u001f\u007f-\u009f]"; " ")] | @csv') || { echo "[review:error]"; exit 1; }
printf '[CONTEXT] REVIEW_CI_STATE=%s; failed=%s\n' "$ci_state" "$ci_failed"
}

# --- numstat ---------------------------------------------------------------------
step_numstat() {
git diff "${base_branch}"...HEAD --numstat
}

# --- issue-spec ------------------------------------------------------------------
step_issue_spec() {
issue_body_file=$(mktemp "${TMPDIR:-/tmp}/rite-review-issue-body-XXXXXX") || { echo "[review:error]"; exit 1; }
if ! gh issue view "${issue_number}" -R "${owner_repo}" --json body --jq '.body' > "$issue_body_file"; then
  echo "ERROR: 関連 Issue の本文を取得できません。受入条件確認を skip せず停止します" >&2
  rm -f "$issue_body_file"
  echo "[review:error]"
  exit 1
fi
echo "[CONTEXT] ISSUE_BODY_FILE=$issue_body_file"
bash "$plugin_root"/scripts/acceptance-criteria-check.sh extract --body-file "$issue_body_file" || { rm -f "$issue_body_file"; echo "[review:error]"; exit 1; }
}

# --- e2e-detect ------------------------------------------------------------------
step_e2e_detect() {
if phase=$(bash "$plugin_root"/hooks/flow-state.sh get --field phase --default ""); then
  :
else
  rc=$?
  echo "WARNING: flow-state.sh failed (rc=$rc) for --field phase in pr-review ステップ 3.3 — falling back to standalone confirmation" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=pr_review_step_3_3_phase; rc=$rc" >&2
  phase=""
fi
if active=$(bash "$plugin_root"/hooks/flow-state.sh get --field active --default ""); then
  :
else
  rc=$?
  echo "WARNING: flow-state.sh failed (rc=$rc) for --field active in pr-review ステップ 3.3 — falling back to standalone confirmation" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=pr_review_step_3_3_active; rc=$rc" >&2
  active=""
fi
# review-cycle-e2e-entry
# 名簿を確定する前の初回 E2E は phase=pr のまま。
# --default "" が false/missing を "" に潰すため AND check は安全（NOT-style check は禁止）。
if { [ "$phase" = "phase5_post_review" ] || [ "$phase" = "phase5_post_fix" ] || [ "$phase" = "pr" ] || [ "$phase" = "review" ] || [ "$phase" = "fix" ]; } && [ "$active" = "true" ]; then
  in_e2e_flow=true
else
  in_e2e_flow=false
fi
echo "[CONTEXT] PR_REVIEW_IN_E2E=$in_e2e_flow"
}

# --- review-start ----------------------------------------------------------------
step_review_start() {
# review-cycle-start
# review-state-initialize
review_state_path=$(bash "$plugin_root"/hooks/flow-state.sh path) || exit 1
review_state='{}'
if [ -e "$review_state_path" ] || [ -L "$review_state_path" ]; then
  review_state=$(jq -e 'select(type == "object")' "$review_state_path") || {
    echo "ERROR: cannot read review state: $review_state_path" >&2
    exit 1
  }
fi
if ! printf '%s' "$review_state" | jq -e --argjson pr "${pr_number}" --arg branch "${head_ref}" '
  ((.pr_number // 0) == 0 or .pr_number == $pr) and
  ((.branch // "") == "" or .branch == $branch)' >/dev/null; then
  echo "ERROR: review state belongs to a different PR or branch" >&2
  exit 1
fi
if printf '%s' "$review_state" | jq -e '(.pr_number // 0) == 0 and (.review_cycle == null)' >/dev/null; then
  bash "$plugin_root"/hooks/flow-state.sh set --phase pr --pr "${pr_number}" \
    --branch "${head_ref}" --next "/rite:pr-review ${pr_number}" || exit 1
fi
echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
review_start_args=()
review_issue=$(bash "$plugin_root"/hooks/flow-state.sh get --field issue_number --default 0) || exit 1
if [ "$review_issue" -gt 0 ] 2>/dev/null; then review_start_args+=(--stagnation); fi
bash "$plugin_root"/hooks/flow-state.sh review-start \
  --selection "${selection}" "${review_start_args[@]}" || {
  echo "[review:error]"
  exit 1
}
}

# --- wiki-query-config -----------------------------------------------------------
step_wiki_query_config() {
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash "$plugin_root"/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_section=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
 wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
 | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_query=""
if [[ -n "$wiki_section" ]]; then
 auto_query=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_query:/ { print; exit }' \
 | sed 's/[[:space:]]#.*//' | sed 's/.*auto_query:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac # opt-out default
case "$auto_query" in true|yes|1) auto_query="true" ;; *) auto_query="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_query=$auto_query"
}

# --- wiki-apply-check ------------------------------------------------------------
step_wiki_apply_check() {
capture_args=(--keep-record --keywords "$keywords")
[ -z "$changed_paths" ] || capture_args+=(--paths "$changed_paths")
wiki_context=$(bash "$plugin_root"/hooks/scripts/wiki-apply-capture.sh "${capture_args[@]}") || {
  echo "ERROR: Wiki 検索に失敗したため、レビューを完了扱いにしません" >&2
  exit 1
}
printf '%s\n' "$wiki_context"
gate_out=$(bash "$plugin_root"/hooks/scripts/wiki-apply-gate.sh --mode review) || {
  echo "ERROR: Wiki 適用証跡が変更と対応していません" >&2
  printf '%s\n' "$gate_out"
  exit 1
}
}

# --- shared-principles -----------------------------------------------------------
step_shared_principles() {
# plugin_root はこのファイルの位置から解決した絶対パスなので、reviewer へ渡すパスも常に絶対パスになる
base="$plugin_root/agents/_reviewer-base.md"
[ -r "$base" ] && grep -q '^## Output Format' "$base" \
  || { echo "ERROR: 共通レビュー原則を読めません: $base" >&2; echo "[review:error]"; exit 1; }
echo "[CONTEXT] SHARED_REVIEWER_PRINCIPLES=$base"
}

# --- spawn-at --------------------------------------------------------------------
step_spawn_at() {
orchestrator_spawn_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || orchestrator_spawn_at=""
if [ -n "$orchestrator_spawn_at" ]; then
  echo "[CONTEXT] ORCHESTRATOR_SPAWN_AT=$orchestrator_spawn_at" >&2
else
  echo "[CONTEXT] ORCHESTRATOR_SPAWN_AT=null; reason=date_failed" >&2
fi
}

# --- rejected-ledger -------------------------------------------------------------
step_rejected_ledger() {
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || true
rejected_ledger=""
ledger_status=empty
existing=$(mktemp "${TMPDIR:-/tmp}/rite-rejected-src-XXXXXX") || existing=""
existing_err=$(mktemp "${TMPDIR:-/tmp}/rite-rejected-err-XXXXXX") || existing_err=""
if [ -z "$existing" ] || [ -z "$existing_err" ]; then
  ledger_status=failed
  echo "WARNING: 却下台帳取得失敗 (mktemp)。空台帳として再訴訟させない" >&2
else
  record_rc=0
  bash "$plugin_root"/hooks/review-nonblocking-record.sh --print-record-body --pr "${pr_number}" --owner-repo "${owner_repo}" \
    > "$existing" 2> "$existing_err" || record_rc=$?
  neutralize_ctrl --keep-newline < "$existing_err" >&2
  if [ "$record_rc" -ne 0 ]; then
    if ! grep -q '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=[0-9]*; reason=related_issue_unresolved$' "$existing_err"; then
      ledger_status=failed
      echo "WARNING: 却下台帳取得失敗 (記録コメント)。空台帳として再訴訟させない" >&2
    fi
  elif [ -s "$existing" ]; then
    if rejected_ledger=$(bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$existing"); then
      [ -n "$rejected_ledger" ] && ledger_status=ok
    else
      ledger_status=failed
      rejected_ledger=""
      echo "WARNING: 却下台帳取得失敗 (extract)。空台帳として再訴訟させない" >&2
    fi
  fi
fi
rm -f -- "$existing" "$existing_err"
case "$ledger_status" in
  ok)
    echo "[CONTEXT] REJECTED_LEDGER=ok" >&2
    printf '%s\n' "$rejected_ledger"
    ;;
  failed)
    echo "[CONTEXT] REJECTED_LEDGER=failed" >&2
    printf '%s\n' "（台帳取得失敗 — 却下済み指摘の再訴訟の可能性）"
    ;;
  *)
    echo "[CONTEXT] REJECTED_LEDGER=empty" >&2
    ;;
esac
}

# --- tmp-dir ---------------------------------------------------------------------
step_tmp_dir() {
echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
}

# --- post-review-verify ----------------------------------------------------------
step_post_review_verify() {
# $plugin_root と ${orig_br} / ${orig_sc} / ${orig_blh} / ${orig_wth} (ステップ 4.0.A の出力値) をリテラル substitute する。
# Placeholder 残留 fail-fast gate: `{...}` 形状のまま渡ると verifier が silent false-positive cascade を
# 起こすため早期 reject する。detached HEAD は ステップ 4.0.A で sentinel 変換済みのため常に非空で到達する。
case "${orig_br}" in
 "{"*"}")
 echo "ERROR: ステップ 5.0.A の {orig_br} placeholder が literal substitute されていません (値: '${orig_br}'). ステップ 4.0.A 未実行 / Bash tool 間変数の引き継ぎ失敗の可能性。" >&2
 echo "[CONTEXT] POST_REVIEW_VERIFY_FAILED=1; reason=orig_br_placeholder_residue" >&2
 exit 1
 ;;
esac
case "${orig_sc}" in
 "{"*"}")
 echo "ERROR: ステップ 5.0.A の {orig_sc} placeholder が literal substitute されていません (値: '${orig_sc}')." >&2
 echo "[CONTEXT] POST_REVIEW_VERIFY_FAILED=1; reason=orig_sc_placeholder_residue" >&2
 exit 1
 ;;
esac
case "${orig_blh}" in
 "{"*"}")
 echo "ERROR: ステップ 5.0.A の {orig_blh} placeholder が literal substitute されていません (値: '${orig_blh}')." >&2
 echo "[CONTEXT] POST_REVIEW_VERIFY_FAILED=1; reason=orig_blh_placeholder_residue" >&2
 exit 1
 ;;
esac
case "${orig_wth}" in
 "{"*"}")
 echo "ERROR: ステップ 5.0.A の {orig_wth} placeholder が literal substitute されていません (値: '${orig_wth}')." >&2
 echo "[CONTEXT] POST_REVIEW_VERIFY_FAILED=1; reason=orig_wth_placeholder_residue" >&2
 exit 1
 ;;
esac

# stdout (JSON line) のみ result_json に収集し、stderr の WARNING は
# Bash tool 経由で会話 context に直接届く (2>&1 で混合させると JSON line を機械的に取り出せない)。
result_json=$(bash "$plugin_root"/hooks/scripts/post-review-state-verify.sh \
 --original-branch "${orig_br}" \
 --original-stash-count "${orig_sc}" \
 --original-branch-list-hash "${orig_blh}" \
 --original-worktree-hash "${orig_wth}" \
 --auto-recover true) || true
printf '%s\n' "$result_json"
}

# --- completion-gate -------------------------------------------------------------
step_completion_gate() {
# reviewer-completion-gate
if ! bash "$plugin_root"/hooks/scripts/reviewer-completion-check.sh --input "${manifest}"; then
  echo "[review:error]" >&2
  exit 1
fi
}

# --- fingerprints-load -----------------------------------------------------------
step_fingerprints_load() {
# ステップ 5.1.2.A: accepted-fingerprints 読込
case "$pr_number" in
 ''|*[!0-9]*)
 echo "WARNING: ステップ 5.1.2.A の pr_number が literal substitute されていません (値: '$pr_number')。suppression を skip します" >&2
 accepted_fingerprints=""
 ;;
 *)
 # state ファイルはリポジトリ共通の state ルート基準 (state-path-resolve.sh)。セッション
 # worktree / main checkout のどちらから実行しても同一パスに解決される (解決失敗時は cwd fallback)
 _state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
 [ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
 state_file="$_state_root/.rite/state/accepted-fingerprints-${pr_number}.txt"
 if [ -f "$state_file" ] && [ -s "$state_file" ]; then
 accepted_fingerprints=$(cat "$state_file" 2>/dev/null || echo "")
 # accept_count は fix.md ステップ 2.1.A Step 7 と bit-exact 対称: wc -l + tr -d + numeric validation
 # (grep -c は 0 行マッチで rc=1 を返し fallback `echo 0` が "0\n0" corruption を起こすため不採用)
 accept_count=$(wc -l < "$state_file" 2>/dev/null | tr -d '[:space:]')
 case "$accept_count" in ''|*[!0-9]*) accept_count=0 ;; esac
 echo "[CONTEXT] ACCEPTED_FINGERPRINTS_LOADED=1; pr=$pr_number; count=$accept_count" >&2
 else
 accepted_fingerprints=""
 echo "[CONTEXT] ACCEPTED_FINGERPRINTS_LOADED=0; pr=$pr_number; reason=no_state_file" >&2
 fi
 ;;
esac
}

# --- fingerprint-check -----------------------------------------------------------
step_fingerprint_check() {
# ステップ 5.1.2.A Step 2 per-finding fingerprint 計算 + 即時 emit (Step 2/3 統合)
# file / category / description は --finding-file の JSON から jq -r で読む。fix 側の accept
# (../skills/fix/references/accept-finding.md) も同じ JSON を同じ jq で読むため、両側の fingerprint は
# 同じ入力から計算される。finding_id / severity / pr_number は --finding-id / --severity / --pr で受け取る。
#
# Step 2/3 統合の理由 (cross-call shell 変数破綻の回避): ../skills/pr-review/references/design-rationale.md#fingerprint-suppression-notes

# ${pr_number} placeholder 残留 fail-fast (Step 1 と対称、per-finding 呼出でも安全)
case "$pr_number" in
 ''|*[!0-9]*)
 echo "WARNING: ステップ 5.1.2.A Step 2 の pr_number が literal substitute されていません (値: '$pr_number') — fingerprint 比較を skip します" >&2
 echo "[CONTEXT] FINGERPRINT_COMPUTE_FAILED=1; reason=pr_number_placeholder_residue; finding_id=$finding_id" >&2
 exit 0 # non-blocking: 当該 finding は suppression なしで通常 finding として処理される
 ;;
esac

# accepted_fingerprints は本 block 内で再読込する (Step 1 と別 invocation の可能性があるため)
# state ルート解決は Step 1 と同一 (worktree / main checkout 間のパス一貫性)
f_file=""; f_category=""; f_description=""
if [ -z "$finding_file" ] || [ ! -r "$finding_file" ]; then
 echo "WARNING: ステップ 5.1.2.A Step 2 の finding ファイルを読めません ($finding_file) — fingerprint 比較を skip します" >&2
 echo "[CONTEXT] FINGERPRINT_COMPUTE_FAILED=1; reason=finding_file_unreadable; finding_id=$finding_id" >&2
 exit 0
fi
# 空値から fingerprint を計算しないよう、読む前に形を検査する (accept-finding.md と同じ述語)
if ! jq -e 'type == "object" and (.file | type) == "string" and (.category | type) == "string" and (.category | length) > 0 and (.description | type) == "string"' "$finding_file" >/dev/null 2>&1; then
 echo "WARNING: ステップ 5.1.2.A Step 2 の finding ファイルが file / category / description を文字列で持つ JSON ではありません ($finding_file) — fingerprint 比較を skip します" >&2
 echo "[CONTEXT] FINGERPRINT_COMPUTE_FAILED=1; reason=finding_file_invalid; finding_id=$finding_id" >&2
 exit 0
fi
f_file=$(jq -r '.file' "$finding_file") || exit 1
f_category=$(jq -r '.category' "$finding_file") || exit 1
f_description=$(jq -r '.description' "$finding_file") || exit 1

_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
state_file="$_state_root/.rite/state/accepted-fingerprints-${pr_number}.txt"
if [ -f "$state_file" ] && [ -s "$state_file" ]; then
 accepted_fingerprints=$(cat "$state_file" 2>/dev/null || echo "")
else
 accepted_fingerprints=""
fi

# 早期 exit: accepted_fingerprints が空なら suppression 候補ゼロ確定 (明示 guard で意図を可視化)
if [ -z "$accepted_fingerprints" ]; then
 : # nothing to compare — suppression mapping は空、次 finding へ
else
 norm_file=$(printf '%s' "$f_file" | sed 's@^\./@@')
 norm_cat="$f_category"
 norm_msg=$(printf '%s' "$f_description" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')
 # portable SHA-1 helper (fix.md ステップ 2.1.A Step 3 と同型)
 if command -v sha1sum >/dev/null 2>&1; then
 fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | sha1sum | awk '{print $1}')
 elif command -v shasum >/dev/null 2>&1; then
 fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | shasum -a 1 | awk '{print $1}')
 else
 echo "WARNING: sha1sum / shasum が見つかりません — fingerprint 比較を skip します" >&2
 echo "[CONTEXT] FINGERPRINT_COMPUTE_FAILED=1; reason=sha1_helper_missing; file=$f_file" >&2
 fingerprint=""
 fi

 # accepted_fingerprints 集合との比較 + 即時 emit (match 時のみ、1 finding につき最大 1 回)
 if [ -n "$fingerprint" ] && grep -qFx "$fingerprint" <<< "$accepted_fingerprints"; then
 # placeholder (${finding_id} / ${severity}) は Claude が literal substitute する。
 # $fingerprint は bash 変数として同一 block 内で参照する。
 echo "[CONTEXT] FINDING_SUPPRESSED_BY_ACCEPT=1; finding_id=${finding_id}; original_severity=${severity}; fingerprint=$fingerprint" >&2
 # suppressed_findings リストに append (Claude が会話コンテキストで管理、ステップ 6.1.a JSON 除外時に参照)
 fi
fi
}

# --- quality-signal --------------------------------------------------------------
step_quality_signal() {
reviewer_a=${reviewers%%,*}
reviewer_b=${reviewers#*,}
echo "[CONTEXT] QUALITY_SIGNAL=3_cross_validation_disagreement; file=${file_line}; reviewers=${reviewer_a},${reviewer_b}; severity_gap=${gap}" >&2
}

# --- number-ref-diff -------------------------------------------------------------
step_number_ref_diff() {
if git rev-parse --verify "origin/${base_branch}^{commit}" >/dev/null 2>&1; then
  number_ref_base="origin/${base_branch}"
else
  number_ref_base="${base_branch}"
fi
# findings は stdout。捕捉すると Bash tool 結果から消え rc=1 腕が空振りする。
bash "$plugin_root"/hooks/scripts/number-reference-check.sh --diff "$number_ref_base"
number_ref_rc=$?
case "$number_ref_rc" in
  0) ;;
  1) ;; # stdout の各 file:line: matched line を 5.3.0.M step 1 の findings[] へ append
  *)
    echo "ERROR: number-reference-check.sh --diff failed rc=$number_ref_rc" >&2
    echo "[review:error]"
    exit 1
    ;;
esac
}

# --- spawn-timings-check ---------------------------------------------------------
step_spawn_timings_check() {
echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
# ステップ 4.6 が本 cycle で走ったかを機械判定する。パスの識別子は 4.6 の外 (ステップ 1.2.5)
# から来るため、4.6 を飛ばした cycle でも「本 cycle のパス」を構成できる。無言で 3 キーを
# 省略すると、結果 JSON 上で「4.6 が飛んだ」「本変更以前に保存された 1.1.0 JSON」「計測不能」
# が区別できなくなる。
# **既知の残余**: 識別子は cycle ではなく commit の粒度なので、HEAD 不変で再入する cycle
# (`/rite:fix` の accept-only 経路が push なしで `[fix:pushed]` を返し re-review を発火させる
# 正規経路) では前 cycle のファイルが同一パスに残り、4.6 を飛ばしても `present` が立つ。
# 本残余は緩和されない。下の marker は解決先パスを開示するだけで、健全 cycle と stale cycle
# でバイト単位に同一となるため stale 判定には使えない。
# ${spawn_file} は 4.6 step 1 と**同一の規則**で組む
# ({review_tmp_dir}/rite-reviewer-timings-{pr_number}-{current_commit_sha}.json)。
if [ -e "${spawn_file}" ]; then
  echo "[CONTEXT] SPAWN_TIMINGS=present; file=${spawn_file}" >&2
else
  echo "WARNING: ステップ 4.6 の spawn spread 計測が本 cycle で実行されていません (timings ファイル不在)。reviewer_timings 等の 3 キーは省略されます" >&2
  echo "[CONTEXT] SPAWN_TIMINGS=not_run" >&2
fi
}

# --- measured-gate ---------------------------------------------------------------
step_measured_gate() {
# ステップ 5.3.0.M: 実測必須ゲート — scripts/review-measured-gate.sh へ委譲済。
# helper 契約: 2 段アンカー判定 / measured=false かつ scope ∈ {current-pr, follow-up} の
# non_blocking_findings[] への append 移送 / blocking 件数からの overall_assessment 両方向確定 /
# 冪等 / 失敗は非ゼロ終了。SoT は helper docstring。
# --reject-preset-verification: step 1 の「verification は書かない」規約を機械的に強制する
# (散文の指示だけでは、複数 cycle にわたり LLM が verification を再生成した実測がある)。
# 本フラグは caller 契約違反だけを弾き、素の再実行 (recover 等) の冪等性は変えない。
bash "$plugin_root"/scripts/review-measured-gate.sh \
  --input "$input" \
  --reject-preset-verification
_gate_rc=$?

# save-pending marker 設置。rationale: ../skills/pr-review/references/measured-gate-record.md#save-pending-marker
# 非ゼロ終了時は marker を張らない（orphan 防止）。
if [ "$_gate_rc" -eq 0 ]; then
  # rationale: ../skills/pr-review/references/design-rationale.md#save-pending-id-path-notes
  save_pending_id="${pr_number}-$(date +%s)"
  save_pending_marker="${TMPDIR:-/tmp}/rite-p61a-pending-${save_pending_id}"
  # rationale: ../skills/pr-review/references/design-rationale.md#noclobber-pending-marker-notes
  if [ -e "$save_pending_marker" ] || [ -L "$save_pending_marker" ]; then
    echo "WARNING: save-pending marker path に既存エントリがあります ($save_pending_marker)。作成せず ステップ 8.0.4 を degraded に倒します" >&2
    echo "  原因候補: 同一秒の並行 review / 共有 TMPDIR での先置き (squat)" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_ID=" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_MARKER=" >&2
  elif ( set -C; : > "$save_pending_marker" ) 2>/dev/null; then
    echo "[CONTEXT] REVIEW_SAVE_PENDING_ID=$save_pending_id" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_MARKER=$save_pending_marker" >&2
  else
    echo "WARNING: save-pending marker を作成できませんでした ($save_pending_marker)。ステップ 8.0.4 の機械強制は skip され Check の prose 判定のみになります" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_ID=" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_MARKER=" >&2
  fi
fi

# helper の rc を本 block の終了コードとして再送出する。**必須** — 落とすと直前の `if`/`fi` の
# rc=0 が block 全体の終了コードになり、step 3 が「rc が最終的な権威」として使う helper の
# 非ゼロ終了が観測不能になる (MEASURED_GATE_FAILED の routing が丸ごと死ぬ)。
exit "$_gate_rc"
}

# --- recommendations-register ----------------------------------------------------
step_recommendations_register() {
bash "$plugin_root"/scripts/review-pr-recommendations.sh register \
  --input "$input" \
  --items "$items" \
  --base-ref "$(git rev-parse --verify -q "origin/${base_branch}^{commit}" >/dev/null && echo "origin/${base_branch}" || echo "${base_branch}")"
}

# --- attribution-gate ------------------------------------------------------------
step_attribution_gate() {
# `if ! var=$(cmd); then rc=$?` は bash 仕様上 `$?` が常に 0 になるため、capture と exit code を
# 両方取る場合は if/else 形式にする。
if loop_count=$(bash "$plugin_root"/hooks/flow-state.sh get --field loop_count --default 0); then
 :
else
 rc=$?
 echo "ERROR: flow-state.sh failed (rc=$rc) for --field loop_count in ステップ 5.3.8" >&2
 echo "[CONTEXT] STATE_READ_FAILED=1; phase=phase5_3_8_loop_count; rc=$rc" >&2
 echo "RESUME_HINT: flow-state.sh が異常 exit (rc=$rc) しました。ファイル不在/empty/jq parse 失敗は --default で吸収 (exit 0) されるため、本経路は helper validation 失敗 / --field 引数欠落 / invalid field name 等の caller 側引数異常で発火します。\$PLUGIN_ROOT/hooks/_validate-helpers.sh と state-path-resolve.sh の存在/実行権限を確認し、必要なら /rite:recover で再開、または STATE_ROOT 配下の sessions/ を確認してください。" >&2
 exit 1
fi
# non-numeric injection 経路 (`{"loop_count": "true"}` 等) を遮断し、後続 integer 比較が
# silent regression する経路を fail-safe で default 0 に降格する。
case "$loop_count" in
 ''|*[!0-9]*)
 echo "WARNING: loop_count is not numeric ('$loop_count'), defaulting to 0 (treat as first review)" >&2
 loop_count=0
 ;;
esac
if [ "$loop_count" -lt 1 ]; then
 echo "[CONTEXT] FINDING_ATTRIBUTION skip (first review, loop_count=$loop_count)"
 exit 0
fi
}

# --- attribution-files -----------------------------------------------------------
step_attribution_files() {

# Files in the original PR (before any fixes)
# Use the first commit on the PR branch
first_commit=$(git log --reverse --format="%H" "${base_branch}..HEAD" 2>/dev/null | head -1)
if [ -n "$first_commit" ]; then
 original_files=$(git diff --name-only "${base_branch}...${first_commit}" 2>/dev/null || echo "")
else
 original_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || echo "")
fi

# Files changed by the last fix commit
fix_files=$(git diff --name-only HEAD~1..HEAD 2>/dev/null || echo "")
original_files_count=$(echo "$original_files" | grep -c . 2>/dev/null || true)
fix_files_count=$(echo "$fix_files" | grep -c . 2>/dev/null || true)
printf '[CONTEXT] ATTRIBUTION original_files=%d fix_files=%d\n' \
 "${original_files_count:-0}" "${fix_files_count:-0}"
}

# --- attribution-write -----------------------------------------------------------
step_attribution_write() {
# fix-cycle-state もリポジトリ共通 state ルート基準 (fix.md ステップ 3.3.1 の書込側と同一解決)
_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
state_file="$_state_root/.rite/fix-cycle-state/${pr_number}.json"
total_findings="${total}"
fix_introduced_count="${fix_introduced}"
critical_count="${critical}"
high_count="${high}"
medium_count="${medium}"
low_medium_count="${low_medium}"
low_count="${low}"
attribution_state_tmp=""
_rite_pr_review_attribution_cleanup() {
 rm -f "${attribution_state_tmp:-}"
}
trap 'rc=$?; _rite_pr_review_attribution_cleanup; exit $rc' EXIT
trap '_rite_pr_review_attribution_cleanup; exit 130' INT
trap '_rite_pr_review_attribution_cleanup; exit 143' TERM
trap '_rite_pr_review_attribution_cleanup; exit 129' HUP

if [ -f "$state_file" ]; then
 if ! attribution_state_tmp=$(mktemp "${state_file}.tmp.XXXXXX"); then
  echo "WARNING: attribution state の一時ファイル作成に失敗しました" >&2
 elif jq --argjson total "$total_findings" \
  --argjson fix_introduced "$fix_introduced_count" \
  --argjson severity "{\"CRITICAL\":$critical_count,\"HIGH\":$high_count,\"MEDIUM\":$medium_count,\"LOW-MEDIUM\":$low_medium_count,\"LOW\":$low_count}" \
  '.cycles[-1].findings_total = $total | .cycles[-1].findings_new_from_fix = $fix_introduced | .cycles[-1].findings_by_severity = $severity' \
  "$state_file" > "$attribution_state_tmp" \
  && [ -s "$attribution_state_tmp" ] \
  && mv "$attribution_state_tmp" "$state_file"; then
  printf '[CONTEXT] ATTRIBUTION_WRITTEN total=%d fix_introduced=%d\n' "$total_findings" "$fix_introduced_count"
 else
  echo "WARNING: attribution state の書き込みに失敗しました" >&2
 fi
fi
}

# --- cycle-id --------------------------------------------------------------------
step_cycle_id() {
review_cycle_id="${pr_number}-$(date +%s)"
echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
echo "[CONTEXT] REVIEW_CYCLE_ID=$review_cycle_id" >&2
# 8.0.3 用 pending marker。rationale: ../skills/pr-review/references/measured-gate-record.md#pending-marker
pending_marker="${TMPDIR:-/tmp}/rite-nbr-pending-$review_cycle_id"
# rationale: ../skills/pr-review/references/design-rationale.md#noclobber-pending-marker-notes
if ( set -C; : > "$pending_marker" ) 2>/dev/null; then
  echo "[CONTEXT] NONBLOCKING_PENDING_MARKER=$pending_marker" >&2
else
  echo "WARNING: pending marker を作成できませんでした ($pending_marker)。ステップ 8.0.3 の機械強制は skip され prose 判定のみになります" >&2
  echo "[CONTEXT] NONBLOCKING_PENDING_MARKER=" >&2
fi
}

# --- review-finish ---------------------------------------------------------------
step_review_finish() {
# review-cycle-finish
bash "$plugin_root"/hooks/flow-state.sh review-finish \
  --manifest "${manifest}" \
  --content-file "$content_file" \
  --pending-id "${pending_id}" || {
  echo "ERROR: レビュー回収・保存の検証に失敗しました。入力を保持して再開してください" >&2
  echo "[review:error]"
  exit 1
}
}

# --- review-observe --------------------------------------------------------------
step_review_observe() {
# review-stagnation-observe
observed_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
if ! printf '%s' "$observed_state" | jq -e '.review_run != null' >/dev/null; then
  exit 0
fi
if ! bash "$plugin_root"/hooks/flow-state.sh review-observe \
  --input "${observation}" --issue "${issue_file}"; then
  echo "[review:error]"
  exit 1
fi
observed_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
if printf '%s' "$observed_state" | jq -e '.review_run.current_decision.action == "stop"' >/dev/null; then
  echo "[review:error]"
  exit 1
fi
}

# --- ledger-preserve -------------------------------------------------------------
step_ledger_preserve() {
# ステップ 6.1.d step 1.5: 却下台帳を新本文へ splice（空なら no-op）
body_file=${tmp_dir}/rite-nonblocking-${pr_number}-${cycle_id}.md
ledger_file=${tmp_dir}/rite-rejected-ledger-${pr_number}-${cycle_id}.md
existing_file=${tmp_dir}/rite-nb-existing-${pr_number}-${cycle_id}.md
existing_err=${tmp_dir}/rite-nb-existing-err-${pr_number}-${cycle_id}.txt
: > "$ledger_file"
record_rc=0
bash "$plugin_root"/hooks/review-nonblocking-record.sh --print-record-body --pr "${pr_number}" --owner-repo "${owner_repo}" \
  > "$existing_file" 2> "$existing_err" || record_rc=$?
neutralize_ctrl --keep-newline < "$existing_err" >&2
if [ "$record_rc" -ne 0 ]; then
  if ! grep -q '^\[CONTEXT\] NONBLOCKING_RECORD_BODY=failed; pr=[0-9]*; reason=related_issue_unresolved$' "$existing_err"; then
    echo "ERROR: 既存 6.1.d コメント取得失敗" >&2
    echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=failed" >&2
    exit 1
  fi
elif [ -s "$existing_file" ]; then
  if ! bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$existing_file" > "$ledger_file"; then
    echo "ERROR: 既存 6.1.d コメントの却下台帳 extract 失敗" >&2
    echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=failed" >&2
    exit 1
  fi
fi
bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh merge-into --body-file "$body_file" --ledger-file "$ledger_file" || {
  echo "ERROR: 却下台帳 merge-into 失敗" >&2
  echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=failed" >&2
  exit 1
}
echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=ok" >&2
}

# --- wm-phase-local --------------------------------------------------------------
step_wm_phase_local() {
# hook stderr 退避 + lock/non-lock 分岐 (fix.md ステップ 4.5 と対称。silent suppress 禁止)
# rationale: ../skills/fix/references/design-rationale.md#output-pattern-notes と同根
hook_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p62-hook-err-XXXXXX") || hook_err=""
if [ -n "$hook_err" ]; then
 if WM_SOURCE="review" \
 WM_PHASE="review" \
 WM_PHASE_DETAIL="レビュー中" \
 WM_NEXT_ACTION="レビュー結果に基づき次のアクションを決定" \
 WM_BODY_TEXT="Review cycle completed." \
 WM_ISSUE_NUMBER="${issue_number}" \
 bash "$plugin_root"/hooks/local-wm-update.sh 2>"$hook_err"; then
 : # success
 else
 hook_rc=$?
 # lock 判定は exact phrase のみ (緩い `lock|contention|busy` は他エラーを silent suppress する)
 if grep -qiE '(file is locked|lock contention|resource busy)' "$hook_err"; then
 echo "WARNING: local work memory lock contention (best-effort skip, rc=$hook_rc)" >&2
 else
 echo "WARNING: local-wm-update.sh failed (non-lock failure, rc=$hook_rc):" >&2
 head -5 "$hook_err" | neutralize_ctrl --keep-newline | sed 's/^/ /' >&2
 echo " 対処: hooks/local-wm-update.sh の存在 / 実行権限 / 内容を確認してください" >&2
 fi
 fi
 rm -f "$hook_err"
else
 # mktemp 失敗時は stderr を 2>&1 経由で stdout 統合し、失敗時に上位 5 行を表示する簡易 fallback
 echo "WARNING: hook_err mktemp 失敗により local-wm-update.sh の stderr 詳細が取得できません" >&2
 if hook_combined=$(WM_SOURCE="review" \
 WM_PHASE="review" \
 WM_PHASE_DETAIL="レビュー中" \
 WM_NEXT_ACTION="レビュー結果に基づき次のアクションを決定" \
 WM_BODY_TEXT="Review cycle completed." \
 WM_ISSUE_NUMBER="${issue_number}" \
 bash "$plugin_root"/hooks/local-wm-update.sh 2>&1); then
 : # success
 else
 hook_fallback_rc=$?
 echo "WARNING: local-wm-update.sh failed (fallback no-tempfile path, rc=$hook_fallback_rc):" >&2
 printf '%s\n' "$hook_combined" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/ /' >&2
 fi
fi
}

# --- wm-phase-sync ---------------------------------------------------------------
step_wm_phase_sync() {
# 上記 Step 1 と同じ L-5 パターンを適用
sync_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p62-sync-err-XXXXXX") || sync_err=""
if [ -n "$sync_err" ]; then
 if bash "$plugin_root"/hooks/issue-comment-wm-sync.sh update \
 --issue "${issue_number}" \
 --transform update-phase \
 --phase "review" --phase-detail "レビュー中" \
 2>"$sync_err"; then
 :
 else
 sync_rc=$?
 # exact phrase pattern (canonical: common-error-handling.md#hook-lock-contention-classification-canonical)
 if grep -qiE '(file is locked|lock contention|resource busy)' "$sync_err"; then
 echo "WARNING: issue-comment-wm-sync lock contention (best-effort skip, rc=$sync_rc)" >&2
 else
 echo "WARNING: issue-comment-wm-sync failed (non-lock failure, rc=$sync_rc):" >&2
 head -5 "$sync_err" | neutralize_ctrl --keep-newline | sed 's/^/ /' >&2
 fi
 fi
 rm -f "$sync_err"
else
 echo "WARNING: sync_err mktemp 失敗により issue-comment-wm-sync.sh の stderr 詳細が取得できません" >&2
 if sync_combined=$(bash "$plugin_root"/hooks/issue-comment-wm-sync.sh update \
 --issue "${issue_number}" \
 --transform update-phase \
 --phase "review" --phase-detail "レビュー中" \
 2>&1); then
 : # success
 else
 sync_fallback_rc=$?
 echo "WARNING: issue-comment-wm-sync.sh failed (fallback no-tempfile path, rc=$sync_fallback_rc):" >&2
 printf '%s\n' "$sync_combined" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/ /' >&2
 fi
fi
}

# --- wm-record -------------------------------------------------------------------
step_wm_record() {
# 空の内容で次のステップ節を置き換えないよう、どの更新よりも前に確かめる
[ -s "$next_file" ] || usage_error "--next-file is missing or empty: $next_file"
# ステップ 6.4 全 hook 呼び出しに L-5 stderr 退避 + lock/non-lock
# 分岐パターンを適用 (fix.md ステップ 4.5 と対称化)。
# helper function として定義し、3 step に統一適用する (drift 防止)。
_rite_review_p64_run_sync() {
 local label="$1"
 shift
 local err_file
 err_file=$(mktemp "${TMPDIR:-/tmp}/rite-review-p64-sync-err-XXXXXX") || err_file=""
 if [ -n "$err_file" ]; then
 if "$@" 2>"$err_file"; then
 :
 else
 local rc=$?
 # exact phrase pattern (canonical: common-error-handling.md#hook-lock-contention-classification-canonical)
 if grep -qiE '(file is locked|lock contention|resource busy)' "$err_file"; then
 echo "WARNING: ${label} lock contention (best-effort skip, rc=$rc)" >&2
 else
 echo "WARNING: ${label} failed (non-lock failure, rc=$rc):" >&2
 head -5 "$err_file" | neutralize_ctrl --keep-newline | sed 's/^/ /' >&2
 fi
 fi
 rm -f "$err_file"
 else
 # mktemp 失敗時も silent suppress せず `2>&1` + `head -5` display fallback (ステップ 6.2 と同型)
 if hook_combined=$("$@" 2>&1); then
 :
 else
 local fallback_rc=$?
 echo "WARNING: ${label} failed (mktemp-unavailable fallback path, rc=$fallback_rc):" >&2
 printf '%s\n' "$hook_combined" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/ /' >&2
 fi
 fi
}

# Step 1: セッション情報更新（defense-in-depth）
_rite_review_p64_run_sync "p64 update-phase" \
 bash "$plugin_root"/hooks/issue-comment-wm-sync.sh update \
 --issue "${issue_number}" \
 --transform update-phase \
 --phase "review" --phase-detail "レビュー中"

# Step 2: レビューの記録（review-close が同じ記録を要求して再保証するため、ここでは停止しない）
_rite_review_p64_run_sync "p64 review-record" \
 bash "$plugin_root"/hooks/flow-state.sh review-record

# Step 3: 次のステップ更新
_rite_review_p64_run_sync "p64 replace-section" \
 bash "$plugin_root"/hooks/issue-comment-wm-sync.sh update \
 --issue "${issue_number}" \
 --transform replace-section \
 --section "次のステップ" --content-file "$next_file"
}

# --- wiki-ingest-config ----------------------------------------------------------
step_wiki_ingest_config() {
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash "$plugin_root"/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_section=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
 wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
 | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_ingest=""
if [[ -n "$wiki_section" ]]; then
 auto_ingest=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_ingest:/ { print; exit }' \
 | sed 's/[[:space:]]#.*//' | sed 's/.*auto_ingest:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac # opt-out default
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest"

if [ "$wiki_enabled" = "false" ]; then
 reason="disabled"
elif [ "$auto_ingest" = "false" ]; then
 reason="auto_ingest_off"
else
 reason=""
fi
if [ -n "$reason" ]; then
 echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
 echo "WARNING: review ステップ 6.5.W Wiki ingest skipped: $reason" >&2
fi
}

# --- state-update ----------------------------------------------------------------
step_state_update() {
case "$result" in
 mergeable)
 bash "$plugin_root"/hooks/flow-state.sh set \
 --phase "review" \
 --active true \
 --next "$next_action" \
 --handoff "FINALIZE:review:mergeable:${pr_number}" \
 --if-exists
 ;;
 fix-needed)
 bash "$plugin_root"/hooks/flow-state.sh set \
 --phase "review" \
 --active true \
 --next "$next_action" \
 --handoff "/rite:fix ${pr_number}" \
 --if-exists
 ;;
 ac-unverified)
 # 受入条件未検証の停止は --handoff を付けず、残存 handoff を default-clear する
 bash "$plugin_root"/hooks/flow-state.sh set \
 --phase "review" \
 --active true \
 --next "$next_action" \
 --if-exists
 ;;
esac
}

# --- nonblocking-gate ------------------------------------------------------------
step_nonblocking_gate() {
case "$pending_marker" in
  "{"*"}")
    echo "WARNING: ステップ 8.0.3 の {pending_marker} が literal substitute されていません (値: '$pending_marker')。機械強制を skip し Check の prose 判定のみで続行します" >&2
    echo "[CONTEXT] NONBLOCKING_GATE=degraded; reason=pending_marker_placeholder_residue" >&2
    ;;
  "")
    # 6.1.a step 0 が marker を作れなかった (read-only /tmp 等)。同 step で WARNING 済。
    echo "[CONTEXT] NONBLOCKING_GATE=degraded; reason=pending_marker_unavailable" >&2
    ;;
  *)
    if [ -e "$pending_marker" ]; then
      echo "ERROR: ステップ 8.0.3 gate failed (機械強制)。pending marker が残存しています: $pending_marker" >&2
      echo "  ACTION: 直近の [CONTEXT] REVIEW_CYCLE_ID= より後で最後に emit された [CONTEXT] REJECTED_LEDGER_PRESERVE= が failed なら step 1.5 の失敗です — step 2 を実行しないでください。" >&2
      echo "    その run の reason が NB_SWEEP_LEDGER=failed; op=merge-into; reason=body_empty / body_marker_missing / count_line_missing なら本文の不備で、本文の作り直しが再実行より優先します — step 1 の本文を作り直してから step 1.5 → step 2 へ進みます。" >&2
      echo "    それ以外の step 1.5 の失敗は step 1.5 の規定 (1 回だけ再実行し、再び failed なら [review:error] で停止) に従ってください。" >&2
      echo "  最後の REJECTED_LEDGER_PRESERVE= が failed でなければ、会話に [CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=body_file_empty / body_marker_missing / body_sentinel_missing / count_body_mismatch のいずれかがあるか確認してください (body_check_unavailable は対象外)。" >&2
      echo "    あれば caller 契約違反です — step 1 の**本文を作り直してから** step 1.5 → step 2 を再実行します。" >&2
      echo "    無ければ 6.1.d 自体が未実行です — step 1 (本文 Write) → step 1.5 (却下台帳の引き継ぎ) → step 2 (helper 実行) の順に実行してください。step 1.5 を飛ばして step 2 を実行してはなりません。" >&2
      echo "  そのうえで ステップ 8.0 を再評価。marker はここでは削除しません。" >&2
      echo "  ⚠️ 本 gate を pass せずに ステップ 8.1 の result pattern を emit してはなりません。" >&2
      echo "[CONTEXT] NONBLOCKING_GATE_FAILED=1; reason=pending_marker_present; marker=$pending_marker" >&2
      exit 1
    fi
    echo "[CONTEXT] NONBLOCKING_GATE=pass; reason=pending_marker_absent" >&2
    ;;
esac
}

# --- save-gate -------------------------------------------------------------------
step_save_gate() {
case "$save_pending_marker" in
  "{"*"}")
    echo "WARNING: ステップ 8.0.4 の {save_pending_marker} が literal substitute されていません (値: '$save_pending_marker')。機械強制を skip し Check の prose 判定のみで続行します" >&2
    echo "[CONTEXT] REVIEW_SAVE_GATE=degraded; reason=save_pending_marker_placeholder_residue" >&2
    ;;
  "")
    echo "[CONTEXT] REVIEW_SAVE_GATE=degraded; reason=save_pending_marker_unavailable" >&2
    ;;
  *)
    if [ -e "$save_pending_marker" ] || [ -L "$save_pending_marker" ]; then
      echo "ERROR: ステップ 8.0.4 gate failed (機械強制)。save-pending marker が残存しています: $save_pending_marker" >&2
      echo "  ACTION: ステップ 6.1.a を **step 0 から** 実行 (step 2 単独禁止 — step 0 が REVIEW_CYCLE_ID / pending marker を生成)。続けて post_comment_mode に応じ 6.1.b または 6.1.c を再実行し、ステップ 8.0 を再評価。" >&2
      echo "  --pending-id は本 cycle の REVIEW_SAVE_PENDING_ID と一致させること。marker はここでは削除しません。" >&2
      echo "  ⚠️ 本 gate を pass せずに ステップ 8.1 の result pattern を emit してはなりません。" >&2
      echo "[CONTEXT] REVIEW_SAVE_GATE_FAILED=1; reason=save_pending_marker_present; marker=$save_pending_marker" >&2
      exit 1
    fi
    echo "[CONTEXT] REVIEW_SAVE_GATE=pass; reason=save_pending_marker_absent" >&2
    ;;
esac
# positive 検査は marker 層の **3 arm すべてを通す** (marker 残存を検出した枝だけは `*)` arm 内の `exit 1` で本 helper に到達しない) — marker の不在は「6.1.a が完走した」と「5.3.0.M〜6.1.a を区間ごと skip した」を区別できず、marker 値が空文字 / 未置換になる cycle では marker 層が degraded に降りるため、`*)` arm の内側に置くと守るべき経路でだけ機械強制が働かない。本検査の入力 (ステップ 1.2.5 の commit SHA と disk 上の JSON) は marker に一切依存しない。失敗のときだけ非ゼロで返る。
bash "$plugin_root"/hooks/scripts/review-save-json-verify.sh --pr "${pr_number}" --commit-sha "${commit_sha}" || exit 1
}

# --- dispatch ----------------------------------------------------------------
[ "$#" -ge 1 ] || usage_error "subcommand is required"
subcommand=$1
shift

args=""
owner_repo=""
issue_number=""
pr_number=""
head_ref=""
commit_sha=""
base_branch=""
selection=""
keywords=""
changed_paths=""
orig_br=""
orig_sc=""
orig_blh=""
orig_wth=""
manifest=""
finding_id=""
severity=""
finding_file=""
file_line=""
reviewers=""
gap=""
spawn_file=""
input=""
items=""
total=""
fix_introduced=""
critical=""
high=""
medium=""
low_medium=""
low=""
content_file=""
pending_id=""
observation=""
issue_file=""
cycle_id=""
tmp_dir=""
next_file=""
result=""
next_action=""
pending_marker=""
save_pending_marker=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage_error "$1 requires a value"
  case "$1" in
    --args|--orig-br|--orig-sc|--orig-blh|--orig-wth|--pending-marker|--save-pending-marker) ;;
    --pr)
      case "$subcommand" in
        fingerprints-load|fingerprint-check) ;;
        *) case "$2" in '{'*'}') usage_error "$1 received an unsubstituted placeholder: $2" ;; esac ;;
      esac
      ;;
    *) case "$2" in '{'*'}') usage_error "$1 received an unsubstituted placeholder: $2" ;; esac ;;
  esac
  case "$1" in
    --args) args=$2 ;;
    --owner-repo) owner_repo=$2 ;;
    --issue) issue_number=$2 ;;
    --pr) pr_number=$2 ;;
    --head-ref) head_ref=$2 ;;
    --commit-sha) commit_sha=$2 ;;
    --base) base_branch=$2 ;;
    --selection) selection=$2 ;;
    --keywords) keywords=$2 ;;
    --paths) changed_paths=$2 ;;
    --orig-br) orig_br=$2 ;;
    --orig-sc) orig_sc=$2 ;;
    --orig-blh) orig_blh=$2 ;;
    --orig-wth) orig_wth=$2 ;;
    --manifest) manifest=$2 ;;
    --finding-id) finding_id=$2 ;;
    --severity) severity=$2 ;;
    --finding-file) finding_file=$2 ;;
    --file-line) file_line=$2 ;;
    --reviewers) reviewers=$2 ;;
    --gap) gap=$2 ;;
    --file) spawn_file=$2 ;;
    --input) input=$2 ;;
    --items) items=$2 ;;
    --total) total=$2 ;;
    --fix-introduced) fix_introduced=$2 ;;
    --critical) critical=$2 ;;
    --high) high=$2 ;;
    --medium) medium=$2 ;;
    --low-medium) low_medium=$2 ;;
    --low) low=$2 ;;
    --content-file) content_file=$2 ;;
    --pending-id) pending_id=$2 ;;
    --observation) observation=$2 ;;
    --issue-file) issue_file=$2 ;;
    --cycle-id) cycle_id=$2 ;;
    --tmp-dir) tmp_dir=$2 ;;
    --next-file) next_file=$2 ;;
    --result) result=$2 ;;
    --next) next_action=$2 ;;
    --pending-marker) pending_marker=$2 ;;
    --save-pending-marker) save_pending_marker=$2 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift 2
done
for numeric in issue_number gap total fix_introduced critical high medium low_medium low; do
  case "${!numeric}" in
    ''|*[!0-9]*)
      [ -z "${!numeric}" ] || { option=${numeric%_number}; usage_error "--${option//_/-} must be a number: ${!numeric}"; } ;;
  esac
done
case "$subcommand" in
  fingerprints-load|fingerprint-check) ;;
  *) case "$pr_number" in ''|*[!0-9]*) [ -z "$pr_number" ] || usage_error "--pr must be a number: $pr_number" ;; esac ;;
esac
case "$result" in
  ''|mergeable|fix-needed|ac-unverified) ;;
  *) usage_error "--result must be mergeable, fix-needed or ac-unverified: $result" ;;
esac

require() {
  local name opt
  for name in "$@"; do
    opt=""
    case "$name" in
      args) opt=--args ;;
      owner_repo) opt=--owner-repo ;;
      issue_number) opt=--issue ;;
      pr_number) opt=--pr ;;
      head_ref) opt=--head-ref ;;
      commit_sha) opt=--commit-sha ;;
      base_branch) opt=--base ;;
      selection) opt=--selection ;;
      keywords) opt=--keywords ;;
      changed_paths) opt=--paths ;;
      orig_br) opt=--orig-br ;;
      orig_sc) opt=--orig-sc ;;
      orig_blh) opt=--orig-blh ;;
      orig_wth) opt=--orig-wth ;;
      manifest) opt=--manifest ;;
      finding_id) opt=--finding-id ;;
      severity) opt=--severity ;;
      finding_file) opt=--finding-file ;;
      file_line) opt=--file-line ;;
      reviewers) opt=--reviewers ;;
      gap) opt=--gap ;;
      spawn_file) opt=--file ;;
      input) opt=--input ;;
      items) opt=--items ;;
      total) opt=--total ;;
      fix_introduced) opt=--fix-introduced ;;
      critical) opt=--critical ;;
      high) opt=--high ;;
      medium) opt=--medium ;;
      low_medium) opt=--low-medium ;;
      low) opt=--low ;;
      content_file) opt=--content-file ;;
      pending_id) opt=--pending-id ;;
      observation) opt=--observation ;;
      issue_file) opt=--issue-file ;;
      cycle_id) opt=--cycle-id ;;
      tmp_dir) opt=--tmp-dir ;;
      next_file) opt=--next-file ;;
      result) opt=--result ;;
      next_action) opt=--next ;;
      pending_marker) opt=--pending-marker ;;
      save_pending_marker) opt=--save-pending-marker ;;
    esac
    [ -n "${!name}" ] || usage_error "$subcommand requires $opt"
  done
}

case "$subcommand" in
  parse-args) step_parse_args ;;
  branch-issue) step_branch_issue ;;
  wm-comment) require owner_repo issue_number; step_wm_comment ;;
  pr-view) require pr_number owner_repo; step_pr_view ;;
  pr-view-current) require owner_repo; step_pr_view_current ;;
  ensure-worktree) require head_ref; step_ensure_worktree ;;
  prev-review-comment) require owner_repo pr_number; step_prev_review_comment ;;
  head-sha) step_head_sha ;;
  ci-snapshot) require pr_number owner_repo commit_sha; step_ci_snapshot ;;
  numstat) require base_branch; step_numstat ;;
  issue-spec) require issue_number owner_repo; step_issue_spec ;;
  e2e-detect) step_e2e_detect ;;
  review-start) require pr_number head_ref selection; step_review_start ;;
  wiki-query-config) step_wiki_query_config ;;
  wiki-apply-check) require keywords; step_wiki_apply_check ;;
  shared-principles) step_shared_principles ;;
  spawn-at) step_spawn_at ;;
  rejected-ledger) require pr_number owner_repo; step_rejected_ledger ;;
  tmp-dir) step_tmp_dir ;;
  post-review-verify) step_post_review_verify ;;
  completion-gate) require manifest; step_completion_gate ;;
  fingerprints-load) step_fingerprints_load ;;
  fingerprint-check) require finding_id severity finding_file; step_fingerprint_check ;;
  quality-signal) require file_line reviewers gap; step_quality_signal ;;
  number-ref-diff) require base_branch; step_number_ref_diff ;;
  spawn-timings-check) require spawn_file; step_spawn_timings_check ;;
  measured-gate) require input pr_number; step_measured_gate ;;
  recommendations-register) require input items base_branch; step_recommendations_register ;;
  attribution-gate) step_attribution_gate ;;
  attribution-files) require base_branch; step_attribution_files ;;
  attribution-write) require pr_number total fix_introduced critical high medium low_medium low; step_attribution_write ;;
  cycle-id) require pr_number; step_cycle_id ;;
  review-finish) require manifest content_file; step_review_finish ;;
  review-observe) require observation issue_file; step_review_observe ;;
  ledger-preserve) require pr_number owner_repo cycle_id tmp_dir; step_ledger_preserve ;;
  wm-phase-local) step_wm_phase_local ;;
  wm-phase-sync) step_wm_phase_sync ;;
  wm-record) require next_file; step_wm_record ;;
  wiki-ingest-config) step_wiki_ingest_config ;;
  state-update) require result pr_number next_action; step_state_update ;;
  nonblocking-gate) step_nonblocking_gate ;;
  save-gate) require pr_number commit_sha; step_save_gate ;;
  *) usage_error "unknown subcommand: $subcommand" ;;
esac
