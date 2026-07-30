---
type: "heuristics"
title: "agent が人間に渡す復旧コマンドは、人間の実行コンテキストで正しいかを検証する"
domain: "heuristics"
description: "agent の Bash tool と人間の端末では session 解決経路・cwd・env が構造的に異なるため、agent の文脈で検証したコマンドは人間が実行すると別の対象に効く。rc=0 は「正しい対象に効いた」ことを意味せず、誤った対象への書き込みが rc=0・無出力で成功して事後の読み取りも正常系と同じ値を返す場合、実行前の実在確認だけが唯一の防護になる。PR #2044 で session 軸・state root 軸・SoT helper 置換の 3 形態が別 cycle に出た。"
created: "2026-07-29T21:32:36+09:00"
updated: "2026-07-29T21:32:36+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260729T064538Z-pr-2044.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T070922Z-pr-2044.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T085226Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T051956Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T073316Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T075214Z-pr-2044.md"
tags: []
confidence: high
---

# agent が人間に渡す復旧コマンドは、人間の実行コンテキストで正しいかを検証する

## 概要

停止通知やエラーメッセージに埋め込む「手動復旧コマンド」は、agent が自分の Bash tool で叩いて rc=0 を確認しても検証にならない。agent と人間では実行コンテキストが構造的に違い、同じコマンドが**別の対象**に効く。しかも誤った対象への書き込みは rc=0・無出力で成功するため、実行者は空振りに気づけない。

## 詳細

### 同じ resolver が持つ軸をすべて塞ぐ

起点事例では同型の欠陥が 3 つの異なる軸で、別々の cycle に出た。

**(1) session 軸**: コマンドが `--session` を持たず `flow-state.sh` の session 解決順に委ねていた。agent の Bash tool は env var 経路、人間の端末は env 不在で `.rite-session-id` 経路になる。さらに `session-start.sh` は env がある間 `.rite-session-id` を書かないため、**両者の不一致は drift ではなく設計上の定常状態**だった。

**(2) state root 軸**: `--session` で sid を固定した後も `resolve_state_root` は cwd へフォールバックする。repo 外の cwd で実行すると rc=0 のまま別ファイルを作り、本来直すべき state は手つかずで残る。marketplace install ではコマンド文字列にプロジェクト参照が一切含まれず、新規端末の既定 cwd が `$HOME`（非 git）になるため、**空振りが例外ではなく既定経路**になる。

**判断の型**: 1 つの軸を明示的に必須化したら、同じ resolver が持つ他の軸も同時に塞ぐ。片方を塞いだ時点で対称性を確認する。

**(3) SoT helper の「同等品」置換**: `state-path-resolve.sh` の代わりに `git rev-parse --show-toplevel` を書くと、linked worktree では前者が main checkout へ unify するのに対し後者は worktree root を返す。「同じ値が得られそうな標準コマンド」は worktree・symlink・sandbox のいずれかで必ず分岐する（[Canonical helper bypass](../anti-patterns/canonical-helper-bypass.md) の一形態）。

### rc=0 は「正しい対象に効いた」を意味しない

これが本パターンの中核。誤対象への書き込みが rc=0 で成功し、事後の読み取りも正常系と同じ値を返す場合、**「実行して結果を見る」型の確認手順は原理的に成立しない**。実行**前**の実在確認だけが唯一の防護になる。

したがって復旧コマンドには、SoT helper を呼んだうえで**対象ファイルの実在を gate にして空振りを明示エラーへ倒す**構造を持たせる。

### 劣化軸が増えても分岐ラベルは増やさない

軸が増えるたびに (a)/(b)/(b')/(c) とラベルを足すと条件表が肥大し、5 cycle 目には「3 テンプレートで 4 象限を覆う」構造になっていた。1 テンプレートが 2 象限を兼ねる代償として、片方の象限で**既に判明している情報を捨てる**（marker にある session_id を無視して人間に探索させる）欠陥が生まれ、しかもその探索は一意に定まらなかった。

**畳み込みの型**: 「1 テンプレート + 軸ごとの optional pre-fill 表」にする。得られた側は必ず埋め、得られなかった側だけを解決手順へ置き換える。各象限が独立に正しく縮退し、情報を捨てる経路が構造的に消える。

判断基準は直交性 — 新しい劣化軸が既存分岐と**直交**するなら pre-fill / 差し替えで吸収し、**排他**ならラベルを足す。直交する軸をラベルで表現すると組み合わせ爆発する。

### 診断手段は「そのケースで実際に観測できるか」を確かめてから書く

「直接確認するほかない」と案内する前に、その確認が事後に可能かを検証する。flow-state の handoff キーは Stop hook の consume-handoff が `jq 'del(.handoff)'` で**再注入と同時に**削除するため、事後に覗いても常に不在で確認手段にならない。さらに、stderr を出す経路がすべて値を返さず終わる実装では、**値が返ったケースでは診断が構造的に出ない** — デバッグフラグを立てても観測できない。one-shot consume される値は、消費後の確認が構造的に不可能。

## 関連ページ

- [Canonical helper bypass: 既存集約 helper を bypass して inline 再実装する](../anti-patterns/canonical-helper-bypass.md)
- [変更・削除の掃き出しは旧語彙・置換した条件式・別記法トークンまで広げる](./change-sweep-spans-old-vocabulary-and-notations.md)
- [bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す](../patterns/bash-initial-value-aligns-with-allowed-values.md)

## ソース

- [PR #2044 review results (cycle 2)](../../raw/reviews/20260729T064538Z-pr-2044.md)
- [PR #2044 review results (cycle 3)](../../raw/reviews/20260729T070922Z-pr-2044.md)
- [PR #2044 review results](../../raw/reviews/20260729T085226Z-pr-2044.md)
- [PR #2044 fix results (cycle 4)](../../raw/fixes/20260729T051956Z-pr-2044.md)
- [PR #2044 fix results (cycle 4)](../../raw/fixes/20260729T073316Z-pr-2044.md)
- [PR #2044 fix results (cycle 5)](../../raw/fixes/20260729T075214Z-pr-2044.md)
