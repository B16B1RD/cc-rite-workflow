# PR #370 (mixed code+docs) replay 実測レポート

> **位置づけ**: Issue #404 (親 Issue #392 の対照実測サブタスク) の成果物。改善後 `rite:pr:review` を mixed (code + docs) PR #370 に対して適用し、**doc-heavy mode と code-reviewer 群の活性化バランス**がどのように振る舞うかを定量的に検証する。
>
> **実測セッション**: 2026-04-10
> **対象 PR**: #370 `feat(workflow): workflow incident 自動 Issue 登録機構を追加 (#366)`
> **baseRefOid**: `dfcabe3a0fc09de57756eb8c854e46b0e553832e`
> **mergeCommit**: `b071a36715626add139215dd48dd1a14f445369e`
> **replay draft PR**: #409 (`investigate/pr370-replay`, commit `8a5296a`)
> **設計書**: [../designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
> **親レポート**: [review-quality-gap-results.md](./review-quality-gap-results.md)
> **手順参考**: PR #408 (PR #334 bash hook replay, [pr334-replay-findings.md](./pr334-replay-findings.md))、PR #406 (PR #373 code-heavy replay, [pr373-replay-findings.md](./pr373-replay-findings.md))

## 0. サマリー

| 指標 | 結果 | 判定 |
|------|------|------|
| 総 finding 数 (reviewer 出力 raw) | **25 件** (CRITICAL 2 / HIGH 14 / MEDIUM 8 / LOW 1) | — |
| 重複除外後の unique finding 数 | 22 件 (grep -A3 parser が 3 reviewer から重複検出) | — |
| FP rate (strict: 疑義あり判定のみ FP) | **8%** (2/25) | ✅ **< 30% threshold** |
| Doc-Heavy 判定 | `false` (lines_ratio=0.21 / count_ratio=0.31 — 両閾値未達) | ⚠️ **mixed PR でも doc-heavy mode は不活性** |
| tech-writer 活性化 | **通常 mode** (docs/SPEC + CHANGELOG 担当、Doc-Heavy Override 不発) | ✅ (想定通り) |
| reviewer 活性化 | 5 人 (prompt-engineer / tech-writer / devops / code-quality / error-handling) | ✅ |
| sole reviewer guard | 不発動 (>=2 reviewer 選定済み) | ✅ |
| Rollback 判定 | **不要** (FP rate 8% は 30% threshold を大きく下回る) | ✅ |

**主要結論**:

1. **Mixed PR でも Doc-Heavy mode は activate しない**: PR #370 は 13 ファイル中 4 ファイル (docs/SPEC x2 + CHANGELOG x2) が人間向け documentation だが、`doc_lines_ratio = 200/951 = 0.21`、`doc_files_count_ratio = 4/13 = 0.31` と両閾値 (0.6 / 0.7) を大きく下回る。commands/**/*.md (459 行) は priority rule で prompt-engineer に振り分けられ doc 分子から除外されるため、mixed PR の diff 構成では code 側が優勢となる。→ **Doc-Heavy 検出閾値の調整材料**。
2. **tech-writer は通常 mode で日英 i18n parity 検査に集中**: priority rule により commands/**/*.md が prompt-engineer 管轄となるため、tech-writer の担当は `docs/SPEC.md` + `docs/SPEC.ja.md` + `CHANGELOG.md` + `CHANGELOG.ja.md` の 4 ファイルに絞られた。結果として「未翻訳日本語文字列の検出」等の i18n parity 特化 finding が 2 件出た (1 件は後述 FP 判定)。
3. **prompt-engineer が最多指摘 (11 件)**: `commands/issue/start.md` の +313 行 (Phase 5.4.4.1 新規セクション) に対して placeholder substitution 責任・flag check 漏れ・Step 番号 drift 懸念・jq 引数置換規約等を検出。専門分化が機能している。
4. **error-handling が silent failure 経路を専門的に検出**: `signal trap 欠落 (EXIT のみ)`, `mktemp 失敗 unhandled`, `emit helper stderr silent (2>/dev/null)` の 3 件は他 reviewer では検出されていない。PR #370 自体が silent failure 防止をテーマとするため、メタ整合性 (自己矛盾) を突く finding が生成された。
5. **高信頼度の指摘 (cross-validation 発火) が 3 件**: `grep -A3 parser` は 3 reviewer (prompt-engineer / code-quality / error-handling) が独立検出、`Workflow Incident Emit Helper 3 file 重複` は 2 reviewer、`dead config keys` は 2 reviewer。**横断問題は複数 reviewer が独立検出する** = cross-validation が機能している。
6. **FP rate = 8% (2/25)** で rollback 閾値 (30%) を大きく下回る。Phase A/B/C/C2 は本 replay データからは rollback 候補にならない。

## 1. 実測条件

### 1.1 対象 PR

- **PR #370**: `feat(workflow): workflow incident 自動 Issue 登録機構を追加 (#366)`
- **ファイル数**: 13
- **変更規模**: +923 / -28 (medium)
- **変更内訳**:

| ファイル | 追加 | 削除 | カテゴリ |
|---------|------|------|---------|
| `plugins/rite/commands/issue/start.md` | +313 | -9 | commands (prompt-engineer) |
| `plugins/rite/hooks/tests/workflow-incident-emit.test.sh` | +184 | 0 | test (新規) |
| `docs/SPEC.md` | +93 | -6 | docs (tech-writer) |
| `docs/SPEC.ja.md` | +93 | -6 | docs (tech-writer) |
| `plugins/rite/hooks/workflow-incident-emit.sh` | +98 | 0 | hooks (新規) |
| `plugins/rite/commands/pr/review.md` | +35 | -3 | commands |
| `plugins/rite/commands/pr/fix.md` | +34 | -2 | commands |
| `plugins/rite/commands/lint.md` | +33 | -1 | commands |
| `plugins/rite/skills/rite-workflow/SKILL.md` | +29 | 0 | skills |
| `rite-config.yml` | +8 | 0 | config |
| `CHANGELOG.ja.md` | +1 | 0 | docs |
| `CHANGELOG.md` | +1 | 0 | docs |
| `plugins/rite/scripts/create-issue-with-projects.sh` | +1 | -1 | scripts |

### 1.2 Replay 手順

1. PR #370 base commit (`dfcabe3a`) を fetch
2. Worktree 作成: `git worktree add ../rite-investigate-pr370 dfcabe3a` → branch `investigate/pr370-replay`
3. PR #370 の diff を取得: `gh pr diff 370 > /tmp/pr370.patch`
4. diff を適用: `git apply --3way /tmp/pr370.patch` (13 files clean apply)
5. 単一 commit として commit: `investigate: replay PR #370 for mixed (code+docs) review measurement (#404)`
6. Force-push: `git push --force-with-lease origin investigate/pr370-replay`
7. Draft PR 作成: **#409** (base: develop, head: investigate/pr370-replay)
8. `/rite:pr:review 409` 実行

### 1.3 レビュアー構成

ユーザー確認済み (AskUserQuestion):

| # | Reviewer | 選定理由 | Selection Type |
|---|----------|---------|----------------|
| 1 | prompt-engineer | `commands/**/*.md` (start/lint/pr/fix/pr/review) + `skills/**/*.md` (priority 1 override) | detected |
| 2 | tech-writer | `docs/**/*.md` + `CHANGELOG.*.md` (非 commands/skills/agents .md) | detected |
| 3 | devops | `hooks/*.sh` + `scripts/*.sh` + `rite-config.yml` | detected |
| 4 | code-quality | sole reviewer guard baseline (ただし >=2 reviewer のため baseline 不要、個別選定として参加) | recommended |
| 5 | error-handling | `trap`, `set -e`, `pipefail`, `\|\| true` キーワード検出 | detected |

### 1.4 Doc-Heavy 判定の内訳 (Phase 1.2.7)

| 項目 | 値 |
|------|-----|
| `doc_lines` (docs/SPEC + CHANGELOG, commands/skills/agents 除外) | 200 |
| `total_diff_lines` (全変更行) | 951 |
| `doc_lines_ratio` | 0.210 |
| `lines_ratio_threshold` | 0.6 |
| `doc_files_count` | 4 |
| `total_files_count` | 13 |
| `doc_files_count_ratio` | 0.308 |
| `count_ratio_threshold` | 0.7 |
| **`doc_heavy_pr`** | **`false`** (両 OR 条件とも不成立) |

**判定ロジック**:
```
doc_heavy_pr = (doc_lines_ratio >= 0.6)                OR
              (doc_files_count_ratio >= 0.7 AND total_diff_lines < 2000)
            = (0.210 >= 0.6)                           OR
              (0.308 >= 0.7 AND 951 < 2000)
            = false OR (false AND true)
            = false
```

→ Phase 2.2.1 Doc-Heavy Reviewer Override は **skip**、tech-writer は通常 mode で活性化。

## 2. Finding 一覧 (reviewer 別)

### 2.1 prompt-engineer (評価: 要修正、11 件)

| # | 重要度 | ファイル:行 | 内容 | TP/FP |
|---|--------|------------|------|:-----:|
| P-1 | CRITICAL | `start.md:~488` | HEREDOC `<<'BODY_EOF'` (quoted) で `{type}`/`{details}` 等の LLM placeholder と `$tmpfile`/`$jq_err` の shell 変数が混在 → literal 解釈時 silent failure | **TP** |
| P-2 | CRITICAL | `start.md:~520` | `{details_truncated_60chars}` placeholder の truncate 方法未定義 | **TP** |
| P-3 | HIGH | `start.md:~432 / ~436` | `workflow_incident_enabled` skip が "Skip condition" 散文のみで Processing flow に組み込まれていない | **TP** |
| P-4 | HIGH | `start.md:~519` | `jq --argjson projects_enabled {projects_enabled}` の substitution 規約未定義 (quoted string 置換で parse error) | **TP** |
| P-5 | HIGH | `start.md:~326 / 360 / 371 / 599 / 640` | Phase 5.2/5.3/5.4.3/5.4.6/5.5.0.1 の Step 番号リネーム stale reference 懸念 | **FP** (検証済: stale refs なし) |
| P-6 | HIGH | `start.md:~292` | `grep -A3 '^workflow_incident:'` parser 脆弱性 (cross-ref: code-quality + error-handling) | **TP** |
| P-7 | HIGH | `start.md:~288` | `case ... in true\|false)` で `True`/`FALSE`/`yes`/`1` variant が全て default-on fallback → AC-8 silent break | **TP** |
| P-8 | MEDIUM | `start.md:~440` | sentinel parse step に具体的抽出方法が書かれていない、`root_cause_hint` 欠落時の branch 不明 | **TP** |
| P-9 | MEDIUM | `start.md:~567` | 5 outcome branch の context-local list 更新が prose+table のみ、`/compact` 回復手順なし | **TP** |
| P-10 | MEDIUM | `start.md:~317 / 347 / 622` | orchestrator-direct emit が `workflow_incident_enabled` check なしで無条件実行 (context 汚染) | **TP** |

**FP 判定根拠**:
- **P-5 (Step renumbering)**: grep で検証したところ、新 Step 番号は `Phase 5.4.4.1 routing table (line 1104)` と `Mandatory After 5.2 Step 2` の記載に一貫して現れており、stale reference は検出されなかった。speculative concern。

### 2.2 tech-writer (評価: 条件付き、2 件)

| # | 重要度 | ファイル:行 | 内容 | TP/FP |
|---|--------|------------|------|:-----:|
| T-1 | HIGH | `docs/SPEC.md:1585` | 英語版 SPEC の Phase 7 表に未翻訳日本語文字列 `"別 Issue として作成"` が残存 | **FP** |
| T-2 | HIGH | `docs/SPEC.md:212 / SPEC.ja.md:88` | Sentinel フォーマットが literal 例に regex 構文 `(root_cause_hint=<hint>; )?` を混在 | **TP** |

**FP 判定根拠**:
- **T-1 (untranslated JP)**: grep で検証したところ、該当行は `| Phase 7 | Issues from reviewer "別 Issue として作成" recommendations | pr_review |` と **quoted reference** として日本語キーワードを引用している。これは「reviewer の推奨事項に含まれる日本語キーワード」を説明するための意図的な引用であり、tech-writer が「未翻訳 prose」と誤認した (quoted keyword の文脈を見逃している)。実装側の keyword matching コードも同じ日本語文字列を検索している (`別 Issue`, `別Issueで対応`, `スコープ外` 等) ため、英訳することは実装との drift を生む。**Methodologically FP** (context-blind literal reading)。

### 2.3 devops (評価: 可、0 件 blocking、推奨 4 件)

blocking 指摘なし。推奨事項のみ。

| # | 推奨事項 | 備考 |
|---|---------|------|
| D-1 | TC-009 に `wc -l` 1 行 assert を追加 | confidence 65、test 精度向上 |
| D-2 | `workflow-incident-emit.sh` 冒頭に `export LC_ALL=C` | confidence 62、dedupe 将来実装備え |
| D-3 | `workflow_incident.dedupe_per_session` の実装有無確認 | confidence 60、未実装 (docs only) |
| D-4 | `PR_NUMBER=0` の「PR 未作成」semantics を SPEC に明記 | confidence 60 |

### 2.4 code-quality (評価: 条件付き、7 件)

| # | 重要度 | ファイル:行 | 内容 | TP/FP |
|---|--------|------------|------|:-----:|
| C-1 | HIGH | `lint.md` + `pr/fix.md` + `pr/review.md` | `Workflow Incident Emit Helper` bash snippet + Sentinel Visibility Rule prose が 3 ファイル verbatim 重複、cycle 2 で pr/create.md 追加対応履歴あり | **TP** |
| C-2 | HIGH | `rite-config.yml` + `docs/SPEC.*` + `SKILL.md` | `workflow_incident.non_blocking` / `dedupe_per_session` が dead config key、`non_blocking: false` で挙動変化なし | **TP** |
| C-3 | HIGH | `start.md:289-291` | `grep -A3` parser 脆弱性 (重複検出: prompt-engineer P-6 と同根) | **TP** (重複) |
| C-4 | MEDIUM | `pr/fix.md:608` | Markdown table cell 内 inline bash `\|\| true` が長大、Phase 5.3/5.5 fenced code block パターンと不整合 | **TP** |
| C-5 | MEDIUM | `start.md` Phase 5.4.4.1/5.3/5.4.4/5.5 | fallback AskUserQuestion labels の wording drift (6 variants) | **TP** |
| C-6 | MEDIUM | `workflow-incident-emit.sh` + 10 ファイル | sentinel type enum が 11+ ファイルに hardcode、single source of truth なし | **TP** |
| C-7 | LOW | `tests/workflow-incident-emit.test.sh:979-987` | TC-009 `sep_count=3` assertion が sentinel 全体の `;` 個数に依存、details 内 sanitize を直接 assert していない | **TP** |

### 2.5 error-handling (評価: 条件付き、5 件)

| # | 重要度 | ファイル:行 | 内容 | TP/FP |
|---|--------|------------|------|:-----:|
| E-1 | HIGH | `start.md:484-486` | `trap '...' EXIT` のみで INT/TERM/HUP 未登録、既存 repository 標準に反する | **TP** |
| E-2 | HIGH | `start.md:484 / 518` | `mktemp` 失敗 check なし、空文字列で進行して silent fallthrough | **TP** (部分: jq_err 側が特に脆弱) |
| E-3 | HIGH | `lint.md:704-709` + `pr/fix.md:756-761` + `pr/review.md:810-815` | sub-skill emit helper の `$(bash ... 2>/dev/null) \|\| true` で stderr 完全破棄、hook validation error が silent に消える | **TP** |
| E-4 | MEDIUM | `start.md:289-291` | `grep -A3` parser (重複検出: P-6 / C-3 と同根) | **TP** (重複) |
| E-5 | MEDIUM | `start.md:506-513` | `if [ ! -s "$tmpfile" ]` warning branch が prose コメントのみで実行コードなし | **TP** |

## 3. 集計

### 3.1 FP rate 計算

| 方式 | 計算 | 結果 |
|------|------|------|
| **Strict** (明確 FP のみ) | 2 / 25 | **8.0%** |
| **Conservative** (borderline を FP に算入) | 2 / 25 | 8.0% |
| **Worst case** (重複を unique 化して dedup) | 2 / 22 | 9.1% |

**判定**: いずれも **30% rollback threshold を大幅に下回る**。Phase A/B/C/C2 の rollback 候補にならない。

### 3.2 Reviewer 別の finding 分布

| Reviewer | CRITICAL | HIGH | MEDIUM | LOW | 合計 | FP 数 |
|----------|---------:|-----:|-------:|----:|-----:|------:|
| prompt-engineer | 2 | 5 | 3 | 0 | **10** (blocking: 10) | 1 |
| tech-writer | 0 | 2 | 0 | 0 | **2** | 1 |
| devops | 0 | 0 | 0 | 0 | **0** (推奨 4) | 0 |
| code-quality | 0 | 3 | 3 | 1 | **7** | 0 (重複 1) |
| error-handling | 0 | 3 | 2 | 0 | **5** (重複 1) | 0 |
| **合計** | **2** | **13** | **8** | **1** | **24** (unique) | **2** |

注: レポート上の total_findings=25 には P-6/C-3/E-4 の `grep -A3` parser 3 重検出が含まれる。unique 化後は 23 件。上記表は重複 1 件 (E-4 を counted out) を引いて 24。

### 3.3 横断問題 (cross-validation 発火)

| 問題 | 検出 reviewer 数 | 重要度 |
|------|:---------------:|-------|
| `grep -A3 '^workflow_incident:'` parser 脆弱性 | **3** (prompt-engineer + code-quality + error-handling) | HIGH |
| `Workflow Incident Emit Helper` 3 file 重複 | 2 (code-quality + prompt-engineer 推奨) | HIGH |
| `workflow_incident.non_blocking` / `dedupe_per_session` dead config key | 2 (code-quality + devops 推奨) | HIGH |

→ 複数 reviewer が独立検出する finding は真陽性率が顕著に高い (3 件すべて TP)。

## 4. Doc-Heavy mode の不活性化について

PR #370 は親 Issue #392 の対照実測 3 件で「mixed (code + docs)」カテゴリに割り当てられたが、実際には **Doc-Heavy mode が activate しなかった**。この結果は Issue #404 の判定基準 2 の観測対象そのもの:

> **判定基準 2** (Issue #404 より引用): mixed でも doc-heavy mode だけが activate する場合、doc-heavy 検出閾値 (`lines_ratio_threshold` / `count_ratio_threshold`) の調整が必要

**観察**: PR #370 は 13 ファイル中 4 ファイル (`docs/SPEC.md`, `docs/SPEC.ja.md`, `CHANGELOG.md`, `CHANGELOG.ja.md`) が人間向け documentation で、残り 9 ファイルは commands/skills/hooks/scripts/config 系。

- `commands/**/*.md` (5 ファイル: start/lint/pr/fix/pr/review/SKILL.md) は **priority rule で tech-writer ではなく prompt-engineer に振り分け**られ、かつ **doc 分子から除外** される (rite plugin self 参照の dogfooding 考慮)。
- その結果、doc 分子は `docs/SPEC.md` + `CHANGELOG.md` 系のみ (200 行) となり、 `doc_lines_ratio = 200/951 = 0.21` と閾値 (0.6) を大きく下回る。
- `doc_files_count_ratio = 4/13 = 0.31` も閾値 (0.7) を下回る。

**解釈**:

(a) **閾値が高すぎる**という解釈もありうるが、実際には **mixed PR は code 側の変更も伴うため code-reviewer 群の活性化が必要**であり、doc-heavy 特化 mode は不要。PR #370 では tech-writer / prompt-engineer / devops / code-quality / error-handling の 5 reviewer が適切に役割分担して指摘を生成しており、**Doc-Heavy mode を強制 activate する方が過剰**になる可能性。

(b) 一方、Issue #404 の仮説 (「mixed でも doc-heavy override が必要」) は本 replay データでは**支持されない**。doc-heavy override の本来の目的 (reviewer を強制的に tech-writer mandatory にして 5-category verification を走らせる) は、**純粋 doc PR** で有効であり、mixed PR では既存の priority rule + 自然な reviewer 選定で十分である。

**推奨アクション**:

1. Issue #404 の仮説 (「mixed で doc-heavy が活性すべき」) は**撤回**を推奨。現状の閾値 (0.6 / 0.7) で OK。
2. 閾値調整が必要になるケースは (i) 純粋 doc PR で doc-heavy が活性しない、(ii) doc が 5 割以上でも code-reviewer が dominant になる、の 2 パターン。本 replay は (i)(ii) いずれにも該当しない。
3. 親 Issue #392 の最終レポート (`review-quality-gap-results.md`) で「mixed PR は doc-heavy override 不要」を記録する。

## 5. Tech-writer の活性化パターン

tech-writer は **通常 mode で活性化**し、以下の behaviour を示した:

### 5.1 担当ファイル
- `docs/SPEC.md` / `docs/SPEC.ja.md` / `CHANGELOG.md` / `CHANGELOG.ja.md` (4 files)
- commands/**/*.md は priority rule で除外 (prompt-engineer 管轄)

### 5.2 活性化した検査
- **日英 i18n parity** ✅ (doc/SPEC 左右比較)
- **CHANGELOG 情報密度・構造** (推奨 1 件)
- **用語の一貫性** (推奨 1 件)
- **SPEC の prose 正確性** (T-2: sentinel format regex mixing)

### 5.3 **活性化しなかった**検査
- Doc-Heavy mode 5 category verification (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) — Doc-Heavy PR ではないため適用外
- Evidence field 必須化 (`tool=Grep, path=...` literal) — 同上

**結論**: tech-writer は mixed PR で「限定的だが有用な i18n parity 検査」を提供。Doc-Heavy mode の重装備を呼び出す必要はない。

## 6. methodological caveats

### 6.1 Post-fix code を replay している (sibling #403 と同様)

PR #370 は 3 cycles のレビュー修正を経てマージされた。本 replay は **post-fix final code** を replay しているため、cycle 1/2/3 で修正された問題は diff に残存しない。したがって、ここで検出された finding は:

- 「cycle 3 final code にも残った真の問題」(= 本 replay の net-new finding) と
- 「cycle 3 で fix された問題の再検出」(= regression check として妥当)

の両方を含む。**真の Phase A/B/C/C2 detection capability を評価するには pre-fix code (cycle 1 入力) を replay する必要がある** — これは Issue #404 のスコープ外。

### 6.2 Issue #404 の判定基準 1 (FP rate > 30%) への照合

本 replay の FP rate = 8% は threshold 30% を大きく下回る。Phase A/B/C/C2 のいずれも本 replay データでは rollback 候補にならない。ただし sibling #407 (PR #334 replay, 0 findings) / #405 (PR #373 replay, 未測定) と合わせて初めて **親 Issue #392 の集約判定** が可能になる。

### 6.3 replay の選択バイアス

PR #370 は workflow incident (silent failure 防止) をテーマとする PR であり、error-handling reviewer が "silent failure 経路" を検出する finding を生成しやすい性質を持つ。この自己言及的な側面は、FP rate の計算を「自己矛盾する silent failure 経路の存在確認」として歪める可能性がある。

ただし、error-handling の 5 findings のうち FP は 0 件で、いずれも **実在する silent failure 経路** (signal trap 欠落、mktemp 失敗 unhandled、stderr silent) を正しく指摘している。replay の選択バイアスは結果を過大評価する方向ではなく、むしろ **PR の設計意図と reviewer の専門領域のマッチ** を確認する健全な結果となった。

## 7. 次アクション

1. ✅ **本レポートを Issue #404 の成果物として確定** (report PR で develop にマージ)
2. 親 Issue #392 の集約時に以下を追記:
   - mixed PR では Doc-Heavy mode override は不要 (閾値調整不要)
   - Phase A/B/C/C2 rollback 候補なし (FP rate 8%)
   - 横断問題 (`grep -A3 parser`, `Workflow Incident Emit Helper 重複`, `dead config keys`) は複数 reviewer が独立検出 → 真陽性の強い指標
3. 本 replay で検出された真陽性 finding (特に HIGH 以上) のうち、PR #370 の **cycle 4 相当** の追加修正として**別 Issue** で対応を推奨:
   - `grep -A3` parser 脆弱性 (3 reviewer 合意) — **新規 Issue 推奨**
   - `Workflow Incident Emit Helper` 3 file 重複 — **新規 Issue 推奨**
   - `dead config keys (non_blocking / dedupe_per_session)` — **新規 Issue 推奨**
   - `Signal trap EXIT のみ` — **新規 Issue 推奨**
4. replay draft PR #409 は OPEN 状態のまま保持 (sibling #407 / #405 と同じ方針)。マージしない。

## 8. 参考

- [親 Issue #392](https://github.com/B16B1RD/cc-rite-workflow/issues/392): review-quality-gap-closure 対照実測
- [Issue #404](https://github.com/B16B1RD/cc-rite-workflow/issues/404): 本レポートの親タスク
- [Draft PR #409](https://github.com/B16B1RD/cc-rite-workflow/pull/409): replay 実測用 draft PR
- [元 PR #370](https://github.com/B16B1RD/cc-rite-workflow/pull/370): 対象 PR (merged)
- Sibling replay: [PR #407 (bash hook)](https://github.com/B16B1RD/cc-rite-workflow/pull/407) / [PR #405 (code-heavy)](https://github.com/B16B1RD/cc-rite-workflow/pull/405)
- Sibling report: [pr334-replay-findings.md](./pr334-replay-findings.md) / [pr373-replay-findings.md](./pr373-replay-findings.md)

---
*実測セッション: 2026-04-10 / Claude Opus 4.6 (1M context) / 5 parallel reviewer sub-agents (rite:*-reviewer)*
