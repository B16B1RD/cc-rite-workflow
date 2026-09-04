---
type: "heuristics"
title: "診断退避用の tempfile は診断が最も要る場面でだけ消える — command substitution へ畳む"
domain: "heuristics"
description: "stderr を退避して WARNING に載せるために tempfile を確保する定型（`err=$(mktemp ... 2>/dev/null) || err=\"\"` に続けて `cmd 2>\"${err:-/dev/null}\"`）は、mktemp が失敗したときに後続コマンドの診断を丸ごと `/dev/null` へ捨てる。"
created: "2026-08-06T00:40:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260805T101044Z-pr-2114.md"
tags: ["mktemp", "diagnostics", "fail-loud", "command-substitution", "mechanism-removal", "correlated-failure"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-06T00:40:00+09:00" }
---

# 診断退避用の tempfile は診断が最も要る場面でだけ消える — command substitution へ畳む

## 概要

stderr を退避して WARNING に載せるために tempfile を確保する定型（`err=$(mktemp ... 2>/dev/null) || err=""` に続けて `cmd 2>"${err:-/dev/null}"`）は、mktemp が失敗したときに後続コマンドの診断を丸ごと `/dev/null` へ捨てる。これは「たまに診断が落ちる」ではなく「診断が最も必要な状況でだけ落ちる」— mktemp が失敗する条件と、退避したかった `mkdir` / `mv` / `rm` が失敗する条件が同じ根本原因（ENOSPC・read-only ファイルシステム・inode 枯渇・permission）を共有しているからである。

## 詳細

### 相関する失敗条件

`${err:-/dev/null}` は一見すると穏当な degradation に見える。しかし失敗の分布を見ると degradation が起きるのは次の場合だけである:

| mktemp が失敗する条件 | 同じ条件で失敗する退避対象 |
|---|---|
| ENOSPC（ディスク満杯） | `mkdir` / `mv` / 書き込みを伴う全操作 |
| read-only TMPDIR | 同じファイルシステム上の `mkdir` / `mv` |
| inode 枯渇 | `mkdir`（ディレクトリエントリ作成） |
| permission 拒否 | 同一ツリーへの `rm` / `mv` |

つまり「診断が欲しい異常系」と「診断機構が壊れる条件」がほぼ一致する。正常系では tempfile 経路が完璧に動き、異常系でだけ無音になる。fail-loud を宣言している helper でこれが起きると、宣言と実挙動の乖離を実測で検出することがきわめて難しい。

### 有効な修正は機構の追加ではなく削除

mktemp 失敗時に WARNING を出す（[mktemp 失敗を WARNING として surface する](../patterns/mktemp-failure-surface-warning.md)）のは degradation を可視化する対処だが、退避が「診断のためだけ」なら、そもそも tempfile が要らない:

```bash
# ❌ 診断機構が診断対象と同じ条件で壊れる
err=$(mktemp "${TMPDIR:-/tmp}/x-XXXXXX" 2>/dev/null) || err=""
mkdir -p "$dst" 2>"${err:-/dev/null}" || {
  [ -n "$err" ] && [ -s "$err" ] && sed 's/^/  /' "$err" >&2
}
rm -f "$err"

# ✅ 失敗する余地が無い
err=$(mkdir -p "$dst" 2>&1) || {
  printf '%s\n' "$err" | sed 's/^/  /' >&2
}
```

command substitution へ畳むと、mktemp 失敗経路・`trap` の設置・orphan tempfile の後始末がまとめて消える。1 つの指摘（診断が消える）と別の指摘（tempfile が orphan になりうる）を、コードを増やさず同時に解消できる。

### 適用条件

command substitution は stdout も飲み込むため、無条件には置き換えられない。判定は「退避対象コマンドが成功時に stdout を持つか」で分かれる:

- **置き換えてよい**: `mkdir` / `mv` / `rm` / `git push --delete` など、成功時 stdout が空のコマンド。`2>&1` で捕捉しても失う情報がない
- **置き換えられない**: `git ls-remote` のように stdout が判定に必要なコマンド。この場合は tempfile が必要で、mktemp 失敗は「判定不能」として fail-loud に surface する（削除・破壊的操作を試行しない側へ倒す）

後者では tempfile を残す代わりに、mktemp 失敗を degradation ではなく **判定不能 = 未完了** として扱うこと。「診断が落ちる」を許容するのと「判定できないまま次の破壊的操作へ進む」を許容するのは別の話で、後者は必ず fail-fast にする。

### 一般化

診断機構を足す前に「この機構が壊れる条件は、機構が診断したい失敗の条件と独立か」を問う。独立でないなら、その機構は正常系専用の飾りになる。独立にできないときは、機構を足す方向ではなく機構が要らない書き方（command substitution・rc 直接検査）へ畳めないかを先に探す。

## 関連ページ

- [mktemp 失敗を WARNING として surface する](../patterns/mktemp-failure-surface-warning.md)
- [mkdir の成功のみを検査するガードと redirect による診断漏れ](../anti-patterns/mkdir-success-only-check-and-redirect-diagnostic-leak.md)
- [trap は mktemp より先に登録する](../patterns/trap-register-before-mktemp.md)

## ソース

- [fix 結果](../../raw/fixes/20260805T101044Z-pr-2114.md)
