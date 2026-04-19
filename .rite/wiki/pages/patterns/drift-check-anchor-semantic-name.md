---
title: "DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）"
domain: "patterns"
created: "2026-04-18T12:50:00+00:00"
updated: "2026-04-19T12:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T122454Z-pr-579.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T122707Z-pr-579.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T034237Z-pr-586-cycle5.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T122543Z-pr-600.md"
  - type: "fixes"
    ref: "raw/fixes/20260419T122750Z-pr-600.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T123103Z-pr-600.md"
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

### code slice 参照による semantic identifier の canonical 実証 (PR #600 での evidence)

PR #600 cycle 1 では `plugins/rite/commands/wiki/lint.md` のコメント内に `Phase 6.0 (line 698)` という「Phase 番号 + literal 行番号」の混成表現が残っていた。同 PR の +2 行差分で実体は L700 に shift し、コメントが即 stale 化した。cycle 2 fix で `(line 698)` を `LC_ALL=C cat .rite/wiki/log.md` という **対象コードの特徴的コード片による論理参照** に置換することで完全解消。両 reviewer (prompt-engineer / code-quality) が以下を独立して高く評価:

- **Grep で実体存在が機械検証可能**: 将来の読者が `grep 'LC_ALL=C cat .rite/wiki/log.md' lint.md` で target を確実に特定できる
- **PR の +N 行差分で stale 化しない**: 行番号 anchor のように shift しない
- **Phase 番号 + code slice の組み合わせ**: Phase 番号が「どの論理階層か」を示し、code slice が「その階層のどの具体行か」を指す 2 段階の semantic identifier として機能

canonical 記法の階層 (drift 耐性が高い順):

1. **Phase 番号 + 特徴的コード片** (最推奨、PR #600 実証): `Phase 6.0 の \`LC_ALL=C cat .rite/wiki/log.md\``
2. **Phase 番号 + heading / function 名**: `Phase 5.0.c canonical commit message`
3. **DRIFT-CHECK ANCHOR の semantic name**: `# >>> DRIFT-CHECK ANCHOR: ... <<<`
4. **literal 行番号** (禁止): `(line 698)` / `L1331-1332`

既存 convention (PR #564 F-06 で確立) を再導入時に違反する self-drift pattern として、commit 前 `grep -nE '\(line [0-9]+\)' <file>` で検出できる。

## 関連ページ

- [LLM substitute placeholder は bash residue gate で fail-fast 化する](./placeholder-residue-gate-bash-fail-fast.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)
- [AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する](./drift-check-anchor-prose-code-sync.md)

## ソース

- [PR #579 review results (cycle 1)](../../raw/reviews/20260418T122454Z-pr-579.md)
- [PR #579 fix results (cycle 1)](../../raw/fixes/20260418T122707Z-pr-579.md)
- [PR #586 cycle 5 review (大量行挿入時のコメント行番号 drift)](../../raw/reviews/20260419T034237Z-pr-586-cycle5.md)
- [PR #600 cycle 1 review (ハードコード行番号参照の self-referential drift 検出)](../../raw/reviews/20260419T122543Z-pr-600.md)
- [PR #600 fix results (semantic code slice 参照への置換による完全解消)](../../raw/fixes/20260419T122750Z-pr-600.md)
- [PR #600 cycle 2 review (code slice 参照の canonical 実証)](../../raw/reviews/20260419T123103Z-pr-600.md)
