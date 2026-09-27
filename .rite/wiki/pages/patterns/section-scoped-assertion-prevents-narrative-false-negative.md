---
title: "Test assertion は section-scoped で行頭 prefix を必須にし narrative mention の false negative を防ぐ"
domain: "patterns"
description: "構造保護 test (例: 「契約 row が table に存在する」「特定 bash literal が 1 reference に存在する」) を substring grep ベースで書くと、narrative の言及 (= prose で言葉として書かれているだけ) や heading-only mention、single-instance match で pass する false negative を生む。"
created: "2026-05-12T15:29:45Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260512T134356Z-pr-936.md"
  - type: "fixes"
    resource: "raw/fixes/20260512T134908Z-pr-936.md"
  - type: "reviews"
    resource: "raw/reviews/20260608T113726Z-pr-1306.md"
  - type: "fixes"
    resource: "raw/fixes/20260608T121039Z-pr-1306.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T165534Z-pr-3317.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T170119Z-pr-3317.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T170635Z-pr-3317.md"
tags: ["test-design", "grep", "false-negative", "section-scoped", "assertion-strictness"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T17:15:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T17:15:00Z" }
---

# Test assertion は section-scoped で行頭 prefix を必須にし narrative mention の false negative を防ぐ

## 概要

構造保護 test (例: 「契約 row が table に存在する」「特定 bash literal が 1 reference に存在する」) を substring grep ベースで書くと、narrative の言及 (= prose で言葉として書かれているだけ) や heading-only mention、single-instance match で pass する false negative を生む。`awk '/^## §3/,/^## §4/'` 等の section-scoped 範囲抽出 + 行頭 prefix 必須 (`^\| ...`) で contract row のみを検証する設計が必要。

## 詳細

### 失敗モード

起点事例で 3 件 MEDIUM (F-03/F-04/F-05) として実測。具体的には:

- **F-03**: 「Detection scope 7-type table の 7 行を機械検証」のつもりが substring grep で書かれていたため、narrative で `7-type` と言及するだけで pass する false negative
- **F-04**: heading だけ存在すれば pass する経路 (本文が空でも検出不能)
- **F-05**: 同じ pattern が 1 箇所でも存在すれば pass する経路 (本来 N 箇所すべてを検証すべき場面で 1 箇所だけ存在しても pass)

これらの false negative は test が「PASS」と報告しても構造保護が成立しない状態を量産する。`test-pin-protection-theater` の sub-class として、「assertion の string match 強度が claim の対象と乖離する」failure mode に分類できる。

### 検出手段

- mutation test (= 該当 contract row を 1 行削除した状態で test が FAIL するか確認) で empirical に false negative を発見する
- assertion の grep pattern が substring か行頭 anchored か (`^\|` `^## ` 等の anchor の有無) を mechanical に lint する
- section-scoped で抽出してから match していない grep を疑う (`awk '/^## §N/,/^## §M/'` のような section range の不在を pattern として detect)

### Canonical 対策

1. **Section-scoped 範囲抽出**: `awk '/^## §3/,/^## §4/' file | grep ...` のように section heading で範囲を絞ってから grep する。section heading そのものを範囲開始 / 終了 marker として使う
2. **行頭 prefix 必須化**: table row の検証なら `^\|` (Markdown table の column separator)、code block 内 literal の検証なら `^[[:space:]]*<literal>` のように行頭 anchor を必須にする
3. **件数 assert**: 「N 行存在する」を claim するなら `[ "$(awk ... | grep -cE '...')" = "N" ]` で件数も pin する (substring の有無だけでなく)
4. **Mutation test の併設**: assertion 強度の empirical 検証として、契約 row を意図的に 1 行削除した mutation で test が FAIL することを CI で確認する (test fidelity の正味)

### 変種: source-code を grep する静的 test は header comment でなく load-bearing logic 行に anchor する

被テストスクリプトを実行せず source を grep して「特定ロジックが存在する」ことを確認する**静的 test** も同じ false negative を起こす。grep が **header comment にマッチする** と「文字列の存在」を検証しているだけになり、肝心の検出ロジックが消えても test が pass する。

exit code semantic 事例では `projects-board-drift-check.sh` の検出ロジックを検証する静的 test が `COMPLETED` / `"Done"` を素朴に grep していた。これらの文字列は header comment にも現れるため、quoted jq 述語 (`stateReason == "COMPLETED"` / `select($st != "Done")`) という **load-bearing logic 行に anchor** する形へ強化した。quoted/predicate 形は header comment の散文と区別でき、述語を削除する mutation で assert が FAIL することを確認した (quoted `COMPLETED` 述語は AC-2 の NOT_PLANNED 除外も同時に pin する — 誤形化で literal が消えるため)。「narrative mention の false negative」が prose だけでなく **code comment** にも生じる、本ページ canonical の code 版。

**sibling 教訓 — exit-code 契約を持つスクリプトの test は exact code を assert する**: `exit 1=drift warning` / `exit 2=invocation error` のような独自 exit-code 契約を持つ script の test は、「非ゼロ」ではなく **「exit 2」を明示 assert** すべき。「非ゼロ」判定では exit 1 ↔ exit 2 の取り違え (Exit code semantic preservation の F-01 type regression) を捕捉できない。同事例では bare `--limit` 値欠落ケースを追加し exit 2 を明示 assert することで契約 regression を test で固定した。capture 行は `set +e`/`set -e` で囲み `set -euo pipefail` 下の harness abort を回避する。

### 変種: 指示と例の pin は所属する範囲に絞り、区間の終わりは一般形で取る

契約を列挙する文書の 1 行と、その契約を書く側の指示・例を固定するテストでは、節全体を探す範囲が広いと「消えたら落ちる」は満たしても「別の場所へ移る」変異を素通しする。読み手にとって、指示が所属する手順の外へ移ることは指示の消失と同じ帰結になるが、広い範囲の検索ではその 2 つを区別できない。指示は所属する手順（step の見出しから次の step の見出しまで）、例は例のコードブロックの中に絞って探す。

範囲を絞った後も、行を消す・句を消すといった削除系の変異が引き続き落ちることを同じ変異セットで確かめる。絞り込みで既存の検出力を失っていないことはこれで示せる。

区間を見出しで切り出す pin は、終わりの見出しを固定文字列にすると、その見出しの表記が変わったときに区間が黙って文書末尾まで広がる。終わりは「次の同種の見出し」の一般形で取り、切り出した区間が空なら落ちる形にすると fail-loud になる。範囲を絞る修正を入れるときは、区間の始まりと終わりの両方の頑健さを最初の修正でまとめて検討する。片方だけ直すと、修正後の再レビューで同系統の推奨がもう片方について出て、持ち越しになる。

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [Mutation testing で test の fidelity を empirical に測る](mutation-testing-test-fidelity.md)
- [ratchet test では occurrence 単位 (`grep -oE | wc -l`) を原則とし line 単位は混在させない](test-counting-occurrence-vs-line-unit.md)
- [`grep -oE | wc -l` が ratchet ideal 値到達時に pipefail で silent abort](../anti-patterns/grep-oe-wc-pipefail-silent-abort.md)
- [Exit code semantic preservation: caller は case で語彙を保持する](exit-code-semantic-preservation.md)

## ソース

- [レビュー結果](../../raw/reviews/20260512T134356Z-pr-936.md)
- [fix 結果](../../raw/fixes/20260512T134908Z-pr-936.md)
- [静的 grep が header comment にマッチする弱点 / exit 2 明示 assert](../../raw/reviews/20260608T113726Z-pr-1306.md)
- [quoted jq 述語への anchor + T-4 exit 2 明示化 + mutation 確認](../../raw/fixes/20260608T121039Z-pr-1306.md)
- [指示と例を所属範囲で探すべきと指摘したレビュー結果](../../raw/reviews/20260927T165534Z-pr-3317.md)
- [pin の検索範囲を step と例のブロックに絞った fix 結果](../../raw/fixes/20260927T170119Z-pr-3317.md)
- [区間の終わりを一般形で取り空なら落とす形を確認したレビュー結果](../../raw/reviews/20260927T170635Z-pr-3317.md)
