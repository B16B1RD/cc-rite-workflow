---
type: "anti-patterns"
title: "grep (BRE) と grep -E (ERE) のメタ文字反転で assert ヘルパーが常時緑の dead assertion になる"
domain: "anti-patterns"
description: "選択子は BRE で `\\|`、ERE で `|`。`grep -qE` を使う assert ヘルパーに `A\\|B` を渡すと「A|B という 1 本の literal 文字列」を探すパターンになり、対象ファイルには決して現れないため常時緑になる。素の grep (BRE) で手元確認すると「マッチする」と観測できてしまうため、検証済みとして commit されうる。PR #2070 cycle 2 で mutation により発覚した。"
created: "2026-08-02T09:53:11+09:00"
updated: "2026-08-02T09:53:11+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260801T184452Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T185220Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260802T000641Z-pr-2070.md"
tags: ["dead-assertion", "bre-vs-ere", "mutation-testing", "assert-helper"]
confidence: high
---

# grep (BRE) と grep -E (ERE) のメタ文字反転で assert ヘルパーが常時緑の dead assertion になる

## 概要

`grep` と `grep -E` はメタ文字の意味が反転する。選択子は BRE (基本正規表現) で `\|`、ERE (拡張正規表現) で `|` である。`grep -qE` を内部で使う assert ヘルパーに `A\|B` を渡すと、選択子ではなく **literal のパイプ文字**として解釈され、「`A|B` という 1 本の文字列」を探すパターンになる。この文字列は対象ファイルに決して現れないため、アサーションは常に緑を返す = **dead assertion** になる。

危険なのは検証手順の側である。手元で素の `grep`（BRE）を使って「このパターンならマッチする」と確認すると、BRE では `\|` が選択子として機能するため **確かにマッチが観測できてしまう**。その観測を根拠に「修正前の状態でマッチする（= fail する）ことを確認済み」と commit message に書ける。結果、検証したつもりの dead assertion が「検証済み」として着地する。

## 詳細

**実例（PR #2070 cycle 1 → cycle 2）**

cycle 1 で「実在しない見出しへの参照を作らない」ことを pin するため、以下のアサーションを追加した。

```
assert_not_grep "$FILE" 'ステップ 3-7\.4\|ステップ 7\.4'
```

ヘルパー `assert_not_grep` の実装は `grep -qE`（ERE）だった。ERE では `\|` は選択子ではなく literal のパイプ文字になるため、このパターンは「`ステップ 3-7.4|ステップ 7.4` という連結された 1 本の文字列」を探す。対象ファイルにそんな文字列は存在せず、修正前の状態へ戻しても検出しない。cycle 2 の mutation testing で「変異を注入しても全緑のまま」として発覚した。

**なぜ手元確認が通ってしまうのか**

| コマンド | 方言 | `\|` の意味 | `A\|B` の挙動 |
|---------|------|-----------|--------------|
| `grep 'A\|B'` | BRE | 選択子 | A または B にマッチ → **観測できる** |
| `grep -E 'A\|B'` | ERE | literal のパイプ | 文字列 `A\|B` を探す → 決してマッチしない |

検証に使ったコマンドとアサーション本体が使うコマンドが違えば、検証結果は何も保証しない。

**回避策**

1. `assert_*` 系ヘルパーへパターンを渡す前に、**ヘルパーの実装で `grep` / `grep -E` のどちらを使うかを確認する**。ヘルパー名からは読み取れない。
2. 「このパターンならマッチするはず」という**推論**も、**別コマンドでの手元確認**も検証ではない。追加したアサーションは、**スイート本体を、そのアサーションが捕らえるはずの変異の下で走らせ、当該 assertion が FAIL することを目視する**まで検証されていない（[[mutation-testing-measures-assertion-strength]]）。
3. 検証の形は「隔離 worktree で変異を注入 → `FAIL: 1` を観測 → 変異を戻す」に統一する。緑のまま通ることこそが検証すべき失敗モードである。

**同型の失敗**

この dead assertion は「anti-pattern の `assert_not_grep` を追加したら、回避策が別の欠陥へ逃げないよう positive 側も同時に pin する」という cycle 1 の教訓の直後に生まれた。禁止（negative）だけを足すと、著者は禁止に触れない別表記へ逃げ、その別表記が新しい欠陥になる。禁止を足すときは、置換後の表記が意図した対象へ解決するかを測る positive 側の pin を対にする。

## 関連ページ

- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)
- [assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる — positive control を対で置く](./assert-not-grep-vacuous-without-fixture-scope.md)
- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](./locale-dependent-error-message-grep-assertion.md)

## ソース

- [PR #2070 review results (cycle 2)](../../raw/reviews/20260801T184452Z-pr-2070.md)
- [PR #2070 fix results (cycle 2)](../../raw/fixes/20260801T185220Z-pr-2070.md)
- [PR #2070 review results (cycle 5, mergeable)](../../raw/reviews/20260802T000641Z-pr-2070.md)
