---
type: "heuristics"
title: "commit 前にリポジトリ自身の checker を全変更ファイルへ回す — 機械検出できる違反を reviewer に探させない"
domain: "heuristics"
description: "リポジトリが規約 checker を持っているなら、commit 前に変更ファイル全件へ回す。自動検出できる違反を reviewer が指摘すると 1 cycle 遅れ、その cycle の指摘枠を消費する。PR #2038 cycle 5 では 14 件の指摘のうち 2 件（ハードコード行番号 / ジャーナルコメント）が repo 自身の checker が rc=1 で検出できるものだった。pre-existing の hit と本 PR 由来を分けるには develop 側との照合が要る。"
created: "2026-07-28T21:30:00+09:00"
updated: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260728T100957Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T122258Z-pr-2038.md"
tags: []
confidence: high
---

# commit 前にリポジトリ自身の checker を全変更ファイルへ回す — 機械検出できる違反を reviewer に探させない

## 概要

リポジトリが規約 checker（ハードコード行番号検出、コメント品質検出、スキーマ drift 検出など）を持っているなら、**commit 前に変更ファイル全件へ回す**。

自動検出できる違反を reviewer に指摘させると:

- **1 cycle 遅れる**（指摘 → fix → 再レビュー）
- **その cycle の指摘枠を消費する**（reviewer の注意が機械で潰せるものに向く）
- 「tautology な pin を直す PR が checker 違反を持ち込む」のような**自己矛盾**が起きる

## 詳細

### 実例（cycle 5）

指摘 14 件のうち 2 件（HIGH ×2）が repo 自身の checker で検出可能だった。

```
$ bash hooks/scripts/hardcoded-line-number-check.sh --target <file>
rc=1  P-C 2 件 (SKILL.md:3546 / SKILL.md:2508 — 参照先はいずれも既にずれていた)

$ bash hooks/scripts/comment-journal-check.sh --target <file>
rc=1  P2 1 件 (「旧実装は ...」のジャーナルコメント)
```

しかも、これらを持ち込んだのは **cycle 4 で「構造的に落ちえない tautology な pin」を修正したコミット**だった。再発防止を実装する PR が、別クラスの機械検出可能な違反を新規に混入させていた。

### 実行の型

```bash
for f in $(git diff --name-only origin/develop...HEAD); do
  [ -f "$f" ] || continue
  bash <checker> --target "$f"
done
```

`--all` オプションがあるものは全体で回す（`hardcoded-line-number-check.sh --all` など）。

### pre-existing と本 PR 由来を分ける

checker を全体に回すと、**本 PR が触っていない既存の hit** が混ざる。これを本 PR の残作業として扱うと、無関係なファイルの修正へスコープが広がる。

分ける手順は、hit 行が develop 側に存在するかの照合。

```bash
line=$(sed -n "${ln}p" "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if git show "origin/develop:$f" | grep -qF -- "$line"; then
  echo "pre-existing"
else
  echo "本 PR 由来"
fi
```

`grep -qF -- "$line"` の `--` は必須。行が `-` で始まると（markdown の箇条書きは頻出）オプションと解釈されて誤判定する。

PR #2038 では checker の hit 5 件のうち 3 件が pre-existing で、本 PR 由来は 2 件だった。この切り分けをせずに全件対応していたら、スコープ外のファイルを触ることになっていた。

### checker が拾えないクラスもある

同 PR では `旧版は` 形式のジャーナルコメント 4 件が checker の正規表現に掛からなかった（検出パターンは `旧実装(は|では)` のみ）。**checker の通過は「そのクラスが無い」ことを意味しない**。checker は下限であって上限ではない。

なお、この種の書き換えを機械的な文字列置換で行うと**意味が反転する**ことがある。「旧版は X で、Y を検出できなかった」の接頭辞だけを「本 pin が満たすべき条件: X」に差し替えると、**棄却された手法 X を要件として宣言する**文になる。ジャーナルコメントを不変条件記述へ直すときは文全体を書き直す。

## 関連ページ

- [cycle が進んでも findings が減らないときは点修正をやめて構造を疑う](./non-converging-review-loop-suspect-structure.md)
- [CI lint チェックを blocking gate に昇格するときはツール自身の exit code を gate にする](./ci-blocking-gate-tool-exit-code.md)
- [pin を足す「前」に mutation を当てると、pin の要否と有効性を分離して判定できる](../patterns/mutation-before-pin-separates-necessity-from-efficacy.md)

## ソース

- [PR #2038 fix results (cycle 5)](../../raw/fixes/20260728T100957Z-pr-2038.md)
- [PR #2038 fix results (cycle 6, final)](../../raw/fixes/20260728T122258Z-pr-2038.md)
