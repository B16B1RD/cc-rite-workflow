---
title: "前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する"
domain: "anti-patterns"
created: "2026-04-25T12:30:00+00:00"
updated: "2026-04-25T12:30:00+00:00"
sources:
  - type: "retrospectives"
    ref: "raw/retrospectives/20260425T122746Z-meta-issue-create-stuck-rootcause.md"
tags: [defense-in-depth, and-logic, precondition, flow-state, stop-guard, silent-failure, fragility, hook]
confidence: high
---

# 前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する

## 概要

過去 9 件の Issue (#3 → #651) で導入した 8 種類の防御層 (declarative / sentinel / Pre-check list / whitelist / Pre-flight / Step 0 / 4-site 対称化 / hook case arm) は **AND 論理**で組まれていた。それぞれが `.rite-flow-state.active=true` という単一の前提条件成立に依存していたが、`commands/issue/create.md` などの patch site が **`--active true` を omit** することで前提条件のチェーンが silent に切断され、stop-guard.sh が `EXIT:0 reason=not_active` で early return → 8 種の case arm / WORKFLOW_HINT / RE-ENTRY DETECTED escalation はすべて到達不能になっていた。**`.rite-stop-guard-diag.log` の直近 30 件中 28 件 (93%) が `EXIT:0 reason=not_active`** で、防御層は本番で 9 割以上機能していなかった事実が一次情報で確認された。

## 詳細

### 観測された連鎖

```
[step 1] session-start.sh:267-294 が新セッション起動時に
         .rite-flow-state.active を false に強制 reset
         (前セッション残存 active=true から保護する設計)

[step 2-4] commands/issue/create.md / create-interview.md の Pre-flight
         + Return Output 直前 re-patch (8 件の bash patch 呼び出し)
         (★ どの site も --active true を指定しない)

→ .rite-flow-state.active = false が永遠に保持される

[step 5] LLM が end_turn を選択
         (declarative enforcement で抑制できない症状、
         「Declarative enforcement で LLM の stop_reason: end_turn は抑制できない」参照)

[step 6] Stop hook fire → stop-guard.sh:79-84
         ACTIVE != "true" → log_diag "EXIT:0 reason=not_active" → exit 0
         case arm / WORKFLOW_HINT / RE-ENTRY DETECTED escalation は到達不能

[step 7] stop_hook_summary: preventedContinuation: false
         → Claude Code は LLM の end_turn をそのまま受理

[step 8] UI: ✻ Churned for X → ユーザー手動 continue で再開
```

### 一次情報による実証

- 現在の `.rite-flow-state`: `{"active": false, "phase": "cleanup_completed", ...}`
- `f0d8791d` セッション (PR #654 マージ後 9 時間後) の diag log: `[2026-04-24T15:32:08Z] EXIT:0 reason=not_active`
- `f7afee09` セッション (PR #636 マージ前 10 時間) でも同症状で 7 分間隔で 2 回再発
- `.rite-stop-guard-diag.log` 直近 30 件: 28/30 = `EXIT:0 reason=not_active`、1 件のみ `EXIT:2 reason=blocking`、1 件 `EXIT:0 reason=other_session`
- `f0d8791d` 内の `flow-state-update.sh patch` 呼び出し 8 件すべてで `--active true` 未指定

### 単体テストが PASS していたのに本番で機能しなかった理由

Issue #634 / #651 で追加された `stop-guard.test.sh` の TC-634-A〜P (60+ TC) は完璧に PASS していたが、TC は **`phase=create_post_interview` + `active=true` を pre-set** してから stop-guard を起動する設計だった。本番では `active=false` のまま hook が起動するので **case arm に到達する前に early return** する → テストが本番動作を保証していなかった。「Test pin protection theater」と同じ系列の盲点だが、本件は「テスト環境の pre-set と本番起動条件の gap」という別の角度。

### Anti-pattern としての症状

防御層を AND 論理で組む際、**1 つの link でも前提条件が omit 可能**だと、そこが silent な単一障害点になる。観測症状:

1. 各 link 単体のテストはすべて PASS
2. 各 link の実装は技術的に正しい
3. しかし本番では 1 link の omit で全体が無効化
4. Diag log や `stop_hook_summary.preventedContinuation` などの一次情報を見ない限り、防御層が機能していないことに気づけない
5. 「直前の対策が効かない」と観測されるたびに防御層を追加 → 累積路線で構造が肥大化するが、依然として 1 link omit で全無効化される

### 検出手段

#### 手段 A: hook diag log の集計

stop-guard.sh のような防御 hook が `log_diag` を出している場合、直近 N 件の `EXIT:0 reason=*` 比率を集計する:

```bash
tail -100 .rite-stop-guard-diag.log | awk -F'reason=' '{print $2}' | awk '{print $1}' | sort | uniq -c
```

`reason=not_active` や `reason=other_session` のような「block を試みなかった」理由が支配的なら、防御層は本番で機能していない。

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

防御層を追加する際、その層が **fire するための前提条件**を必ず明文化し、本番でその前提条件が成立しているかを **一次情報** (hook diag log / stop_hook_summary / .rite-flow-state の現状) で定期検証する。AND 論理の防御層を組む場合、各 link の前提条件が **生成側の実装で網羅** されているかを grep audit で証明できる構造にする。

## 関連ページ

- [Declarative enforcement で LLM の stop_reason: end_turn は抑制できない](declarative-enforcement-cannot-prevent-llm-end-turn.md)
- [Test pin protection theater](test-pin-protection-theater.md)
- [Fix-induced drift in cumulative defense](fix-induced-drift-in-cumulative-defense.md)
- [Fix verification requires natural workflow firing](../heuristics/fix-verification-requires-natural-workflow-firing.md)

## ソース

- [meta-investigation: /rite:issue:create が累積 9 件の対策後も止まり続けた meta-retrospective](../../raw/retrospectives/20260425T122746Z-meta-issue-create-stuck-rootcause.md)
