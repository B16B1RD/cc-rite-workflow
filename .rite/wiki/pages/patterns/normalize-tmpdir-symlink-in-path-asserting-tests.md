---
type: "patterns"
title: "git のパス出力を assert するテストは fixture の mktemp 値を `pwd -P` で実体パスへ正規化する"
domain: "patterns"
description: "macOS の `$TMPDIR` は `/var/folders/...` という symlink で、git は `rev-parse --show-toplevel` でも `worktree list` でも実体側 `/private/var/folders/...` を返す。mktemp の値をそのまま期待値に使うと Linux では緑・macOS CI だけ赤になる。"
created: "2026-09-01T20:29:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-01T20:29:00+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T110702Z-pr-2498.md"
tags: []
confidence: high
---

# git のパス出力を assert するテストは fixture の mktemp 値を `pwd -P` で実体パスへ正規化する

## 概要

macOS の `$TMPDIR` は `/var/folders/...` という symlink で、git は `rev-parse --show-toplevel` でも `worktree list` でも実体側 `/private/var/folders/...` を返す。mktemp の値をそのまま期待値に使うと Linux では緑・macOS CI だけ赤になる。

## 詳細

**対処**: fixture root を作った直後に物理パスへ正規化する。

```bash
TMP_ROOT=$(mktemp -d)
# 物理パスへ正規化する。macOS の $TMPDIR は /var/folders/... の symlink で、git は
# rev-parse --show-toplevel / worktree list のいずれでも実体側 (/private/var/folders/...) を
# 返すため、mktemp の値をそのまま assert すると helper の出力と一致しない。
TMP_ROOT=$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
```

**適用条件**: fixture の一時ディレクトリ配下に git リポジトリを作り、helper の出力（git が返したパス）と fixture 側の変数を文字列比較するテスト。パスを比較しないテストには不要。

**Linux 上で同条件を再現する**: `$TMPDIR` を symlink 経由にすれば、macOS を持たなくても同じ失敗を作れる。修正前は FAIL、修正後は PASS になることまで確認すると、正規化が load-bearing であることを実証できる。

```bash
mkdir -p /path/real && ln -s /path/real /path/link
TMPDIR=/path/link bash hooks/tests/<suite>.test.sh
```

**この欠陥が生き延びる理由**: レビュアーは全員ローカル（Linux）でテストを走らせる。PR #2498 では 2 cycle × 6 reviewer の全員がスイート緑を報告し、merge 直前の CI gate（`tests (macos-latest)`）が初めて捕まえた。「N 名がテストを実行して緑」は、その N 名が同じ OS なら 1 名分の情報しかない。

## 関連ページ

- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](../anti-patterns/locale-dependent-error-message-grep-assertion.md)
- [追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない](./mutation-prove-new-pin.md)

## ソース

- [PR #2498 review results (cycle 5)](../../raw/reviews/20260901T110702Z-pr-2498.md)
