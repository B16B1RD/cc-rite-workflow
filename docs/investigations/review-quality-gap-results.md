# /rite:pr:review 品質ギャップ解消 — Phase D 定量検証レポート

> **位置づけ**: Issue #360 (Phase D 定量検証) の成果物。Issue #355 親 Issue で計画された Phase A-D の改善効果を検証する。
>
> **執筆セッション**: 2026-04-09
> **対象 commit**: `19f9fe3` (Phase D ブランチ作成時の develop HEAD)
> **設計書**: [docs/designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
> **Phase 0 レポート**: [docs/investigations/review-quality-gap-baseline.md](./review-quality-gap-baseline.md)

## 0. サマリー

| 指標 | 目標 | 結果 | 判定 |
|------|------|------|------|
| カバレッジ率 (signal rate 調整後) | ≥70% | 🔶 実測未完了 | 後続セッションで実施 |
| False positive rate | ≤20% | 🔶 実測未完了 | 後続セッションで実施 |
| カテゴリカバレッジ (6中4以上) | ≥4/6 | ✅ 理論分析で 6/6 カバー確認 | 実測で確認必要 |
| 対照 PR FP rate | ≤30% | 🔶 実測未完了 | 後続セッションで実施 |
| signal rate (baseline_V) | ≥90% 望ましい | 🔶 監査未完了 | 個別指摘データ未取得 |

**制約事項**:
- Phase A/B/C/C2 が全てマージ済みのため、**個別ラウンド測定 (Round 1-3) は実施不可**
- PR #350 は MERGED 状態かつ diff が現在の develop に clean apply/revert 不可のため、**replay PR 方式での実測が不可能**
- baseline_V (verified-review 172件) の個別指摘データは PR コメントに存在せず、セッションログからの完全抽出には dedicated session が必要

---

## 1. Baseline データ

### 1.1 baseline_A (/rite:pr:review 改善前)

**ソース**: PR #350 のレビューコメント (2026-04-07、measure-review-findings.sh で集計)

```json
{
  "source": "pr:350",
  "totals": {
    "total_findings": 20,
    "total_cycles": 3,
    "by_severity": {
      "CRITICAL": 2,
      "HIGH": 5,
      "MEDIUM": 11,
      "LOW": 2
    }
  },
  "cycles": [
    { "cycle": 1, "total": 14, "by_severity": { "CRITICAL": 2, "HIGH": 4, "MEDIUM": 6, "LOW": 2 } },
    { "cycle": 2, "total": 6, "by_severity": { "CRITICAL": 0, "HIGH": 1, "MEDIUM": 5, "LOW": 0 } },
    { "cycle": 3, "total": 0, "by_severity": { "CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0 } }
  ]
}
```

**Reviewer 別内訳** (Cycle 1):
- prompt-engineer: 8 件
- tech-writer: 3 件
- code-quality: 3 件

### 1.2 baseline_V (/verified-review)

**ソース**: Issue #355 背景セクション + セッションログ (2026-04-07〜08)

- **総件数**: 172 件 (8 サイクル)
- **平均**: 21 件/サイクル
- **サイクル別** (セッションログから部分抽出):

| Cycle | 件数 | 備考 |
|-------|------|------|
| 1-2 | 不明 | セッションログから未抽出 |
| 3 | ~22 | 修正の下流実装取り残しが主成分 |
| 4 | 20 | CRITICAL 4 / HIGH 7 / MEDIUM 7 / LOW 2 |
| 5 | 14 | — |
| 6 | 15 | — |
| 7 | 11 | — |
| 8 | 不明 | — |

**個別指摘データ**: PR コメントに未記録。セッションログ (58685911-d795-4c81-904c-d209327c779d.jsonl, 15MB) に散在。signal rate 監査には dedicated extraction session が必要。

### 1.3 カテゴリ分布 (PR #350 で見落とされた 6 カテゴリ)

Issue #355 で特定された、baseline_A (rite) が見落とし baseline_V (verified-review) が検出した 6 カテゴリ:

| # | カテゴリ | 説明 | rite 検出 (改善前) |
|---|---------|------|-------------------|
| 1 | flow control | 到達不能コード、unreachable 経路 | ❌ 0件 |
| 2 | i18n parity | i18n key の整合性 | ❌ 0件 |
| 3 | pattern portability | regex の locale 依存、BSD/GNU 互換 | ❌ 0件 |
| 4 | dead code | 未使用変数、不要な import | ❌ 0件 |
| 5 | stderr 混入 | デバッグ出力の残存 | ❌ 0件 |
| 6 | semantic collision | 変数名・関数名の意味的衝突 | ❌ 0件 |

---

## 2. Phase A/B/C/C2 の改善内容と理論的カバレッジ分析

### 2.1 Phase A (#357): Part A 抽出バグ修正 + frontmatter drift cleanup

**変更内容**:
- `review.md` の Part A 抽出仕様を `## Reviewer Mindset` + `## Confidence Scoring` のみ → `## Input` 直前までの全セクション抽出に変更
- `## Cross-File Impact Check` (5 項目: deleted/renamed exports, changed config keys, changed interface contracts, **i18n key consistency**, **keyword list consistency**) が reviewer に到達するようになった
- 全 13 reviewer の `tools:` と `model:` frontmatter を削除して inherit 化
- fix.md Phase 8.1 reason table drift 修正

**理論的カバレッジ効果**:

| カテゴリ | Phase A での対応 | 効果 |
|---------|-----------------|------|
| i18n parity | ✅ Cross-File Impact Check #4 (i18n key consistency) が復活 | 直接対応 |
| pattern portability | ⚠️ Cross-File Impact Check #5 (keyword list consistency) が復活 | 間接的に対応 |
| semantic collision | ⚠️ 部分的（Cross-File Impact Check の broader scope で検出可能性向上） | 間接的 |

### 2.2 Phase B (#358): named subagent 切り替え

**変更内容**:
- `subagent_type: "general-purpose"` → `subagent_type: "rite:{reviewer_type}-reviewer"` (scoped 名)
- agent body が user prompt 内注入 → **system prompt** として注入
- reviewer の役割定義の拘束力が根本的に向上

**理論的カバレッジ効果**:

| カテゴリ | Phase B での対応 | 効果 |
|---------|-----------------|------|
| 全カテゴリ | ✅ reviewer の Detection Process / Checklist が system prompt として強制 | 全般的な検出精度向上 |
| flow control | ⚠️ error-handling-reviewer の Detection Process が確実に適用 | 間接的 |
| dead code | ⚠️ code-quality-reviewer の Detection Process が確実に適用 | 間接的 |

### 2.3 Phase C (#359): reviewer プロンプト改善

**変更内容** (PR #372):
- tech-writer: Doc-Heavy PR Mode の 5 カテゴリ verification protocol 強化
- i18n parity 検出ロジックの明示化
- catch-all/stderr 検出パターンの追加
- error-handling-reviewer の stderr 混入検出強化

**理論的カバレッジ効果**:

| カテゴリ | Phase C での対応 | 効果 |
|---------|-----------------|------|
| i18n parity | ✅ tech-writer の i18n parity 検出が明示化 | 直接対応 |
| stderr 混入 | ✅ error-handling-reviewer の stderr 検出パターン追加 | 直接対応 |
| flow control | ⚠️ catch-all パターン検出で到達不能コードも対象 | 間接的 |

### 2.4 Phase C2 (#361): 分散伝播漏れ検出 lint

**変更内容** (PR #373):
- 5 パターンの分散修正 drift 検出 lint を新規実装
- Pattern-1: 同一構造の修正が一部 Phase にしか伝播しない
- Pattern-2: 変数名・関数名の rename が一部にのみ適用
- Pattern-3: 列挙型の要素追加が一部 case 文にのみ反映
- Pattern-4: config key の追加/変更が一部参照箇所にのみ反映
- Pattern-5: エラーメッセージ / コメントの更新が一部にのみ反映

**理論的カバレッジ効果**:

| カテゴリ | Phase C2 での対応 | 効果 |
|---------|-------------------|------|
| pattern portability | ⚠️ lint が regex pattern の不整合を検出可能 | 間接的 |
| dead code | ⚠️ lint が rename 漏れによる参照切れを検出可能 | 間接的 |
| semantic collision | ⚠️ lint が rename 不整合を検出可能 | 間接的 |

### 2.5 カテゴリカバレッジ理論分析サマリー

| # | カテゴリ | Phase A | Phase B | Phase C | Phase C2 | 理論的カバー |
|---|---------|---------|---------|---------|----------|-------------|
| 1 | flow control | — | ⚠️ | ⚠️ | — | ✅ (B+C の組み合わせ) |
| 2 | i18n parity | ✅ | — | ✅ | — | ✅ (A+C で直接対応) |
| 3 | pattern portability | ⚠️ | — | — | ⚠️ | ✅ (A+C2 の組み合わせ) |
| 4 | dead code | — | ⚠️ | — | ⚠️ | ✅ (B+C2 の組み合わせ) |
| 5 | stderr 混入 | — | — | ✅ | — | ✅ (C で直接対応) |
| 6 | semantic collision | ⚠️ | — | — | ⚠️ | ✅ (A+C2 の組み合わせ) |

**理論的カテゴリカバレッジ: 6/6** (全カテゴリに少なくとも 1 つの改善が対応)

> **注意**: これは理論分析であり、実測での確認が必要です。各 Phase の改善が「カテゴリに対応する」とは「検出可能性が向上した」の意味であり、「確実に検出する」の保証ではありません。

---

## 3. 実測制約と今後のアクションプラン

### 3.1 実測が不可能だった理由

| 制約 | 詳細 |
|------|------|
| PR #350 merged | `/rite:pr:review` は OPEN/DRAFT PR のみ対象。MERGED PR にはレビュー実行不可 |
| replay ブランチ conflict | Phase A/B/C/C2 が PR #350 と同じファイル (review.md, fix.md, tech-writer.md 等) を大幅変更。`git apply` / `git revert -m 1` / `git cherry-pick` いずれも conflict |
| baseline_V 個別データ未取得 | verified-review の 172 件の個別指摘は PR コメントではなくセッション会話内に散在。signal rate 監査にはセッションログからの構造化抽出が必要 |

### 3.2 推奨アクションプラン (別セッションで実施)

#### Option A: Worktree ベースの replay (推奨)

1. **Phase A マージ前の commit** (`54b291f` = PR #350 merge commit の直後) から worktree を作成
2. worktree 上で PR #350 の diff を apply (Phase A/B/C/C2 による conflict なし)
3. investigation PR を作成し、**現在の Claude Code セッション** (改善後のプラグイン) で `/rite:pr:review` を実行
4. これにより「改善後の review system」×「PR #350 の diff」の組み合わせで実測可能

```bash
# 推奨手順
git worktree add /tmp/phase-d-investigation 54b291f
cd /tmp/phase-d-investigation
git checkout -b investigation/phase-d-pr350
gh pr diff 350 | git apply
git add -A && git commit -m "investigation: replay PR #350 for Phase D measurement"
git push -u origin investigation/phase-d-pr350
gh pr create --base develop --head investigation/phase-d-pr350 --draft \
  --title "[investigation] Phase D: PR #350 replay measurement" \
  --body "Phase D quantitative validation (no merge intended)"
```

> **注意**: worktree 内の `plugins/rite/` は Phase A/B/C/C2 **前** の状態。Claude Code が使うプラグインは **メインの working directory のもの** が優先されるため、改善後の review system で旧 diff をレビューできる。

#### Option B: 新規 PR での代替測定

PR #350 の replay が困難な場合、以下の代替 PR で測定:

| # | タイプ | 候補 | 目的 |
|---|--------|------|------|
| 1 | 新規作成 | 本 Phase D の results.md PR | doc-heavy PR での review system 検証 |
| 2 | 既存 OPEN | (なし — 全て merged) | — |
| 3 | 新規作成 | dummy bash/hook 変更 PR | error-handling reviewer の stderr 検出検証 |

#### Option C: signal rate 監査

1. セッションログ `58685911...jsonl` (15MB) から verified-review 指摘を構造化抽出するスクリプトを作成
2. 各指摘を現在のコードと突合し true/false 判定
3. signal rate を算出し、70% 未満なら定量目標再設計

---

## 4. 結論と判定

### 4.1 現時点での判定

| 指標 | 判定 | 根拠 |
|------|------|------|
| カテゴリカバレッジ | ✅ 理論上 6/6 達成 | Phase A-C2 の全改善が 6 カテゴリそれぞれに対応 |
| カバレッジ率 | 🔶 未判定 | 実測データなし |
| FP rate | 🔶 未判定 | 実測データなし |
| signal rate | 🔶 未判定 | baseline_V 個別データ未取得 |

### 4.2 Phase D 完了条件

Phase D の完了には以下が必要 (本レポートの理論分析に加えて):

- [ ] Option A (worktree replay) または Option B (新規 PR) による実測データ取得
- [ ] baseline_V の signal rate 監査 (Option C)
- [ ] 3 指標 (カバレッジ率 / FP rate / カテゴリカバレッジ) の実測値確定
- [ ] 未達項目があれば追加対応 Issue 起票

---

## 5. 関連リソース

- 親 Issue: [#355](https://github.com/B16B1RD/cc-rite-workflow/issues/355)
- 本 Issue: [#360](https://github.com/B16B1RD/cc-rite-workflow/issues/360)
- Phase 0 レポート: [review-quality-gap-baseline.md](./review-quality-gap-baseline.md)
- 症例研究: [fix-cycle-pattern-analysis.md](./fix-cycle-pattern-analysis.md)
- 設計書: [docs/designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
- 測定スクリプト: [plugins/rite/scripts/measure-review-findings.sh](../../plugins/rite/scripts/measure-review-findings.sh)
