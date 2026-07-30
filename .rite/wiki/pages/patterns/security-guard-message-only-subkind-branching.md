---
title: "security guard の deny メッセージ改善は判定ロジック不変の subkind タグ分岐で行う"
domain: "patterns"
created: "2026-06-09T18:38:00Z"
updated: "2026-06-09T18:38:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260609T182954Z-pr-1323.md"
tags: []
confidence: medium
---

# security guard の deny メッセージ改善は判定ロジック不変の subkind タグ分岐で行う

## 概要

security hook の over-broad block 体験 (中身が無害でも一律 block される等) を改善する際、判定 (deny gate) を一切緩和せず、メッセージのみを subkind タグで分岐する。パターン名 (deny reason の識別子) は既存テストの substring assertion 互換のため不変に保つ。

## 詳細

確立の経緯: reviewer subagent の read-only な `bash -c` 挙動プローブが `pre-tool-bash-guard.sh` の (Z) shell-wrapper guard で一律 block される over-broad 体験に対し、以下の手順でメッセージのみを是正した:

1. **緩和しない判断を先に確定する**: `bash -c` の quote 内パースで「無害なら許可」を実装するのは fragile な bypass 面 (`bash -c 'git reset --hard'` の隠蔽) を security hook に再導入する。wrapper 一律 block は PR #997 / Issue #995 の実インシデントへの意図的な構造的防御であり、reviewer は subshell `( ... )` / 直接実行 / `bash <script.sh>` で検証強度を落とさず代替できるため実害はほぼゼロ。over-broad 体験の実害は **deny メッセージの乖離** (中身が git でない probe にも "State-changing git commands ... forbidden" と表示) に局在する。
2. **subkind タグでメッセージのみ分岐**: `BLOCKED_SUBKIND=""` を判定ブロック前に無条件初期化し、(Z) shell-wrapper の case arm でのみ `BLOCKED_SUBKIND="shell-wrapper"` を設定。deny メッセージ組立部 (`[ -n "$BLOCKED_PATTERN" ]` 内側) で subkind を見て wrapper 専用の理由 (quote 内が word-boundary マッチに opaque) と代替 (直接実行 / subshell / `bash <script.sh>`) を既存メッセージに**前置**する。deny 決定の gate は `BLOCKED_PATTERN` 単独のまま、subkind は決定に一切関与しない。
3. **パターン名は不変に pin**: 既存テストの `assert_subagent_deny` が deny reason に `reviewer-state-mutating-git` の包含を要求しているため、パターン名は変えず message だけを分岐する。これにより既存回帰テスト全件が無変更で通る。
4. **検証 3 点セット** (レビューで全レビュアー「可」・0 findings を裏付けた verify):
   - **deny gate 不変の静的解析**: 新変数の init / set / read の全参照点を列挙し、deny 決定経路に関与しないことを確認 (init は判定前に無条件、set は対象 case arm のみ、read はメッセージ組立のみ)。
   - **案内する代替が bypass にならないことの実プローブ**: deny メッセージで案内する subshell `( git reset --hard )` は paren が空白区切りトークンで quote と違い opaque でないため、word-boundary マッチが依然発火することを実プローブで確認。`bash <script.sh>` も既存設計で (Z) case (`" bash -c "` のみマッチ) を踏まないことを確認。**メッセージで代替を案内する変更は、その代替自体が新たな bypass 経路にならないかを必ず検証する**。
   - **message assertion の non-vacuity を mutation で立証**: 新規テストの reason token AND 検査が、worktree-only mutation (subkind 代入の無効化 / 文言改変) で確実に FAIL することを実機確認 (load-bearing assertion の証明)。
5. **「緩和しない」方針自体をテストで pin**: read-only コマンドを包んだ wrapper (`bash -c "git status"`) が依然 deny されることを回帰テストとして固定し、将来の安易な緩和を構造的に防ぐ。

この手法は「security boundary に触れずに UX (deny メッセージの説明力) を改善する」canonical な分離パターンであり、guard 系 hook のメッセージ品質改善 PR に再利用できる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [入力注入経路のない静的文字列処理連鎖は関数抽出 + 境界行 extract で非 vacuous unit テスト化する](./static-input-chain-function-extraction-non-vacuous-test.md)

## ソース

- [PR #1323 review results](../../raw/reviews/20260609T182954Z-pr-1323.md)
