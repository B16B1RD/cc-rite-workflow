---
title: "新規 file 命名と既存 find glob が collision して silent 削除を起こす"
domain: "anti-patterns"
description: "既存の find glob (例: `.rite-flow-state.??????*` で `??????` が 6 文字 wildcard、`*` が任意文字) と、新規導入する file 命名 (例: `.rite-flow-state.legacy.<timestamp>`) が**偶発的に一致**する場合、find が新規 file をマッチしてしまい、`-mmin +1` 経過後に silent 削除される。"
promote: rite-plugin
created: "2026-04-30T03:50:00+00:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260430T031013Z-pr-747.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T102208Z-pr-3448.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T10:30:31Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T10:30:31Z" }
---

# 新規 file 命名と既存 find glob が collision して silent 削除を起こす

## 概要

既存の find glob (例: `.rite-flow-state.??????*` で `??????` が 6 文字 wildcard、`*` が任意文字) と、新規導入する file 命名 (例: `.rite-flow-state.legacy.<timestamp>`) が**偶発的に一致**する場合、find が新規 file をマッチしてしまい、`-mmin +1` 経過後に silent 削除される。新しい命名規則を導入する際は、既存 glob との semantic 衝突を必ず verify する。

## 詳細

### 検出された具体ケース（cycle 3）

`migrate-flow-state.sh` の backup ファイル命名を `.rite-flow-state.legacy.<UTC_timestamp>` に決定した直後、`session-start.sh` の cleanup find pattern `.rite-flow-state.tmp.* または .rite-flow-state.??????*` に対する collision が顕在化:

- `legacy` がちょうど **6 文字** で `??????` (6 文字 wildcard) にマッチ
- `*` (任意文字) が `.<timestamp>` 部分を消化
- 結果、新規生成された backup file が「tmpfile 残骸」と誤分類され、`-mmin +1` 経過後に削除される silent regression

### 同パターンの cross-component 伝播（cycle 4 CRITICAL）

cycle 3 で `session-start.sh` のみに `-not -name '.rite-flow-state.legacy.*'` 例外を追加したが、**`session-end.sh` に同一の find cleanup パターンが存在**しており propagation が漏れていた。reviewer の cross-file impact check (Asymmetric Fix Transcription) で初めて検出された。

### canonical 防御策

1. **新規命名導入時の glob audit**: 命名 token (`legacy` 等) を導入する前に、`grep -r "find.*-name" plugins/rite/hooks/` で既存 find pattern を全件 audit し、文字数 wildcard (`??????` 等) と semantic 衝突がないか verify する
2. **命名 token の test 化**: 「`legacy.` token が含まれる」のような暗黙の前提を test assertion 化し、将来 token が変わったときに silent regression を防ぐ
3. **`-not -name` 例外**: 既存 glob を変更したくない場合、find pattern に `-not -name '.rite-flow-state.legacy.*'` 例外を追加して **同一 cleanup pattern を持つ全ファイルに propagate** する (Asymmetric Fix Transcription 防止)
4. **regression test の defense-in-depth**: positive case (期待動作) のみ assert する test は brittle。**negative counter-test** (例外なしだと削除されることを assert) を併設することで、将来 refactor で例外が削除された場合に確実に検出できる
5. **timestamp 秒精度の race**: `date +%Y%m%dT%H%M%SZ` 等の秒精度では同秒並走時に path 衝突する可能性がある。`.$$.${RANDOM:-0}` (PID + RANDOM) の suffix で一意化するのが軽量解。`mv -n` (no-clobber) は片側を silent skip する semantics で data loss が発生するため非推奨

### root cause としての pattern class

このパターンは「**新しい命名規則を既存 system に導入する際の wildcard collision**」という class に属する。同型の事例として:

- find `-name '*.bak'` glob と新規 backup tool の `name.bak.<ts>` 命名
- gitignore `*.tmp` と新規生成される `temp.tmp` ファイル
- log rotation の `*.log.gz` glob と新規 archive の `name.log.gz.<ts>` 命名

いずれも「文字数 wildcard」または「任意文字 wildcard」の位置と新規命名 token の長さがちょうど一致する偶発で、テスト時には reproduce しにくい (timing-dependent: `-mmin +1` 経過後にのみ顕現する) のが特徴。

### state を読む glob が別の helper の保留ファイルを拾う

同じ衝突は削除以外でも起きる。新しい helper が state ディレクトリを接頭辞と接尾辞だけの glob で読んだところ、同じ接頭辞と接尾辞を持つ別ゲートの保留ファイルまで拾い、スキーマの違いで全体が停止した。state を読む helper は、読む対象のファイル名を完全な命名規則（識別子部分の形まで）で絞る。

同じレビューで並んだ指摘:

- 同じ記録の意味を 2 つの helper が別々に判定すると（評価順の違いなど）、同じ記録に食い違う処分を出す。判定は片方に寄せ、もう片方はその結果を読む。
- 自前の YAML パーサが null を文字列 "null" として読み、外部 helper に渡していた。
- 外部 helper が返す warnings を捨てていた（既存の呼び出し側は stderr に出す規約）。
- nested skill の返却 sentinel に `completed` の語を使うと caller の turn が閉じる。
- 公開リポジトリで Issue 本文の HTML コメント marker を信頼境界なしに処分の根拠にすると、第三者が処分を誘発できる。
- テストの stub が read 系のフラグ（`--state` など）を無視しており、否定側の fixture も無いため、条件の除去を検出できなかった。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [fix 結果](../../raw/fixes/20260430T031013Z-pr-747.md)
- [state を読む glob が別ゲートの保留ファイルを拾ったレビュー結果](../../raw/reviews/20260929T102208Z-pr-3448.md)
