---
type: "anti-patterns"
title: "`cmd > file || true` は no-match (rc=1) と書き込み失敗 (rc>=2) を混同する"
domain: "anti-patterns"
description: "`grep pattern > file || true` のような best-effort リダイレクトは、grep の「no-match」(rc=1) と「書き込み失敗」(rc>=2、disk full / permission denied 等) をどちらも `|| true` で握り潰し区別しない。"
created: "2026-07-22T13:15:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260722T022920Z-pr-1967.md"
  - type: "fixes"
    resource: "raw/fixes/20260722T023104Z-pr-1967.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-22T13:15:00+09:00" }
---

# `cmd > file || true` は no-match (rc=1) と書き込み失敗 (rc>=2) を混同する

## 概要

`grep pattern > file || true` のような best-effort リダイレクトは、grep の「no-match」(rc=1) と「書き込み失敗」(rc>=2、disk full / permission denied 等) をどちらも `|| true` で握り潰し区別しない。生成された（あるいは生成に失敗した）`file` の中身を後続処理が `[ -s file ]`（空でないか）で分岐に使う場合、書き込み失敗時は file が空のままになるため no-match と誤認され、file の中身に応じた破壊的分岐（例: 空なら不要と判断して `rm` する）を誤って選択しうる。

## 詳細

reap manifest から、既に消費済み・削除対象になった branch/worktree のエントリを除いた「生存者」を再構築する処理で、以下のパターンが使われていた:

```bash
grep -v -F "$deleted_entry" "$manifest_file" > "$tmp_file" || true
if [ -s "$tmp_file" ]; then
  mv "$tmp_file" "$manifest_file"
else
  rm -f "$manifest_file"  # 空 = 全エントリ消費済みと判断して manifest 自体を削除
fi
```

この設計の意図は「フィルタ後に生存エントリが 0 件なら manifest ファイル自体を消してよい」という正当なものだが、`grep ... || true` は以下 2 つの異なる状況を同じ「`$tmp_file` が空 (またはリダイレクト自体が起きていない)」という見た目に潰してしまう:

1. **意図した no-match** (rc=1): フィルタ後に本当に生存エントリが 0 件 → `rm` してよい
2. **書き込み失敗** (rc>=2): `$tmp_file` への書き込みが disk full / permission denied 等で失敗 → `$tmp_file` は空または存在しないが、`$manifest_file` 側の生存エントリは実際には失われていない（フィルタ自体は評価されたが出力できなかっただけ）→ `rm` すると本来消えるべきでない manifest エントリ（他 branch の未消費レコード等）を巻き添えで喪失する

`[ -s "$tmp_file" ]` という空判定だけでは、この 2 状況を区別できない。

### Canonical 対策

`||` で握り潰す前に rc を明示的に capture し、rc>=2（grep の「エラー」を表す慣習: 0=match, 1=no-match, 2 以上=エラー）のときは破壊的分岐（`rm`）を選ばず、無変更のフォールバック（元の manifest をそのまま残す）に倒す:

```bash
grep -v -F "$deleted_entry" "$manifest_file" > "$tmp_file" 2>/dev/null
grep_rc=$?
if [ "$grep_rc" -ge 2 ]; then
  echo "WARNING: manifest フィルタ書き込みに失敗しました (rc=$grep_rc)。manifest は変更せず残します。" >&2
elif [ -s "$tmp_file" ]; then
  mv "$tmp_file" "$manifest_file"
else
  rm -f "$manifest_file"
fi
```

正常経路（rc<=1）は一切触らず、失敗経路（rc>=2）だけを閉じることで、既存テストを壊さずに修正できる。

## 関連ページ

- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)
- [mkdir 成功のみの判定漏れと brace group 未使用によるリダイレクト診断メッセージ漏洩](./mkdir-success-only-check-and-redirect-diagnostic-leak.md)

## ソース

- [PR #1967 review results (cycle 2) — rc 混同の finding](../../raw/reviews/20260722T022920Z-pr-1967.md)
- [PR #1967 fix results (cycle 3) — rc>=2 分岐での修正](../../raw/fixes/20260722T023104Z-pr-1967.md)
