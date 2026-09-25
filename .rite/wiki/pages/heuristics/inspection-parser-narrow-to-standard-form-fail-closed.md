---
type: "heuristics"
title: "検査用のシェル字句解析は判定対象を標準形に絞り、それ以外を fail-closed にする"
domain: "heuristics"
description: "コマンドを検査する guard で bash の字句規則を近似する自前パーサを直し続けると、指摘は前回の修正の隣の形として増え続ける。理解すると主張する範囲を実運用の標準形に絞り、それ以外は分類したうえで止める方が収束する。"
created: "2026-09-25T03:58:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-25T03:58:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260924T212015Z-pr-3060.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T215513Z-pr-3060.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T231240Z-pr-3060.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T212910Z-pr-3060.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T220725Z-pr-3060.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T224558Z-pr-3060.md"
tags: ["guard", "parser", "fail-closed", "heredoc", "divergence"]
confidence: high
---

# 検査用のシェル字句解析は判定対象を標準形に絞り、それ以外を fail-closed にする

## 概要

commit 前検査のように「実行されるものを見落とさない」ことを要求される guard で、bash の字句規則を近似する自前パーサを修正し続けると、各 cycle の指摘は前回の修正の隣の形（引用内のコマンド置換、オプションの省略形、heredoc でない `<<`）として現れ、blocking 件数が増え続ける。パーサが理解すると主張する範囲を実運用の標準形に絞り、それ以外の形は分類したうえで fail-closed に止める方が収束する。

## 詳細

### 発散の経過

ある guard では、shlex を自前の tokenizer に置き換えたところから次の順に穴が移った。

- 二重引用内のコマンド置換（`x="$(git commit ...)"`）が検出から漏れた。旧実装は parse error で fail-closed に止めていた
- git の long option は一意な前方一致の省略形を受け付けるため、完全一致での判定が省略形で迂回された
- 引用内の置換を再帰分割した結果、heredoc 本文（データ）までコマンドとして読み、エージェント標準の `git commit -m "$(cat <<'EOF' ... EOF)"` が本文のアポストロフィだけで拒否された
- 「data として捨てる範囲」を構文規則で決めると、heredoc でない `<<` や展開される本文まで捨てて fail-open になった

blocking 件数は 2 → 2 → 5 → 7 → 14 と増え、サーキットブレーカーで停止した。

### 収束させる方針

- **標準形を 1 つに絞る**: data として読み飛ばすのは実運用の標準形（置換全体が `cat` の heredoc で、最初の区切り行の後に空白と `)` しか無い形）だけにする。それ以外は読んで判定する
- **サブシェルは解析せず nested として扱う**: `$( )` / バッククォート / `( )` の中の `cd` は外側に効かせず、中の commit / merge は direct でないとして拒否する。中身を分類するより面が小さい
- **列挙しきれない入力は拒否する**: オプションの省略形のように既定動作を列挙しきれない入力は通さない
- **拒否の根拠は分類の後に適用する**: 対象外の操作を巻き込まない
- **実運用の入力をコーパスとして固定する**: commit メッセージの heredoc 形や skill の fenced bash を corpus テストにし、変更前後の分類を突き合わせる。敵対的な形だけを追うと、実運用側の後退に気付けない

### 判断の合図

発散（blocking の増加）は個別指摘への対処ではなく構造の見直しが必要な合図である。同じ方針の変種を試すのではなく、パーサが理解すると主張する範囲を狭める方向へ切り替える。

## 関連ページ

- [同じ述語を 2 言語で並行実装すると受理集合が環境で割れる — 定義を 1 本に寄せるまで症状は再発し続ける](../anti-patterns/dual-language-predicate-divergence.md)
- [ゲートに検査を足すより、実行者が選べる自由度を削る](./reduce-gate-degrees-of-freedom.md)
- [best-effort な静的 matcher hardening は allowlist を COMMON-SET（非網羅）と宣言して review の whack-a-mole を止める](./best-effort-matcher-declare-common-set-to-stop-whackamole.md)

## ソース

- [レビュー結果](../../raw/reviews/20260924T212015Z-pr-3060.md)
- [レビュー結果](../../raw/reviews/20260924T215513Z-pr-3060.md)
- [レビュー結果](../../raw/reviews/20260924T231240Z-pr-3060.md)
- [fix 結果](../../raw/fixes/20260924T212910Z-pr-3060.md)
- [fix 結果](../../raw/fixes/20260924T220725Z-pr-3060.md)
- [fix 結果](../../raw/fixes/20260924T224558Z-pr-3060.md)
