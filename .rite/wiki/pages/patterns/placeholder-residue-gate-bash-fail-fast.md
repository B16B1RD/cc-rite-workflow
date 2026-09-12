---
title: "LLM substitute placeholder は bash residue gate で fail-fast 化する"
domain: "patterns"
description: "LLM が literal substitute する bash 変数 (例: `commit_msg=\"... {n_pages_created} ...\"` や `var=\"{placeholder}\"`) は、substitute 漏れ時に bash レベルで silent 誤動作する経路を持つ。"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/patterns/placeholder-residue-gate-bash-fail-fast.md"
created: "2026-04-18T12:50:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260418T122454Z-pr-579.md"
  - type: "fixes"
    resource: "raw/fixes/20260418T122707Z-pr-579.md"
  - type: "reviews"
    resource: "raw/reviews/20260804T145133Z-pr-2111.md"
  - type: "reviews"
    resource: "raw/reviews/20260904T091303Z-pr-2549.md"
  - type: "fixes"
    resource: "raw/fixes/20260904T092650Z-pr-2549.md"
  - type: "reviews"
    resource: "raw/reviews/20260912T094630Z-pr-2731.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-12T10:05:00Z" }
verified:
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-04T13:54:13Z" }
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-12T10:05:00Z" }
---

# LLM substitute placeholder は bash residue gate で fail-fast 化する

## 概要

LLM が literal substitute する bash 変数 (例: `commit_msg="... {n_pages_created} ..."` や `var="{placeholder}"`) は、substitute 漏れ時に bash レベルで silent 誤動作する経路を持つ。`case "$var" in "{"*"}") exit 1 ;; esac` 形式の residue gate を同型に配置することで fail-fast 化し、literal `{placeholder}` が landed する silent regression を防ぐ。

## 詳細

### 失敗モード

bash block で `[ "{placeholder}" -gt 0 ]` のような比較を行う場合、LLM が `{placeholder}` を literal substitute しないまま実行すると:

- `[ "{n_contradictions}" -gt 0 ]` は `integer expression expected` rc=2 を返す
- `set -o pipefail` のみでは検知されず silent に `else` 分岐に落ちる
- 結果として `lint:clean` / `lint:warning` 判定が誤値で emit され downstream が汚染される

### Canonical fix（cycle 1 で導入）

placeholder を含む変数を使う bash block の冒頭で、以下の gate を同型に配置する:

```bash
case "$commit_msg" in
  *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
    echo "ERROR: Phase 5.1 の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
    echo "  対処: LLM は Phase 2.1 / Phase 4 で incrementate したカウンタ値を本 bash block で literal substitute する必要があります" >&2
    exit 1
    ;;
esac
```

### 既存 5 site + 新規 1 site = 6 site 対称化

起点事例の時点で同型の residue gate が `rite` plugin 内の 6 site で運用されている (Phase 1.1 / 1.3 / 6.2 F-01 / 8.3 F-14 / F-04 + 新規 1 site)。canonical reference として新規 bash block を登録する際は既存同種 site と一字一句同型に揃えること。drift は silent regression の温床となる。

### 新設 helper にも gate を置く — sibling との対称性が判断基準（cycle 3）

LLM substitute シームを持つ helper を新設するとき、SKILL.md 側（呼び出し bash block）の residue gate だけでは防げない — helper 側にも引数検証としての gate を置く。判断基準は **sibling helper との対称性**: 同種の LLM substitute シームを持つ sibling（`wiki-lint-stale.sh`）と SKILL.md 5.0.c に canonical gate があるのに新設 helper だけ無い状態は Canonical helper bypass の変種であり、片肺のまま残すと substitute 漏れが helper 内で silent 誤動作に変換される。

なお、gate の検出条件を「brace 囲み」の形状ヒューリスティックとして free text（title/description）へ転用すると正当値を棄却する（同 PR cycle 4 で実測）。residue 検出は呼び出し側が渡す literal（`{title}` 等）との exact 突合で行う — 詳細は関連ページの「防御は攻撃面と同じ粒度で張る」を参照。

### 残留検査のパターンは placeholder 名ではなくブレースの形状で書く

検査対象の値ではなく、**検査パターン自身**が substitute されると、gate は自分を無効化する。パターンに `*"{plugin_root}"*` のように placeholder 名を書くと、literal substitute がパターン側まで書き換え、実行時には常に既に埋まっている値と照合して residual を見逃す。sibling が使っているのはブレースの形状（`"{"*"}"`）であり、名前をパターンに埋め込まない。この欠陥は静的 grep からは見えず、実行可能ブロックを 1 回走らせた pin が捕まえた。

### ファイルパスに入る placeholder は一度だけ変数で受けて数値検証する

placeholder が state ファイル名に直接入る場合（`.rite/state/review-run-since-{pr_number}.txt` 等）、置換漏れはエラーにならず字面どおりの名前のファイルとして通る。書く側と読む側が同じように漏らすと、字面どおりの名前のファイル同士で辻褄が合い、警告も出ずに誤った状態を読む。bash block の先頭で `pr_number="{pr_number}"` を一度だけ受け、`case "$pr_number" in ''|*[!0-9]*) ... exit 1 ;; esac` で最初のファイル操作より前に止め、以降のパスは `${pr_number}` で組み立てる。Bash 呼び出し間でシェル変数は引き継がれないため、同じ値を使う fence ごとに gate を置く。

この形をテストで検証するときは、SKILL.md から gate と対象部を literal 抽出し、置換は gate 行の `"{pr_number}"` だけに当てる。全文を機械置換すると `${pr_number}` の内側まで書き換わり、テスト自体が本番と違う bash を走らせる。不正値（未置換・空・数字混じり・先頭空白・負号）では書込側がファイルを作らず、読込側が後段の helper 呼び出しに進まないことを観測点にする。

### LLM 内部状態 vs shell 変数の境界

bash tool 呼び出し境界を跨いで shell 変数は保持されない。Phase A で `count=5` を定義しても Phase B からは参照不能で、LLM は自身の内部状態 (会話コンテキスト) から literal 値を substitute する責務を負う。この契約は bash コメントで明示することで、将来の読者が「なぜ placeholder が多いのか」を理解できる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](./drift-check-anchor-semantic-name.md)
- [防御は攻撃面と同じ粒度で張る — 過剰防御は「安全側」ではなく別の実害](../heuristics/defense-granularity-matches-attack-surface.md)

## ソース

- [レビュー結果](../../raw/reviews/20260418T122454Z-pr-579.md)
- [fix 結果](../../raw/fixes/20260418T122707Z-pr-579.md)
- [レビュー結果](../../raw/reviews/20260804T145133Z-pr-2111.md)
- [レビュー結果](../../raw/reviews/20260904T091303Z-pr-2549.md)
- [fix 結果](../../raw/fixes/20260904T092650Z-pr-2549.md)
- [レビュー結果](../../raw/reviews/20260912T094630Z-pr-2731.md)
