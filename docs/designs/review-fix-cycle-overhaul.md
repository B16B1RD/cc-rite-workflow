# refactor(review): レビュー修正サイクルの根本見直し（Observed Likelihood Gate + Fail-Fast First）

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

rite workflow の PR レビュー修正サイクルを根本から再設計する。指摘の入口ゲートに "実発生立証" 軸 (Observed Likelihood Gate) を導入し、低確率の hypothetical 問題を自動降格。reviewer/fix の両方で Fail-Fast First 原則 (fallback 推奨の前に throw/raise を必須検討) を強制。別 Issue 化フローでは E2E の AskUserQuestion スキップを撤廃してユーザー確認を必須化。Fact-Check Phase を拡張して internal likelihood claim の Grep ベース検証と Context7 MCP デフォルト有効化を行う。既存問題 (Source C) のレビュー報告は廃止し `/rite:investigate` へ委譲する。

詳細な改修計画の要点は本ドキュメントの「アーキテクチャ」「実装ガイドライン」セクションに転記済み。追加の背景は親 Issue #502 / 本 PR で実装される子 Issue #503 の本文を参照。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

現状のレビューサイクルは以下の問題を抱えており、実運用コストを圧迫している:

1. **過剰な低確率指摘**: 発生確率 ~0.01% 程度の hypothetical 問題が CRITICAL 指摘として blocking 扱いされる。severity-levels.md は impact 軸のみで likelihood 軸がない。
2. **フォールバック強制文化**: reviewer が「null チェック追加せよ」「catch して default を返せ」等、防御的コード追加を推奨し、fix がそれに従う。本来は throw/raise で呼び出し元に伝播すべきケースでも fallback が正解とされる。
3. **別 Issue 化が先延ばし装置化**: review.md Phase 7 と fix.md Phase 4.3 が E2E で AskUserQuestion をスキップし自動 Issue 化。スコープ外判定は reviewer 自己申告のキーワードマッチ依存で曖昧。
4. **指摘の真実性検証が External claim 限定**: Internal claim (コード内の挙動主張) は reviewer の自己判断のみで、公式ドキュメント/Context7 による裏取りがない。
5. **可能性と実発生の軸の欠落**: 「ありえる」だけで指摘可能になっており、"実運用で本当に発生するか" の軸がない。

目的: レビュー指摘を「本当にミッションクリティカルな問題」だけに絞り、実運用で到達するパスを持つ指摘のみを blocking にし、別 Issue 化を人間判断に戻し、真実性検証を強化することで、レビューサイクルの実運用コストを下げる。

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

1. **Observed Likelihood Gate**: reviewer は指摘事項化の必要条件として、Confidence ≥ 80 に加え、Observed Likelihood ≥ Demonstrable (diff 適用後のコードベースで triggering call site or entrypoint 接続を立証) を満たす必要がある。満たさない場合は "報告禁止" または "推奨事項" へ降格。
2. **Hypothetical 例外カテゴリ**: security / database migration / infrastructure / dependencies の 4 reviewer は Hypothetical でも severity 維持可能。他 reviewer は Demonstrable 以上が必須。
3. **Fail-Fast First (reviewer 側)**: reviewer は fallback 追加を推奨する前に throw/raise/再 throw の選択肢を必ず検討。project convention と衝突する場合は Wiki 参照を必須化。skill 側に「fallback 許容条件」がある場合のみ fallback 推奨可。
4. **Fail-Fast First (fix 側)**: fix.md Phase 3 の修正方針決定ステップで、fallback 追加前に throw/raise の検討をチェックリスト必須化。
5. **Fact-Check Phase 拡張**: Internal Likelihood Claim カテゴリを追加し、Grep ベースで call site / trigger 条件を検証。実在しない claim は CONTRADICTED として findings から除外。
6. **Context7 default ON**: `use_context7: true` をデフォルト値に変更。サブエージェント不可用時は既存の WebSearch fallback に自動切替。
7. **max_claims 拡張**: 10 → 20 に引き上げ。Likelihood claim は Grep ベース検証のため上限枠外。
8. **別 Issue 化のユーザー確認必須化**: review.md Phase 7 / fix.md Phase 4.3 / fix.md severity_gating の 3 経路すべてで E2E の AskUserQuestion スキップを撤廃。severity_gating strategy は廃止。
9. **既存問題 (Source C) 廃止**: reviewer 出力から既存問題セクションを削除。代わりに統合レポート末尾に `/rite:investigate` 導線 (非 blocking) を提示。
10. **後方互換性の維持**: `[review:mergeable]` / `[review:fix-needed:N]` 出力パターン、work memory スキーマ、loop 終了条件 `findings == 0` は不変。新規設定キーはすべて opt-out 可能。
11. **Revert Test Gate**: reviewer は指摘事項化の 3 ゲート目として revert test を実施。diff-line inspection (default) / git show comparison / git worktree add で当該 finding が本 PR diff 起因か pre-existing かを判別する。pre-existing と判定された場合は `/rite:investigate` へ委譲 (本 PR の指摘対象外)。"mental" 判定のみは不十分とする。

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

- **ロールアウト安全性**: 4 PR に分割して段階ロールアウト。各 PR 単位で独立に `/rite:lint` + dry-run レビュー検証が可能。
- **False Negative 防止**: 過去 10 件程度の close した PR で新ルールを dry-run 再実行し、本物の bug が降格されていないことを benchmark で確認。
- **既存ユーザーへの配慮**: Context7 default ON は既存 `rite-config.yml` に `use_context7` キーがなければ新 default 適用。リリースノート + `/rite:init --upgrade` で通知。
- **cost 制御**: max_claims=20 は external claim のみに適用。Likelihood claim は Grep ベースで追加コストなし。
- **i18n parity**: すべての新規 UI 文言を `i18n/ja.yml` / `i18n/en.yml` で同期更新。
- **Observability**: 各 PR review 実行後に降格件数、fact-check 件数、AskUserQuestion 発火頻度を work memory / metrics ログに記録 (ロールアウト後の調整判断用)。

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

ユーザー承認済みの決定事項:

| 論点 | 決定 | 理由 |
|---|---|---|
| Fallback 厳密度 | 柔軟運用 (まず throw 検討必須、禁止ではない) | graceful degradation 要件との衝突を避けつつ文化を変える |
| Context7 default | ON (fallback で安全確保) | 真実性検証強化のため。既存 fallback で安全性維持 |
| 既存問題 (Source C) | 報告自体を廃止 | 「本 PR 完結」原則の徹底。見える化は investigate で別途実施 |
| Likelihood 判定軸 | Observed Likelihood Gate | 「1文で書ける」ではなく "triggering path が実在するか" を立証責任化 |
| Hypothetical 例外 | Security / DB migration / Infra / Dependencies の 4 カテゴリ | これらは 1 回の失敗で致命的、または adversarial input 想定が職務 |
| 新機能 PR の抜け穴 | 立証範囲を「diff 適用後のコードベース全体」に設定 | 新規 call site も立証対象に含めることで新機能 PR が全 Hypothetical 降格される穴を塞ぐ |
| Dynamic dispatch | Grep 失敗 ≠ Hypothetical、entrypoint 接続立証で Demonstrable 可 | reflection / hook / framework convention 経由の call site を正しく扱う |
| 指摘ゲートの数 | 3 ゲート同時充足 (Confidence ≥ 80 / Observed Likelihood ≥ Demonstrable / Revert Test pass) | 「本 PR diff 起因問題」と「pre-existing 問題」を機械的に分離し、本 PR スコープ完結を徹底 (pre-existing は `/rite:investigate` 委譲) |

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

改修は以下 4 層に分割される (4 PR 分割に対応):

1. **原則ドキュメント層** (Layer 1)
   - `references/severity-levels.md` — Observed Likelihood Axis + Matrix + 例外カテゴリ
   - `agents/_reviewer-base.md` — Observed Likelihood Gate 節 + Fail-Fast First 節
   - `skills/reviewers/SKILL.md` — 全 reviewer 共通リマインド
   - `skills/reviewers/error-handling.md`, `code-quality.md` — Fail-Fast 明文化
   - `skills/reviewers/security.md`, `database.md`, `devops.md`, `dependencies.md` — Hypothetical 例外宣言

2. **reviewer 出口層** (Layer 2)
   - `commands/pr/review.md` — L1618 mandatory fix policy, L1704 ガイド, L1713-1718 既存問題セクション削除, Phase 7 Source C 廃止 + AskUserQuestion 必須化 + investigate 導線
     (行番号は **設計時点: 2026-04 / `commands/pr/review.md` 全 4102 行** のスナップショットに基づく。Layer 2 実装時にセクション見出しを基準に再マッピングすること)
   - `commands/pr/references/assessment-rules.md` — Observed Likelihood 降格 mechanical rule

3. **Fact-Check 拡張層** (Layer 3)
   - `commands/pr/references/fact-check.md` — Configuration 変更 + Likelihood Claim サブフェーズ + Dynamic dispatch ケース
   - `templates/config/rite-config.yml` — fact_check 既定値変更

4. **fix 応答層 + 設定層 + 全体配線** (Layer 4)
   - `commands/pr/fix.md` — Phase 3 Fail-Fast Response, Phase 4.3 AskUserQuestion 必須, severity_gating 廃止
   - `commands/issue/start.md` — Phase 5.4 Source C 参照削除
   - `templates/config/rite-config.yml` — 新規キー追加
   - `hooks/` — Source C / severity_gating 参照調査・削除
   - `i18n/ja.yml`, `i18n/en.yml` — 新規 UI 文言
   - `CHANGELOG.md`, `CHANGELOG.ja.md`, `docs/` — ユーザー可視化

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

```
Reviewer (subagent)
  ├─ Confidence Gate (≥80, 既存)
  ├─ Observed Likelihood Gate (新規)
  │    └─ Demonstrable 立証 (Grep call site / entrypoint 接続)
  ├─ Revert Test Gate (新規、3 ゲート目)
  │    └─ diff-line inspection / git show comparison / git worktree add で
  │       diff 起因か pre-existing かを判別
  └─ Fail-Fast First Review (fallback 推奨前に throw 検討)
       ↓ findings
review.md Phase 5 (Critic Pipeline)
  ├─ 5.1 Result Collection (上記フローの findings を集約)
  ├─ 5.2 Cross-Validation
  │    ├─ Dedup (同一 file:line の findings を集約し severity 最高値を採用)
  │    ├─ Fact-Check Phase (拡張)
  │    │    ├─ External Claim Verification (既存)
  │    │    └─ Internal Likelihood Claim Verification (新規)
  │    │         └─ Grep で call site 検証 → CONTRADICTED なら除外
  │    └─ Spec Consistency (Issue 仕様との整合確認)
  ├─ 5.3 Overall Assessment Determination
  │    └─ Observed Likelihood mechanical 降格 rule
  └─ 5.4 Integrated Report Generation
          ↓ assessment
review.md Phase 7 (Issue Creation)
  ├─ Source A (findings with keyword) ← 残存
  ├─ Source B (recommendations with keyword) ← 残存
  └─ Source C (pre-existing issues) ← **廃止**
       ↓
  AskUserQuestion (E2E でも必須) → ユーザー確認後に Issue 作成
```

fix.md の応答フロー:

```
fix.md Phase 1 (findings parse)
  ↓
fix.md Phase 3 (修正方針決定)
  └─ Fail-Fast Response Checklist (新規)
       ├─ throw/raise で伝播できないか
       ├─ 既存エラー境界に到達できないか
       ├─ null チェック追加は問題隠蔽になっていないか
       └─ テストが throw を許さない形式なら、テスト側を修正
  ↓
fix.md Phase 4.3 (別 Issue 化)
  ├─ severity_gating strategy ← **廃止**
  └─ skip findings → AskUserQuestion 必須 (E2E でも) → 再試行/Issue化/取り下げ
```

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

| PR | 層 | 主要ファイル |
|---|---|---|
| PR #1 | 原則ドキュメント | `references/severity-levels.md`, `agents/_reviewer-base.md`, `skills/reviewers/SKILL.md`, `error-handling.md`, `code-quality.md`, `security.md`, `database.md`, `devops.md`, `dependencies.md` |
| PR #2 | reviewer 出口 | `commands/pr/review.md`, `commands/pr/references/assessment-rules.md` |
| PR #3 | Fact-Check 拡張 | `commands/pr/references/fact-check.md`, `templates/config/rite-config.yml` (fact_check セクション) |
| PR #4 | fix 応答 + 配線 | `commands/pr/fix.md`, `commands/issue/start.md`, `templates/config/rite-config.yml` (残りキー), `hooks/`, `i18n/ja.yml`, `i18n/en.yml`, `CHANGELOG.md`, `CHANGELOG.ja.md`, `docs/` |

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

**エッジケース**:

- **新規機能 PR の立証責任**: Gate の「call site 実在」は「diff 適用後のコードベース全体」を対象にすること。既存コードだけに限定すると新機能 PR が全て Hypothetical 降格する。
- **Dynamic dispatch / reflection / hook**: Grep で call site が見つからなくても、framework convention / CLI / webhook / cron 等のエントリポイント接続を立証できれば Demonstrable 扱い。
- **Project convention との衝突**: 既存コードベースが fallback を標準パターンとしている場合、reviewer は Wiki (`/rite:wiki:query`) を必須参照してから推奨を書く。
- **Context7 アップグレードパス**: 既存ユーザーが新 default を受け取る際は `/rite:init --upgrade` + CHANGELOG で通知。サブエージェント不可用時は既存 fallback で安全。
- **Source C 廃止の副作用**: PR 対象ファイルの既存 CRITICAL/HIGH が見えなくなる懸念は、統合レポート末尾の `/rite:investigate` 導線 (非 blocking) で緩和。

**リスクと緩和**:

| リスク | 緩和策 |
|---|---|
| Likelihood gate が Security 以外の重大問題を落とす | Demonstrable の定義に "entrypoint 接続" を含める、例外カテゴリを 4 つに拡張 |
| Context7 default ON で subagent 委譲時に失敗 | 既存 L106 WebSearch fallback で自動回復、opt-out キー確保 |
| Fail-Fast First が graceful degradation と衝突 | 禁止ではなく "まず検討" の必須化、skill 側 exception で逃げ道 |
| AskUserQuestion 強制で自動 loop が停止 | 停止は仕様どおり (人間判断必須地点)、完全自動化は opt-out |
| max_claims=20 で cost 増 | Likelihood claim は Grep ベースで無料、external のみ上限 |
| 既存 hooks が Source C / severity_gating を参照 | PR #4 で事前調査 (Pre-flight Check) + 参照削除 |

**Pre-flight Checks** (PR #1 のキックオフタスクとして実施):

1. `hooks/` 配下を `grep -rn "Source C\|severity_gating\|既存問題"` で参照箇所を列挙
2. 既存 E2E テストで review-fix ループ終了条件が検証されているか確認
3. `/rite:init --upgrade` が既存ユーザーの `rite-config.yml` をどう扱うか確認、新規キーの opt-in/opt-out デフォルト決定
4. `_reviewer-base.md` の Wiki 参照必須化を reviewer instruction template に注入する経路の確認

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

以下は本改修に含めない:

- **review-fix loop 終了条件の変更**: `findings == 0` の原則は維持
- **Confidence 閾値 (80) の変更**: 既存値を据え置き、新 Gate を直交追加
- **reviewer エージェントの統廃合**: 既存 13 reviewer はそのまま維持
- **Wiki 構造の変更**: Wiki 参照の仕組みは既存を利用
- **Context7 MCP 以外の外部検証ソース追加**: WebSearch / WebFetch / Context7 の既存 3 種で十分
- **レビュー UI の変更**: PR コメント出力フォーマットは既存
- **Phase 5 Critic Pipeline の根本再設計**: Dedup → Fact-Check → Spec Consistency → Assessment の順序は維持
- **既存の work memory スキーマ変更**: 読み書きキーは既存のまま

---

## 参照

- 親 Issue: #502 — refactor(review): レビュー修正サイクルの根本見直し (Observed Likelihood Gate + Fail-Fast First)
- Layer 1 実装 Issue: #503 — refactor(review): 原則ドキュメント層に Observed Likelihood Gate + Fail-Fast First 導入
- 後続 Layer の Issue は親 Issue #502 のタスクリストから辿れる
