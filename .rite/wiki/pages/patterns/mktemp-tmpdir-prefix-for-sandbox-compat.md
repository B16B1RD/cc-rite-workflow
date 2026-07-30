---
type: "patterns"
title: "mktemp テンプレートは `${TMPDIR:-/tmp}` を使う — `/tmp` 直下ハードコードは sandbox で書き込み拒否される"
domain: "patterns"
description: "sandbox 有効環境は書き込み許可を `$TMPDIR` 配下に限定するため、`mktemp /tmp/xxx-XXXXXX` のような `/tmp` 直下ハードコードテンプレートは書き込み拒否される。`mktemp \"${TMPDIR:-/tmp}/xxx-XXXXXX\"`（GNU/BSD 両対応）へ統一する。"
created: "2026-07-18T23:38:52Z"
updated: "2026-07-18T23:38:52Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260718T194343Z-pr-1902.md"
tags: ["bash", "mktemp", "tmpdir", "sandbox", "portability"]
confidence: high
---

# mktemp テンプレートは `${TMPDIR:-/tmp}` を使う — `/tmp` 直下ハードコードは sandbox で書き込み拒否される

## 概要

sandbox 有効環境では書き込み許可ディレクトリが `$TMPDIR`（例: `/tmp/claude-1000/...`）に限定される。`mktemp /tmp/rite-xxx-XXXXXX` のように `/tmp` 直下をハードコードしたテンプレートは `$TMPDIR` を無視するため書き込み拒否される。`mktemp "${TMPDIR:-/tmp}/rite-xxx-XXXXXX"`（GNU/BSD 両対応のポータブル形式）へ統一することで、sandbox 環境でも非 sandbox 環境でも同じコードで動く。

## 詳細

### Anti-pattern

```bash
# ❌ NG: /tmp 直下をハードコード。sandbox の書き込み許可リストが $TMPDIR 限定だと拒否される
tmpfile=$(mktemp /tmp/rite-foo-XXXXXX)
```

### Canonical pattern

```bash
# ✅ OK: ${TMPDIR:-/tmp} で環境変数を優先、未設定時のみ /tmp にフォールバック
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-foo-XXXXXX")
```

### 背景

rite リポジトリでは既存の canonical helper（`_mktemp-stderr-guard.sh`）がこの形式を既に使っていたが、それ以外の本番コード 21 ファイルが `/tmp` 直下ハードコードのままだった。修正はテンプレート文字列を canonical helper と揃えるだけの機械的な変更で、レビュアー 4 名（security / application / error-handling / test）全員が指摘事項 0 件・可判定。この機械性の高さは、ハードコードパターンが「動くが環境依存」という気付きにくい形で埋め込まれやすいことの裏返しでもある。

### スコープ境界の判断

同根の `/tmp` ハードコードパターンは、修正対象外としたテストハーネス自身（`hooks/tests/_test-helpers.sh` の `make_sandbox` 等、約 15 ファイル）にも残存していることが 3 名の reviewer から重複して指摘された。本番コードとテストコードは影響範囲・リスクが異なるため、同一 PR で拡張せず Issue #1903 として独立に切り出す判断をした（scope を広げすぎない一方、フォローアップの追跡は明示する）。

### 既存 Wiki ページの記載例について

本ページ以前に書かれた mktemp 関連ページ（[trap 登録 → mktemp の順序](./trap-register-before-mktemp.md) 等）のコード例は `mktemp /tmp/rite-xxx-XXXXXX` 形式のまま残っている。それらのページの主題（trap 順序 / silent failure 可視化）自体は本パターンと独立に妥当だが、コード例をそのまま転用する場合は本ページの `${TMPDIR:-/tmp}` プレフィックスを併用すること。

## 関連ページ

- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](./mktemp-failure-surface-warning.md)
- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](./trap-register-before-mktemp.md)
- [Canonical helper bypass: 既存集約 helper を bypass して inline 再実装する](../anti-patterns/canonical-helper-bypass.md)

## ソース

- [PR #1902 review results](../../raw/reviews/20260718T194343Z-pr-1902.md)
