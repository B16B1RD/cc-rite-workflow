---
type: "heuristics"
title: "失敗時の復旧ヒントは呼び出し元の切り詰めと cwd の違いを越えて届く形で書く"
domain: "heuristics"
description: "helper が失敗時に出す復旧ヒントは、呼び出し元が stderr を先頭数行へ切り詰めると人に届かず、helper が cd した先と利用者の cwd が違うと相対パスのヒントが空振りする。ヒントは先頭数行に収め、パスは絶対パスで示す。"
promote: rite-plugin
created: "2026-09-27T03:08:04Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T08:50:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T030348Z-pr-3196.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T031119Z-pr-3196.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T073259Z-pr-3221.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T074833Z-pr-3221.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T074557Z-pr-3241.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T075442Z-pr-3241.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T082009Z-pr-3221.md"
tags: ["stderr", "hint", "cwd", "worktree"]
confidence: medium
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:16:22Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T07:40:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T08:00:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T08:50:00Z" }
---

# 失敗時の復旧ヒントは呼び出し元の切り詰めと cwd の違いを越えて届く形で書く

## 概要

helper が失敗時に出す復旧ヒントは、呼び出し元が stderr を先頭数行へ切り詰めると人に届かず、helper が cd した先と利用者の cwd が違うと相対パスのヒントが空振りする。ヒントは先頭数行に収め、パスは絶対パスで示す。

## 詳細

### 起きたこと

- 呼び出し元が helper の stderr を `head -5` で切り詰めて表示するため、診断行の後ろに置いた復旧ヒントが表示範囲から落ちていた
- helper が内部で main checkout へ cd して動く一方、利用者はセッション worktree を cwd にしている。helper の cwd を前提にした相対パスのヒントは、利用者の場所では別の場所を指す
- 診断を stderr に出さない stub でテストすると、診断行とヒントの出力順が固定されず、順序の後退を検出できない

### 対処

- 人が行動するための 1 行（何をすれば復旧するか）を、呼び出し元の切り詰め幅の内側、診断の詳細より前に置く
- ヒントに含めるパスは、helper の cwd ではなく実体の絶対パスで示す
- 順序を守りたいなら、テストの stub にも実際と同じ形の診断を stderr へ出させ、ヒントの位置を固定する

### 修正で確かめたこと

- 復旧コマンドは、helper が cd した先（main checkout）を `git -C` で明示する形にした。利用者の cwd がセッション worktree でも、別の index を対象に空振りしない
- 失敗経路のテストの stub に stderr を 1 行出させ、診断行とヒントの順序まで assert した。無言の stub では診断の出力経路そのものが検証されない
- コメントが述べる保証範囲は、実装が実際に操作する集合に合わせて限定して書いた。広く書くと、操作していない要素まで守っているように読める

### 戻り方の案内を書くとき

- 診断が不正箇所を先頭数行しか出さないなら、戻り方を「診断に出た行を直す」と書かない。表示範囲を超える不正が残ると、直して再実行しても同じ失敗に戻り空回りする。直す対象は入力全体として書く
- 案内を出す条件を理由名の接頭辞で絞ると、同じ段で別の理由を出す失敗が案内から漏れる。条件は理由名ではなく、失敗した手順の段で表す
- 途中で読むのをやめる `head` を入力を読み切る別コマンドへ替えると、`head` / `tail` の形だけを拾う既存の静的検査の対象から外れる。読み方を変えるときは、その形を前提にした検査の母集団も確かめる
- 再実行を禁じる案内には解除条件（どの工程まで終えたら再実行してよいか）を付ける。条件が無いと、利用者はどこから戻ればよいか判断できない

- 戻り先を「中断した表の次の行から続ける」と書くとき、その行が会話の中にしか残らない値（直前の手順が出力した判定値など）を要求するなら、同じ会話で続ける前提を明記する。明記しないと、別セッションで手順書だけを読む人には値の出どころがなく、再開の出口がない

### 案内の中身を実装から導く

- エラーメッセージの復旧案内は、そのメッセージを出す分岐に到達する条件をコードで追ってから書く。上流で別の分岐（WARNING と既定値で続行）に吸収される原因を案内に書くと、案内どおりに調べても原因に届かない
- 下請けスクリプトを `bash <path>` で呼ぶ helper の失敗は、実行不能（欠落 rc=127 / 読めない rc=126）であることが多い。案内は直前の bash のエラー行が示すファイルと、プラグインの再取得へ向ける
- 案内の適用条件を「exit 1 すべて」のように広く書くと、固有の案内を持つ他の経路まで同じ一般則で読める。条件は列挙したメッセージに限定し、それ以外の経路にも「既定値で続行せず停止する」ことを明示する

## 関連ページ

- [stderr ノイズ削減: truncate ではなく selective surface で解く](./stderr-selective-surface-over-truncate.md)
- [セッション worktree + sandbox 環境の 3 つの罠: cwd 相対 write-allowlist・`.rite-plugin-root` のブランチ相違・`--show-toplevel` の誤解決](./worktree-cwd-write-allowlist-and-plugin-root-staleness.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T030348Z-pr-3196.md)
- [fix 結果](../../raw/fixes/20260927T031119Z-pr-3196.md)
- [レビュー結果](../../raw/reviews/20260927T073259Z-pr-3221.md)
- [fix 結果](../../raw/fixes/20260927T074833Z-pr-3221.md)
- [fix 結果](../../raw/fixes/20260927T074557Z-pr-3241.md)
- [レビュー結果](../../raw/reviews/20260927T075442Z-pr-3241.md)
- [レビュー結果](../../raw/reviews/20260927T082009Z-pr-3221.md)
