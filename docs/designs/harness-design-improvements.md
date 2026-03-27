# Anthropic ハーネス設計記事の知見を rite workflow に取り入れる

## 実装ステータス

| # | 改善領域 | ステータス | Issue |
|---|---------|-----------|-------|
| 1 | Sprint Contract（検証基準） | ✅ 実装済み | #256 |
| 2 | Evaluator キャリブレーション（Few-shot 例） | ⬜ 未着手 | #257 |
| 3 | Post-Step Quality Gate（セルフチェック） | ✅ 実装済み | #258 |
| 4 | コンテキストリセット戦略強化 | ⬜ 未着手 | #259 |

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

Anthropic Engineering ブログ記事 "[Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps)" (2026-03-24) の知見を分析し、rite workflow に適用可能な改善を実装する。記事は GAN にインスピレーションを得た Generator-Evaluator パターンを軸に、長時間実行エージェントの設計原則を解説している。

対象となる改善は 4 領域:
1. Sprint Contract（実装ステップごとの検証基準）— **実装済み**
2. Evaluator キャリブレーション（Few-shot 例追加）
3. Post-Step Quality Gate（実装後セルフチェック）
4. コンテキストリセット戦略強化

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

rite workflow は既に Generator-Evaluator 分離、ファイルベース通信、Sprint 構造、コンテキスト管理の基盤を持っているが、記事が指摘する以下の点でギャップがある:

- **実装ステップの完了定義がない**: 依存グラフテーブルに「何をもって完了とするか」の基準列がなく、Adaptive Re-evaluation が「次に何をするか」の判断のみで「前のステップが本当に完了したか」を検証しない
- **レビュアーの品質キャリブレーションが抽象的**: チェックリストと重要度定義はあるが、Few-shot 例（良い指摘/報告すべきでないケース）がなく、抽象的なガイドラインのみ
- **実装中の自己品質チェックがない**: Adaptive Re-evaluation は次ステップ選択とボトルネック検出に焦点、直前ステップの品質（スコープ逸脱、リグレッション、仕様乖離）は未チェック
- **コンテキスト圧力時のリセット推奨が弱い**: ORANGE 閾値で出力最小化を推奨するのみで、`/clear` + `/rite:resume` による積極的リセットを提案しない

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

1. **Sprint Contract** ✅: `implementation-plan.md` の依存グラフテーブルに `検証基準` 列を追加し、`implement.md` の 5.1.0.5 Adaptive Re-evaluation でステップ完了前に検証基準を Read/Grep/Bash で確認する（#256 で実装済み）
2. **Few-shot Evaluator Calibration**: 全レビュアー共通の Few-shot 例集（`finding-examples.md`）を作成し、良い指摘例・報告すべきでない例・ボーダーライン例を提供する。`SKILL.md` に懐疑的トーン設定を追加する
3. **Post-Step Quality Gate**: 5.1.0.5 内にスコープ逸脱・リグレッション懸念・仕様整合の軽量セルフチェックを追加する
4. **Context Reset Strategy**: ORANGE 閾値到達時に `/clear` + `/rite:resume` を推奨するメッセージに変更し、work memory の自動最新化を追加する

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

- 検証基準チェックは既存の Adaptive Re-evaluation フロー内に統合し、追加のツール呼び出しを最小限に抑える
- Post-Step Quality Gate はツール呼び出し不要（直前の作業コンテキストから判断）で 10 秒以内に完了する
- Few-shot 例は全レビュアー共通ファイル 1 つで管理し、各レビュアースキルファイルへの個別追加は初期段階では不要
- コンテキストリセットは「推奨」であり「強制」ではない（Opus 4.6 の 1M コンテキストでは compaction で十分なケースもある）

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

| 決定 | 理由 |
|------|------|
| 検証基準は「ツールで確認可能」なものに限定 | ファイル存在、関数エクスポート、grep 可能な条件など、機械的に検証できるものだけを基準とし、主観的判断を排除 |
| Few-shot 例は共通ファイル 1 つで開始 | 10 個のレビュアースキルに個別例を追加するのは初期コストが高い。共通例で効果を確認後、必要に応じてドメイン固有例を追加 |
| Post-Step Quality Gate はメンタルチェック | ツール呼び出しを追加するとコンテキスト消費が増大し、本末転倒。直前の作業記憶から判断する軽量チェックに留める |
| コンテキストリセットは選択肢として強化 | 強制リセットはモデル改善で不要になるリスクがある。記事の「簡素化原則」に従い、選択肢として提供 |

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

| コンポーネント | 改善 | 役割 | ステータス |
|--------------|------|------|-----------|
| `plugins/rite/commands/issue/implementation-plan.md` | 1 | 依存グラフテンプレートに検証基準列を追加 | ✅ 実装済み |
| `plugins/rite/commands/issue/implement.md` | 1, 3 | 5.1.0.5 に検証ステップを追加（改善1）、Post-Step Quality Gate を追加（改善3） | 改善1: ✅ / 改善3: ✅ |
| `plugins/rite/skills/reviewers/references/finding-examples.md` | 2 | Few-shot 例集（新規作成） | ⬜ 未着手 |
| `plugins/rite/skills/reviewers/SKILL.md` | 2 | 懐疑的トーン設定 + finding-examples.md 参照追加 | ⬜ 未着手 |
| `plugins/rite/hooks/context-pressure.sh` | 4 | ORANGE 閾値メッセージ強化 | ⬜ 未着手 |
| `plugins/rite/commands/resume.md` | 4 | 単一 Issue 実装途中リジューム強化 | ⬜ 未着手 |

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

```
改善 1 (Sprint Contract):
  implementation-plan.md Phase 3.3 → 検証基準付きテーブル生成
    → implement.md 5.1.0.5 → ステップ完了前に検証基準を確認
    → 基準未達 → 再試行 or 計画逸脱ログ

改善 2 (Evaluator Calibration):
  finding-examples.md → SKILL.md Finding Quality Policy が参照
    → 各レビュアーエージェントが実行時にロード
    → レビュー出力品質の向上

改善 3 (Post-Step Quality Gate):
  implement.md 5.1.0.5 → 検証基準チェック後 → Quality Gate チェック
    → 逸脱検知 → 計画逸脱ログに記録

改善 4 (Context Reset):
  context-pressure.sh ORANGE → work memory 最新化 + /clear 推奨メッセージ
    → ユーザーが /clear 実行 → /rite:resume で状態復元
```

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

| ファイル | 変更内容 | 改善 |
|---------|---------|------|
| `plugins/rite/commands/issue/implementation-plan.md` | Phase 3.3 テンプレートに `検証基準` 列追加 + 検証基準記述ガイドライン追加 | 1 |
| `plugins/rite/commands/issue/implement.md` | 5.1.0.5 に検証基準チェックステップ追加 + Post-Step Quality Gate 追加 | 1, 3 |
| `plugins/rite/skills/reviewers/references/finding-examples.md` | 新規作成: 良い指摘例 2-3 件、報告すべきでない例 2-3 件、ボーダーライン例 1 件 | 2 |
| `plugins/rite/skills/reviewers/SKILL.md` | Finding Quality Policy に懐疑的トーン設定追加 + finding-examples.md 参照追加 | 2 |
| `plugins/rite/hooks/context-pressure.sh` | ORANGE 閾値メッセージを `/clear` + `/rite:resume` 推奨に変更 | 4 |
| `plugins/rite/commands/resume.md` | Flow state + Work memory + Implementation plan からの完全状態復元強化 | 4 |

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

- **改善 1 と 3 の依存関係**: 改善 3 (Post-Step Quality Gate) は改善 1 (Sprint Contract) の検証基準を前提とする。実装順序は 1 → 3
- **既存テーブルフォーマットとの互換性**: 検証基準列の追加により、既存の work memory 更新ロジック（5.1.1.2 の一括反映）が影響を受ける可能性がある。`状態` 列のインデックスがずれないか確認が必要
- **Few-shot 例の言語**: `rite-config.yml` の `language` 設定に応じて日本語/英語の例を提供するか、日本語のみとするか。初期段階では日本語のみで開始し、必要に応じて i18n 対応
- **context-pressure.sh のメッセージ変更**: stdout と stderr の使い分けが既存ロジックで重要（stdout はモデルへのヒント、stderr はユーザー表示）。変更時にこの区別を維持する

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

| 項目 | 理由 |
|------|------|
| 簡素化監査（コンポーネント削減） | rite は汎用プラグイン（Sonnet/Opus 混在）。特定モデルへの最適化はリスクが高い |
| Planner スコープ拡大 | rite は Issue ドリブン。記事のオープンエンドなユースケースとは前提が異なる |
| QA/Evaluator 効果追跡 | Ground truth データ（人間の判定）が必要。将来課題 |
| 各レビュアースキルへの個別 Few-shot 例追加 | 共通例で効果を確認後に検討 |
| コンテキストリセットの強制化 | モデル改善で不要になるリスク。選択肢として提供のみ |
