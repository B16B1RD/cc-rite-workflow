---
title: "【現行仕様では廃止】前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する"
domain: "anti-patterns"
description: "Stop hook ガード機構（stop-guard.sh）は撤去済みで、本ページの `--active true` 省略による連鎖は現行では成立しない。「AND 論理の防御層は単一の前提条件の omit で全体が無効化される」という一般則のみ、後段の教訓として有効。"
promote: rite-plugin
created: "2026-04-25T12:30:00+00:00"
sources:
  - type: "retrospectives"
    resource: "raw/retrospectives/20260425T122746Z-meta-issue-create-stuck-rootcause.md"
  - type: "reviews"
    resource: "raw/reviews/20260425T133145Z-pr-661.md"
  - type: "reviews"
    resource: "raw/reviews/20260425T153740Z-pr-661.md"
  - type: "reviews"
    resource: "raw/reviews/20260425T161137Z-pr-661.md"
  - type: "reviews"
    resource: "raw/reviews/20260425T165246Z-pr-661.md"
  - type: "reviews"
    resource: "raw/reviews/20260425T171440Z-pr-661-cycle-4.md"
  - type: "fixes"
    resource: "raw/fixes/20260425T133451Z-pr-661.md"
  - type: "fixes"
    resource: "raw/fixes/20260425T154517Z-pr-661-cycle-1.md"
  - type: "fixes"
    resource: "raw/fixes/20260425T161635Z-pr-661.md"
  - type: "fixes"
    resource: "raw/fixes/20260425T165546Z-pr-661.md"
tags: [defense-in-depth, and-logic, precondition, flow-state, stop-guard, silent-failure, fragility, hook]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-31T01:26:57+09:00" }
---

# 【現行仕様では廃止】前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する

## 概要

（現行仕様では廃止: 本ページが扱った Stop hook ガード機構 `stop-guard.sh` は機構ごと撤去済みで、後継の `stop-loop-continuation.sh` は `stop_hook_active` に依存しない one-shot 設計のため、`--active true` の省略で防御層が到達不能になる連鎖は成立しない。「AND 論理の防御層は単一の前提条件の omit で全体が無効化される」という一般則のみ、後段の教訓に残る。）

## 詳細

### 観測された連鎖

（現行仕様では廃止: `session-start.sh` の active reset → patch site の `--active true` 省略 → `stop-guard.sh` の `not_active` early return という連鎖は、`stop-guard.sh` の撤去により存在しない。）

### 一次情報による実証

- 現在の `.rite-flow-state`: `{"active": false, "phase": "cleanup_completed", ...}`
- `f0d8791d` セッション（4-site 対称化マージの 9 時間後）の diag log: `[2026-04-24T15:32:08Z] EXIT:0 reason=not_active`
- `f7afee09` セッション（8 回目対策のマージ前 10 時間）でも同症状で 7 分間隔で 2 回再発
- `.rite-stop-guard-diag.log` 直近 30 件: 28/30 = `EXIT:0 reason=not_active`、1 件のみ `EXIT:2 reason=blocking`、1 件 `EXIT:0 reason=other_session`
- `f0d8791d` 内の `flow-state-update.sh patch` 呼び出し 8 件すべてで `--active true` 未指定

### 単体テストが PASS していたのに本番で機能しなかった理由

先行 Issue で追加された `stop-guard.test.sh` の TC-634-A〜P (60+ TC) は完璧に PASS していたが、TC は **`phase=create_post_interview` + `active=true` を pre-set** してから stop-guard を起動する設計だった。本番では `active=false` のまま hook が起動するので **case arm に到達する前に early return** する → テストが本番動作を保証していなかった。「Test pin protection theater」と同じ系列の盲点だが、本件は「テスト環境の pre-set と本番起動条件の gap」という別の角度。

### Anti-pattern としての症状

防御層を AND 論理で組む際、**1 つの link でも前提条件が omit 可能**だと、そこが silent な単一障害点になる。観測症状:

1. 各 link 単体のテストはすべて PASS
2. 各 link の実装は技術的に正しい
3. しかし本番では 1 link の omit で全体が無効化
4. Diag log や `stop_hook_summary.preventedContinuation` などの一次情報を見ない限り、防御層が機能していないことに気づけない
5. 「直前の対策が効かない」と観測されるたびに防御層を追加 → 累積路線で構造が肥大化するが、依然として 1 link omit で全無効化される

### 検出手段

#### 手段 A: hook diag log の集計

（現行仕様では廃止: hook diag log を集計する方式は撤去済みで、`stop-loop-continuation.sh` の debug 出力は `RITE_DEBUG` 設定時のみ。）

#### 手段 B: stop_hook_summary の確認

セッション `.jsonl` 内の `stop_hook_summary.preventedContinuation` を grep:

```bash
jq -c 'select(.type=="system" and .subtype=="stop_hook_summary")' "$JSONL" | head -5
```

`preventedContinuation: true` が一度も出ていないなら、Stop hook は走っているが block 試行が成功していない。

#### 手段 C: AND 論理の前提条件 audit

各防御層が依存している前提条件 (環境変数 / フラグ / state file の値) を列挙し、その前提条件を **生成する側のコード** が網羅的に成立を保証しているか grep で確認:

```bash
# 例: --active true が flow-state-update.sh patch で網羅されているか
grep -n "flow-state-update.sh patch" commands/**/*.md | grep -v -- "--active true"
```

omit 箇所が見つかれば silent な単一障害点候補。

### 修正の方向性

#### 短期 (link 修復)

各 patch site に `--active true` を網羅的に追加する。Phase 1 修正。

#### 中期 (デフォルト挙動の固定)

`flow-state-update.sh patch` の `--active` 省略時のデフォルト挙動を「phase が non-terminal なら自動で true」に変更する。omit が発生しても safe-side に倒れる設計。

#### 長期 (前提条件依存の解消)

stop-guard の early return 条件を「current session が書いた flow-state なら active=false でも block 試行」に緩和する、もしくは前提条件 (`active=true`) 自体を別の signal (session_id の一致 / phase の存在) に置き換える。

### 教訓

防御層を追加する際、その層が **fire するための前提条件**を必ず明文化し、本番でその前提条件が成立しているかを **一次情報** (stop_hook_summary / state file の現状。hook diag log 方式は現行仕様では廃止) で定期検証する。AND 論理の防御層を組む場合、各 link の前提条件が **生成側の実装で網羅** されているかを grep audit で証明できる構造にする。

### 実証された短期修復と invariant 強化

累積 11 回目で 17 patch site / 12 ファイルに `--active true` を網羅追加 (terminal phase 除く)。post-fix の本番 diag log で `EXIT:2 reason=blocking` が 9 件、`EXIT:0 reason=not_active` が 3 件観測され、stop-guard が正しく blocking 動作するように回復した。重要な副次対策:

1. **本番条件再現 TC の追加** (TC-660-A〜E): 既存 60+ TC が「pre-set + active=true」前提で書かれており、本番起動条件 (`active=false` 起動 → exit 0 → case arm 到達不能) を assert する TC が一つも無かった。`active=false` で起動したら `EXIT:0 reason=not_active` が必ず emit される negative assertion を canonical な test infrastructure として永続化することで、AND 論理 silent omit が次回 PR で再導入された場合に CI で検出可能になる。
2. **Inverse TC の重要性**: 「`--active true` 明示時の flip」だけでなく「`--active` 省略時の preserve-existing semantics」も assert する inverse TC が必要。修正対象の `flow-state-update.sh:254` の `if [[ -n "$ACTIVE" ]]` 条件分岐 semantics が将来変更されると、AC-1 を full carpeted した修正自体が無効化される silent regression が起きるため、双方向 (active=false / active=true) の preserve assertion で固定する。
3. **AC 文言の literal 検証可能性**: AC-1 等で「`git grep` 1 行の oneliner」を AC として記載すると、複数行の `\` continuation 構造を持つ patch site で literal 実行が常に false positive になる。block-aware scan (awk) または python here-doc を AC 文言に書く運用ガイドが必要。
4. **4-site DRIFT-CHECK ANCHOR の bash 引数 symmetry 拡張**: 元 `--phase` / `--next` / `--preserve-error-count` の 3-arg → `--phase` / `--active` / `--next` / `--preserve-error-count` の 4-arg に昇格。create.md / create-interview.md / cleanup.md / stop-guard.sh の 4 site を atomic 同期。本拡張は「Asymmetric Fix Transcription」と「DRIFT-CHECK ANCHOR は semantic name 参照で記述する」の合流ケース。

### 累積対策 PR の review-fix loop convergence（cycle 1→4）

累積対策 11 回目では cycle 1 → 4 で findings 数が 7 → 2 → 1 → 0 と明確 convergence。各 cycle の finding の大半 (cycle 2 の MEDIUM 2、cycle 3 の MEDIUM 1) は前 cycle fix 自体が導入した drift 起因 (詳細は「Fix-induced drift in cumulative defense」参照)。これは「累積対策 PR fractal pattern」の典型的な収束プロファイル。production diag log の `EXIT:2 reason=blocking` 観測数の変化と finding count を併走させて、修復が link 全体に波及したことを多角的に確認するのが canonical。

## 関連ページ

- [Declarative enforcement で LLM の stop_reason: end_turn は抑制できない](declarative-enforcement-cannot-prevent-llm-end-turn.md)
- [Test pin protection theater](test-pin-protection-theater.md)
- [Fix-induced drift in cumulative defense](fix-induced-drift-in-cumulative-defense.md)
- [Fix verification requires natural workflow firing](../heuristics/fix-verification-requires-natural-workflow-firing.md)

## ソース

- [meta-investigation: /rite:issue:create が累積 9 件の対策後も止まり続けた meta-retrospective](../../raw/retrospectives/20260425T122746Z-meta-issue-create-stuck-rootcause.md)
- [レビュー結果](../../raw/reviews/20260425T133145Z-pr-661.md)
- [expanded](../../raw/reviews/20260425T153740Z-pr-661.md)
- [レビュー結果](../../raw/reviews/20260425T161137Z-pr-661.md)
- [レビュー結果](../../raw/reviews/20260425T165246Z-pr-661.md)
- [mergeable, 0 findings](../../raw/reviews/20260425T171440Z-pr-661-cycle-4.md)
- [fix 結果](../../raw/fixes/20260425T133451Z-pr-661.md)
- [fix 結果](../../raw/fixes/20260425T154517Z-pr-661-cycle-1.md)
- [fix 結果](../../raw/fixes/20260425T161635Z-pr-661.md)
- [fix 結果](../../raw/fixes/20260425T165546Z-pr-661.md)
