---
type: "patterns"
title: "git のパス出力を assert するテストは fixture の mktemp 値を `pwd -P` で実体パスへ正規化する"
domain: "patterns"
description: "macOS の `$TMPDIR` は `/var/folders/...` という symlink で、git は `rev-parse --show-toplevel` でも `worktree list` でも実体側 `/private/var/folders/...` を返す。mktemp の値をそのまま期待値に使うと Linux では緑・macOS CI だけ赤になる。"
created: "2026-09-01T20:29:00+09:00"
generated: { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-09T15:44:58Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260908T090455Z-pr-2628.md"
  - type: "fixes"
    resource: "raw/fixes/20260908T090558Z-pr-2628.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T110702Z-pr-2498.md"
  - type: "reviews"
    resource: "raw/reviews/20260909T152156Z-pr-2635.md"
  - type: "fixes"
    resource: "raw/fixes/20260909T152539Z-pr-2635.md"
  - type: "reviews"
    resource: "raw/reviews/20260909T153857Z-pr-2635.md"
tags: []
confidence: high
verified:
  - { by: "rite-wiki-ingest/gpt-6", at: "2026-09-08T09:16:17Z" }
  - { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-09T15:44:58Z" }
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

**この欠陥が生き延びる理由**: レビュアーは全員ローカル（Linux）でテストを走らせる。観測された事例では 2 cycle × 6 reviewer の全員がスイート緑を報告し、merge 直前の CI gate（`tests (macos-latest)`）が初めて捕まえた。「N 名がテストを実行して緑」は、その N 名が同じ OS なら 1 名分の情報しかない。

### TMPDIR の末尾 slash も先に吸収する

symlink だけでなく、`TMPDIR=/tmp/` のような末尾 slash も fixture と実パスの比較を壊す。生成された root に二重 slash が残り、cwd 側だけが単一 slash へ正規化されると、root の equality と file path の prefix 照合が一致しない。結果として検査対象が外れ、診断や意図したエラー経路まで実行されなくなる。

fixture root を作成した直後、派生するリポジトリ・helper・payload の各パスを作る前に `pwd -P` を適用する。観測した事例では plugin root の比較と after-edit の診断・失敗伝播の3アサーションが失敗し、この順序での正規化により回復した。Linux でも末尾 slash のある TMPDIR で同条件を再現できた。

別の assertion が一度失敗して再実行で成功した場合、元の3失敗が解消した証拠と、全試行成功という主張を分けて記録する。失敗時の commit ID などが残っていなければ、関連する型変換バグとの因果を断定しない。

### git を介さない Python の `Path.resolve()` でも片辺だけ正規化すると同じ罠になる

git のパス出力に限らない。fixture 内の symlink を検証する Python heredoc で `(p / '.grok/plugins/rite').resolve() == p / 'plugins/rite'` のように左辺だけ `resolve()` すると、`p` 自身が `mktemp -d` の symlink 配下にあるとき左辺は実体パス、右辺は symlink パスになり、fixture が正しくても AssertionError になる。観測した事例では 6 名の reviewer が同一箇所を独立に指摘し、Linux で `TMPDIR` を symlink 化して再現できた（36 passed / 1 failed）。

**最小差分の修正は実体解決を両辺に足すことではなく、契約が相対 link なら link 文字列そのものを検査すること**。`os.readlink(p / '.grok/plugins/rite') == '../../plugins/rite'` は生成側（`symlink_to('../../plugins/rite')`）と同じリテラルを比較するため、temp ディレクトリの symlink 有無に依存しない。対象が symlink でなければ `OSError` で fail-loud に止まる。両辺 `resolve()` や `os.path.samefile` でも通るが、契約（相対 link）を直接 pin できる分 `readlink` が強い。同じ heredoc の bare `assert` にはメッセージを添え、CI ログだけで失敗箇所が読めるようにする。

## 関連ページ

- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](../anti-patterns/locale-dependent-error-message-grep-assertion.md)
- [追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない](./mutation-prove-new-pin.md)

## ソース

- [レビュー結果](../../raw/reviews/20260901T110702Z-pr-2498.md)

- [追加観測](../../raw/reviews/20260908T090455Z-pr-2628.md)
- [追加観測](../../raw/fixes/20260908T090558Z-pr-2628.md)
- [レビュー結果](../../raw/reviews/20260909T152156Z-pr-2635.md)
- [fix 結果](../../raw/fixes/20260909T152539Z-pr-2635.md)
- [差分レビュー結果](../../raw/reviews/20260909T153857Z-pr-2635.md)
