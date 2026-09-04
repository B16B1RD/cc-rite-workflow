---
type: "patterns"
title: "git check-ignore の実効判定は -q と -v で rc 意味論が異なる (negation マッチ検査の要否)"
domain: "patterns"
promote: rite-plugin
description: "`git check-ignore` の exit code は flag によって意味論が異なる: `-q` (quiet / non-verbose) は negation ルール (`!pattern`) 決着時に rc=1 (= not ignored) を返すが、`-v` (verbose) は negation マッチも「マッチあり」として数え rc=0 を返す。"
created: "2026-07-13T00:29:27+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260712T145139Z-pr-1836.md"
  - type: "reviews"
    resource: "raw/reviews/20260712T151954Z-pr-1836.md"
tags: ["git", "check-ignore", "gitignore", "negation", "effective-judgment", "rc-semantics"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-13T00:29:27+09:00" }
---

# git check-ignore の実効判定は -q と -v で rc 意味論が異なる (negation マッチ検査の要否)

## 概要

`git check-ignore` の exit code は flag によって意味論が異なる: `-q` (quiet / non-verbose) は negation ルール (`!pattern`) 決着時に rc=1 (= not ignored) を返すが、`-v` (verbose) は negation マッチも「マッチあり」として数え rc=0 を返す。「ignore されているか」を rc で判定する実効判定へ移行する際、`-v` を使う経路では「rc==0 かつ matched pattern が negation でない」の複合条件が必須になる。

## 詳細

### rc 意味論の非対称 (git 2.43 で実測)

`.rite/sessions/*` + `!.rite/sessions/**` のような negation-leak 構成 (probe が実際には ignore されず leak する) に対し:

| 呼び出し | rc | 意味 |
|----------|----|------|
| `git check-ignore -q <probe>` | **1** | not ignored (真の実効判定) |
| `git check-ignore -v <probe>` | **0** | 「マッチした」(negation マッチ含む) — ignore されているとは限らない |

verbose モードは非 verbose が skip する negation パターンも出力対象に含めるため、rc=0 が「ignored」を意味しなくなる。`-v` の出力形式 `<source>:<linenum>:<pattern>\t<pathname>` の pattern 先頭が `!` かどうかで実効判定を補完する:

```bash
ci_negated=0
if [ "$ci_rc" -eq 0 ] && printf '%s' "$ci_out" | grep -qE ':[0-9]+:!'; then
  ci_negated=1
fi
if [ "$ci_rc" -eq 0 ] && [ "$ci_negated" -eq 0 ]; then
  : # healthy (実効的に ignored)
fi
```

`:[0-9]+:!` は誤検出しても安全側 (false-positive DRIFT) に倒れ、probe パスが固定文字列なら実発火経路はない（security reviewer が bypass 経路なしを実測検証）。

### 発生事例

gitignore-health-check の判定を「特定ルール表記への文字列一致」から rc ベースの実効判定へ移行した cycle 1 実装が、`-v` のこの verbose 特性を見落とし rc==0 のみを healthy 条件とした。negation-leak 構成を healthy と誤判定する回帰を導入し、cycle 1 review の security reviewer が runtime_observation + revert test で検出。修正は negated フラグ + grep の 2 行を sessions/worktrees 両ブロックへ対称適用し、negation 構成 → DRIFT exit 1 の回帰テストを両テストファイルへ追加。

### 設計上の帰結: -q と -v の使い分け

- **判定だけが必要な経路** (setup の「未カバー時のみ追記」ゲート等) は `-q` を使う。rc がそのまま実効判定になり negation 分岐は不要
- **診断出力が必要な経路** (health-check の「どのルールで ignore されているか」の log 等) は `-v` を使い、negation 検査を必ず併用する
- 同一 invariant を判定する sibling が `-q` と `-v` に分かれる場合、negation-leak 構成での両者の判定一致 (`-q` rc=1 = 追記 / `-v` + `!` 検査 = DRIFT) を実測で確認する

### 関連する周辺特性

- git のディレクトリ pruning により `check-ignore -v` は最初に一致した親ルール (例: 広域 `.rite/`) を報告する。特定ルール表記への文字列一致を healthy 条件に要求すると、広域 + 個別の重複構成で偽陽性 DRIFT になる (本 PR の元バグ)
- 親ディレクトリが exclusion されている場合、配下の negation (`!dir/**`) は再 include できない (git 仕様)。この構成では `-v` は実効ルール (親) を報告するため誤 DRIFT にならない

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Documentation review は対応する実装側の grep verify を必須 step とする](../heuristics/docs-review-implementation-grep-verification.md)

## ソース

- [fix 結果](../../raw/fixes/20260712T145139Z-pr-1836.md)
- [レビュー結果](../../raw/reviews/20260712T151954Z-pr-1836.md)
