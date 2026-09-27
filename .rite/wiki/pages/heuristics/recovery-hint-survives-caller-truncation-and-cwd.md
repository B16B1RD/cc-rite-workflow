---
type: "heuristics"
title: "失敗時の復旧ヒントは呼び出し元の切り詰めと cwd の違いを越えて届く形で書く"
domain: "heuristics"
description: "helper が失敗時に出す復旧ヒントは、呼び出し元が stderr を先頭数行へ切り詰めると人に届かず、helper が cd した先と利用者の cwd が違うと相対パスのヒントが空振りする。ヒントは先頭数行に収め、パスは絶対パスで示す。"
promote: rite-plugin
created: "2026-09-27T03:08:04Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:16:22Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T030348Z-pr-3196.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T031119Z-pr-3196.md"
tags: ["stderr", "hint", "cwd", "worktree"]
confidence: medium
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:16:22Z" }
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

## 関連ページ

- [stderr ノイズ削減: truncate ではなく selective surface で解く](./stderr-selective-surface-over-truncate.md)
- [セッション worktree + sandbox 環境の 3 つの罠: cwd 相対 write-allowlist・`.rite-plugin-root` のブランチ相違・`--show-toplevel` の誤解決](./worktree-cwd-write-allowlist-and-plugin-root-staleness.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T030348Z-pr-3196.md)
- [fix 結果](../../raw/fixes/20260927T031119Z-pr-3196.md)
