#!/bin/bash
# rite workflow - Decompose Issue into Parent + Sub-Issues
# Creates an "epic" parent Issue plus N child (Sub-)Issues, links each child
# to the parent via the Sub-issues API, then fetches the parent body so the
# caller can append a Sub-Issues section.
#
# Extracted from `skills/issue-create/SKILL.md` ステップ 5.3+5.4+5.5 Step 1
# The old inline block expanded a
# `{REPEAT_FOR_EACH_SUB_ISSUE}` placeholder and embedded each body via heredoc;
# both were heredoc/placeholder malform sources. This helper takes a spec JSON
# whose `body_file` fields point at raw files the caller wrote with the Write
# tool — the bash loop is now native (no placeholder expansion).
#
# Usage:
#   bash decompose-issues.sh --spec <spec.json>
#   jq -n '...' | bash decompose-issues.sh --spec -      # stdin (spec = "-")
#
# Input JSON schema (--spec):
#   {
#     "parent":     { "title": "string", "body_file": "path to raw body md" },
#     "sub_issues": [ { "title": "string", "body_file": "path", "complexity": "XS|S|M|L|XL" } ],
#     "labels_csv": "comma,separated",      # shared; parent prepends "epic"
#     "projects": {
#       "enabled": true,                    # default: true
#       "project_number": 6,
#       "owner": "{owner}",
#       "status": "Todo",                   # default: "Todo"
#       "priority": "High|Medium|Low"
#     },
#     "repo": "cc-rite-workflow",           # for link-sub-issue.sh
#     "workdir": "path"                     # optional; rm -rf'd on EXIT if a dir
#   }
#
# Output (stdout) — marker fidelity contract with create.md ステップ 5.5 Step 2/3.
# These three CONTEXT markers + the raw fetch_output MUST be emitted verbatim
# so the caller can literal-parse PARENT_ISSUE_NUMBER / SUB_ISSUE_NUMBERS and
# the fetch tmpfile paths:
#   [CONTEXT] PARENT_ISSUE_NUMBER=<n>
#   [CONTEXT] SUB_ISSUE_RESULT created=<n> failed=<n> link_failures=<n>
#   [CONTEXT] SUB_ISSUE_NUMBERS=<space-separated child numbers>
#   <fetch_output: original_length= / tmpfile_read= / tmpfile_write= lines>
#
# Exit codes:
#   0 = decomposition completed (per-sub create/link failures are non-blocking
#       and counted, NOT fatal — per the counting contract)
#   1 = fatal (missing/invalid spec, empty parent body, parent create failed)
#   2 = usage error
#
# NOTE: `set -e` is intentionally omitted. The Sub-Issue loop counts per-item
# create/link failures and continues (non-blocking, mirroring the original
# create.md inline block). `set -e` would abort on the first non-zero
# `create_rc` capture and break the counting contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_SCRIPT="$SCRIPT_DIR/create-issue-with-projects.sh"
LINK_SCRIPT="$SCRIPT_DIR/link-sub-issue.sh"
ISSUE_BODY_SCRIPT="$SCRIPT_DIR/../hooks/issue-body-safe-update.sh"

# --- Argument parsing ---
# 各値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、
# `shift 2` は $# を減らせず set -e 非設定 + `${2:-}` (nounset 非発火) の下で無限ループに
# 陥る。1 回目の shift で $# を確実に 0 にし、2 回目は no-op で安全に抜ける
# (--spec 欠落はループ後の必須チェックが exit 2 で検出)。
SPEC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) SPEC="${2:-}"; shift; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; echo "Usage: $0 --spec <spec.json>" >&2; exit 2 ;;
  esac
done

if [ -z "$SPEC" ]; then
  echo "Usage: $0 --spec <spec.json>" >&2
  exit 2
fi

for dep in "$CREATE_SCRIPT" "$ISSUE_BODY_SCRIPT"; do
  if [ ! -f "$dep" ]; then
    echo "ERROR: required helper not found: $dep" >&2
    exit 1
  fi
done

# --- Read spec (file path or stdin via "-") ---
if [ "$SPEC" = "-" ]; then
  SPEC_JSON=$(cat)
else
  if [ ! -f "$SPEC" ]; then
    echo "ERROR: spec file not found: $SPEC" >&2
    exit 1
  fi
  SPEC_JSON=$(cat "$SPEC")
fi

if ! printf '%s' "$SPEC_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: spec is not valid JSON: $SPEC" >&2
  exit 1
fi

spec_get() { printf '%s' "$SPEC_JSON" | jq -r "$1"; }

# --- Centralized cleanup: remove the caller-owned workdir on every exit path.
# A single EXIT/INT/TERM trap mirrors the original inline block's `trap 'rm -rf
# "$tmpdir"' EXIT INT TERM`. The fetch tmpfiles (tmpfile_read/tmpfile_write)
# live under /tmp/rite-issue-body-* — outside workdir — so they survive for the
# caller's apply step. ---
workdir=$(spec_get '.workdir // empty')
# Per-iteration helper stderr is captured to this scratch file so it is never
# merged into the helper's stdout JSON: create-issue-with-projects.sh
# emits `ERROR: ...` on stderr while still printing valid JSON on stdout with
# exit 0 on partial-Projects failures. A `2>&1` capture would splice
# that ERROR ahead of the JSON and break the downstream `jq -r .issue_number`,
# silently miscounting an actually-created Sub-Issue as failed (counting contract break).
helper_err_file=$(mktemp "${TMPDIR:-/tmp}/rite-decompose-helper-err.XXXXXX") \
  || helper_err_file="${TMPDIR:-/tmp}/rite-decompose-helper-err.$$"
trap 'rm -f "$helper_err_file"; if [ -n "$workdir" ] && [ -d "$workdir" ]; then rm -rf "$workdir"; fi' EXIT INT TERM

# --- Resolve shared projects fields ---
proj_enabled=$(spec_get '.projects.enabled // true')
project_number=$(spec_get '.projects.project_number')
owner=$(spec_get '.projects.owner')
status=$(spec_get '.projects.status // "Todo"')
priority=$(spec_get '.projects.priority // "Medium"')
repo=$(spec_get '.repo // empty')
labels_csv=$(spec_get '.labels_csv // ""')

# build_payload <title> <body_file> <labels_json> <complexity>
# Constructs the create-issue-with-projects.sh JSON. Identical shape to the
# original inline `jq -n` calls (issue / projects / options).
build_payload() {
  jq -n \
    --arg title "$1" \
    --arg body_file "$2" \
    --argjson labels "$3" \
    --argjson enabled "$proj_enabled" \
    --argjson project_number "$project_number" \
    --arg owner "$owner" \
    --arg status "$status" \
    --arg priority "$priority" \
    --arg complexity "$4" \
    --arg iter_mode "none" \
    --arg source "xl_decomposition" \
    '{
      issue: { title: $title, body_file: $body_file, labels: $labels },
      projects: {
        enabled: $enabled,
        project_number: $project_number,
        owner: $owner,
        status: $status,
        priority: $priority,
        complexity: $complexity,
        iteration: { mode: $iter_mode }
      },
      options: { source: $source, non_blocking_projects: true }
    }'
}

# ============================================================
# Step 5.3 親 Issue 作成
# ============================================================
parent_title=$(spec_get '.parent.title')
parent_body_file=$(spec_get '.parent.body_file')

[ -s "$parent_body_file" ] || { echo "ERROR: parent Issue body is empty" >&2; exit 1; }

# Parent labels = "epic" prepended to the shared CSV (gsub trims whitespace,
# select(length>0) drops empties — e.g. a trailing comma when labels_csv="").
labels_json=$(printf '%s' "epic,${labels_csv}" | jq -R 'split(",") | map(select(length>0) | gsub("^\\s+|\\s+$"; ""))')

# 各ラベルを冪等に事前作成する (`gh issue create --label X` は X 未存在時に fail するため。
# skills/issue-create/SKILL.md ステップ 4.3 と同パターン)。親 labels (epic + labels_csv) は
# sub-issue labels (labels_csv のみ) の上位集合のため、ここでの 1 回で Step 5.4 の分もカバーする。
# 既存ラベル / 権限不足の失敗は無視して続行し、真の失敗は gh issue create 側で surface される。
while IFS= read -r label; do
  [ -z "$label" ] && continue
  gh label create "$label" --description "auto-created by rite issue-create" --color "ededed" 2>/dev/null || true
done < <(printf '%s\n' "$labels_json" | jq -r '.[]')

parent_result=$(bash "$CREATE_SCRIPT" "$(build_payload "$parent_title" "$parent_body_file" "$labels_json" "XL")") || {
  echo "ERROR: 親 Issue 作成失敗" >&2
  exit 1
}

parent_issue_number=$(printf '%s' "$parent_result" | jq -r '.issue_number // empty')
[ -z "$parent_issue_number" ] && { echo "ERROR: 親 Issue の issue_number 取得失敗: $parent_result" >&2; exit 1; }

# ============================================================
# Step 5.4 Sub-Issue 一括作成
# ============================================================
created_count=0
failed_count=0
link_failures=0
created_numbers=()
expected_sub_count=$(printf '%s' "$SPEC_JSON" | jq '.sub_issues | length')
# labels_csv を --arg で渡し stdin を経由しない。`jq -R` 方式は空の labels_csv に対し
# 空出力 + exit 0 を返すため sub_labels_json="" となり、直後の `--argjson labels ""` が
# invalid JSON で落ちる一方 `|| "[]"` ガードは exit 0 なので発火しない（空ラベルでの
# 分解が必ず失敗する境界バグになる）。--arg なら "" → [] が常に有効な JSON 配列として得られ、
# 非空 CSV も同じ結果になる。ガードは malformed 入力への保険として残す。
sub_labels_json=$(jq -cn --arg csv "$labels_csv" '$csv | split(",") | map(select(length>0) | gsub("^\\s+|\\s+$"; ""))' 2>/dev/null) || {
  echo "WARNING: labels_csv の jq パースに失敗。labels を空で続行: $labels_csv" >&2
  sub_labels_json="[]"
}

while IFS= read -r sub_json; do
  sub_title=$(printf '%s' "$sub_json" | jq -r '.title')
  sub_body_file=$(printf '%s' "$sub_json" | jq -r '.body_file')
  sub_complexity=$(printf '%s' "$sub_json" | jq -r '.complexity')
  if [ ! -s "$sub_body_file" ]; then
    echo "WARNING: Sub-Issue '$sub_title' body が空、skip" >&2
    failed_count=$((failed_count + 1))
  else
    # stderr を helper_err_file へ分離する。`2>&1` だと partial-Projects
    # 失敗時の stderr ERROR が stdout JSON 前方へ混入し、直後の jq parse が壊れて
    # 実際には作成された Sub-Issue を failed_count に誤カウントする (silent data loss)。
    sub_result=$(bash "$CREATE_SCRIPT" "$(build_payload "$sub_title" "$sub_body_file" "$sub_labels_json" "$sub_complexity")" 2>"$helper_err_file")
    create_rc=$?
    if [ $create_rc -ne 0 ]; then
      create_err=$(cat "$helper_err_file" 2>/dev/null)
      echo "WARNING: Sub-Issue '$sub_title' の作成に失敗: ${sub_result}${create_err:+ | stderr: $create_err}" >&2
      failed_count=$((failed_count + 1))
    else
      sub_number=$(printf '%s' "$sub_result" | jq -r '.issue_number // empty')
      if [ -z "$sub_number" ] || [ "$sub_number" = "null" ]; then
        echo "WARNING: Sub-Issue '$sub_title' の result に issue_number 無し: $sub_result" >&2
        failed_count=$((failed_count + 1))
      else
        # 成功時でも create-issue-with-projects.sh は partial-Projects 失敗を
        # exit 0 + JSON の .warnings[] で返す。jq parse が clean に
        # なった今、その warning を silent に捨てず link-warning と同形式で surface
        # する (Wiki: stderr ノイズは truncate でなく selective surface で解く)。
        printf '%s' "$sub_result" | jq -r '.warnings[]?' 2>/dev/null \
          | while read -r w; do echo "⚠️ Sub-Issue #$sub_number 作成時の警告: $w" >&2; done
        # Sub-issues API linkage — canonical SoT [`sub-issue-link-handler.md`](../references/sub-issue-link-handler.md)
        # Variant B (counting). link-sub-issue.sh は非 blocking failure 時に exit 0 + status="failed"
        # を返す契約のため、bash exit code ではなく JSON stdout の `.status` を inspect すること。
        # ⚠️ DRIFT 警告: 本 case 文を編集する際は SoT `references/sub-issue-link-handler.md`
        # Variant B を同時に更新する責務がある。
        # link-sub-issue.sh normally returns JSON on stdout (status="failed" for
        # non-blocking failures). Only construct fallback JSON on fatal exit.
        # Build it via `jq -n --arg` so embedded `"` in stderr cannot break the
        # JSON the caller will parse.
        # 対称修正。link-sub-issue.sh は
        # 現状 stderr に書かないため JSON 破損は起きないが、create と同じく stderr を
        # helper_err_file へ分離して将来の regression を防ぐ。fatal exit 時の fallback err は
        # stdout (link_result) と stderr を結合し、診断情報を取りこぼさない。
        link_result=$(bash "$LINK_SCRIPT" \
            "$owner" "$repo" "$parent_issue_number" "$sub_number" 2>"$helper_err_file") || link_result=$(jq -n \
              --arg err "${link_result}$(cat "$helper_err_file" 2>/dev/null)" \
              '{status:"failed",message:"link-sub-issue.sh fatal exit",warnings:[$err]}')
        link_status=$(printf '%s' "$link_result" | jq -r '.status // "failed"' 2>/dev/null || echo "failed")
        link_msg=$(printf '%s' "$link_result" | jq -r '.message // ""' 2>/dev/null || echo "")
        case "$link_status" in
          ok|already-linked)
            echo "✅ $link_msg"
            ;;
          failed)
            printf '%s' "$link_result" | jq -r '.warnings[]?' 2>/dev/null \
              | while read -r w; do echo "⚠️ $w" >&2; done
            echo "⚠️ Sub-issues API linkage failed for #$sub_number; body meta fallback in place" >&2
            link_failures=$((link_failures + 1))
            ;;
          *)
            # 未知 status を silent 通過させない
            echo "⚠️ Unexpected link status '$link_status' for #$sub_number (msg: $link_msg)" >&2
            link_failures=$((link_failures + 1))
            ;;
        esac

        created_numbers+=("$sub_number")
        created_count=$((created_count + 1))
      fi
    fi
  fi
done < <(printf '%s' "$SPEC_JSON" | jq -c '.sub_issues[]')

# ============================================================
# zero-iteration guard (silent placeholder expansion failure 検出)
# ============================================================
if [ "$created_count" -eq 0 ] && [ "$expected_sub_count" -gt 0 ]; then
  echo "WARNING: Expected $expected_sub_count Sub-Issues but created 0 (placeholder expansion or shell loop failure). parent=#$parent_issue_number" >&2
fi

# ============================================================
# Loop-abort sanity check: if created+failed != expected, the loop dropped
# iterations to an unexpected shell error (set -e upstream, jq crash, signal),
# and the partial state would otherwise go silently missing from the report.
# ============================================================
loop_processed=$((created_count + failed_count))
if [ "$loop_processed" -ne "$expected_sub_count" ] && [ "$expected_sub_count" -gt 0 ]; then
  echo "WARNING: Loop processed $loop_processed of $expected_sub_count expected Sub-Issues (created=$created_count, failed=$failed_count). Possible mid-loop abort. parent=#$parent_issue_number" >&2
fi

# ============================================================
# Step 5.5 Step 1: fetch (親 Issue body の取得)
# ============================================================
fetch_output=$(bash "$ISSUE_BODY_SCRIPT" fetch --issue "$parent_issue_number" --parent 2>&1) || fetch_output=""

# ============================================================
# CONTEXT markers — 後続 Step 2 (LLM 編集) と Step 3 (apply) に値を受け渡す
# ============================================================
echo "[CONTEXT] PARENT_ISSUE_NUMBER=$parent_issue_number"
echo "[CONTEXT] SUB_ISSUE_RESULT created=$created_count failed=$failed_count link_failures=$link_failures"
echo "[CONTEXT] SUB_ISSUE_NUMBERS=${created_numbers[*]:-}"
# tmpfile_read=, tmpfile_write=, original_length= は fetch_output に含まれる
printf '%s\n' "$fetch_output"
