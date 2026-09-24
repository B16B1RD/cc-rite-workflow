---
type: "anti-patterns"
title: "手順を helper へ移して入口検証を足すと、未定義 placeholder で流れていた終端経路が停止に変わる"
domain: "anti-patterns"
description: "手順書のシェルブロックを helper のサブコマンドへ移し、入口に必須・数値・未置換検査を足すと、旧ブロックでは空値のまま既定分岐へ落ちていた経路が exit 2 で止まる。移設時は placeholder を読む全経路で値が決まるかを列挙し、関数内に残る旧 guard とそれを前提にした文書・テストも入口の出力へ寄せる。"
created: "2026-09-25T00:50:10+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-25T00:50:10+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260924T152559Z-pr-3055.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T153248Z-pr-3055.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T154135Z-pr-3055.md"
tags: []
confidence: high
promote: rite-plugin
---

# 手順を helper へ移して入口検証を足すと、未定義 placeholder で流れていた終端経路が停止に変わる

## 概要

手順書のシェルブロックを helper のサブコマンドへ移し、入口に必須・数値・未置換検査を足すと、旧ブロックでは空値のまま既定分岐へ落ちていた経路が exit 2 で止まる。移設時は placeholder を読む全経路で値が決まるかを列挙し、関数内に残る旧 guard とそれを前提にした文書・テストも入口の出力へ寄せる。

## 詳細

### 何が起きるか

インラインのシェルブロックでは、LLM が埋めない placeholder は空文字や未置換のまま case の既定分岐へ落ち、結果として「何もしない」挙動で素通りしていた。同じ処理を helper に移して入口で引数を検証すると（fail-loud 化自体は正しい）、その素通りしていた経路が停止に変わる。典型は通常ループ以外の終端 — 中断・ユーザー取消・後処理完了から run を閉じる経路 — で、手順書の値域定義が通常ループの値しか書いていなかった。

### 移設時の確認手順

1. 移すブロックが読む placeholder ごとに、**そのブロックへ到達する全経路**（通常・中断・取消・後処理完了・再開）を列挙する
2. 各経路で placeholder の値が一意に決まるかを確認し、決まらない経路があれば手順書の値域定義に追加する（「未定義なら既定分岐」に頼らない）
3. この列挙を fix で先に済ませると、再レビューは 1 cycle で収束した

### 入口検証を足した後の死文化

入口で検証すると、関数内に残した旧 guard は到達不能になる。さらにその guard の ERROR 文言を条件にした手順書のエラー方針と、guard 断片を抽出して直接叩くテストも、実入口では再現しない経路を検証することになる。検証は入口 1 箇所に寄せ、エラー方針は「helper が exit 2 で止まったら placeholder を直して同じステップから再実行」のように全サブコマンド共通の 1 行にし、テストも実エントリポイントの exit code を見る形へ置き換える。

### テスト入力は検証したい分岐だけが拒否するものを選ぶ

同じ入力が複数の検証に掛かると、assert は目的の分岐を消しても通る。例えば未置換 placeholder の拒否を数値オプションで試すと、数値検査でも exit 2 になるため placeholder 検査を削除しても緑のままになる。placeholder 検査だけが守る自由文字列オプションに `'{...}'` を渡して exit 2 を確かめる。

## 関連ページ

- [LLM substitute placeholder は bash residue gate で fail-fast 化する](../patterns/placeholder-residue-gate-bash-fail-fast.md)
- [明示的 Phase 遷移で駆動する SKILL.md に新規 Phase を挿入する際、既存の終端ルーティング更新漏れで到達不能になる](./unrouted-phase-insertion-in-explicit-transition-skill.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)

## ソース

- [レビュー結果](../../raw/reviews/20260924T152559Z-pr-3055.md)
- [fix 結果](../../raw/fixes/20260924T153248Z-pr-3055.md)
- [レビュー結果](../../raw/reviews/20260924T154135Z-pr-3055.md)
