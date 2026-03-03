# テスト仕様書: stop-guard.sh

## 概要

- **対象スクリプト**: `plugins/rite/hooks/stop-guard.sh`
- **テストスクリプト**: `plugins/rite/hooks/tests/stop-guard.test.sh`

### 関連 Issue / PR

| 番号 | 種別 | 内容 |
|------|------|------|
| #495 | Issue | stop-guard.sh の品質改善（元 Issue） |
| #504 | PR | 変数クォートと macOS 互換性の修正（#495 対応） |
| #506 | Issue | テスト追加（#495 の残作業、本テスト仕様書） |

## 対象機能

rite workflow のアクティブセッション中に Claude が停止しようとした際、exit 2 + stderr でブロックするフック。

主な検証対象:
- exit 2 + stderr によるブロック動作（Claude Code が停止を阻止し stderr をアシスタントにフィード）
- `$AGE` 変数のクォート（`STATE_TS` が非数値の場合の安全性）
- `date -d`（GNU）→ `date -j -f`（macOS BSD）→ `echo 0` のフォールバックチェーン
- タイムゾーン付き日時文字列（`+09:00` 形式）の `sed` コロン除去処理
- `STATE_TS=0` 時のフォールバック動作

---

## テストケース

### TC-001: stop_hook_active=true は無視され通常フローへ（チェック削除済み）

**目的**: `stop_hook_active` チェックが削除されたことを確認。`stop_hook_active: true` でも特別扱いされず、通常の cwd チェックに進む。cwd が存在しないため exit 0。

**入力**:
```json
{"stop_hook_active": true, "cwd": "<tempdir>/nonexistent-dir"}
```

**期待結果**: exit 0、出力なし（cwd チェックで早期リターン）

**背景**: `stop_hook_active` チェックは `preventedContinuation` が常に `false` のため無限ループが発生しないことが判明し、削除された。

---

### TC-002: ステートファイル不存在

**目的**: `.rite-flow-state` ファイルが存在しない場合に exit 0 することを確認。

**入力**: `cwd` にステートファイルがないディレクトリを指定

**期待結果**: exit 0、出力なし

---

### TC-003: active=false

**目的**: ステートファイルの `active` が `false` の場合に exit 0 することを確認。

**ステートファイル**:
```json
{"active": false, "updated_at": "2026-01-01T00:00:00+00:00"}
```

**期待結果**: exit 0、出力なし

---

### TC-004: STATE_TS 非数値フォールバック（AGE 変数クォート安全性）

**目的**: `updated_at` が `date` コマンドでパースできない文字列の場合、`echo 0` フォールバックが発動し、`$AGE` の算術展開が安全に動作することを確認。

**ステートファイル**:
```json
{"active": true, "updated_at": "INVALID-TIMESTAMP", "phase": "test", "next_action": "test"}
```

**期待結果**: STATE_TS=0 → AGE=CURRENT（>> 3600）→ exit 0、出力なし

**検証ポイント**: PR #504 で修正された `"$AGE"` のクォートが正しく機能し、`STATE_TS` が非数値にならないこと。

---

### TC-005: GNU date -d による ISO 8601 パース検証

**目的**: GNU `date -d` が ISO 8601 タイムスタンプを正しくパースし、エポック秒に変換できることを確認。

**ステートファイル**: `updated_at` を現在時刻の 5 分前に設定

**期待結果**: AGE ≈ 300（< 3600）→ exit 2、stderr にフェーズ/アクション情報を含むメッセージ

**注**: Linux 環境では `date -d` が成功するため、2 番目（`date -j -f`）と 3 番目（`echo 0`）のフォールバックはテストされない。macOS でのテストは手動検証が必要。

---

### TC-006: タイムゾーン付き日時文字列（+09:00 形式）

**目的**: `+09:00` 形式のタイムゾーンオフセットを含むタイムスタンプが正しく処理されることを確認。

**ステートファイル**:
```json
{"active": true, "updated_at": "2020-01-01T00:00:00+09:00", "phase": "test", "next_action": "test"}
```

**期待結果**: 古いタイムスタンプ → AGE > 3600 → exit 0

**検証ポイント**:

| 環境 | 検証される範囲 | 検証されない範囲 |
|------|---------------|-----------------|
| Linux (GNU date) | `date -d` が `+09:00` 形式を含むタイムスタンプを正しくパースすること | `sed` コロン除去、`date -j -f` パース（フォールバック先に到達しないため） |
| macOS (BSD date) | `sed` コロン除去（`+09:00` → `+0900`）、`date -j -f` パース | `date -d`（GNU date 非対応） |

**注**: Linux 自動テストでは `date -d` が `+09:00` を直接処理するため sed 分岐には到達しない。macOS 固有のフォールバック（`sed` + `date -j -f`）は手動検証セクションを参照。

---

### TC-007: STATE_TS=0 フォールバック動作

**目的**: `updated_at` が空文字列の場合、すべての `date` コマンドが失敗し、`echo 0` フォールバックで `STATE_TS=0` となり、`AGE = CURRENT - 0 = CURRENT`（数十億秒）で exit 0 することを確認。

**ステートファイル**:
```json
{"active": true, "updated_at": "", "phase": "test", "next_action": "test"}
```

**期待結果**: STATE_TS=0 → AGE=CURRENT（>> 3600）→ exit 0、出力なし

---

### TC-008: 通常ケース（アクティブ、1時間以内）→ block

**目的**: ワークフローがアクティブかつ 1 時間以内の場合、stop をブロックし、フェーズとアクション情報を含む JSON を出力することを確認。

**ステートファイル**: `updated_at` を現在時刻に設定、`phase: "implementing"`, `next_action: "run tests"`

**期待結果**（部分一致で検証）:
- exit code が 2 であること
- stdout が空であること
- stderr に `"rite workflow active"` と `"implementing"` と `"run tests"` が含まれること

**参考**: 完全な stderr 文字列:
```
rite workflow active (phase: implementing). CONTINUE: run tests. If context limit reached, use /clear then /rite:resume to recover.
```

---

### TC-009: 1時間超過（stale 判定）

**目的**: `updated_at` が 1 時間以上前の場合、ワークフローが放棄されたと判定し exit 0 することを確認。

**ステートファイル**: `updated_at` を 2 時間前に設定

**期待結果**: AGE > 3600 → exit 0、出力なし

---

### TC-010〜TC-012: 境界値テスト群

TC-010/TC-011/TC-012 は 3600 秒閾値の周辺を検証するテスト群です:
- **TC-010（3550秒）**: 閾値の十分手前で block されることを確認
- **TC-011（3601秒）**: 閾値超過で exit 0（stale）になることを確認
- **TC-012（3595秒）**: 閾値直前で block されることを確認（`-gt 3600` 条件の正確性検証）

### TC-010: 境界値テスト（閾値未満）→ block

**目的**: 3600 秒閾値未満でワークフローがまだアクティブと判定され、stop がブロックされることを確認。

**ステートファイル**: `updated_at` を 3550 秒前に設定、`active: true`

**期待結果**: AGE ≈ 3550（< 3600）→ exit 2（stderr にメッセージ出力）

**注**: 3599秒ではなく3550秒を使用。テスト側と stop-guard.sh 側で `date` を別々に呼ぶため、1-2秒の実行遅延で AGE が閾値を超える flaky リスクを回避。プロダクションコードの条件は `[ "$AGE" -gt 3600 ]`（3600 より大きい場合に exit 0）。

---

### TC-011: 境界値テスト（3601秒 = 閾値超過）→ exit 0

**目的**: 3600 秒閾値の直後（3601秒前）でワークフローが stale と判定され、exit 0 することを確認。

**ステートファイル**: `updated_at` を 3601 秒前に設定、`active: true`

**期待結果**: AGE = 3601（> 3600）→ exit 0、出力なし

---

### TC-012: 境界値テスト（閾値近傍）→ block

**目的**: 3600 秒閾値近傍（3595秒前）でワークフローがまだアクティブと判定され、stop がブロックされることを確認。プロダクションコードの `[ "$AGE" -gt 3600 ]` は「3600 より大きい」条件であり、AGE ≤ 3600 では条件不成立で block となる。

**ステートファイル**: `updated_at` を 3595 秒前に設定、`active: true`

**期待結果**: AGE ≈ 3595（≤ 3600）→ exit 2（stderr にメッセージ出力）

**注**: 3600秒ではなく3595秒を使用。テスト実行中の1秒の遅延で AGE=3601 になる flaky リスクを回避。TC-010（3550秒）とともに、閾値 3600 の「block 側」を余裕を持って検証。TC-011（3601秒）で「exit 0 側」を検証。

---

### TC-013: 不正 JSON 入力のエラーハンドリング

**目的**: stdin に不正な JSON が渡された場合、`jq` のパースエラーにより `set -e` で即座に非ゼロ exit することを確認。

**入力**: `NOT-VALID-JSON`（JSON として無効な文字列）

**期待結果**: 非ゼロ exit（jq パースエラーによる `set -e` 発動）。block は発生しない。

---

### TC-014: phase/next_action 欠落時のデフォルト値（"unknown"）検証

**目的**: ステートファイルに `phase` と `next_action` フィールドが存在しない場合、`jq` の `// "unknown"` フォールバックにより reason 文字列に "unknown" が含まれることを確認。

**ステートファイル**:
```json
{"active": true, "updated_at": "<現在時刻>"}
```

**期待結果**: exit 2、stderr に "unknown" が含まれる

**検証ポイント**: プロダクションコードの `'.phase // "unknown"'` と `'.next_action // "unknown"'` のデフォルト値フォールバック。

---

## テスト実行

### 自動テスト

```bash
bash plugins/rite/hooks/tests/stop-guard.test.sh
```

**前提条件**: `jq` コマンドがインストールされていること

### 手動検証（macOS 固有のフォールバック）

macOS 環境で以下を確認:

1. `date -d` が失敗すること（GNU date 非対応）
2. `date -j -f "%Y-%m-%dT%H:%M:%S%z"` が `sed` でコロン除去されたタイムスタンプをパースすること
3. `+09:00` → `+0900` の `sed` 変換が正しく動作すること

```bash
# macOS での手動確認
echo "2026-02-08T12:00:00+09:00" | sed 's/\(+[0-9][0-9]\):\([0-9][0-9]\)$/\1\2/'
# 期待: 2026-02-08T12:00:00+0900

date -j -f "%Y-%m-%dT%H:%M:%S%z" "2026-02-08T12:00:00+0900" +%s
# 期待: エポック秒が出力される
```

### TC-028: exit 2 パスで診断ログに EXIT:2 が記録される（AC-3）

**目的**: stop-guard.sh が exit 2（ブロック）で終了した際、診断ログファイル（`.rite-stop-guard-diag.log`）に `EXIT:2` が記録されることを確認。

**ステートファイル**: `active: true`, `updated_at: <現在時刻>`, `phase: "phase5_review"`, `error_count: 0`

**期待結果**: exit 2、`.rite-stop-guard-diag.log` に `EXIT:2` が記録される

**検証ポイント**: `log_diag` 関数が exit 2 パスで正しく呼び出され、診断ログに exit reason が記録されること。

---

### TC-029: exit 0 パスで診断ログに reason=not_active が記録される（AC-3）

**目的**: stop-guard.sh が `active: false` で exit 0 した際、診断ログファイルに `reason=not_active` が記録されることを確認。

**ステートファイル**: `active: false`, `updated_at: "2026-01-01T00:00:00+00:00"`

**期待結果**: exit 0、`.rite-stop-guard-diag.log` に `reason=not_active` が記録される

**検証ポイント**: `log_diag` 関数が exit 0 パスでも正しく呼び出され、exit reason が記録されること。

---

## テスト実行記録

**運用ノート**: 反復的なレビュー修正サイクルの記録は全て残す方針。最終結果は末尾のエントリを参照。

| 日付 | テスター | 結果 | 備考 |
|------|---------|------|------|
| 2026-02-08 | Claude (rite:issue:start) | 9/9 PASS | Linux (WSL2) 環境、初版 |
| 2026-02-08 | Claude (rite:pr:fix) | 11/11 PASS | レビュー指摘対応後（TC-010/011 追加） |
| 2026-02-08 | Claude (rite:pr:fix) | 13/13 PASS | 再レビュー指摘対応（TC-012/013 追加） |
| 2026-02-08 | Claude (rite:pr:fix) | 14/14 PASS | 再々レビュー指摘対応（TC-014 追加、flaky 対策、TC-013 修正） |
| 2026-02-08 | Claude (rite:pr:fix) | 14/14 PASS | 第4回レビュー指摘対応（変数名改善、stderr mktemp 化、テストヘッダー英語化） |
| 2026-02-08 | Claude (rite:pr:fix) | 14/14 PASS | 第5回レビュー指摘対応（TC-013 コメント追記、TC-008 固定テキスト検証、概要整理） |
| 2026-02-11 | Claude | 14/14 PASS | exit 2 + stderr 方式への移行、TC-001 更新（stop_hook_active チェック削除対応） |
| 2026-03-03 | Claude (rite:issue:start) | 29/29 PASS | #22 対応: compact_state 修正、診断ログ追加、TC-028/029 追加 |

---

## 変更履歴

| 日付 | 変更内容 |
|------|---------|
| 2026-02-08 | 初版作成（#506） |
| 2026-02-08 | レビュー指摘対応: stderr キャプチャ、境界値テスト追加、検証範囲明確化 |
| 2026-02-08 | 再レビュー指摘対応: AGE=3600 境界値テスト、不正 JSON テスト、テスト名改善 |
| 2026-02-08 | 再々レビュー指摘対応: TC-013 false positive 修正、境界値テスト flaky 対策、TC-014 追加 |
| 2026-02-08 | 第4回レビュー指摘対応: 変数名改善、stderr mktemp 化、TC-001 コメント追加、表記統一、TC-008 検証条件明確化 |
| 2026-02-08 | 第5回レビュー指摘対応: TC-013 コメント追記、TC-008 固定テキスト検証追加、概要箇条書き化、境界値テスト群説明追加、README 互換性注記 |
| 2026-02-11 | exit 2 + stderr 方式への移行: TC-001 更新（stop_hook_active チェック削除）、block テストを exit 2 + stderr 検証に変更、デバッグログ追加 |
| 2026-03-03 | #22 対応: compact_state=blocked/resuming で exit 0 する旧コード削除（AC-1/AC-6）、log_diag 診断ログ追加（AC-3）、INPUT ガード追加（AC-5）、TC-028/029 追加 |
