---
type: "heuristics"
title: "リポジトリ owner rename の一括置換はリポジトリ外成果物に届かない"
domain: "heuristics"
description: "owner/URL の一括置換 PR は git grep で見えるツリー内しか更新できない。アップロード済み動画などリポジトリ外に出た成果物はソース置換後も旧表記を表示し続けるため、成果物の隣に暫定注記 + 正しい導線を置き、本体差し替えは follow-up に分離して収束させる。PR #2029 で実測。"
created: "2026-07-26T20:51:40+09:00"
updated: "2026-07-26T20:51:40+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260726T110848Z-pr-2029.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T111323Z-pr-2029.md"
tags: []
confidence: medium
---

# リポジトリ owner rename の一括置換はリポジトリ外成果物に届かない

## 概要

owner 名・URL の一括置換 PR は、git grep で走査できるツリー内の参照しか更新できない。GitHub user-attachment としてアップロード済みの動画のような「リポジトリ外に出た成果物」は、その生成元ソース（composition）を置換しても公開物側が旧表記を表示し続け、同一ページ内で新旧 2 つの owner を提示する状態を作る。再生成コストが高い成果物は、成果物の隣に「旧表記である旨 + 正しい導線への誘導」の暫定注記を置いて実害を解消し、本体差し替えは follow-up に分離するのが低コストな収束経路になる。

## 詳細

PR #2029（asakaguchi → B16B1RD のアカウント移管）で実測したパターン。

- **盲点の構造**: README 冒頭の Demo 動画はレンダリング済み MP4 を GitHub user-attachment として別途アップロードした成果物で、リポジトリからは再導出されない（PROVENANCE.md に明記されていた）。owner rename PR は動画の composition ソース（scene-7.html）を更新したが、公開動画は旧 owner のインストールコマンドを表示し続け、README のインストール手順（更新済み）と食い違う状態が生まれた。
- **`git grep <旧owner>` ベースの掃引の限界は 2 種類ある**: (1) リポジトリ外に出た成果物には届かない。(2)「旧 owner 名ではない誤った owner スロット」（例: 未置換の `USERNAME` プレースホルダ）を構造的に検出できない。
- **暫定注記 + follow-up 分離**: 動画の再レンダリング（headless Chromium + ffmpeg + 手動アップロード）は文字列置換 PR のスコープを超える。fix cycle 内で強行せず、Demo 節に「動画内のコマンドは旧 owner 表記。最新は Installation を参照」の 1 行注記（英日同時）を置いて実害（誤 owner でのインストール）を解消し、動画差し替え・注記削除・バージョンスタンプ更新を 1 件の follow-up に束ねた。
- **周辺の再確認事項**: GitHub の transfer redirect は旧 namespace に同名リポジトリ/fork が作成されると恒久削除される（公式 docs で fact-check VERIFIED）。project_number は owner ごとの連番のため transfer 先で必ず再確認する（移管先の同番号は別プロジェクトが占有していた — 番号据え置きだと無関係ボードへ書き込まれていた）。大文字・数字を含む owner 名への変更は、テストフィクスチャの charset カバレッジを副次的に強化する。

## 関連ページ

- [暫定注記は対象成果物内の同種表記を全数列挙してから書く](./interim-notice-enumerate-all-stale-references-first.md)

## ソース

- [PR #2029 review results (cycle 1)](../../raw/reviews/20260726T110848Z-pr-2029.md)
- [PR #2029 fix results (cycle 1)](../../raw/fixes/20260726T111323Z-pr-2029.md)
