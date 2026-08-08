---
type: "heuristics"
title: "移植性の指摘は「環境分岐を足す」より先に「その正規表現機能が本当に要るか」を疑う"
domain: "heuristics"
description: "sed の GNU 拡張（\\b 単語境界）への依存を、BSD 分岐の追加でも sed -E への切り替えでもなく「貪欲な文字クラスでトークン全体を取り、妥当性判定は既存の case へ一本化する」で解いた。境界指定が必要に見えたのは、値の長さ制限という別の制約を正規表現側に持たせていたためで、その制約自体が不要だった。GNU 依存と「値の集合が 2 箇所にある」重複が同時に消える。"
created: "2026-08-08T14:00:41+09:00"
updated: "2026-08-08T14:00:41+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260807T235335Z-pr-2142.md"
  - type: "fixes"
    ref: "raw/fixes/20260808T001157Z-pr-2142.md"
tags: ["portability", "posix", "sed", "regex", "simplification"]
confidence: high
---

# 移植性の指摘は「環境分岐を足す」より先に「その正規表現機能が本当に要るか」を疑う

## 概要

`sed` の抽出式が GNU 拡張の `\b`（単語境界）に依存していた。POSIX BRE に `\b` は無く、BSD/macOS sed は**無警告で不一致**になる。ここで反射的に選びたくなるのは次の 2 つだが、どちらも構造を増やす。

- BSD 用の分岐を足す（`bash-portable-command-fallback` の適用）
- `sed -E`（ERE）へ切り替える

PR #2142 で採ったのは 3 つ目 — **貪欲な `[A-Za-z][A-Za-z]*` でトークン全体を取り、妥当性判定は既に存在する `case` に一本化する**。GNU 依存と「レーン値の集合が 2 箇所にある」重複が同時に消えた。

## 詳細

### なぜ境界指定が要ると錯覚したか

`\b` は値の切り詰め（1-2 文字という長さ制限）を正規表現側で担保するために置かれていた。つまり**「抽出」と「妥当性判定」という別の関心を 1 つの式に混ぜていた**。判定を `case` へ寄せれば長さ制限は式から消え、境界指定も要らなくなる。

移植性の指摘を受けたら、まず「この機能は何を担保しているか」を分解する。担保しているものが別レイヤーにも存在するなら、正規表現からは削れる。

### 環境分岐が正しい場合との切り分け

本リポジトリは `stat` / `date` / `wc` / `rm` / `realpath` / `md5sum` について既に BSD 分岐を持っている。**コマンドの機能そのものが GNU/BSD で違う**場合は分岐が正しい。一方 `sed` の GNU 正規表現拡張は「同じ機能を別の書き方で書ける」ので、書き方を POSIX に寄せるほうが安い。実測では plugins/rite 配下 1,135 箇所の sed 使用のうち、GNU 拡張に依存していたのは本 2 行だけだった。

### 再混入を止める probe は「探し方」で壊れる

GNU 拡張の再混入を止めるために静的 denylist probe を書いたが、haystack を `grep -n 'sed -n' file` にしたため (i) 式を継続行へ折り返すだけで走査対象から外れ、(ii) 探し方が 0 件を返すと haystack が空になり assert が**無言で vacuous pass** した。対策は 3 つ:

- haystack の非空を precondition として先に assert する
- 走査軸を「実装の形」ではなく「コメント以外の本文全体」のように壊れにくいものにする
- denylist の語彙を、宣言した規範（POSIX BRE のみ）に対して網羅する — `\b` `\|` だけ挙げて `\+` `\?` を漏らすと、最も自然な書き換え形が素通りする

## 関連ページ

- [bash 移植性: コマンドの GNU/BSD 差はフォールバックで吸収する](../patterns/bash-portable-command-fallback.md)
- [外部コマンドの入れ替えはプラットフォーム差の所在を移すだけのことがある](../anti-patterns/external-command-swap-relocates-platform-divergence.md)
- [静的ガードは走査スコープの限界を宣言する](./static-guard-declare-scan-scope-limits.md)
- [negative assertion は precondition floor が無いと vacuous になる](../anti-patterns/negative-assertion-vacuous-without-precondition-floor.md)

## ソース

- [PR #2142 review results](../../raw/reviews/20260807T235335Z-pr-2142.md)
- [PR #2142 fix results](../../raw/fixes/20260808T001157Z-pr-2142.md)
