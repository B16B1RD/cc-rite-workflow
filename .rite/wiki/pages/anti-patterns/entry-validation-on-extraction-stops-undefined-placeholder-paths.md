---
type: "anti-patterns"
title: "手順を helper へ移して入口検証を足すと、未定義 placeholder で流れていた終端経路が停止に変わる"
domain: "anti-patterns"
description: "手順書のシェルブロックを helper のサブコマンドへ移し、入口に必須・数値・未置換検査を足すと、旧ブロックでは空値のまま既定分岐へ落ちていた経路が exit 2 で止まる。移設時は placeholder を読む全経路で値が決まるかを列挙し、関数内に残る旧 guard とそれを前提にした文書・テストも入口の出力へ寄せる。"
created: "2026-09-25T00:50:10+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T03:24:18Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260924T152559Z-pr-3055.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T153248Z-pr-3055.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T154135Z-pr-3055.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T213306Z-pr-3349.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T214525Z-pr-3349.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T010548Z-pr-3349.md"
tags: []
confidence: high
promote: rite-plugin
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T21:52:19Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T03:24:18Z" }
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

### 移設先で新たに掛かる静的検査と、テストが通る経路

手順書の中の fenced block は、CI の shellcheck（scripts/ 配下の `*.sh` を blocking で走査する）の対象外になっていることがある。本文を helper へ移した瞬間に、それまで検査されなかった既存行（二重引用符内の案内用バッククォートなど）が CI の blocking gate を落とす。移設したら、移設先に掛かる静的検査を移設直後にその場で実行する。

「1 ブロック = 1 シェル」だった呼び出しを「dispatch + 関数」に移し、引数検査を dispatch に集めると、元はブロック内で `[fix:error]` などの sentinel を出していた検査より先に usage error（exit 2）で止まるようになる。手順書側に exit 2 の分岐が無いと、手順に従う実行者はどの分岐にも一致しない状態で止まる。先例の「exit 2 は引数を直して同じステップを再実行」という共通規則を、移設と同時に持ち込む。既存の reason 説明が到達不能になっていないかも同時に確かめる。

テストの参照先を「helper の関数本体を抜き出して直接実行」に置き換えると、手順書の 1 行呼び出しから dispatch arm を経る経路が検査されなくなる。dispatch arm を壊す変異が全スイートを通過した。fixture の plugin に helper の複製と resolver の stub を置き、手順書の呼び出し行そのものを実行する形にすれば、同じ観測を保ったまま arm の変異で失敗させられる。

### 移設で加わる厳格化は、追加ではなく除去で直す

ステップ本体を helper へ移すと、引数検査や呼び出しの flag が移設元より厳しくなりやすい。移設元が空値を許して best-effort で続けていた経路や、再実行すれば表示が得られた経路が、helper の固定動作で塞がれる。直し方は検査や分岐を足して帳尻を合わせることではなく、移設で加わった厳格化を外して移設元の挙動へ戻すことである。

- 空値が正常経路で来る引数は、dispatch 側で「引数が渡されたこと」だけを要求し、値が空でないことは要求しない。手順書側は placeholder を引用符で囲み、空でも 1 引数として届ける
- 回帰テストは fixture の plugin root に stub の hook を置いて実行経路を通し、実環境の作業メモリやレビュー結果に触れない。呼び出し元が stub を直接実行するなら stub に実行権を付ける。付け忘れると別のフォールバック経路で通ってしまい、テストが目的の経路を検査しない

## 関連ページ

- [LLM substitute placeholder は bash residue gate で fail-fast 化する](../patterns/placeholder-residue-gate-bash-fail-fast.md)
- [明示的 Phase 遷移で駆動する SKILL.md に新規 Phase を挿入する際、既存の終端ルーティング更新漏れで到達不能になる](./unrouted-phase-insertion-in-explicit-transition-skill.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)

## ソース

- [レビュー結果](../../raw/reviews/20260924T152559Z-pr-3055.md)
- [fix 結果](../../raw/fixes/20260924T153248Z-pr-3055.md)
- [レビュー結果](../../raw/reviews/20260924T154135Z-pr-3055.md)
- [移設で CI の静的検査・停止経路・テスト経路が変わったレビュー結果](../../raw/reviews/20260927T213306Z-pr-3349.md)
- [移設先の静的検査と SKILL 呼び出し行の実行テストを足した fix 結果](../../raw/fixes/20260927T214525Z-pr-3349.md)
- [移設で加わった厳格化を外して元の挙動へ戻した fix 結果](../../raw/fixes/20260929T010548Z-pr-3349.md)
