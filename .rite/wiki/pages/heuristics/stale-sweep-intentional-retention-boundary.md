---
type: "heuristics"
title: "stale 参照一掃の『残照ゼロ』AC は意図的維持カテゴリの線引きで判定する"
domain: "heuristics"
description: "grep 残照ゼロ型の受入基準 (AC) は機械 grep 単独では完結しない。歴史記録 (過去形 incident 記述)・機能コード (別 Issue 化して除外)・同期 invariant コメントを『意図的維持』として明示ラベリングし、現在形の仕様記述のみを実装一致の対象とする線引きで判定する。"
created: "2026-07-02T12:35:00+09:00"
updated: "2026-07-02T19:42:40+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260702T015417Z-pr-1722.md"
  - type: "fixes"
    ref: "raw/fixes/20260702T020209Z-pr-1722.md"
  - type: "reviews"
    ref: "raw/reviews/20260702T032816Z-pr-1722.md"
  - type: "reviews"
    ref: "raw/reviews/20260702T100548Z-pr-1726.md"
tags: ["stale-reference", "acceptance-criteria", "grep-sweep", "intentional-retention", "revert-test", "documentation-drift"]
confidence: medium
---

# stale 参照一掃の『残照ゼロ』AC は意図的維持カテゴリの線引きで判定する

## 概要

「`grep で旧パス参照 0 件`」型の受入基準 (AC) を持つ stale 参照一掃 PR では、機械 grep の hit 数だけで達成判定すると、正当に残すべき参照 (歴史記録・機能コード・同期 invariant) まで巻き込むか、逆に「hit が残っている = 未達」と誤判定して収束しなくなる。**意図的維持カテゴリを明示的にラベリングして grep 結果から除外する線引き**が判定の核になる。

## 詳細

commands/ → skills/ 移行に伴う stale 参照一掃で実測した線引き:

**意図的維持と判定するカテゴリ (grep hit が残ってよい)**:

1. **歴史記録**: 過去形の incident 記述 (「過去に複数のコマンド本文 (`pr/fix.md` 等) が…していた」)、migration anchor、retired ラベル付きの旧ファイル名。**過去形かどうか**が判定基準 — 現在形の仕様記述 (「X が Y を走査して」) は実装一致の対象で、過去形の観測事実は残置可。
2. **機能コード**: 稼働中の検出ロジック (grep パターン等) に埋まった旧パス。修正には動作検証が必要で、doc 追随 PR の non-goal に抵触するため、PR body の Known Issues で明示 deferred + 別 Issue 化して AC の除外対象と宣言する。
3. **同期 invariant コメント**: bash 実装と同じ prefix で書く必要があると明記されたコメント例 (「上記コメントの prefix は意図的。下記 bash 実装と同じ prefix で書く必要がある」)。片側だけ更新すると invariant が壊れる。

**判定プロセス**:

- reviewer は各 hit を revert test (「本 PR を revert したら問題は消えるか」) で pre-existing / diff 由来に分類し、pre-existing は blocking 化せず boundary 推奨・調査推奨へ分流する。
- 「意図的維持」の帰属が曖昧な hit (機能コードだが AC の除外宣言がない等) は reviewer 単独で判定せず boundary 分類でユーザー判断に回す。
- AC 達成報告では「残存 N 件はすべて除外カテゴリ該当 (内訳付き)」の形で grep 結果と線引きを同時に示す。

**参照更新時の派生原則**: 旧パスを新パスへ置換する際、旧ファイル固有の識別子 (Phase 番号・行番号) を機械的に持ち込まず、**現行ファイルで実在確認したパターン名・セクション名へ言い換える**。実在しない識別子の転記は新規 drift の即時導入になる（fix では旧 `pr/create.md Phase 3.4` を、現行ファイルで実在確認した `pr_title.txt 変数経由パターン` へ言い換えて新規 drift を回避した）。

**inert / vestigial 記述への拡張**: 同じ意図的維持境界の線引きは、path 参照一掃だけでなく **inert（書いてあるが効かない）記述の掃除**（空 `## Detailed Checklist` 見出し・未実装スキャフォルディング prose・forward-looking な「将来 X を実装する計画」記述）にも適用される。各記述の処置は「削除 / reword / 変更なし」の 3 択で判定する:

- **削除した見出しが umbrella ラベルとして別ファイルの散文から参照される**場合、その別ファイルが本 PR の凍結対象 (MUST NOT modify) なら片側だけ更新せず follow-up Issue へ切り出す（一部更新は N 箇所間の不整合を生む。起点事例では散文参照 5 箇所を別 Issue へ分離）。
- **forward-looking な「将来実装」prose が既に部分実装済み**のことがある。この場合は削除でも保持でもなく **reword** で stale claim のみ除去し、有効な運用指示は残す（例: 「enforcement 未実装 / 将来 drift-check で計画」→「自動 drift-check なし = 手動同期せよ」）。
- 番号付きフローの中間 step 削除時は renumber と実装ノート内の全「順序 N」参照の整合を必ず検証する（[Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の step-renumber 系）。
- **死蔵に見えて実は機能している slot は「変更なし」**と判定する（実測では status enum の 1 値が read 側で実消費されており「将来予約」ではないため保持。inert 判定には consumer の grep 確認が必要）。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる](./exhaustiveness-claims-require-mechanical-inventory.md)
- [Documentation review は対応する実装側の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md)

## ソース

- [PR #1722 review results (cycle 1: AC-1 残照ゼロ型 AC の境界判定が boundary 分類でユーザー判断へ回された実測)](../../raw/reviews/20260702T015417Z-pr-1722.md)
- [PR #1722 fix results (過去形 incident 記述の意図的残置判断 + 実在確認済みパターン名への言い換え)](../../raw/fixes/20260702T020209Z-pr-1722.md)
- [PR #1722 review results cycle 2 (pre-existing ドリフトの revert test による boundary/調査推奨への正分流)](../../raw/reviews/20260702T032816Z-pr-1722.md)
- [PR #1726 review results — reviewer agent 定義の inert 記述掃除。空 Detailed Checklist 削除 + 未実装スキャフォルディング prose の削除/reword、0 findings で 1 cycle mergeable)](../../raw/reviews/20260702T100548Z-pr-1726.md)
