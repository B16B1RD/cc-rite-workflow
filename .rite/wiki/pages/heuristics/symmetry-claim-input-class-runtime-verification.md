---
title: "sanitization 対称性 claim は入力クラス別に runtime byte-level 検証してから書く"
domain: "heuristics"
description: "設計判断コメントで「経路 A は経路 B と対称」という sanitization 保証 claim を書く場合、入力クラス (raw 単独バイト / valid UTF-8 エンコード済み) を列挙し各クラスごとに runtime byte-level 検証 (xxd) してから書く。過去のレビューで「C1 素通しは jq と対称」claim が raw 8-bit C1 では偽 (jq は 0x9b を U+FFFD 化 / --c0-only は素通し)、valid UTF-8 C1 でのみ真と実測。fix は挙動変更ではなく入力クラス別の claim 訂正で、同一 claim の複製 3 箇所を git grep で全列挙し 1 commit 同時訂正。author の事前検証と reviewer の反証が同一の安価な手法 (xxd) で対称に成立する。"
promote: rite-plugin
created: "2026-06-05T10:33:05Z"
updated: "2026-06-05T10:33:05Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260605T085618Z-pr-1279.md"
  - type: "fixes"
    ref: "raw/fixes/20260605T090238Z-pr-1279.md"
  - type: "reviews"
    ref: "raw/reviews/20260605T091117Z-pr-1279.md"
tags: ["comment-rot", "sanitization", "symmetry-claim", "input-class", "byte-level-verification", "xxd", "control-characters", "utf-8", "jq"]
confidence: high
---

# sanitization 対称性 claim は入力クラス別に runtime byte-level 検証してから書く

## 概要

設計判断コメントで「経路 A の挙動は経路 B と対称」という sanitization 保証 claim を書く場合、対象データの**入力クラスを列挙し、各クラスごとに runtime byte-level 検証 (xxd 等) してから**書く。入力クラスを区別しない一括の対称性主張は、一部クラスでのみ偽となる Comment Rot を埋め込む。起点事例で「C1 素通しは jq プライマリ経路と対称」という claim が **raw 8-bit C1 バイト単独では偽** (jq は raw 0x9b を U+FFFD に sanitize / `--c0-only` は素通し) であり、**valid UTF-8 エンコード済み C1 (c2 9b) でのみ真** (両者素通し) であることが security reviewer の byte-level 反証で実測された。

## 詳細

### 失敗の構造 — 入力クラスを区別しない対称性 claim

起点事例 (`stop-loop-continuation.sh` の JSON emit フォールバックに `neutralize_ctrl --c0-only` を適用) の設計判断コメントは「C1 (0x80-0x9f) の素通しは jq プライマリ経路の JSON エンコードと対称」と主張した。しかし「C1 バイト」には 2 つの入力クラスがあり、挙動はクラスごとに異なる:

| 入力クラス | jq プライマリ経路 | `--c0-only` フォールバック | 対称性 |
|-----------|------------------|---------------------------|--------|
| raw 8-bit 単独 C1 バイト (例: `0x9b`) | invalid UTF-8 として **U+FFFD に置換** | 素通し | **非対称 (claim は偽)** |
| valid UTF-8 エンコード済み C1 (例: `c2 9b` = U+009B) | 素通し (valid UTF-8) | 素通し | 対称 (claim は真) |

claim は後者のクラスのみで成立するが、コメントはクラスを区別せず「対称」と一括主張していた — sanitization 保証に関する Comment Rot。security reviewer は xxd による runtime byte-level 検証 (raw 0x9b を両経路に通して出力バイト列を比較) で claim を反証した (MEDIUM)。

### Fix 方針 — 挙動変更ではなく入力クラス別の claim 訂正

実装挙動はどちらの経路も RFC 8259 上正当 (生バイト禁止は C0 のみ) のため、fix は挙動変更ではなく **コメント訂正**: 対称性 claim を「valid UTF-8 C1 のみ対称、raw 8-bit C1 は非対称 (jq は U+FFFD 置換 / --c0-only は素通し)」と入力クラス別に明示する文言へ書き換えた。

### 適用手順 (canonical)

1. **対称性 / 等価性 claim を書く前に入力クラスを列挙する**: 制御バイトなら「raw 単独バイト」と「valid UTF-8 エンコード済み」の 2 クラスが最低限の partition。
2. **各クラスで runtime byte-level 検証する**: `printf '\x9b' | jq -R .` / `printf '\xc2\x9b' | ...` 等で両経路に実入力を通し、`xxd` で出力バイト列を比較する。reviewer 側の反証も同一手法で成立する (検証コストは対称)。
3. **クラスごとに挙動が割れたら claim をクラス別に書き分ける**: 「X のみ対称、Y は非対称 (各挙動を明記)」の形式にする。一括主張への要約は禁止。
4. **同一 claim の全複製 site を grep で列挙して同時訂正する**: 起点事例では同一 claim が実装 2 ファイル + テストコメント (TC-11) の 3 箇所に存在し、`git grep -E '(C1|c0-only).*対称'` で全列挙して 1 commit で同時訂正した ([Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の予防)。テスト assert 自体は挙動 pin として正しいため不変。

### 検証の有効性 (cycle 2 で実測)

cycle 2 review で security reviewer が訂正後コメントの事実性を同じ byte-level 再検証 (raw 0x9b → jq U+FFFD vs --c0-only 素通し / valid UTF-8 c2 9b → 両者素通し) で確認し、0 findings 収束 (2 cycle: 1 → 0)。「claim を書く前の検証」と「claim を review する際の反証」が同一の安価な手法 (xxd) で対称に成立するため、本 heuristic は author / reviewer 双方に適用できる。

## 関連ページ

- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](../heuristics/prose-cited-implementation-behavioral-verification.md)
- [状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)](../anti-patterns/stale-historical-comment-after-state-change.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1279 review results](../../raw/reviews/20260605T085618Z-pr-1279.md)
- [PR #1279 fix results](../../raw/fixes/20260605T090238Z-pr-1279.md)
- [PR #1279 review results (cycle 2)](../../raw/reviews/20260605T091117Z-pr-1279.md)
