---
title: "state machine を 2 箇所で記述する場合は動作の文字列レベルで同期する"
domain: "patterns"
created: "2026-04-19T03:30:00+00:00"
updated: "2026-04-20T15:15:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260419T034237Z-pr-586-cycle5.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T150304Z-pr-624-cycle2.md"
tags: [ring-pattern, helper-caller-sync, observability]
confidence: high
---

# state machine を 2 箇所で記述する場合は動作の文字列レベルで同期する

## 概要

同一 state の動作を「実装ロジックの Skip 条件記述」と「LLM 分岐テーブル」のように 2 箇所に分けて記述する場合、両者で動作の文字列 (silent / verbose / 表示メッセージ内容) が食い違うと **LLM 実行時の動作が不定** になる。文字単位で同期し、UX-positive 側 (通常は ✅ 表示付きのフィードバック経路) に統一するのが canonical。

## 詳細

### 発生事例 (PR #586 cycle 5)

`/rite:wiki:init` Phase 1.3.1 の `already_negated` state について:

- Skip 条件記述 (L119): 「silent skip」と明記
- LLM 分岐テーブル (L173): 「✅ メッセージを表示して Phase 2 へ」と指定

同じ state に対して実装ロジックは「無言」、LLM 側テーブルは「有言」を指示しており、LLM が指示書を読む際どちらに従うか不定 (F-03 として cycle 5 review で MEDIUM 検出)。

### 失敗の構造

1. 実装ロジック設計時に「無駄な出力は silent に」と書く
2. 後から LLM UX 改善で分岐テーブルを追加し「✅ 表示」を追記する
3. 2 箇所を別タイミングで編集した結果、動作記述の文字列が drift する
4. LLM は指示書の両方を参照し、どちらを採用するか run ごとにブレる
5. 「動作が変動する」silent regression として下流で検出される

### Canonical pattern

1. **動作文字列を 1 箇所で canonical 定義する**: 例えば「`state="already_negated"` → `✅ 既に negation が有効です` を表示して Phase 2 へ進む」を canonical 宣言として冒頭に書く
2. **分岐テーブル / Skip 条件記述は canonical 文字列を参照する**: `上記 canonical の通り動作する` 等、重複定義を避ける
3. **どうしても複数箇所に書く必要がある場合は DRIFT-CHECK ANCHOR で機械検証可能にする**: 同一 semantic を 2-3 site に展開する場合は anchor コメントで 3 者 explicit sync 契約を結ぶ (詳細は [drift-check-anchor-semantic-name](./drift-check-anchor-semantic-name.md) 参照)
4. **UX-positive 側に統一**: silent skip vs verbose skip の選択では、原則として verbose (✅ / ℹ️ メッセージ付き) に倒す。「何も起きない」は debug 困難で silent failure と区別できない

### 検出手段

- PR レビュー時に同一 state name (`already_negated` / `skip` 等) で `grep` し、全 hit で動作記述の文字列を diff で比較する
- 分岐テーブルがあるドキュメントでは、テーブル内の「メッセージ / アクション」列を canonical 宣言と突き合わせる lint を将来的に追加する

### helper case 拡張 × caller WARN_MSG 連動 (PR #624 cycle 2 での evidence)

PR #624 cycle 2 で、本 pattern の適用範囲が「実装ロジック / LLM 分岐テーブル」の 2 箇所記述から **「helper 関数内の case 分岐」と「caller 側の user-facing message (WARN_MSG / error output 等)」** の 2 箇所記述に拡張されることが実測された (G3 HIGH)。

**発生事例**:

PR #624 は `stop-guard.sh` の phase 別 case arm に `ingest_pre_lint` / `ingest_post_lint` を追加し、`manual_fallback_adopted` workflow_incident sentinel を emit する経路を拡張した。しかし:

- helper (`stop-guard.sh`) 側: case arm 追加済み (新 phase で sentinel emit)
- caller (`session-end.sh` lifecycle helper) 側: cleanup mid-ingest セッション終了時の WARN_MSG 文面が旧 phase 列挙 (`cleanup_pre_ingest` / `cleanup_post_ingest` のみ) のまま残存

→ session-end 時の user-facing WARN_MSG が `ingest_pre_lint` phase を認識せず、observability regression が発生 (cleanup mid-ingest セッション終了時の復旧 hint が不完全)。

**失敗の構造 (元 pattern の観点拡張)**:

1. helper 側の case 分岐は「state → action mapping」という実装ロジック記述
2. caller 側の WARN_MSG は「state → user-facing message mapping」という user-visible 記述
3. 両者は同一の state 集合 (phase 列挙) を参照するが、別ファイル / 別レビュー観点で編集される
4. helper 拡張のみで merge されると、caller 側が旧 state 列挙で silent に fallback してしまう observability gap が発生
5. 「何も起きない」とは違うが、user-facing message の情報量が不完全になる silent regression

**canonical 対策 (PR #624 cycle 2 fix で確立)**:

1. **state 列挙の canonical SoT を 1 箇所に宣言**: phase enum 列挙は `phase-transition-whitelist.sh` 等の共通定義ファイルに canonical 宣言し、helper / caller / WARN_MSG / documentation は全て同 SoT を参照する
2. **ring / enum 拡張は semantic SoT helper 全件の同時更新を契約化**: 「新 phase 追加 PR」では以下 N site を必ず同時更新:
   - helper 内 case arm (state → action)
   - caller 側 WARN_MSG / error output 文面 (state → user message)
   - phase-transition-whitelist (state → allowed transitions)
   - documentation 内 phase 列挙表
3. **Pre-PR grep**: `grep -rnE '(phase|state).*enum|phase.*列挙' <changed_dirs>` で SoT 以外の phase enum 列挙を検出し、同期更新漏れを pre-PR self-check で捕捉
4. **DRIFT-CHECK ANCHOR で 3+ site 契約化**: helper case arm と caller WARN_MSG の対称関係を DRIFT-CHECK ANCHOR で semantic name 参照し、「このサイトは N 箇所で同期される」旨を prose 併記する

**本 pattern との関係**:

元 pattern ( silent vs verbose の文字列 drift) は同一ファイル内 2 箇所記述を対象とし、本 sub-pattern (helper case × caller WARN_MSG) は cross-file の state 参照を対象とするが、**根本は「同一 state 集合を別 layer で記述したとき文字列が drift する」**という同型構造。どちらも:

- 共通 SoT から派生する duplication の synchronization 問題
- silent fallback (元 pattern: 動作不定 / sub-pattern: 情報量不完全) を引き起こす
- grep / DRIFT-CHECK ANCHOR で機械検証可能にする対策が canonical

**scope**: helper 拡張 PR / enum 拡張 PR / ring pattern 拡張 PR では observability helper (lifecycle 系 / session-end 系 / monitoring 系) の連動漏れが recurring failure mode。code-quality reviewer は必ず「enum 拡張 → downstream caller の enum 列挙 site 全件 grep」を review checklist に含める。

## 関連ページ

- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](./drift-check-anchor-semantic-name.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](../heuristics/canonical-list-count-claim-drift-anchor.md)

## ソース

- [PR #586 cycle 5 review (state 動作矛盾 F-03 検出)](../../raw/reviews/20260419T034237Z-pr-586-cycle5.md)
- [PR #624 cycle 2 fix (helper case 拡張 × caller WARN_MSG 連動漏れ G3 HIGH)](../../raw/fixes/20260420T150304Z-pr-624-cycle2.md)
