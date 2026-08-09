---
type: "anti-patterns"
title: "修正が既存の no-op 経路を有効化すると、その経路に潜んでいたバグが初めて顕在化する"
domain: "anti-patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/anti-patterns/fix-activates-dormant-no-op-path-reveals-latent-bug.md"
promoted_from: "wiki:/pages/anti-patterns/fix-activates-dormant-no-op-path-reveals-latent-bug.md"
description: "ある bug fix が別の書き込み経路を『実在ファイルを指す』ように変えると、以前は常に no-op で無害だったその経路の潜在的な欠陥（merge-preserve 漏れ等）が初めて発火する。"
created: "2026-07-09T09:29:35Z"
updated: "2026-07-09T09:29:35Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260709T090623Z-pr-1809-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260709T090806Z-pr-1809-cycle2.md"
tags: ["latent-bug", "side-effect", "code-path-activation", "review-fix-loop"]
confidence: high
---

# 修正が既存の no-op 経路を有効化すると、その経路に潜んでいたバグが初めて顕在化する

## 概要

ある bug fix が「これまで存在しなかった値を指すファイルパス」等の解決を変えると、それを書き込み先として使っていた別の既存コードが、以前は「実在しない/無害な経路」への no-op 書き込みだったものが「実在ファイルへの書き込み」に変わる。その書き込み経路自体に元々あった欠陥（例: merge-preserve のフィールド漏れ）は、no-op の間は一切発火せず気付かれない。修正によって経路が有効化された瞬間、初めてその欠陥が実害を持つようになる。

## 詳細

### 発生した事例

- 元修正: `issue-comment-wm-sync.sh` の `FLOW_STATE` 解決を、常に存在しない legacy 共有ファイル (`.rite-flow-state`) 決め打ちから、`flow-state.sh path`（実在するセッション別ファイルを返す canonical resolver）経由に変更した。
- 副次的に有効化された経路: 同ファイル内の `cache_comment_id()` が `wm_comment_id` を `$FLOW_STATE` に書き込む処理。修正前は `$FLOW_STATE` が指す先が実在しない legacy ファイルだったため、この書き込みは常に no-op だった。
- 有効化されて顕在化した欠陥: `flow-state.sh` の `cmd_set` が既存 JSON を `jq -n` で再構築する際の merge-preserve whitelist に `wm_comment_id` が含まれていなかった。この欠陥自体は修正前から存在していたが、書き込み先が無かったため無害だった。修正後、ほぼ全 phase transition で発火する `flow-state.sh set` 呼び出しのたびに、直前にキャッシュされた `wm_comment_id` が silent に消失するようになった。
- 発見経緯: レビュアーが実機で `cache_comment_id()` → 直後の `flow-state.sh set` という順序を再現し、`wm_comment_id` が消えることを実際に repro して確認した（推測ではなく実測）。

### 一般化した失敗のメカニズム

1. **修正 A（正しい）**: コンポーネント X の値解決ロジックを「常に無害な dead end」から「実在する resource」に変える
2. **潜在欠陥 B（修正前から存在、無害）**: コンポーネント Y が X の解決結果に対して行う操作に、元々欠陥がある（フィールド欠落・型不一致・競合など）
3. **有効化**: 修正 A の適用により、Y の操作が初めて「実害のある対象」に対して実行されるようになる
4. **顕在化**: B が初めて実害を持つ副作用として発火する。修正 A のレビューでは A 自体は正しいため見過ごされやすい

この失敗モードは Asymmetric Fix Transcription（対称位置への伝播漏れ (`Wiki provenance: asymmetric-fix-transcription.md`)）とは異なる軸である点に注意: Asymmetric Fix Transcription は「同じ修正を適用すべき複数箇所の一部を見落とす」horizontal な伝播漏れだが、本パターンは「無関係に見える既存コードが、今回の修正によって初めて実行条件を満たすようになる」activation 型の欠陥である。

### 検出のための観察ポイント

- 修正対象の値解決ロジックが「常に存在しない/無害な dead end を指していた」ものを「実在する resource を指す」ように変える場合、**その解決結果を書き込み先・入力として使う他のコードの経路を洗い出す**
- 洗い出した経路について、「これまで no-op だったから欠陥があっても発火しなかった」可能性を疑い、実機で実際にシーケンス（例: 書き込み → 直後の再構築処理）を再現して確認する
- レビュー観点として「この修正は正しいか」だけでなく「この修正によって、これまで発火しなかった副作用が発火するようになるか」を明示的に問う

### 対処方針

- 発見した副次的欠陥が修正対象 PR のスコープ外（follow-up scope）と判断できる場合は、無理に同一 PR で対応せず別 Issue として起票し、accept（fingerprint 永続化 + PR コメントでの reply）で決着させることで、review-fix ループが未修正の finding で無限に回り続けることを防ぎつつ、指摘自体は追跡可能な形で記録できる。

## 関連ページ

- Asymmetric Fix Transcription (対称位置への伝播漏れ) (`Wiki provenance: ./asymmetric-fix-transcription.md`)

## ソース

- PR #1809 review results (cycle 2) (`Wiki provenance: ../../raw/reviews/20260709T090623Z-pr-1809-cycle2.md`)
- PR #1809 fix results (cycle 2, accept) (`Wiki provenance: ../../raw/fixes/20260709T090806Z-pr-1809-cycle2.md`)
