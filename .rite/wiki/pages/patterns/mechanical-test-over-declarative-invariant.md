---
title: "Wording 層の self-referential loop は mechanical test 化で構造解消する"
domain: "patterns"
promote: rite-plugin
created: "2026-05-26T00:30:00Z"
updated: "2026-06-04T16:30:25Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260525T221902Z-pr-1143.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T233957Z-pr-1143.md"
  - type: "reviews"
    ref: "raw/reviews/20260604T061732Z-pr-1267.md"
  - type: "reviews"
    ref: "raw/reviews/20260604T160823Z-pr-1270.md"
tags: []
confidence: high
---

# Wording 層の self-referential loop は mechanical test 化で構造解消する

## 概要

SoT 集約 PR で declarative invariant note (両者の集合差を 0 にする 等) を追加すると、note 文言自身が次 cycle の review finding 源になる self-referential loop が発生する。canonical 対策は (a) **mechanical test の green を contract に置換**、(b) **cross-axis declarative mapping は書かない**。文書上の宣言を実行可能な test に格上げすることで、wording 層の new claim ↔ 実装 gap 経路を構造的に断つ。

## 詳細

### 適用 PR

起点事例の cycle 6-7 で確立:

- **cycle 6**: `hooks/tests/comment-best-practices-parity.test.sh` を新規作成し、SoT 22 entry 全部が Heuristics regex で match することを assert (forward subset の test 化)。declarative invariant が文書上の宣言から実行可能な test に格上げされた
- **cycle 7**: `1 対 1 mapping` 等の cross-axis declarative mapping を **削除** し、「parity test の green が contract」に統一。wording 層の self-referential loop を構造的に閉塞

0 findings / 1 cycle の PR で **初回実装時からの preventive 適用 + mutation 検証による test 検出力の実証** を追加:

- Issue 側 AC が「declarative wording / sentinel 命名のみの修正は reject」(#1144 AC-4 継承) と明示し、WIKICHAIN handoff gate の実装と**同時に**静的 parity test (`cleanup-wikichain-handoff-parity.test.sh` TC-1〜5: writer / consumer / terminal set default-clear / チェーン 3 段 return sentinel) + runtime TC-11〜13 を追加。grep anchor 5 件は実装 literal と byte 一致 (anchor / context 分離の canonical 準拠)
- test reviewer が isolated worktree (`git worktree add --detach`) で **6 種の mutation 検証** (case arm 削除 / handoff set 削除 / terminal set への `--handoff` 付与 / reason 補間除去 / WARNING 削除 / reason 文面 copy-paste) を実施し、全 mutation で該当 TC が FAIL することを確認 — 「test が green であること」だけでなく「実装を壊せば red になること」(false positive 不在) を review 段階で実証する手法として記録
- 「2 cycle 以上 finding 再発後に test 化する」remediation 経路ではなく、**着手時から mechanical test を実装と同梱する** preventive 経路でも本 pattern が成立し、0 findings / 1 cycle 収束に寄与することを実測

その follow-up PR（0 findings / 1 cycle）で **prose-only guard の follow-up 昇格 (reviewer 指摘起点の事後 test 化)** を追加:

- WIKICHAIN gate 事例が導入した handoff gate のステップ 9〜12 間 intervening set 回帰 (intervening `flow-state.sh set` が handoff を premature default-clear し gate が silent に外れる経路) は、cleanup.md ステップ 9 直下の prose「制約」note のみで守られていた。同事例の test reviewer 指摘を起点に TC-6 を parity test に追加し、`--handoff` なしの executable な intervening set を機械検出する形に昇格
- TC-6 設計の要点: 既存 anchor (TC-2 `handoff_line` / TC-4 `terminal_set_line`) を再利用して新規 anchor 追加の drift コストを回避 / 行末 `\` 継続行を join してから判定 / prose の backtick 言及 (`{plugin_root}/hooks/` path literal) を除外 / `--handoff` 再指定済み intervening set は TC-6 では許容し TC-1 (単一 site assert) の fail に委譲して意識的なテスト更新を強制
- sandbox negative test (Case A: `--handoff` なし intervening set 注入 → TC-6 FAIL / Case B: 継続行 `--handoff` 再指定 → TC-6 PASS + TC-1 FAIL) で検出力と false positive 不在を commit 前に実証 — preventive 経路と follow-up 昇格経路の両方で 0 findings / 1 cycle 収束が連続再現

### 適用条件

| 条件 | 説明 |
|------|------|
| **複数 list 間 parity 契約** | SoT (canonical) と Heuristics (regex) 等、2 ファイル / 2 表で同期維持が必要な場合 |
| **declarative wording で 2 cycle 以上 finding が再発** | wording 追加で連鎖 finding が出始めたら mechanical test 化を検討する signal |
| **invariant が機械検証可能** | 集合等価性 / forward subset / 全 entry の regex match 等、shell script で表現できる契約 |

### 設計手順

1. **wording 層 invariant の最小化**: 「forward subset」のみ主張し、bidirectional は best-effort と明示
2. **mechanical test の作成**: SoT 全 entry を loop し Heuristics regex に対する match を assert する shell script を `hooks/tests/` 配下に追加
3. **Contract 宣言**: 「parity test の green が contract」と SoT / Heuristics 両方の Maintenance Note で明記し、wording による cross-axis mapping は書かない
4. **Cross-axis declarative mapping の削除**: 「N 対 M mapping」「composite case の対応」等の散文 mapping を削除し test に委譲

### 関連パターン

- [[drift-check-anchor-prose-code-sync]] の 3 重契約 (AC anchor / reasons table / Eval-order enumeration / bash 実装) も同じ「文書 → mechanical 検証への格上げ」doctrine の一部
- [[canonical-list-count-claim-drift-anchor]] の `N site 対称化 counter 宣言` も drift 検出 anchor として grep 機械検証可能化する同型パターン
- [[declarative-invariant-wording-layer-escalation]] (本 pattern が解こうとしている anti-pattern の親 page)

### 注意

mechanical test 化自体も新たな declarative 層を生む経路を持つ（cycle 6-7 で実測: test 追加によって「test が何を検証しているか」「test と invariant の対応関係」という新しい declarative 層が増えた)。Maintenance Note で test 設計意図を明示し、cross-axis declarative mapping を test green = contract green に統一する rollback path を確保すること。

## 関連ページ

- [[declarative-invariant-wording-layer-escalation]] ([../anti-patterns/declarative-invariant-wording-layer-escalation.md](../anti-patterns/declarative-invariant-wording-layer-escalation.md))

## ソース

- [PR #1143 cycle 6 fix (mechanical parity test 追加 + 3 列 column schema 拡張)](../../raw/fixes/20260525T221902Z-pr-1143.md)
- [PR #1143 cycle 7 fix (declarative mapping を mechanical test に委譲、wording 層 self-meta-conflict 構造解消)](../../raw/fixes/20260525T233957Z-pr-1143.md)
- [PR #1267 review results — 0 findings: WIKICHAIN handoff gate を静的 parity test TC-1〜5 + runtime TC-11〜13 と同梱実装、mutation 検証 6 種で全 TC の検出力を実証した preventive 適用)](../../raw/reviews/20260604T061732Z-pr-1267.md)
- [PR #1270 review results — 0 findings: prose「制約」note のみで守られていた intervening set 回帰を TC-6 へ昇格、sandbox negative test Case A/B で検出力と false positive 不在を実証した follow-up 適用)](../../raw/reviews/20260604T160823Z-pr-1270.md)
