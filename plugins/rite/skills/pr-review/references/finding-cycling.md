# Finding Cycling Detection — Quality Signal SoT

> **Source of Truth**: 本ファイルは Review/Fix ループにおける **Finding Cycling Detection** (review サイクル間の同一 finding 持続検出) と **Quality Signal 3 & 4 Detection** の SoT である。実際の caller は `skills/pr-review/SKILL.md` (Signal 3) と `skills/fix/SKILL.md` (Signal 2) であり、`skills/iterate/SKILL.md` の review-fix loop 内で間接的に実行される。本ファイルは cycle 間比較の判断基準 / Quality Signal markers / split bash / 4-option AskUserQuestion の標準形を定義する。

## 概要 — Quality Signal 1-4 の位置付け

review-fix loop には、cycle 数に応じてレビュー品質を段階的に緩める **cycle-count-based degradation は存在しない** 設計 (旧 cycle-count monitor は完全に削除済み)。品質判定の escalation は以下 **4 つの quality signal** で行う。（これとは別レイヤで、非収束ループの最終安全網として `safety.max_review_cycles` の cycle 上限サーキットブレーカー = #1701 が存在するが、これは品質を緩めず cycle 上限で停止/ユーザー委譲するだけで、下記 signal 群とは独立に両立する。詳細は `skills/iterate/SKILL.md` 設計判断を参照。）

| Signal | 検出 phase | 内容 |
|--------|-----------|------|
| **Signal 1** — 同一 finding cycling | Phase 5.4.1.0 (本 reference) | review サイクル間で同一内容の finding が残存 |
| **Signal 2** — root-cause-missing fix | `fix.md` ステップ 3.2.1 | 根本原因を捉えない fix がコミットされる経路の検出 |
| **Signal 3** — cross-validation disagreement | `pr-review.md` ステップ 5.2 + debate fails | レビュアー間の disagreement が debate でも解消されない |
| **Signal 4** — finding quality gate failure | `_reviewer-base.md` Finding Quality Guardrail | reviewer 自身が self-degraded 状態を宣言 |

Signal 1 は Phase 5.4.1.0 (本 reference §1)、Signal 3 と Signal 4 は Phase 5.4.3 Step 3.1 (本 reference §2) で検出する。4 signal すべてに対して **同じ 4-option AskUserQuestion** (本 reference §3) で escalation する。

設計判断: **品質 escalation の機構**は 4 quality signal のみとし、cycle 数に応じてレビュー品質を段階的に緩める iteration counter（progressive relaxation / degradation）は導入しない。過去に明示的に削除した cycle-count-based degradation の再発を防ぐため。ただしこれは「品質緩和の禁止」であり、非収束ループの最終安全網としての cycle 上限サーキットブレーカー（`safety.max_review_cycles`、#1701）とは別レイヤで両立する — 後者は品質を一切緩めず、上限到達で機械的に停止（対話は停止通知、`/rite:batch-run` バッチは failed 遷移）するだけで、本 signal 群の quality escalation を代替も抑制もしない。

## §1 — Phase 5.4.1.0 Finding Cycling Detection

`review.loop.convergence_monitoring` が enabled (default: `true`) で、PR に先行する `📜 rite レビュー結果` コメントがある時に発火する。Signal 1 of 4。

### Design note

旧 cycle-count-based convergence monitor を **置き換え** た monitor。cycle は数えない。**2 つのレビュー結果を比べ、同じ指摘が残っているかを semantic に判断** し、cycle 間で同一内容の finding が 1 度でも再出現すれば escalate する。ハッシュや類似度スコアによる機械判定は使わない — 文言のリライトで同一指摘を取りこぼす硬直があるため。

### Step 1 — Fetch 2 most recent review comments

直近の 2 件の `📜 rite レビュー結果` PR コメント (this cycle + previous cycle) を取得。2 件未満なら skip (比較対象なし):

```bash
# ⚠️ gh api --paginate + --jq は各ページ独立適用のため併用できない
# (gh の仕様: --paginate は複数ページを stdout に stream 出力し、--jq は各ページに独立適用される)。
# 代わりに --paginate --slurp で全ページを単一 JSON array に統合し、外側の jq で filter する。
# pipefail を有効化して pipeline 途中の失敗も捕捉する。
set -o pipefail
pr_number="{pr_number}"
gh_err=$(mktemp "${TMPDIR:-/tmp}/rite-fc-gh-err-XXXXXX" 2>/dev/null) || gh_err=""
if ! comments=$(gh api --paginate --slurp repos/{owner}/{repo}/issues/${pr_number}/comments 2>"${gh_err:-/dev/null}" \
    | jq 'add | [.[] | select(.body | contains("📜 rite レビュー結果"))] | .[-2:]'); then
  echo "WARNING: gh api による PR コメント取得または jq filter に失敗。cycling check を skip します (fail-open)" >&2
  [ -n "$gh_err" ] && [ -s "$gh_err" ] && head -5 "$gh_err" | sed 's/^/  /' >&2
  [ -n "$gh_err" ] && rm -f "$gh_err"
  set +o pipefail
  echo "[CONTEXT] CYCLING_CHECK skip (gh api or jq failure)"
  exit 0
fi
[ -n "$gh_err" ] && rm -f "$gh_err"
set +o pipefail

count=$(printf '%s' "$comments" | jq 'length' 2>/dev/null || echo 0)
if [ "${count:-0}" -lt 2 ]; then
  echo "[CONTEXT] CYCLING_CHECK skip (only ${count:-0} review comment(s) on PR)"
  exit 0
fi
```

### Step 2 — Compare the two review results semantically

取得した 2 件のレビュー結果 (previous cycle / this cycle) の Markdown body から finding を読み取り、**前サイクルの各指摘が今サイクルにも残存しているか** を判断する。ハッシュや類似度計算は使わない — LLM が指摘の内容そのものを比較する。

**同一判断の基準**:

- 文言・行番号・severity 表記が変わっていても、**同じファイルの同じ性質の欠陥** を指しているなら同一指摘とみなす（指摘文言の大幅リライトも取りこぼさない）
- 同じファイルでも **別の欠陥**（別の関数・別の失敗モード）を指すなら別指摘
- 前サイクルの指摘が fix により解消され、その fix が **新たに生んだ** 指摘は残存ではない（新規 finding として扱う）
- **判断がつかない場合は「残存」側に倒す**（見逃しより誤検出を許容 — escalation は AskUserQuestion で人間が最終判断するため false positive のコストは低い）

### Step 3 — Judge cycling

| Condition | Signal |
|-----------|--------|
| 残存指摘なし | **Healthy progress** — finding が残存していない、review を normal continue |
| 残存指摘 1 件以上 | **Signal 1 fired (same-finding cycling)** — escalate |

context marker を emit:

```
[CONTEXT] FINDING_CYCLING hits={n} total_current={m} total_previous={p}
```

`hits` は残存と判断した指摘数、`total_current` / `total_previous` は各サイクルの指摘総数。

### Step 4 — Escalate via AskUserQuestion (hits >= 1 のみ)

```
品質シグナル発火: 同一 finding が 2 サイクル以上残存しています（{n} 件）。

継続サイクル数ではなく、指摘そのものの循環を検出しています。
```

4-option AskUserQuestion を提示する (§3 共通 4-option の節を参照)。

### Step 5 — Proceed to review invocation

Step 4 routing が「本 PR 内で再試行」または「別 Issue として切り出す (split bash 実行後)」の場合のみ実行:

```
Invoke `skill: "rite:pr-review"`.
```

review が return したら `skills/iterate/SKILL.md` review-fix loop の fix side へ進む。

## §2 — Quality Signal 3 & 4 Detection (After Review)

review が return した後、最新の `📜 rite レビュー結果` PR コメント **AND** conversation context を以下 marker で grep:

| Marker | Source | Signal |
|--------|--------|--------|
| `[CONTEXT] QUALITY_SIGNAL=3_cross_validation_disagreement` | `pr-review.md` ステップ 5.2 (cross-validation disagreement + debate fails) | Signal 3 — cross-validation disagreement |
| `### Reviewer self-assessment` section + `Status: degraded (quality-gate failure)` (review body 内) | 任意の reviewer 出力 (`_reviewer-base.md` Finding Quality Guardrail 経由) | Signal 4 — reviewer self-degraded |

### Detection bash (Signal 4)

```bash
latest_review=$(gh api repos/{owner}/{repo}/issues/{pr_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | last | .body' 2>/dev/null) || latest_review=""
signal4_hit=0
if printf '%s' "$latest_review" | grep -qE '^### Reviewer self-assessment'; then
  if printf '%s' "$latest_review" | grep -qE '^Status: degraded'; then
    signal4_hit=1
  fi
fi
echo "[CONTEXT] SIGNAL_4_HIT=$signal4_hit"
```

Signal 3 は `pr-review.md` が stderr に emit 済みのため、conversation context を grep するだけで検出可能 (本 phase で再取得は不要)。

### Routing

Signal 3 または Signal 4 が発火した場合、**§3 の 4-option AskUserQuestion** を提示し、§3 の branching table を適用する。いずれも発火しなかった場合は Phase 5.4.3 Step 4 (review result pattern routing) に直接進む。

## §3 — 共通 4-option AskUserQuestion (Signal 1 / 3 / 4 共用)

> `-R {owner_repo}` は [Owner/Repo Resolution](../../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）をリテラル置換する（SSH host alias 環境対応）。

| Option | Action |
|--------|--------|
| 本 PR 内で再試行（推奨） | review invocation (Phase 5.4.1.0 §1 Step 5 / Phase 5.4.3 Step 4) へ進む。再発火しても本 phase が再 escalate する (次サイクル経路) |
| 別 Issue として切り出す | §4 の split bash で persistent finding を tracking Issue 化、work memory に split メモを残し、review invocation へ進む |
| PR を取り下げる | `gh pr close {pr_number} -R {owner_repo}` を実行、review invocation を skip、Phase 5.6 (completion report) へ jump (workflow 終端) |
| 手動レビューへエスカレーション | review invocation を skip、review-fix loop を抜けて Phase 5.5 (Ready for Review) へ jump (人手レビューに引継ぎ) |

### Branching after user selection

| Selection | Next |
|-----------|------|
| 本 PR 内で再試行 | review invocation 実行 |
| 別 Issue として切り出す | §4 の split bash 実行 → review invocation 実行 |
| PR を取り下げる | `gh pr close {pr_number} -R {owner_repo}` → Phase 5.6 (review invocation skip) |
| 手動レビューへエスカレーション | Phase 5.5 へ jump (review invocation skip) |

## §4 — Split bash for "別 Issue として切り出す"

**Important**: 以下の bash ブロックは **単一の Bash tool 呼び出し** で実行すること。本ブロックは一時ファイル cleanup の `trap 'rm -f "$tmpfile"' EXIT` と、write / empty / empty-result の各失敗で中断する `exit 1` ガード および empty-url 失敗で中断する `exit 1` ガード を含む。複数の Bash 呼び出しに分割すると trap が中間状態で発火して cleanup 契約が崩れ、`exit 1` も後続呼び出しへ伝播せず guard が機能しなくなる (先例 pr-review.md ステップ 7.4.2 の single-invocation 注記と同契約)。

**Placeholder value sources** (Claude はスクリプト生成前に必ず以下のソースから値を取得してプレースホルダーを置換すること。これらはシェル変数ではない):

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{persistent_finding_body}` | 持続した finding の body (review 結果コンテキスト) | (finding 本文) |
| `{short_summary}` | finding の要約 (動詞始まり、50 文字以内) | `fix XYZ guard` |
| `{pr_number}` | 現在の PR 番号 (review-fix ループのコンテキスト) | `1253` |
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `B16B1RD` |
| `{plugin_root}` | [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version) | `/home/user/.claude/plugins/rite` |

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

if ! cat <<'BODY_EOF' > "$tmpfile"
## 概要

レビューサイクル中に持続した finding を別 Issue として切り出しました (Quality Signal 1 発火)。

## 元の finding
{persistent_finding_body}

## 関連

- 元の PR: #{pr_number}
BODY_EOF
then
  echo "ERROR: Issue 本文テンプレートの一時ファイル書き込みに失敗" >&2
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=body_tmpfile_write_failure" >&2
  exit 1
fi

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue 本文の生成に失敗" >&2
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=empty_body_tmpfile" >&2
  exit 1
fi

# jq -n の出力を stdin で create-issue-with-projects.sh に渡す (skills/pr-review/SKILL.md と同じ pipe 形式、入れ子 $() を回避)
result=$(jq -n \
  --arg title "review-split: {short_summary}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg complexity "S" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: "none" }
    },
    options: { source: "fingerprint_split", non_blocking_projects: true }
  }' | bash {plugin_root}/scripts/create-issue-with-projects.sh)

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=empty_script_result" >&2
  exit 1
fi
new_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
# create-issue-with-projects.sh は失敗時も非空の failed JSON (issue_url=="") を emit してから
# exit する契約のため、上の empty-result ガードは通過する。空 URL のまま ✅ を echo する silent
# failure を防ぐため issue_url を guard し warnings[] を surface する (先例 pr-review.md ステップ
# 7.4.2 の post-result handling を移植)
if [ -z "$new_issue_url" ] || [ "$new_issue_url" = "null" ]; then
  echo "ERROR: 循環 finding の Issue 化に失敗しました (issue_url が空)" >&2
  printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w" >&2; done
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=empty_issue_url" >&2
  exit 1
fi
echo "✅ 循環 finding を #$(printf '%s' "$result" | jq -r '.issue_number') として切り出しました: $new_issue_url"
# Issue 作成は成功。Projects 登録の partial/failed と warnings[] を surface する (silent にしない)
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
if [ "$project_reg" = "partial" ] || [ "$project_reg" = "failed" ]; then
  echo "⚠️ Projects 登録が完全に完了しませんでした（status: $project_reg）。手動登録: gh project item-add {project_number} --owner {owner} --url $new_issue_url"
fi
```

Signal 3 / Signal 4 由来の split では title prefix を `review-split:` のまま (Signal 1 と統一)、body の冒頭 "Quality Signal 1 発火" を実発火 signal 名に置換する。`options.source` も `fingerprint_split` → `quality_signal_3_split` / `quality_signal_4_split` に変更する（enum 値は `create-issue-with-projects.sh` の機械契約のため `fingerprint_split` の名称を維持している — Signal 1 由来の split を意味する歴史的名称）。
