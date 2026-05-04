# [Umbrella] refactor(create): create-interview/decompose/register.md 本体スリム化

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

`/rite:issue:create` コマンドを構成する 3 つの sub-skill ファイルの本体スリム化を実施する。

- `create-interview.md` (現状 511 行 → 目標 ≤200 行)
- `create-decompose.md` (現状 661 行 → 目標 ≤300 行)
- `create-register.md` (現状 615 行 → 目標 ≤300 行)

各ファイル独立で進められるため Sub-Issue 化する。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

Issue #773 (#768 P1-3) PR 1-8 で 8 references の抽出は完了したが、本体側の重複削除は部分着手にとどまっている。本体スリム化により PDF 原則「Critical instructions at the top」「Move detailed reference to separate files」(p.13) の本来の効果 (LLM 認知負荷削減 / context 占有量削減) を達成する。

create.md の本体スリム化は別 Issue (#803) で扱うため、本 Umbrella は残り 3 ファイルを対象とする。

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

- 各ファイルから既存 references への重複箇所を削除し、参照リンクに置き換える
- 各 Sub-Issue は完全独立で並行作業可能
- 各 Sub-Issue 内で対象ファイルのみを修正 (references 側変更は別 Issue)

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

- NFR-2 protected (本体に残す) — 全 3 ファイル共通:
  - 4-site 対称化 grep test pass (`hooks/tests/4-site-symmetry.test.sh`)
  - Defense-in-Depth section (Pre-flight bash block / Return Output re-patch)
  - Terminal Completion sentinel emit ロジック (`create-decompose` / `create-register` の Phase 1.0 / Phase 4)
  - Pre-flight bash block (`create-interview` Phase 1)

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

- スリム化方針: 各 references への参照リンク (Markdown blockquote 形式 `> **Moved (Issue #773 P1-3 PR N/8)**:`) で重複削除
- PR 戦略: 各 Sub-Issue は独立 PR で実施、cross-link 整合性チェックを各 PR 内で完結
- Sub-Issue 分解基準: ファイル単位 (各 sub-skill ファイル = 1 Sub-Issue)

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

3 つの sub-skill ファイルが orchestrator (`create.md`) から呼び出される構造:

```
create.md (orchestrator)
├── create-interview.md   ← Phase 0.4.1 + 0.5
├── create-decompose.md   ← Phase 0.7 + 0.8 + 0.9 + 1.0
└── create-register.md    ← Phase 1 + 2 + 3 + 4
```

各ファイルは独立して動作するため、本体スリム化も独立で進められる。

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

スリム化前後で以下のデータフローは変更なし:

1. `create.md` から各 sub-skill が Skill tool 経由で起動
2. Pre-flight bash block で flow state 更新 (NFR-2 protected)
3. 本体ロジック実行 (本体スリム化対象)
4. Return Output で sentinel emit + control return (NFR-2 protected)

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

| Sub-Issue | 対象ファイル | 主な参照先 references |
|-----------|--------------|----------------------|
| #1 | `plugins/rite/commands/issue/create-interview.md` | edge-cases-create.md (EDGE-2 / EDGE-5)、complexity-gate.md |
| #2 | `plugins/rite/commands/issue/create-decompose.md` | bulk-create-pattern.md (PR 8 抽出 Phase 0.9.2)、edge-cases-create.md (EDGE-3)、contract-section-mapping.md |
| #3 | `plugins/rite/commands/issue/create-register.md` | contract-section-mapping.md (PR 7 抽出)、complexity-gate.md、edge-cases-create.md |

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

- **Parallel work conflict**: 3 Sub-Issue が同一 references を読むのは OK (read-only)、references 側を modify するのは別 Issue で実施
- **NFR-2 protected 削除リスク**: 各 Sub-Issue の reviewer に「NFR-2 protected 項目を grep verify」を AC に含める
- **cross-file links**: スリム化後も `start.md` / 他 references / `hooks/tests` からの link target が壊れないか各 PR 内で verify

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

- `create.md` 本体スリム化 (別 Issue #803 で扱う)
- 新規 references ファイルの作成
- references 側の修正 (cross-file impact が出る場合は別 Issue)
