---
title: "DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）"
domain: "patterns"
created: "2026-04-18T12:50:00+00:00"
updated: "2026-04-19T03:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T122454Z-pr-579.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T122707Z-pr-579.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T034237Z-pr-586-cycle5.md"
tags: []
confidence: high
---

# DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）

## 概要

drift 防止を目的とする anchor comment で literal 行番号 (例: `(L1331-1332)`) を埋め込むと、そのアンカー自身が drift 源になる。`# >>> DRIFT-CHECK ANCHOR: <canonical-semantic-name> <<<` 形式 (+ END marker) で semantic name 参照として記述するのが canonical。ingest.md Phase 5.0.c の 4 site が既存 reference implementation。

## 詳細

### 問題: literal 行番号の自己撞着

ファイル内で「他所と一字一句同期すべき」ことを示す DRIFT-CHECK ANCHOR コメントに `参照: L1331-1332` と literal 行番号を書くと、同ファイル自身が以下の通り「行番号は drift するため Phase 番号と semantic 名のみで参照する」と 3 site で規範化している既存方針に反する:

- line 番号はファイル編集で容易に shift する
- anchor 本体が指す target と anchor 自身が drift する経路ができる
- 将来の読者は「行番号が当たらない anchor」を noise として無視するようになる

### Canonical 形式 (PR #579 cycle 1 で統一)

```bash
# >>> DRIFT-CHECK ANCHOR: Phase 5.0.c canonical commit message <<<
commit_msg="..."
# >>> END DRIFT-CHECK ANCHOR <<<
```

semantic name は canonical SoT への参照として機能し、`grep` で target を特定可能にする。ingest.md Phase 5.0.c canonical / Phase 5.0.c canonical placeholder-residue gate の 4 site が reference implementation。

### 3 箇所 explicit sync の契約

Phase 5.1 / Phase 5.2 / Phase 5.0.c のように同一 semantic の記述が複数 site にまたがる場合は、explicit sync の契約を prose で明示する:

> 本 `commit_msg` 文字列と直下の placeholder-residue gate は Phase 5.0.c canonical と Phase 5.1 / Phase 5.2 の同一文字列と 3 箇所 explicit sync を契約。変更時は 3 箇所同時更新必須。

将来 `/rite:lint` で grep ベースの drift 検出を実装可能にする設計意図も含む。

### 大量行挿入時のコメント内行番号参照 drift (PR #586 cycle 5 での evidence)

PR #586 cycle 4 fix で Phase 1.3 ブロック (約 235 行) を init.md の Phase 1.2 と Phase 2 の間に挿入した結果、cycle 4 fix の F-02 修正コメント自身が「同一ファイル内 L555」を参照していたが、実際の対象行は L563 にずれた (8 行 drift)。cycle 5 review で F-02 として検出。

本原則は DRIFT-CHECK ANCHOR コメントだけでなく、**fix コメント / 設計メモ / 概要説明など**「同一ファイル内の他箇所を参照するあらゆる散文」に拡張される:

1. **参照は anchor / Phase 番号 / heading / function 名で書く**: drift 耐性が高い
2. **大量行挿入を伴う PR では最終 commit 後に行番号参照を grep で走査**: `grep -nE 'L[0-9]+' <file>` で全件取り出して目視再確認
3. **将来的に `/rite:lint` でコメント内行番号参照を検出する lint を追加する候補**: `L[0-9]+` を含むコメントは機械検証できないため、anchor / Phase 番号への置換を促す

## 関連ページ

- [LLM substitute placeholder は bash residue gate で fail-fast 化する](./placeholder-residue-gate-bash-fail-fast.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)
- [AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する](./drift-check-anchor-prose-code-sync.md)

## ソース

- [PR #579 review results (cycle 1)](../../raw/reviews/20260418T122454Z-pr-579.md)
- [PR #579 fix results (cycle 1)](../../raw/fixes/20260418T122707Z-pr-579.md)
- [PR #586 cycle 5 review (大量行挿入時のコメント行番号 drift)](../../raw/reviews/20260419T034237Z-pr-586-cycle5.md)
