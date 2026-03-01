# テスト仕様書: start.md フロー継続の責任パターン

## 概要

`plugins/rite/commands/issue/start.md` の「フロー継続の責任」パターンに対するテスト仕様書。
Issue #377 で導入された、Task エージェント方式によるコンテキスト分離と、各 Skill が次の Skill を呼び出す責任を持つ設計の検証。

## 対象機能

`/rite:issue:start` の Phase 5 では、2 層のフロー継続パターンが採用されている:

### 1. start.md: Task エージェント方式

`/rite:issue:start` が Task ツールでサブコマンドを呼び出し、結果に応じて次のステップに進む。

| ステップ | Task ツールでの実行 | 結果の処理 |
|---------|-------------------|-----------|
| 5.2 lint | `rite:lint` を Task で実行 | `[lint:success]`/`[lint:skipped]` → 5.3 へ |
| 5.3 PR 作成 | `rite:pr:create` を Task で実行 | PR 番号を取得 → 5.4 へ |
| 5.4 レビュー | `rite:pr:review` を Task で実行 | 結果に応じて 5.5 へ |
| 5.5 修正 | 必要に応じて `rite:pr:fix` を Task で実行 | 修正後 5.4 に戻る |

### 2. 各 Skill: フロー継続の責任

各 Skill（lint.md, pr/create.md, pr/review.md）は、一気通貫フロー内で実行された場合、次の Skill を呼び出す責任を持つ:

| Skill | フロー継続の責任 |
|-------|-----------------|
| `/rite:lint` | 成功/スキップ時、Skill ツールで `rite:pr:create` を呼び出す |
| `/rite:pr:create` | 成功時、Skill ツールで `rite:pr:review` を呼び出す |
| `/rite:pr:review` | 結果に応じて `rite:pr:fix` または `rite:pr:ready` を呼び出す |

---

## テストケース

### TC-001: フロー継続の責任（Task エージェント方式）の構造確認

**目的**: 「フロー継続の責任（Task エージェント方式）」セクションが正しい構造と内容を持っていることを確認する。

**対象セクション** (`start.md`):

```markdown
### フロー継続の責任（Task エージェント方式）

> **`/rite:issue:start` が Task ツールでサブコマンドを呼び出し、結果に応じて次のステップに進む。各サブコマンドは独立したコンテキストで実行されるため、親コンテキストを圧迫しない。**

**Task エージェント方式の利点:**
- **コンテキスト分離**: 各サブコマンドが独立したコンテキストで実行され、親の会話履歴を圧迫しない
- **結果の明確化**: Task ツールの戻り値として結果を受け取るため、フロー制御が明確
- **エラー隔離**: サブコマンドのエラーが親コンテキストに影響しない

| ステップ | Task ツールでの実行 | 結果の処理 |
|---------|-------------------|-----------|
| 5.2 lint | `rite:lint` を Task で実行 | `[lint:success]`/`[lint:skipped]` → 5.3 へ、`[lint:error]` → 修正後再実行 |
| 5.3 PR 作成 | `rite:pr:create` を Task で実行 | PR 番号を取得 → 5.4 へ |
| 5.4 レビュー | `rite:pr:review` を Task で実行 | 結果に応じて 5.5 へ |
| 5.5 修正 | 必要に応じて `rite:pr:fix` を Task で実行 | 修正後 5.4 に戻る |
```

**検証項目**:

| # | 検証項目 | 期待値 | 結果 |
|---|---------|--------|------|
| 1 | セクション名 | 「フロー継続の責任（Task エージェント方式）」 | - |
| 2 | 引用ブロック | Task ツールでサブコマンドを呼び出す説明 | - |
| 3 | 利点リスト | コンテキスト分離、結果の明確化、エラー隔離 | - |
| 4 | テーブルの行数 | 4 行（ヘッダー除く: 5.2, 5.3, 5.4, 5.5） | - |
| 5 | lint の結果処理 | `[lint:success]`/`[lint:skipped]` → 5.3 へ | - |
| 6 | レビューの結果処理 | 結果に応じて 5.5 へ | - |

---

### TC-002: /rite:issue:start からの最初のサブコマンド呼び出し確認

**目的**: `/rite:issue:start` が Phase 5.2 で Task ツールを使用して `rite:lint` を呼び出すことを確認する。

**対象セクション** (`start.md` Phase 5.2):

```markdown
### 5.2 品質チェック

5.1 完了後、Task ツールで `rite:lint` を呼び出す（コンテキスト分離）。

```yaml
Task ツール呼び出し:
  description: "Run rite:lint"
  prompt: |
    /rite:lint を実行してください。
    ...
  subagent_type: "general-purpose"
```
```

**検証項目**:

| # | 検証項目 | 期待値 | 結果 |
|---|---------|--------|------|
| 1 | 呼び出すタイミング | 5.1 完了後 | - |
| 2 | 使用するツール | Task ツール（Skill ツールではない） | - |
| 3 | subagent_type | `general-purpose` | - |
| 4 | 呼び出すコマンド | `/rite:lint` | - |

---

### TC-003: Phase 5.2〜5.5 の Task ツール呼び出しパターン確認

**目的**: Phase 5.2〜5.5 で `/rite:issue:start` が Task ツールを使用して各サブコマンドを順次呼び出す設計になっていることを確認する。

**対象セクション** (`start.md` フローの概要):

```
5.2 品質チェック（/rite:lint）
    ↓ Task ツール完了後、/rite:issue:start が結果を確認

5.3 ドラフト PR 作成（/rite:pr:create）
    ↓ Task ツール完了後、/rite:issue:start が結果を確認

5.4 セルフレビュー（/rite:pr:review）
    ↓ Task ツール完了後、/rite:issue:start が結果を確認

5.5 レビュー結果対応
    ↓ /rite:issue:start が結果に応じて /rite:pr:fix を呼び出し
```

**検証項目**:

| # | Phase | 検証内容 | 期待値 | 結果 |
|---|-------|---------|--------|------|
| 1 | 5.2 | lint 結果の処理 | `/rite:issue:start` が Task 結果を確認し 5.3 へ進む | - |
| 2 | 5.3 | PR 作成後の処理 | `/rite:issue:start` が Task 結果を確認し 5.4 へ進む | - |
| 3 | 5.4 | レビュー後の処理 | `/rite:issue:start` が Task 結果を確認し 5.5 へ進む | - |
| 4 | 5.5 | 修正判断 | `/rite:issue:start` が結果に応じて `/rite:pr:fix` を呼び出し | - |

---

### TC-004: フロー図の整合性確認

**目的**: Phase 5 のフロー概要図が Task エージェント方式を正しく反映していることを確認する。

**対象セクション** (`start.md` フローの概要):

```
5.1 実装作業・コミット・プッシュ
    ↓ git push 成功？
    ├─ No → エラー修正して再プッシュ
    └─ Yes → Task ツールで rite:lint を呼び出す（コンテキスト分離）

────────────────────────────────────────
以下のステップは /rite:issue:start が Task ツールで各コマンドを
順次呼び出す。各コマンドは独立したコンテキストで実行され、
結果のみが親コンテキストに返される。
────────────────────────────────────────
```

**検証項目**:

| # | 検証項目 | 期待値 | 結果 |
|---|---------|--------|------|
| 1 | 5.1 完了後のアクション | 「Task ツールで rite:lint を呼び出す（コンテキスト分離）」 | - |
| 2 | 区切り線の存在 | `────────` で区切られている | - |
| 3 | 説明文 | 「/rite:issue:start が Task ツールで各コマンドを順次呼び出す」 | - |
| 4 | コンテキスト分離の記載 | 「各コマンドは独立したコンテキストで実行」 | - |

---

### TC-005: 各 Skill 仕様書でのフロー継続責任パターン確認

**目的**: 各 Skill の仕様書に「フロー継続の責任」が明記され、一気通貫フロー内で次の Skill を Skill ツールで呼び出すロジックが実装されていることを確認する。

**対象ファイル**:

| Skill | 仕様書パス | 確認セクション |
|-------|-----------|---------------|
| `/rite:lint` | `plugins/rite/commands/lint.md` | 「呼び出し元コンテキストと一気通貫フロー」「Phase 5」 |
| `/rite:pr:create` | `plugins/rite/commands/pr/create.md` | 「呼び出し元コンテキストと一気通貫フロー」「Phase 5」 |
| `/rite:pr:review` | `plugins/rite/commands/pr/review.md` | 「呼び出し元コンテキストと一気通貫フロー」「Phase 8」 |

**検証方法**:

```bash
# 各ファイルで「フロー継続の責任」と次の Skill 呼び出しを検索
grep -n "フロー継続の責任\|rite:pr:create" plugins/rite/commands/lint.md
grep -n "フロー継続の責任\|rite:pr:review" plugins/rite/commands/pr/create.md
grep -n "フロー継続の責任\|rite:pr:fix\|rite:pr:ready" plugins/rite/commands/pr/review.md
```

**検証項目**:

| # | 対象 | 検証内容 | 期待値 | 結果 |
|---|------|---------|--------|------|
| 1 | lint.md | 「フロー継続の責任」の明記 | 「この Skill が次の Skill（`rite:pr:create`）を呼び出す責任を持つ」 | - |
| 2 | lint.md | Skill ツール呼び出し | `skill: "rite:pr:create"` | - |
| 3 | pr/create.md | 「フロー継続の責任」の明記 | 「この Skill が次の Skill（`rite:pr:review`）を呼び出す責任を持つ」 | - |
| 4 | pr/create.md | Skill ツール呼び出し | `skill: "rite:pr:review"` | - |
| 5 | pr/review.md | 「フロー継続の責任」の明記 | 「この Skill がレビュー結果に応じて次の Skill を呼び出す責任を持つ」 | - |
| 6 | pr/review.md | Skill ツール呼び出し | `skill: "rite:pr:fix"` または `skill: "rite:pr:ready"` | - |

---

### TC-006: コンテキスト分離の意図確認

**目的**: Issue #377 の背景（コンテキスト圧迫の解決）が仕様書に反映されていることを確認する。

**対象**: Issue #377 の概要

> `/rite:issue:start` 実行中にコンテキストが圧迫される問題を解決するため、内部で呼び出すサブコマンド（`/rite:pr:create`、`/rite:pr:review`、`/rite:pr:ready`）を Task エージェントでコンテキスト分離する。

**検証項目**:

| # | 検証項目 | 期待値 | 結果 |
|---|---------|--------|------|
| 1 | 各 Skill が独立して実行される | `/rite:issue:start` は最初の Skill のみ呼び出す | - |
| 2 | 親コンテキストの圧迫軽減 | 各 Skill が自身のコンテキスト内で処理を完結 | - |

**手動検証手順**:

1. `/rite:issue:start` を実行
2. Phase 5 まで進める
3. 各 Skill 呼び出し時のコンテキスト使用量を観察
4. lint → pr:create → pr:review の遷移が自動で行われることを確認

---

### TC-007: 誤動作パターンの防止確認

**目的**: 仕様書が AI の誤動作パターンを防止する設計になっていることを確認する。

**防止すべき誤動作パターン**:

| # | 誤動作パターン | 防止方法 | 確認箇所 | 結果 |
|---|--------------|---------|---------|------|
| 1 | lint 後に停止して「PR を作成しますか？」と確認を求める | lint.md に「Skill ツールで `rite:pr:create` を呼び出す」「停止は禁止」と明記 | lint.md Phase 5 | - |
| 2 | PR 作成後に停止して「レビューを開始しますか？」と確認を求める | pr/create.md に「Skill ツールで `rite:pr:review` を呼び出す」「停止は禁止」と明記 | pr/create.md Phase 5 | - |
| 3 | `/rite:issue:start` が Skill ツールで各コマンドを呼び出そうとする | start.md に「Task ツールで」と明記し、コンテキスト分離を強調 | start.md Phase 5.2〜5.5 | - |
| 4 | サブコマンドがフロー継続せず呼び出し元に戻る | 各 Skill 仕様書に「呼び出し元への復帰を待たない」と明記 | lint.md, pr/create.md, pr/review.md | - |

---

## 付録: 関連仕様書

| ファイル | 関連セクション | 役割 |
|---------|---------------|------|
| `plugins/rite/commands/issue/start.md` | Phase 5「フロー継続の責任（Task エージェント方式）」 | Task ツールで各サブコマンドを呼び出す |
| `plugins/rite/commands/lint.md` | 「呼び出し元コンテキストと一気通貫フロー」「Phase 5」 | 一気通貫時に Skill で `rite:pr:create` を呼び出す |
| `plugins/rite/commands/pr/create.md` | 「呼び出し元コンテキストと一気通貫フロー」「Phase 5」 | 一気通貫時に Skill で `rite:pr:review` を呼び出す |
| `plugins/rite/commands/pr/review.md` | 「呼び出し元コンテキストと一気通貫フロー」「Phase 8」 | 一気通貫時に結果に応じて次の Skill を呼び出す |

---

## テスト実行記録

| 日付 | テスター | 結果 | 備考 |
|------|---------|------|------|
| - | - | - | - |

---

## 変更履歴

| 日付 | 変更内容 |
|------|---------|
| 2026-02-03 | 初版作成（#379 - Issue #377 の残作業） |
