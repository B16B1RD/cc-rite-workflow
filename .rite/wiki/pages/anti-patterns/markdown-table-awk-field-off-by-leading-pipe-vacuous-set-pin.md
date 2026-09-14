---
type: "anti-patterns"
title: "Markdown 表を awk の既定 FS で抽出すると $1 が行頭のパイプになり、空集合ループの pin が常時 PASS する"
domain: "anti-patterns"
promote: rite-plugin
description: "Markdown 表の行を awk の既定フィールド分割で読むと第 1 フィールドは行頭の `|` であり、記号を gsub で剥がすと空文字になる。その空集合を for で回す「SoT の各要素を実装が扱う」pin はループが 0 回で常に PASS し、arm を削っても落ちない。集合を抽出したら非空を先に pin する。"
created: "2026-09-15T00:45:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260914T151507Z-pr-2822.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T153152Z-pr-2822.md"
tags: ["test", "static-pin", "awk", "markdown-table", "vacuous-truth", "fixture", "bash"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-15T00:45:00Z" }
---

# Markdown 表を awk の既定 FS で抽出すると $1 が行頭のパイプになり、空集合ループの pin が常時 PASS する

## 概要

Markdown 表の行（`| \`init\` | ... |`）を awk の既定フィールド分割で読むと、第 1 フィールドは行頭の `|` である。記号を `gsub` で剥がすと空文字になり、集合は空になる。その集合を `for p in $set` で回して「SoT が列挙する各要素を実装の case が扱う」と主張する pin は、ループが 0 回で `missing` が空のまま PASS する。実装から arm を削っても落ちない。

集合を抽出する pin は、**抽出直後に非空（または下限件数）を pin してから**要素ごとの検査に入る。空集合で真になる assert は何も守っていない。

## 詳細

### 実測された症状

recover スキルの Phase enum 表（13 行）から phase 名を抽出し、batch-run の再開振り分け case が全 phase を扱うことを pin した。抽出は `awk '/^\| \`[a-z_]+\` \|/{gsub(/[\`| ]/,"",$1); print $1}'`。`$1` は `|` であり、gsub 後は空行 1 本だけが出力された。suite は 34 件すべて PASS で、`cleanup|ingest)` の arm を `cleanup)` に変えても green のままだった。

3 名の reviewer が独立に同じ pin を「常時 PASS」と実測した。修正は `$2` への変更に加え、`recover_count` の非空 pin（`grep -c '^[a-z_]\+$'` が 0 でないこと）を集合抽出の直後に置くこと。修正後は arm 削除が `未扱い: completed` として FAIL になった。

### 同型: fixture を作る helper が値を正規化し、対象 arm に到達しない

同じ PR の次サイクルで、bash の `case "$fs_pr" in ''|0|*[!0-9]*)` の `''` arm を pin するつもりで `run_stage ... ""` と空の PR 番号を fixture helper に渡したが、`flow-state.sh set --pr ""` は state に `pr_number: 0` を書き、`get` は `0` を返す。テストは既存の `0` 経路を再実行しただけで、`''` arm を除去しても 47 件 PASS のままだった。

空文字が実際に届くのは state ファイルが `"pr_number": ""` を持つ場合だけであり、それを pin するには `set` 後に `flow-state.sh path` のファイルを `jq '.pr_number = ""'` で直接書き換える fixture が要る。**fixture を作る helper の正規化を通ると、狙った分岐に入力が届かない**。分岐を pin するときは、その分岐の入力が helper の正規化を素通りできるかを先に確かめる。

### 確認手順

1. 集合を抽出したら `printf '%s\n' "$set" | grep -c .` を非空 / 下限で pin する（等値ではなく下限にすると SoT 側の正当な増減で無関係な赤にならない）
2. 実装から arm を 1 つ削った変異で pin が落ちることを実測する
3. fixture を helper 経由で作るときは、helper が入力を既定値へ正規化していないか（空 → 0、未設定 → default）を helper の docstring か実測で確かめる

## 関連ページ

- [assert_not_grep は fixture の範囲が空なら空虚に真になる](./assert-not-grep-vacuous-without-fixture-scope.md)
- [pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する](../patterns/pin-literal-uniqueness-verified-by-mutation.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](./test-pin-protection-theater.md)

## ソース

- [レビュー結果](../../raw/reviews/20260914T151507Z-pr-2822.md)
- [レビュー結果](../../raw/reviews/20260914T153152Z-pr-2822.md)
