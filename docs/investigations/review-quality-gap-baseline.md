# /rite:pr:review 品質ギャップ — Phase 0 事前検証レポート

> **位置づけ**: Issue #356 (Phase 0 事前検証) の成果物。Issue #355 親 Issue で計画された Phase A-D の修正に着手する前に、前提となる事実を実機検証で確定させる。
>
> **執筆セッション**: 2026-04-08
> **対象 commit**: `54b291f1` (本 Phase 0 ブランチ作成時の develop HEAD)
> **設計書**: [docs/designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)

## 0. サマリー

| 項目 | 状態 | 確定事項 |
|------|------|---------|
| **Item 1**: Part A 抽出バグ実機検証 | ✅ 完了 | spec citation + bash 機械再現で `## Cross-File Impact Check` の structural drop を確定。Phase A (#357) で抽出仕様修正が必要 |
| **Item 2**: scoped subagent name 実機テスト | ✅ 完了 | プラグイン環境では **`rite:xxx-reviewer` 形式のみ解決可能**。bare 形式はエラー。Phase B (#358) は scoped 名を使う |
| **Item 3**: tools/model frontmatter drift 全量監査 | ✅ 完了 | 13 reviewer 中 5 件で drift 確定 (tech-writer は CRITICAL)。Phase A (#357) で frontmatter cleanup 方針決定 |
| **Item 4**: PR #350 親 commit ベースライン取得 | ⏸ **Deferred** | コンテキスト予算上、別セッションで実施。実行手順書を Section 4 に記載 |
| **Item 5**: 自動測定スクリプト作成 | ✅ 完了 | `plugins/rite/scripts/measure-review-findings.sh` 新規作成、PR #350 で 20 件・3 cycle を集計確認 |
| **Item 6**: PR #350 fix-cycle 症例研究 | ✅ 完了 | [fix-cycle-pattern-analysis.md](./fix-cycle-pattern-analysis.md) に 5 パターン + 検出条件 + 再発回数を記録。Issue #361 (Phase C2) の要件仕様化 |

**Phase A (#357) 着手可否**: ✅ Item 1, 3 が完了したため Phase A は本 PR マージ後に着手可能
**Phase B (#358) 着手可否**: ✅ Item 2 が完了したため Phase B は scoped 名を採用して着手可能
**Phase C2 (#361) 着手可否**: ✅ Item 6 が完了したため Phase C2 は症例研究を要件仕様として着手可能
**Phase D (#360) 着手可否**: ⏸ Item 4 (baseline) が pending のため、Phase D 着手前に Item 4 を完了する必要あり

---

## 1. Item 1: Part A 抽出バグの実機検証

### 1.1 仮説

`plugins/rite/commands/pr/review.md` Phase 4.3 (Sub-Agent Identity Construction, line 1234-1252) の Part A 抽出仕様は `## Reviewer Mindset` と `## Confidence Scoring` の 2 セクションのみを抽出する。一方 `_reviewer-base.md` の見出し構造上、両セクションの間に位置する `## Cross-File Impact Check` (i18n key consistency, keyword list consistency 等を含む 5 項目チェック) が **構造的に dropped** されている。

### 1.2 仕様引用 (一次証拠)

`plugins/rite/commands/pr/review.md:1238`:

> Extract the `## Reviewer Mindset` and `## Confidence Scoring` sections (everything between these headings and the next `##` heading or `## Input` section)

`plugins/rite/agents/_reviewer-base.md` の見出し構造:

```
L3   ## Reviewer Mindset
L12  ## Cross-File Impact Check    ← 仕様の対象に含まれない
L22  ## Confidence Scoring
L42  ## Input
L52  ## Output Format
```

仕様の文字通り解釈で `## Reviewer Mindset` (L3-11) と `## Confidence Scoring` (L22-41) のみを抽出すると、L12-21 (`## Cross-File Impact Check` の本体: 5 つのチェック項目) が完全にドロップする。

### 1.3 Bash による機械再現 (二次証拠)

抽出ロジックを bash で機械的に再現するスクリプト ([/tmp/reproduce-part-a-extraction.sh](#1-3-script-source) — 検証セッション中の一時スクリプト) を実行:

```
=== Part A extracted per review.md:1238 spec ===
## Reviewer Mindset       count: 1
## Confidence Scoring     count: 1
## Cross-File Impact Check count: 0    ← 仮説どおり drop

--- Source file structure ---
3:## Reviewer Mindset
12:## Cross-File Impact Check
22:## Confidence Scoring
42:## Input
52:## Output Format
```

#### 1.3.1 検証基準達成

| 検証項目 | 期待値 | 実測値 | 判定 |
|---------|--------|--------|------|
| `grep -c "## Cross-File Impact Check" /tmp/agent-identity-part-a.txt` | `0` | `0` | ✅ |
| `grep -c "## Reviewer Mindset" /tmp/agent-identity-part-a.txt` | `>= 1` | `1` | ✅ |
| `grep -c "## Confidence Scoring" /tmp/agent-identity-part-a.txt` | `>= 1` | `1` | ✅ |

### 1.4 影響範囲

- `agents/_reviewer-base.md` の `## Cross-File Impact Check` 本体 (5 項目: deleted/renamed exports, changed config keys, changed interface contracts, **i18n key consistency**, **keyword list consistency**) が reviewer に届いていない
- 13 reviewer 全員が「Cross-File Impact Check 該当事項を mandatory final step として実施せよ」という指示を受けていない
- 結果として **i18n key consistency や keyword list consistency が PR 1 件たりとも機能していなかった**
- PR #350 で発覚した「verified-review が i18n parity 漏れを大量検出、rite が 1 件も検出しなかった」現象の構造的原因

### 1.5 Phase A (#357) への引き継ぎ

修正方針: Part A 抽出仕様を「`## Reviewer Mindset` から `## Input` 直前まで全セクション抽出」に変更する。具体的には:

```diff
- Extract the `## Reviewer Mindset` and `## Confidence Scoring` sections
- (everything between these headings and the next `##` heading or `## Input` section)
+ Extract everything from `## Reviewer Mindset` heading inclusive
+ until just before `## Input` heading (preserves all intervening sections)
```

これにより `## Cross-File Impact Check` を含む base reviewer の全セクションが reviewer に届く。

---

## 2. Item 2: scoped subagent name 実機テスト

### 2.1 試行環境

- セッション: 2026-04-08 (cc-rite-workflow develop branch)
- Claude Code: プラグイン環境 (`rite@rite-marketplace: false`、ローカル `plugins/rite` から読み込み)
- Task ツール経由で `subagent_type` パラメータに 2 形式を渡し、解決成否を観測

### 2.2 試行結果

| # | `subagent_type` | 結果 | 出力 / エラーメッセージ |
|---|-----------------|------|-------------------|
| 1 | `rite:code-quality-reviewer` | ✅ **解決成功** | `RESOLVED:rite:code-quality-reviewer` (agent 応答) |
| 2 | `code-quality-reviewer` (bare) | ❌ **解決失敗** | `Agent type 'code-quality-reviewer' not found. Available agents: general-purpose, statusline-setup, ..., rite:code-quality-reviewer, rite:devops-reviewer, ..., rite:dependencies-reviewer, rite:api-reviewer, ...` |

### 2.3 確定事項

- **プラグイン配布環境では scoped 形式 `rite:xxx-reviewer` のみが正しく解決される**。bare 形式 `xxx-reviewer` は agent registry に存在しない
- エラーメッセージから、本環境で利用可能な全 rite reviewer は `rite:` プレフィックス付きで列挙されている
- `general-purpose` 経由の現状 (review.md:1237) では agent registry を経由しないため bare/scoped どちらでも実害はないが、Phase B で `subagent_type` を直接 reviewer 名に切り替える際は **必ず scoped 形式を使う必要がある**

### 2.4 Phase B (#358) への引き継ぎ

修正方針: review.md:1237 の `subagent_type: "general-purpose"` を `subagent_type: "rite:{reviewer_type}-reviewer"` に変更する。プレースホルダ `{reviewer_type}` は `code-quality`, `security` 等の reviewer slug。

注意点 (本セッションで判明): プラグイン非経由のローカル開発環境 (`agents/` をリポジトリ直下から読み込む等) では bare 形式が解決される可能性があるが、本プラグインは配布前提のため scoped 形式が portable な選択。

---

## 3. Item 3: tools/model frontmatter drift 全量監査

### 3.1 監査方法

1. `plugins/rite/agents/*-reviewer.md` 全 13 ファイルの YAML frontmatter から `model:` と `tools:` を Read で抽出
2. `plugins/rite/skills/reviewers/*.md` 全 13 ファイルを Grep で `Bash`/`gh api`/`WebFetch`/`WebSearch` パターン検索 (skill 側で要求される検証ツール)
3. **feedback memory に従い、agents/ ファイル本体も Read で読み**、Detection Process / Step 内で要求されるツールを併せて確認 (skill だけ見ない)

### 3.2 結果テーブル

| # | reviewer | frontmatter `model` | frontmatter `tools` | skill 要求ツール (実際の verification) | drift 有無 | 優先度 |
|---|----------|---------------------|---------------------|----------------------------------------|----------|--------|
| 1 | api | opus | Read, Grep, Glob | **WebSearch** (REST 規約検証, skill L108) | **Drift: WebSearch missing** | MEDIUM |
| 2 | code-quality | sonnet | Read, Grep, Glob | (なし) | OK | — |
| 3 | database | opus | Read, Grep, Glob | (なし) | OK | — |
| 4 | dependencies | opus | Read, Grep, Glob, **WebSearch, WebFetch** | WebSearch, WebFetch (CVE check, skill L106-110) | OK | — |
| 5 | devops | opus | Read, Grep, Glob | **WebSearch** (Docker CVE), **WebFetch** (Actions docs) (skill L94-95) | **Drift: WebSearch + WebFetch missing** | HIGH |
| 6 | error-handling | sonnet | Read, Grep, Glob | (skill 内 Bash 言及はすべて検出対象 bash コードであり、reviewer 自身が Bash ツールを使うわけではない) | OK | — |
| 7 | frontend | opus | Read, Grep, Glob | **WebSearch** (WCAG 検証, skill L94) | **Drift: WebSearch missing** | LOW |
| 8 | performance | sonnet | Read, Grep, Glob | (なし) | OK | — |
| 9 | prompt-engineer | opus | Read, Grep, Glob | **WebSearch + WebFetch** (Claude Code 公式 docs 検証, skill L106) | **Drift: WebSearch + WebFetch missing** | HIGH |
| 10 | security | opus | Read, Grep, Glob, **WebSearch, WebFetch** | WebSearch, WebFetch (CVE check) | OK | — |
| 11 | tech-writer | opus | Read, Grep, Glob | **Bash** (`gh api repos/{other_owner}/{other_repo}/contents/...`, skill L143) + **WebFetch** (broken link 検証, skill L143/L210) | **Drift: Bash + WebFetch missing** | **CRITICAL** |
| 12 | test | opus | Read, Grep, Glob | (なし) | OK | — |
| 13 | type-design | sonnet | Read, Grep, Glob | (なし) | OK | — |

**Drift 集計**: 13 中 5 件で drift 確定 (api, devops, frontend, prompt-engineer, tech-writer)。tech-writer は cross-repo 検証で `gh api` を要求するが Bash ツールが frontmatter に含まれず、最も影響範囲が広いため CRITICAL。

### 3.3 Model 分布

| model | reviewer 数 | reviewer 名 |
|-------|-------------|-------------|
| opus | 9 | api, database, dependencies, devops, frontend, prompt-engineer, security, tech-writer, test |
| sonnet | 4 | code-quality, error-handling, performance, type-design |

### 3.4 Phase A (#357) への引き継ぎ

設計書 D3/D4 ([docs/designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md#技術的決定事項)) で確定した方針: **frontmatter から `tools:` と `model:` を全削除して inherit 化** する。理由:

- Phase A 時点 (named subagent 切替前) は tools/model 制限が実効化していないため drift があっても害がないが、Phase B で named subagent に切り替えた瞬間に sonnet 固定の 4 reviewer や tools 不足の 5 reviewer が機能不全になる
- skill 要求と frontmatter を都度同期するのは drift が再発するため、`inherit` で一律解決する方が保守コストが低い
- 親セッションが opus + 全ツールを持っていれば全 reviewer がそれを継承する

---

## 4. Item 4: PR #350 親 commit ベースライン取得 (Deferred)

### 4.1 Deferral 理由

本セッションで実施しない。理由:

1. **コンテキスト予算**: `/verified-review` を 8 サイクル実行する場合、累計 200+ 件の指摘を読み取り・cross-mapping する作業がメインフローのコンテキストを圧迫する
2. **時間コスト**: PR #350 の親 commit を checkout し、両 review ツールを完走するには独立したセッションが必要
3. **依存関係**: Item 4 は Phase D (#360) のみブロッカーで、Phase A (#357) / B (#358) / C (#359) / C2 (#361) はブロックしない。Phase 0 を本セッションで「Item 4 deferral 状態」のまま完了し、Phase A 着手と並行して別セッションで Item 4 を実施できる
4. **memory feedback** ([feedback_plan_requires_empirical_grounding.md](file:///home/akiyoshi/.claude/projects/-home-akiyoshi-Projects-personal-cc-rite-workflow/memory/feedback_plan_requires_empirical_grounding.md)): 数値主張は dry-run 実証で gating する原則。Item 4 を急いで本セッションで実行して品質が落ちるより、別セッションで丁寧に取得する方がベースラインの信頼性が高い

### 4.2 実行手順書 (別セッションで実施)

#### 前提

- 対象 commit: `e1498f5c361de2187b26f358ceabf5b08dc0f13f` (PR #350 first commit `bf3f2a79` の親 commit、PR #348 マージコミット)
- 対象 commit hash 取得方法: `git log -1 --pretty=format:'%H %s' bf3f2a79e8d13f22797e2cf31ae7430ad8a398eb~1`
- `/verified-review` は `~/.claude/commands/verified-review.md` ユーザーコマンドで定義されている (本リポジトリ外)
- `/rite:pr:review` は本リポジトリの plugins/rite/commands/pr/review.md

#### Step 1: 環境準備

```bash
# 別ブランチで作業 (本ブランチは汚さない)
git fetch origin
git checkout -b investigation/baseline-pr350 e1498f5c361de2187b26f358ceabf5b08dc0f13f

# Note: この時点ではまだ PR #350 のコードは含まれていない (親 commit 状態)
# /rite:pr:review と /verified-review は PR #350 自体の diff を review する必要がある
# つまり、PR #350 の diff を別ブランチに適用し、その状態で両 review を実行する

# PR #350 の diff を取得
gh pr diff 350 > /tmp/pr-350.diff
git apply /tmp/pr-350.diff
git add -A
git commit -m "investigation: replay PR #350 diff for baseline measurement"
```

#### Step 2: ダミー PR 作成 (review ツールの input)

```bash
# 別リポジトリ or 同リポジトリの investigation スコープで PR を作成
git push -u origin investigation/baseline-pr350
gh pr create --base develop --head investigation/baseline-pr350 \
  --title "[investigation] PR #350 baseline measurement" \
  --body "Phase 0 Item 4 baseline measurement (no merge intended)" \
  --draft
```

#### Step 3: /rite:pr:review 実行 (baseline_A)

```bash
# Claude Code 内で実行
/rite:pr:review {investigation_pr_number}
```

完了後、結果コメントを取得して measure script で集計:

```bash
plugins/rite/scripts/measure-review-findings.sh \
  --pr {investigation_pr_number} --owner B16B1RD --repo cc-rite-workflow \
  > /tmp/baseline_A.json

cat /tmp/baseline_A.json | jq '.totals'
```

期待出力フォーマット (PR #350 で実測される値):

```json
{
  "total_findings": 20,        // 既知値: 3 cycle 累計 20 件
  "total_cycles": 3,           // 既知値
  "by_severity": {
    "CRITICAL": 2,
    "HIGH": 5,
    "MEDIUM": 11,
    "LOW": 2
  }
}
```

#### Step 4: /verified-review 実行 (baseline_V)

```bash
# Claude Code 内で実行 (~/.claude/commands/verified-review.md ベース)
/verified-review {investigation_pr_number}
```

完了後、結果コメントを手動で集計 (verified-review は rite と異なるフォーマットの可能性):

```bash
gh api repos/B16B1RD/cc-rite-workflow/issues/{investigation_pr_number}/comments \
  --jq '.[] | select(.body | contains("verified-review")) | .body' \
  > /tmp/baseline_V_raw.md

# 手動集計 or jq script で件数抽出
```

期待出力フォーマット (PR #350 で実測される値):

```
Total findings: 172 (8 cycles)
Average per cycle: 21
```

#### Step 5: クロスマッピング

両者の指摘を手動で 3 カテゴリに分類:

| カテゴリ | 説明 | 期待件数 (PR #350) |
|---------|------|------------------|
| **共通** | rite と verified の両方が検出した指摘 | 〜10 件 |
| **rite-only** | rite のみが検出 | 〜10 件 |
| **verified-only** | verified のみが検出 (= rite が見落とした) | 〜162 件 |

クロスマッピング結果は `docs/investigations/baseline-cross-mapping.md` (新規) として保存。

#### Step 6: signal rate 監査 (本セッション 2026-04-08 で追加された AC)

verified-review 自体に LLM 由来の偽陽性が含まれることが本セッションで実測された (Issue #355 Meta-Observation 参照)。verified-only 162 件のうち、Explore agent や手動検証で「実は既に修正済み」「コードを誤読」と判定されるものを記録:

```
verified-only 162 件中:
- 真の指摘: N 件
- 偽陽性: 162 - N 件
- signal rate: N / 162 = X%
```

signal rate が 70% 未満の場合は、Issue #355 の定量目標 (カバレッジ率 70%) の分母を baseline_V の代わりに **真の指摘数 N** に置き換える decision point を発火させる。

### 4.3 Pending マーク

🔶 **Status: PENDING — 別セッションで実施**

本ドキュメントの Section 4 は実行手順書のみ。実測データは未取得。Phase D (#360) 着手前に Item 4 を完了すること。

---

## 5. Item 5: 自動測定スクリプト動作確認

### 5.1 成果物

`plugins/rite/scripts/measure-review-findings.sh` (新規作成)

### 5.2 設計

- **入力**: GitHub PR 番号 (`--pr N`) または ローカル markdown ファイル (`--file path`)
- **出力**: JSON (cycles 配列 + totals サマリー、CRITICAL/HIGH/MEDIUM/LOW 別集計、reviewer 別集計)
- **実装**: Bash + Python3 ヒアドキュメント (Markdown table parser を Python で実装)
- **エラーコード**: 0=成功 / 1=引数エラー / 2=API or file エラー / 3=parse 失敗

### 5.3 動作確認ログ

```bash
$ plugins/rite/scripts/measure-review-findings.sh --help
measure-review-findings.sh — Extract findings statistics from rite review comments

USAGE:
  measure-review-findings.sh --pr <number> [--owner <owner>] [--repo <repo>]
  measure-review-findings.sh --file <path>
$ echo "exit: $?"
exit: 0
```

PR #350 への実機実行:

```bash
$ plugins/rite/scripts/measure-review-findings.sh --pr 350 --owner B16B1RD --repo cc-rite-workflow | jq '.totals'
{
  "total_findings": 20,
  "total_cycles": 3,
  "by_severity": {
    "CRITICAL": 2,
    "HIGH": 5,
    "MEDIUM": 11,
    "LOW": 2
  }
}
```

### 5.4 既知の制約

- Cycle 番号が `(Cycle N)` 表記で省略されている場合は **コメント順序ベースのフォールバック** で番号を割り当てる (PR #350 の Cycle 1 がこのケース、コメント上は `## 📜 rite レビュー結果` のみで `(Cycle 1)` 抜け)
- verified-review のフォーマットは未対応 (rite フォーマット専用)。Phase D で必要なら verified-review parser を別途追加
- reviewer 別集計は `### レビュアー合意状況` テーブル必須

---

## 6. Phase A 以降への引き継ぎ事項

| 引き継ぎ先 | 内容 | 根拠 Section |
|-----------|------|------------|
| Phase A (#357) | Part A 抽出仕様の修正 (`## Reviewer Mindset` から `## Input` 直前まで全セクション抽出) | Section 1.5 |
| Phase A (#357) | frontmatter `tools:` および `model:` を全 13 reviewer から削除して inherit 化 | Section 3.4 |
| Phase A (#357) | tech-writer は CRITICAL 優先度。`gh api` (Bash) と WebFetch を要求するため inherit 化が必須 | Section 3.2 |
| Phase B (#358) | `subagent_type: "general-purpose"` → `subagent_type: "rite:{reviewer_type}-reviewer"` (scoped 形式必須) | Section 2.4 |
| Phase B (#358) | bare 形式 (`code-quality-reviewer`) は使わない。Migration Guide で明示 | Section 2.3 |
| Phase C2 (#361) | 5 つの分散伝播漏れパターン定義と検出条件は [fix-cycle-pattern-analysis.md](./fix-cycle-pattern-analysis.md) を要件仕様として参照 | Item 6 |
| Phase D (#360) | **Item 4 (baseline 取得) を別セッションで実施してから着手すること**。手順書は Section 4.2 | Section 4 |
| Phase D (#360) | signal rate 監査 AC を追加 (verified-review の false positive 率測定) | Section 4.2 Step 6 |
| Phase D (#360) | 自動測定スクリプト `plugins/rite/scripts/measure-review-findings.sh` を Phase D の集計に使用 | Section 5 |

## 7. 関連リソース

- 親 Issue: [#355](https://github.com/B16B1RD/cc-rite-workflow/issues/355) (refactor: /rite:pr:review 品質ギャップ解消)
- 本 Issue: [#356](https://github.com/B16B1RD/cc-rite-workflow/issues/356) ([Phase 0] 事前検証)
- 後続 Issues: [#357](https://github.com/B16B1RD/cc-rite-workflow/issues/357) (Phase A) / [#358](https://github.com/B16B1RD/cc-rite-workflow/issues/358) (Phase B) / [#359](https://github.com/B16B1RD/cc-rite-workflow/issues/359) (Phase C) / [#360](https://github.com/B16B1RD/cc-rite-workflow/issues/360) (Phase D) / [#361](https://github.com/B16B1RD/cc-rite-workflow/issues/361) (Phase C2)
- 設計書: [docs/designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
- 症例研究: [docs/investigations/fix-cycle-pattern-analysis.md](./fix-cycle-pattern-analysis.md)
- 測定スクリプト: [plugins/rite/scripts/measure-review-findings.sh](../../plugins/rite/scripts/measure-review-findings.sh)
- 過去 PR: [#350](https://github.com/B16B1RD/cc-rite-workflow/pull/350) (本調査の主要対象)

<a id="1-3-script-source"></a>

### 付録: Section 1.3 で使用した bash 抽出再現スクリプト

検証セッション中の一時スクリプト `/tmp/reproduce-part-a-extraction.sh`:

```bash
#!/bin/bash
# Reproduce review.md:1234-1252 Part A extraction logic mechanically.
set -euo pipefail
BASE_FILE="${1:-plugins/rite/agents/_reviewer-base.md}"
OUT_FILE="${2:-/tmp/agent-identity-part-a.txt}"

extract_section() {
  local file="$1" heading="$2"
  awk -v hdr="$heading" '
    $0 == hdr { capture = 1; print; next }
    capture && /^## / { exit }
    capture { print }
  ' "$file"
}

{
  extract_section "$BASE_FILE" "## Reviewer Mindset"
  extract_section "$BASE_FILE" "## Confidence Scoring"
} > "$OUT_FILE"

echo "## Cross-File Impact Check count: $(grep -c '^## Cross-File Impact Check' "$OUT_FILE" || true)"
```

このスクリプトは Phase A 修正後は **不要になる** (Cross-File Impact Check が抽出結果に含まれるようになる) ため、本ドキュメント Section 1.3 では出力ログを保存した上で物理ファイルは削除している。
