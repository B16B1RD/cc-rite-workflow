---
type: "heuristics"
title: "新規 helper は既存 sibling の安全規約に整合させる（trap・tree 解決・制御文字無害化）"
domain: "heuristics"
promote: rite-plugin
description: "新規 helper を書くとき、既存 sibling helper が確立した安全規約（signal trap での tempfile 回収 / strategy 依存の tree 解決 / 制御文字無害化 / 委譲先 stderr の素通し / summary の不変条件）へ整合させる。規約非対称は個別バグではなく複数 MEDIUM 指摘として段階的に surface する。"
created: "2026-07-03T00:42:39+00:00"
updated: "2026-07-03T00:42:39+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260703T003518Z-pr-1731.md"
tags: ["sibling-convention", "bash", "git-worktree", "control-char", "utf-8", "signal-trap", "code-review-convergence"]
confidence: high
---

# 新規 helper は既存 sibling の安全規約に整合させる（trap・tree 解決・制御文字無害化）

## 概要

新規の shell helper を書くとき、同ディレクトリの既存 sibling helper が確立した安全規約（signal-specific trap での tempfile 回収 / branch-strategy 依存の tree 解決 / 制御文字無害化 / 委譲先の stderr 素通し / summary の不変条件）へ整合させる。これらを踏襲しないと、レビューでは個別バグではなく「既存規約との非対称」として複数の MEDIUM 指摘が段階的に surface し、review⇄fix ループが収束しにくくなる。

## 詳細

### 発生背景

`wiki-backfill-skipped-frontmatter.sh` を新規追加した PR のセルフレビューで、cycle1 に 5 件・cycle2 に 2 件の MEDIUM/LOW-MEDIUM 指摘が段階的に検出され、3 cycle（5→2→0）で収束した。指摘はいずれも個別の論理バグではなく、既存 sibling（`wiki-lint-*.sh` / `wiki-worktree-*.sh` / `lib/wiki-config.sh`）が既に確立している安全規約への非対称に還元された。修正はすべて「sibling パターンへの整合」で解消した。

### 特に再利用価値の高い具体的 gotcha

1. **`cd` の後に `git rev-parse --show-toplevel` を呼ぶと必ず current tree（= cd 先）に collapse する**。linked worktree セッションで「セッション worktree の tree」を解決したい場合、共有 state root へ `cd` する**前**に `INVOKE_TREE="$(git rev-parse --show-toplevel)"` を捕捉する必要がある。cd 後に解決すると常に共有 root を返し、if/else の分岐が実質デッドコード化する。writer（back-fill）が collapse 済み root へ書くと、同じ素の `show-toplevel` で読む reader（lint）が永久に観測できず reader/writer が食い違う。

2. **制御文字の無害化は content が多バイト UTF-8 を含む場合、byte 単位ではなく codepoint 単位で行う**。共有 helper の byte 単位モード（`LC_ALL=C tr` で 0x80-0x9f を除去）は診断出力向けで、日本語 UTF-8 の継続バイト（0x80-0x9f にかかる）を巻き込んで破壊する。また `python3 json.dumps(ensure_ascii=False)` は 8-bit C1（CSI 0x9b）を**エスケープせずリテラル通過**させ、リテラル C1 は YAML c-printable 不変条件を破る。「生の 0x9b は UTF-8 decode で弾かれる」という前提も C/POSIX locale では偽（PEP 538 の surrogateescape で round-trip する）。正しくは `decode("utf-8","replace")`（invalid → U+FFFD、locale 非依存）＋ codepoint 単位で C0/DEL/C1 を `?` 化する。日本語（U+3000 以上）は無傷、locale 非依存で C1 を閉じられる。

3. **その他の踏襲項目**: 書込中の in-tree tempfile は signal-specific trap（EXIT/INT/TERM/HUP）で回収する（中断時の孤児が後続 `git add` で混入するのを防ぐ）。委譲先 helper の stderr は `2>&1` で握り潰さず素通しして remediation hint を残す。per-item resilient な処理では失敗をカウンタに計上し summary の不変条件（各カウンタ合計 == 総処理数）を保つ（exit 0 の summary から部分失敗が silent に漏れない）。

### 予防

新規 helper を追加する前に、同ディレクトリ / 同ファミリの sibling helper を 1 本 grep で読み、trap パターン・repo_root/tree 解決・エラー surface・summary 契約を確認して整合させる。「動く実装」ではなく「既存規約と対称な実装」を目標にすると review⇄fix の cycle 数が減る。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1731 review results](../../raw/reviews/20260703T003518Z-pr-1731.md)
