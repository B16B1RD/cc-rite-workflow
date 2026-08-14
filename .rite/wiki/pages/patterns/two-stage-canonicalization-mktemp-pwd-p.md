---
type: "patterns"
title: "mktemp -d の canonical 化は 2 段階に分ける — `cd \"$(mktemp -d)\"` は失敗時にリポジトリ本体を掴む"
domain: "patterns"
promote: rite-plugin
description: "macOS の `$TMPDIR` は `/var/folders/...`（`/private` への symlink）なので、テストが temp ディレクトリの path を比較すると symlink 解決の差で落ちる。"
created: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260724T175144Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T180733Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T193804Z-pr-2013.md"
  - type: "fixes"
    resource: "raw/fixes/20260725T004542Z-pr-2013.md"
tags: ["portability", "macos", "mktemp", "canonicalization", "fail-open", "destructive"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-25T07:05:21Z" }
---

# mktemp -d の canonical 化は 2 段階に分ける — `cd "$(mktemp -d)"` は失敗時にリポジトリ本体を掴む

## 概要

macOS の `$TMPDIR` は `/var/folders/...`（`/private` への symlink）なので、テストが temp ディレクトリの path を比較すると symlink 解決の差で落ちる。対策として `pwd -P` による正準化を入れるのは正しいが、**ネストして 1 行で書くと fail-fast が反転する**。bash の `cd ""` は rc=0 で cwd を変えないため、`mktemp` が失敗すると変数には「実行時の cwd」= リポジトリ checkout が入る。直後の `trap ... rm -rf "$TEST_DIR"` や `git init` / `git commit` が **repo 本体に着弾する**。

## 詳細

### 失敗する形

```bash
# ❌ mktemp 失敗時に cwd（= リポジトリ）を掴む
TEST_DIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT     # ← リポジトリを消しにいく

# ❌ 同型。`|| true` が失敗を握り潰す
d=$(cd "$d" && pwd -P) || true
```

内側の `$(mktemp -d)` が失敗すると空文字列になり、`cd ""` は **rc=0 で何もしない**。続く `pwd -P` は現在の cwd を返すため、`TEST_DIR` にリポジトリの絶対 path が入る。

### 検出できない理由

この事故は `git status --porcelain` の post-condition invariant（porcelain hash / branch / stash の比較）では検出できない。テストが repo 内に `git init` してコミットしても、**サブディレクトリの独立 git リポジトリは親の porcelain 出力に現れない**（あるいは gitignore 済みの path に着地する）ため、reviewer の標準的な副作用チェックを素通りする。

### canonical な形

```bash
# ✅ 2 段階に分け、各段で exit code を検査する
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-XXXXXX") || exit 1
TEST_DIR=$(cd "$TEST_DIR" && pwd -P) || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
```

ポイント:

- `mktemp` の失敗と `cd` の失敗を **別々に** 検査する。ネストすると内側の rc が外側に伝わらない
- `|| true` を付けない。ここは「失敗したら止まるべき」場所
- テンプレートは `${TMPDIR:-/tmp}` prefix を使う（sandbox 互換。[mktemp-tmpdir-prefix-for-sandbox-compat](./mktemp-tmpdir-prefix-for-sandbox-compat.md) 参照）

### ひな形（SoT）も同時に直す

起点事例では本体テストを 2 段階に直した一方、CONTRIBUTING.md の「新規テストひな形」は 1 段目のみのまま残り、**コメントだけが 2 段構成を説明する**矛盾状態になった。ひな形は複製起点なので、直したばかりのバグを次の contributor が再導入する経路が開いたままになる。3 レビュアーが独立に同一箇所へ収束した。

> **規則**: 移植性・規約バグを直す PR では「そのパターンを再生産する SoT（ひな形・スニペット・生成器）」を必ず同時に grep して更新する。詳細は [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md)。

### fixture 自身が同じ差異を踏んでいないか確認する

canonicalization を pin する TC を「`$TMPDIR` を symlink に向ける」方式で書いたが、その誘導は **bare `mktemp -d` が `$TMPDIR` を尊重すること** を前提にしており、BSD/macOS では成立しない — 検証したい差異と同じ差異を fixture 自身が踏んでいた。

> **規則**: プラットフォーム差異の修正をテストするときは、fixture がその差異に依存していないかを先に確認する。単一のアサーションで両プラットフォームを load-bearing にできないなら、観測点を 2 系統に分ける（一方は「戻り値が自身の canonical 形と一致する」、他方は「symlink 化した `$TMPDIR` 経由」）。

なお GNU `mktemp` は bare 呼び出しでも `$TMPDIR` を尊重するため、**テンプレート化の revert は leak count では検出できない**（mutation で検出ゼロを確認済み）。basename アサートのようなプラットフォーム非依存の観測点を足す。

## 関連ページ

- [mktemp テンプレートは `${TMPDIR:-/tmp}` を使う — `/tmp` 直下ハードコードは sandbox で書き込み拒否される](./mktemp-tmpdir-prefix-for-sandbox-compat.md)
- [_SCRIPT_DIR canonicalize: cd 前に BASH_SOURCE を絶対 path 化する](./script-dir-canonicalize-before-cd.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #2013 review cycle 1 — canonical 化イディオムが fail-fast を反転させる](../../raw/reviews/20260724T175144Z-pr-2013.md)
- [PR #2013 fix results — 環境差異の吸収は fail-open の温床](../../raw/fixes/20260724T180733Z-pr-2013.md)
- [PR #2013 fix results (cycle 3) — fixture が検証したい差異自身を踏む問題](../../raw/fixes/20260724T193804Z-pr-2013.md)
- [PR #2013 fix results — ひな形（CONTRIBUTING）の同時更新漏れ](../../raw/fixes/20260725T004542Z-pr-2013.md)
