---
type: "anti-patterns"
title: "存在確認と破壊的操作で ref 解決規則が異なると、検証した ref 集合と破壊する ref 集合がずれる"
domain: "anti-patterns"
description: "git では `ls-remote <pattern>` が slash 境界の tail 一致、`push --delete <dst>` が全 namespace 解決で、どちらも完全一致ではない。存在確認を refs/heads/ 修飾で行いながら削除を非修飾で行うと、検証した集合と削除する集合が一致しない窓が生まれる。破壊的操作は検証と同じ ref 修飾で行い、検証側は rc だけでなく出力の ref 名まで完全一致で確かめる。"
created: "2026-07-26T10:05:51Z"
updated: "2026-07-26T10:05:51Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260726T080036Z-pr-2022.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T082019Z-pr-2022.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T040115Z-pr-2022.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T092442Z-pr-2022.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T085050Z-pr-2022.md"
tags: []
confidence: high
---

# 存在確認と破壊的操作で ref 解決規則が異なると、検証した ref 集合と破壊する ref 集合がずれる

## 概要

「存在するなら削除する」型のガードは、存在確認と削除で ref 解決規則が違うと成立しない。git の場合、`git ls-remote <pattern>` は ref の先頭または任意の slash 境界からの **tail 一致**であり、`git push origin --delete <shortname>` は remote の**全 namespace** に対して dst を解決する。どちらも完全一致ではないうえ規則が異なるため、両者が一致しない窓が構造的に生まれる。

## 詳細

### 実測された挙動（git 2.43.0）

- `git ls-remote origin refs/heads/target` は `refs/heads/wip/refs/heads/target` に一致して rc=0 を返す。`refs/heads/` を前置しても anchor されない。
- `git push origin --delete target` は同名のタグ（`refs/tags/target`）を削除しうる。
- `--exit-code` は真に不在の ref に対して rc=2 を返すため、3 分岐ガードの土台としては機能する。

### 修正の型

1. **破壊的操作は検証と同じ ref 修飾で行う。** 検証を `refs/heads/{branch}` で行うなら削除も `refs/heads/{branch}` を渡す。非修飾の削除が返す rc=0 は「削除試行 → 失敗」に落ちて偽の残作業を生む。
2. **検証側は rc だけでなく出力の ref 名まで完全一致で確かめる。** tail 一致がある以上、rc=0 は「その ref が存在する」ことを意味しない。
3. **rc は 3 分岐にする。** `if ! cmd` の短絡形は「失敗」と「判定不能」を融合する。存在確認系コマンド（`git show-ref` は不在=1 / リポジトリ外=128、`git ls-remote --exit-code` は不在=2 / 通信失敗=128、awk は不一致=1 / 異常終了>=2）では rc を明示捕捉しないと、判定不能が「不在＝正常系」に丸まる。
4. **refname の合法性を先に確定させる。** `git show-ref` / `git ls-remote` は refname として非合法な値（末尾空白・`:` 混入・`origin/` 前置）にも「不在」を返す。`git check-ref-format` を通さないと、削除していないのに完了と報告する。
5. **1 つの変数に数値と文字列を兼ねさせない。** `_ls_rc="awk-2"` のような設計は、後から数値比較を足した瞬間に壊れ、診断メッセージも実際に失敗したコマンドを誤って名指しする。原因は別変数に分ける。

### 散文コメントは契約にならない

前 cycle はコメントで「この形なら完全一致になる」と主張しながら実装は tail 一致のままで、テストも通っていた。技術主張はサンドボックスで実際に ref を仕込み、rc と副作用を観測して裏を取る。テスト自身の検証コマンドも同じ落とし穴を踏む — fixture に入れ子衝突 ref を仕込むと、テスト側の `ls-remote --exit-code` による存在確認まで tail 一致で誤判定する。

### 発見までに 3 cycle・4 reviewer を要した

この欠陥は cycle 1/2 で「調査推奨」として挙がり、cycle 3 で security reviewer が runtime 実測を添えて finding に昇格させた。**複数 cycle で同じ調査推奨が繰り返されたら finding へ昇格させるシグナル**として扱う。

### 片側だけ直さない

リモート側だけに「既に不在 = 正常系」を実装すると、ローカル側で同じ症状（必ず失敗する処方の提示）が再生産される。対称性は fallback の判定行だけでなく emitter の経路まで揃える。なお「必ず失敗する処方をユーザーに出さない」は fail-fast の WARNING にも適用される — 空ブランチ名に対して `git branch -D ""` を案内するのは、まさにその Issue が塞いだ欠陥の再導入である。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)
- [`cmd > file || true` は no-match (rc=1) と書き込み失敗 (rc>=2) を混同する](../anti-patterns/cmd-redirect-or-true-conflates-nomatch-and-write-failure.md)
- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](../heuristics/prose-cited-implementation-behavioral-verification.md)

## ソース

- [PR #2022 review results](../../raw/reviews/20260726T080036Z-pr-2022.md)
- [PR #2022 fix results](../../raw/fixes/20260726T082019Z-pr-2022.md)
- [PR #2022 fix results (cycle 8)](../../raw/fixes/20260726T040115Z-pr-2022.md)
