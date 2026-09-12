### 7.2-7.3 推奨決定 + User Confirmation

0 件: ステップ 7 を skip（**7.7 も skip**）。1+: 下記モード表で分岐する。
**モード判定**: ステップ 3.3 の `PR_REVIEW_IN_E2E` を読む。欠落は `false`（確認を出す側）。
rationale: design-rationale.md#phase7-askuser-evidence

| `PR_REVIEW_IN_E2E` | 分岐 |
|---|---|
| `true` | E2E / batch。Decision Log への記録である候補は可逆なので質問せず推奨で処理する。別 Issue 作成・本 PR への scope 追加・無視だけ `AskUserQuestion` |
| `false` | 対話。全候補を `AskUserQuestion` で確認する。**回答を得るまで 7.4（Decision Log 追記・Issue 作成）を実行しない** |

**推奨機械決定表**（裁量禁止）:

| 候補の性質 | 推奨 |
|-----------|------|
| Source B（推奨事項）由来、または Source A で `内容` に `Likelihood-Evidence:` prefix が無い（Hypothetical） | Decision Log に記録 |
| Source A かつ `内容` に `Likelihood-Evidence:` prefix がある（Observed / Demonstrable。MEDIUM+ は 7.1 の抽出条件で担保済み） | 別 Issue 作成 |

`{source_issue_number}`（ステップ 7.1 で解決）が空の候補は「Decision Log に記録」選択肢自体を非表示にする（3 択: 別 Issue 作成 / 本 PR で対応 / 無視。この場合は推奨を付与しない）。

**MANDATORY — ステップ 7.2 disposition-entry sentinel emit**:

sentinel は **確認完了後**（対話: 選択値を得た後 / E2E 自動: 推奨機械決定表の判定を確定した後）に emit する。marker 名は変えない。`mode=` と `choice=` と `reason=` を必須とする（自動 Decision Log 経路でも emit する）。**7.4 は本 sentinel の後でのみ実行する**:

```bash
# LLM (Claude) は以下を Bash tool で実行する前に literal 置換すること:
# - {N} → ステップ 7.1 で抽出した candidate 総数 (Source A + Source B、dedup 後の正整数)
# - {iteration_id} → ステップ 7.1 で生成した一意 ID (例: pr_number-$(date +%s) 形式)
# - {mode} → ask | auto
# - {choice} → 対話の選択値（自動は decision_log）。空禁止
# - {reason} → user_answer | reversible_decision_log
# Bash 変数 (${candidate_count} 等) は Bash tool 呼び出し間で継承されないため使用不可
echo "[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}; iteration_id={iteration_id}; mode={mode}; choice={choice}; reason={reason}" >&2
```

`{N}` は 7.1 の合算。`{iteration_id}` は iteration 一意（推奨: `${pr_number}-$(date +%s)`）。7.7 / 8.0.2 が読む。stderr に MUST emit。
- 対話: `mode=ask; choice={ユーザー選択}; reason=user_answer`
- E2E 自動 Decision Log: `mode=auto; choice=decision_log; reason=reversible_decision_log`
- E2E で質問した候補: `mode=ask; choice={ユーザー選択}; reason=user_answer`

判定不能時は確認を出す側へ倒す。Issue 作成を自動決定しない。

**AskUserQuestion prompt text**:

```
以下は PR #{N} の diff とは無関係と reviewer が判定した問題です。各候補について対応方針を選んでください: [Decision Log に記録 / 別 Issue 作成 / 本 PR で対応 / 無視]（先頭 = 推奨機械決定表による推奨。候補ごとに順序を入れ替え、推奨に "(Recommended)" を付与する）
```

**Candidate display format:**

| # | Source | ファイル | 内容 | 重要度 | Priority | 推奨 |
|---|--------|---------|------|--------|----------|------|
| 1 | 指摘 | {file:line} | {content} | {severity} | {mapped_priority} | {推奨機械決定表より: Decision Log に記録 / 別 Issue 作成} |
| 2 | 推奨 | {file:line or "—"} | {content} | — | Medium | Decision Log に記録 |

**Default values for recommendation-based candidates** (Source B):
- **Priority**: `Medium`
- **Complexity**: `S`
- **Severity in Issue body**: `推奨事項（重要度なし）`
- **File:line**: Use mentioned path if available; otherwise `特定ファイルなし`

**E2E**: Decision Log 推奨は自動。Issue 作成・scope 追加・無視は明示承認。Issue 作成を自動決定しない。対話は 7.2-7.3 モード表のとおり確認後にのみ 7.4 へ進む。

「別 Issue 作成」で既存 Issue #{N} へ新規作成を見送る場合の実行は 7.4 表。CLOSED なら当該候補について 7.2 の既存 4 択を再掲する（新規の disposition 質問種別は出さない）。
rationale: design-rationale.md#assignee-handoff-comment

### 7.4 Disposition Execution

ステップ 7.2-7.3 で確定した候補ごとの選択に応じて分岐する:

| User selection | Action |
|-----------------|--------|
| 別 Issue 作成 | 新規作成なら 7.4.1-7.4.2。既存 Issue #{N} への見送りなら 7.4.4 の後に 7.4.3。CLOSED なら投稿せず当該候補について 7.2 の既存 4 択を再掲し、`HANDOFF_COMMENT_REJECTED=1` のときは 7.4.3 / 7.5 へ進まない |
| Decision Log に記録 | 7.4.3（Decision Log Append）を実行。既存 Issue #{N} を引き受け先とする場合は 7.4.4 を先に必須実行し、記録のみで完了扱いにしない |
| 本 PR で対応 / 無視 | 追加のアクションなし（既存動作を維持） |

「別 Issue 作成」の新規作成枝は `gh issue create` + Projects 登録。`/rite:issue-create` Skill は使わない。見送りは 7.2 の 5 択ではなく「別 Issue 作成」の結果分岐である。
Issue creation failure reasons: (`body_tmpfile_write_failure` / `empty_body_tmpfile` / `empty_script_result`)

| reason | Description |
|--------|-------------|
| `body_tmpfile_write_failure` | Issue body heredoc write to tmpfile failed |
| `empty_body_tmpfile` | Issue body tmpfile is empty after write |
| `empty_script_result` | create-issue-with-projects.sh returned empty result |

#### 7.4.1 Generate Issue Title

```
{type}: {summary}
```

| Element | Generation Method |
|---------|-------------------|
| `{type}` | Inferred from the finding content (`fix`, `feat`, `refactor`, `docs`, etc.) |
| `{summary}` | Summarize the finding's description (50 characters or less, starting with a verb) |

#### 7.4.2 Create Issue via Common Script

> **Reference**: [Issue Creation with Projects Integration](../../../references/issue-create-with-projects.md)

heredoc の `{placeholder}` はスクリプト生成前に埋める（shell 変数ではない）。**単一 Bash invocation**。
Priority: CRITICAL→High, HIGH→Medium, MEDIUM/LOW-MEDIUM/LOW→Low, Source B→Medium。
Complexity: XS = 単箇所、S = 1–2 ファイル。

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `{owner}` |
| `{iteration_mode}` | `rite-config.yml` → `iteration.enabled` が `true` かつ `iteration.auto_assign` が `true` なら `"auto"`、それ以外は `"none"` | `"none"` |
| `{plugin_root}` | [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version) | `/home/user/.claude/plugins/rite` |

**⚠️ Projects 登録失敗時の警告表示（必須）**: スクリプト実行後、`project_registration` の値を必ず確認し、`"partial"` または `"failed"` の場合は以下を表示すること:

```
⚠️ Projects 登録が完全に完了しませんでした（status: {project_registration}）
手動登録: gh project item-add {project_number} --owner {owner} --url {created_issue_url}
```

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

if ! cat <<'BODY_EOF' > "$tmpfile"
## 概要

{description}

## 背景

この Issue は PR #{pr_number} のレビューで検出されたスコープ外の{source_label}から作成されました。

### 元のレビュー{source_label}
- **ファイル**: {file}:{line}
- **レビュアー**: {reviewer_type}
- **重要度**: {severity}
- **{source_label}内容**: {original_comment}

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

# jq -n の出力を stdin で create-issue-with-projects.sh に渡す。
# 旧コードは jq 出力をコマンド置換でスクリプト引数に入れ子展開していたが、パイプ + 1 段の
# コマンド置換に削減して malform 確率を下げた (入れ子コマンド置換の literal 例は除去済)。
result=$(jq -n \
 --arg title "{type}: {summary}" \
 --arg body_file "$tmpfile" \
 --argjson projects_enabled {projects_enabled} \
 --argjson project_number {project_number} \
 --arg owner "{owner}" \
 --arg priority "{priority}" \
 --arg complexity "{complexity}" \
 --arg iter_mode "{iteration_mode}" \
 '{
 issue: { title: $title, body_file: $body_file },
 projects: {
 enabled: $projects_enabled,
 project_number: $project_number,
 owner: $owner,
 status: "Todo",
 priority: $priority,
 complexity: $complexity,
 iteration: { mode: $iter_mode }
 },
 options: { source: "pr_review", non_blocking_projects: true }
 }' | bash {plugin_root}/scripts/create-issue-with-projects.sh)

if [ -z "$result" ]; then
 echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=empty_script_result" >&2
 exit 1
fi
created_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Source-aware placeholder values**: The `{source_label}` placeholder in the heredoc template above must be substituted based on the candidate source. When from Source A (findings), use `指摘`. When from Source B (recommendations), use `推奨事項`. The `{severity}` placeholder uses the actual severity for Source A, or `推奨事項（重要度なし）` for Source B. The `{file}:{line}` placeholder uses `特定ファイルなし` for Source B when no file path is mentioned.

**Error handling**:

| Error Case | Response |
|------------|----------|
| Script returns `issue_url: ""` | Display warning with error details. If remaining candidates exist, continue creating others |
| `project_registration: "partial"` or `"failed"` | Display warnings from result. Issue creation itself succeeded |

#### 7.4.3 Decision Log Append

「Decision Log に記録」は元 Issue の Section 9 へ 1 行 append。番号は Section 9 の内側（見出しの次行から `## ` / `---` / `</details>` まで）の最大 D-NN に 1 を足す。無ければ本文に Section 9 を新設して `D-01` を記録する。
`{decision}` / `{reason}` / `{impact}` を生成前に埋める。**候補ごとに単一 Bash invocation**。
rationale: design-rationale.md#decision-log-per-candidate

```bash
today=$(date +%Y-%m-%d)

# {decision}/{reason}/{impact} は reviewer/レビュー指摘由来の free-text。quoted heredoc
# (`<<'DECISION_EOF'`) でシェル展開を無害化してから読み込む（`line_content="{decision} ..."`
# のような直接代入は backtick / `$(` / `"` 混入時にコマンド置換・文字列破壊を招くため禁止）。
decision_tmp=$(mktemp)
if ! cat <<'DECISION_EOF' > "$decision_tmp"
{decision} / Reason: {reason} / Impact: {impact}
DECISION_EOF
then
  echo "ERROR: Decision Log 行テンプレートの一時ファイル書き込みに失敗" >&2
  echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=line_content_write_failure; issue={source_issue_number}" >&2
  rm -f "$decision_tmp"
  exit 1
fi
line_content=$(tr -d '\n' < "$decision_tmp")
rm -f "$decision_tmp"

body=$(gh issue view {source_issue_number} -R {owner_repo} --json body --jq '.body')

if [ -z "$body" ]; then
  echo "WARNING: 元 Issue #{source_issue_number} の body 取得に失敗。Decision Log 記録をスキップします" >&2
  echo "手動追記してください: - ${today} D-NN: ${line_content}" >&2
  echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=body_fetch_failure; issue={source_issue_number}" >&2
elif printf '%s' "$body" | grep -q '^## 9\. Decision Log'; then
  # 採番は Section 9 の内側だけを数える。本文の散文（転記されたレビュー指摘等）にある D-NN を
  # 数えると番号が飛ぶ。境界は下の追記 awk と同じ。awk の後ろにパイプを繋ぐと終了コードが
  # 失われるため、awk 単体の出力と終了コードを取ってから D-NN を抽出する。
  awk_rc=0
  section9=$(printf '%s\n' "$body" | awk '
    /^## 9\. Decision Log/ { in_section=1; next }
    in_section && (/^## / || /^---[[:space:]]*$/ || /^<\/details>/) { in_section=0 }
    in_section { print }
  ') || awk_rc=$?
  # `(^|[^A-Za-z])D-[0-9]+` で先頭境界を要求し、`CARD-12` 等の部分文字列誤マッチを防ぐ
  max_d=$(printf '%s\n' "$section9" | grep -oE '(^|[^A-Za-z])D-[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
  [ -n "$max_d" ] || max_d=0
  # 10# で 10 進固定。先頭ゼロ付き 08/09 を 8 進と解釈させない
  next_num=$((10#$max_d + 1))
  next_d=$(printf 'D-%02d' "$next_num")
  # 走査が異常終了した番号は信用できないため、手動追記の案内でも番号を確定させない
  [ "$awk_rc" -eq 0 ] || next_d=D-NN
  new_line="- ${today} ${next_d}: ${line_content}"

  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT
  # `awk -v` はバックスラッシュエスケープを解釈するため（`\n`→改行, `\t`→タブ, `\d`→`d` 等）、
  # $new_line に正規表現例・Windows パス等 backslash を含む free-text が入ると「1 行 append」
  # 不変条件（AC-3）を破って複数行に分割されうる。ENVIRON はエスケープ解釈しないため経由する。
  printf '%s\n' "$body" | NEW_LINE="$new_line" awk '
    /^## 9\. Decision Log/ { print; in_section=1; next }
    in_section && (/^## / || /^---[[:space:]]*$/ || /^<\/details>/) { print ENVIRON["NEW_LINE"]; print; in_section=0; next }
    { print }
    END { if (in_section) print ENVIRON["NEW_LINE"] }
  ' > "$tmpfile" || awk_rc=$?

  # awk 異常終了時（部分出力）で body 全体を切り詰めたまま上書きしないよう、exit code も検査する
  # （full-body PATCH のため `[ -s ]` の非空チェックだけでは途中終了の部分出力を見逃す）。
  if [ "$awk_rc" -eq 0 ] && [ -s "$tmpfile" ] && gh issue edit {source_issue_number} -R {owner_repo} --body-file "$tmpfile"; then
    echo "[CONTEXT] DECISION_LOG_APPENDED=1; issue={source_issue_number}; entry=$next_d"
    echo "記録: $new_line"
  else
    echo "WARNING: 元 Issue #{source_issue_number} への Decision Log append に失敗しました" >&2
    echo "手動追記してください: $new_line" >&2
    echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=gh_edit_failure; issue={source_issue_number}" >&2
  fi
else
  # Section 9 が無い Issue → 本文に Section 9 を新設して D-01 を記録する。
  # 置き場所は Implementation Contract の </details> の直前（pr-create が読む契約層の内側）。
  # 無ければ署名行だけが後に続くフッター区切り `---` の直前、どちらも無ければ本文末尾。
  # 本文の自由記述に混ざる `---` / `</details>` は境界とみなさない。挿入行以外は 1 文字も変えない。
  new_line="- ${today} D-01: ${line_content}"

  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT
  awk_rc=0
  # 1 回目で挿入する行番号を決め（0 は本文末尾）、2 回目でその行の直前に挿入する
  insert_at=$(printf '%s\n' "$body" | awk '
    /^<summary>Implementation Contract/ { contract = 1 }
    contract && /^<\/details>/ { details = NR }
    /^---[[:space:]]*$/ { rule = NR; footer = 1; next }
    rule && !/^[[:space:]]*$/ && !/^🤖 / { footer = 0 }
    END { print (details ? details : ((rule && footer) ? rule : 0)) }
  ') || awk_rc=$?
  printf '%s\n' "$body" | NEW_LINE="$new_line" INSERT_AT="$insert_at" awk '
    NR == ENVIRON["INSERT_AT"] + 0 { print "## 9. Decision Log"; print ""; print ENVIRON["NEW_LINE"]; print "" }
    { print }
    END { if (ENVIRON["INSERT_AT"] + 0 == 0) { print ""; print "## 9. Decision Log"; print ""; print ENVIRON["NEW_LINE"] } }
  ' > "$tmpfile" || awk_rc=$?

  # 既存 Section 9 分岐と同じく、awk の異常終了（部分出力）と空出力のどちらでも書き戻さない。
  if [ "$awk_rc" -eq 0 ] && [ -s "$tmpfile" ] && gh issue edit {source_issue_number} -R {owner_repo} --body-file "$tmpfile"; then
    echo "[CONTEXT] DECISION_LOG_APPENDED=1; issue={source_issue_number}; entry=D-01; section=created"
    echo "記録: $new_line"
  else
    echo "WARNING: 元 Issue #{source_issue_number} への Decision Log append に失敗しました" >&2
    echo "手動追記してください: $new_line" >&2
    echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=gh_edit_failure; issue={source_issue_number}" >&2
  fi
fi
```

Decision Log append failure reasons: (`line_content_write_failure` / `body_fetch_failure` / `gh_edit_failure`)

| reason | Description |
|--------|-------------|
| `line_content_write_failure` | Decision Log 行テンプレートの一時ファイル書き込みに失敗 |
| `body_fetch_failure` | 元 Issue の body 取得（`gh issue view`）に失敗 |
| `gh_edit_failure` | Section 9 の採番走査・行挿入、または Section 9 新設時の本文組み立て（awk）の異常終了 / 空出力、または `gh issue edit` 適用に失敗 |

失敗は non-blocking。WARNING + 記録予定行を出し、7.5-7.6 の completion report にも転記する（AC-5）。

#### 7.4.4 引き受け先 Issue への申し送りコメント

既存 Issue `{assignee_issue}` を引き受け先とする候補ごとに実行する。Decision Log のみでは完了にしない。
rationale: design-rationale.md#assignee-handoff-comment

heredoc の `{placeholder}` はスクリプト生成前に埋める（shell 変数ではない）。**候補ごとに単一 Bash invocation**。

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{assignee_issue}` | 見送り先として確定した既存 Issue 番号。`{source_issue_number}`（元 Issue）および 7.2 sentinel の `{N}`（candidate 総数）と混同しない | `2340` |
| `{owner_repo}` | [Owner/Repo Resolution](../../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) の slash 形式 | `owner/repo` |
| `{pr_number}` | 本レビューの PR 番号 | `42` |
| `{summary}` | 当該候補の指摘要約 | （1 段落） |
| `{check_points}` | 引き受け先で着手するときの確認点 | （箇条書き） |

1. `gh issue view {assignee_issue} -R {owner_repo} --json state --jq '.state'`
2. `OPEN` 以外 → 投稿しない。`[CONTEXT] HANDOFF_COMMENT_REJECTED=1; issue={assignee_issue}; reason=closed` を emit し、当該候補について 7.2 の既存 4 択を再掲する（7.4.3 / 7.5 へ進まない）
3. `OPEN` → `--body-file` で申し送りを投稿（指摘要約・元 PR・着手時確認点）。成功は `[CONTEXT] HANDOFF_COMMENT_POSTED=1; issue={assignee_issue}`。失敗は WARNING + `[CONTEXT] HANDOFF_COMMENT_FAILED=1; issue={assignee_issue}; reason=gh_comment_failure`（完了レポートに未投稿として列挙）

```bash
assignee_issue={assignee_issue}
owner_repo={owner_repo}

state=$(gh issue view "$assignee_issue" -R "$owner_repo" --json state --jq '.state' 2>/dev/null || echo "")
if [ "$state" != "OPEN" ]; then
  echo "ERROR: 引き受け先 Issue #${assignee_issue} は ${state:-取得失敗} のため引き受け先にできない。triage 判定を 7.2 へ差し戻す" >&2
  echo "[CONTEXT] HANDOFF_COMMENT_REJECTED=1; issue=$assignee_issue; reason=closed" >&2
  exit 0
fi

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
if ! cat <<'HANDOFF_EOF' > "$tmpfile"
## 申し送り（PR #{pr_number} レビューのスコープ外指摘）

### 指摘の要約
{summary}

### 元 PR
#{pr_number}

### 着手時の確認点
{check_points}
HANDOFF_EOF
then
  echo "WARNING: 申し送りコメント本文の一時ファイル書き込みに失敗" >&2
  echo "[CONTEXT] HANDOFF_COMMENT_FAILED=1; issue=$assignee_issue; reason=body_write_failure" >&2
  exit 0
fi

if gh issue comment "$assignee_issue" -R "$owner_repo" --body-file "$tmpfile"; then
  echo "[CONTEXT] HANDOFF_COMMENT_POSTED=1; issue=$assignee_issue"
else
  echo "WARNING: 引き受け先 Issue #${assignee_issue} への申し送りコメント投稿に失敗しました" >&2
  echo "[CONTEXT] HANDOFF_COMMENT_FAILED=1; issue=$assignee_issue; reason=gh_comment_failure" >&2
fi
```

Handoff comment failure reasons: (`closed` / `body_write_failure` / `gh_comment_failure`)

| reason | Description |
|--------|-------------|
| `closed` | 引き受け先 Issue が OPEN でない（CLOSED または state 取得失敗） |
| `body_write_failure` | 申し送り本文の一時ファイル書き込みに失敗 |
| `gh_comment_failure` | `gh issue comment` が非ゼロ終了（権限・ネットワーク） |

`HANDOFF_COMMENT_REJECTED=1` を観測したら当該候補の 7.4.3 を実行せず 7.5 へ進まない。投稿失敗は non-blocking だが記録のみで完了扱いにせず、7.5-7.6 の完了レポートに未投稿として列挙する。

### 7.5-7.6 Append to PR & Report

Issue 一覧を PR コメントへ（`mktemp` + `--body-file`）。`DECISION_LOG_APPENDED=1` の件数と、失敗があれば「手動追記してください」行を completion report に転記する（AC-5）。`HANDOFF_COMMENT_POSTED=1` / `HANDOFF_COMMENT_FAILED=1` も転記し、失敗分は未投稿の申し送りとして列挙する。

### 7.7 Post-condition Gate — Recommendation Disposition Enforcement

本 gate は **mechanical gate**。`candidate_count >= 1` なのに 7.2 の disposition（自動 Decision Log または必要な `AskUserQuestion`）を飛ばして result を emit する silent skip を止める。
**Execution condition**: ステップ 7 に入ったとき（`candidate_count >= 1`）。0 件なら silent skip。

**Step 1 — Determine candidate count**:

7.1 の `candidate_count` を読む。`0` なら **7.7 全体を skip** して 8.0 へ。
**Step 2 — Grep sentinel from conversation context (latest iteration_id)**:
Search the conversation context (ステップ 7.2 emit site) for the following sentinel pattern:

```
[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}; iteration_id={ID}; mode={mode}; choice={choice}; reason={reason}
```

`{N}` は Step 1 の件数、`{ID}` は 7.2 の iteration。複数行なら **最大 iteration_id** を採用する。`mode=` と `choice=` と `reason=` が無い行は未確認の emit として採用しない。

**Step 3 — Routing**:

| Condition | Action |
|-----------|--------|
| Latest sentinel found with `candidates >= 1` AND iteration_id matches current cycle AND `mode=` / `choice=` / `reason=` が全て非空 | Gate passes — proceed to ステップ 8.0 (Defense-in-Depth State Update) |
| Latest sentinel found with matching iteration_id but `mode=` / `choice=` / `reason=` のいずれかが欠落 | **ERROR**: sentinel が確認証跡を欠く（emit-before-evidence）。Execute the ACTION below |
| Latest sentinel NOT found AND candidate_count >= 1 | **ERROR**: ステップ 7.2 was skipped in current cycle. Execute the ACTION below |
| Latest sentinel found but iteration_id is **stale** (matches cycle N-1, not current cycle N) | **ERROR**: ステップ 7.2 was skipped in current cycle (cycle N-1 sentinel false-positive avoided). Execute the ACTION below |
| Sentinel found but `candidates == 0` | Defensive observation: ステップ 7.1 / 7.2 count mismatch (e.g., dedup edge case). Display WARNING and proceed (non-blocking, gate passes); the discrepancy is observability-only. ステップ 7.2-7.3 の "If 0 candidates: Skip ステップ 7" 規約が成立しているため、本行は通常到達不能 dead branch だが defense-in-depth として残す |

**On ERROR** (sentinel not found, candidates >= 1):

```
ERROR: ステップ 7.7 post-condition gate failed.
candidate_count = {N} (>= 1) but no [CONTEXT] PHASE_7_ASKUSER_INVOKED sentinel found.
This means ステップ 7.2 disposition handling was NOT executed — silent skip of recommendation disposition.
ACTION: Return to ステップ 7.2, complete confirmation (対話は回答後、E2E 自動は判定確定後), emit the sentinel with mode/choice/reason, then re-enter ステップ 7.7. Do not run 7.4 before that sentinel.
⚠️ LLM MUST NOT output [review:mergeable] or [review:fix-needed:{n}] until ステップ 7.2 has been executed and the sentinel is emitted.
ANTI-PATTERN reference: This gate enforces the prohibition declared in
.rite/wiki/pages/anti-patterns/aggregate-recommendation-label-evasion.md
(if Wiki has not yet ingested this page, see the background section).
Silent skip with aggregate label "推奨 N 件 (全て scope 外)" is the specific
failure mode being blocked here.
```

本 gate は prose。ERROR を認識して 7.2 に戻る。overall_assessment に関係なく発火する。
rationale: design-rationale.md#phase7-gate-notes

---
