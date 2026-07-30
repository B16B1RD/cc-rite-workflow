---
type: "heuristics"
title: "再発防止 guard スクリプトは docstring の宣言意図と実装 regex を実測で校正する"
domain: "heuristics"
description: "guard 系スクリプトは「宣言した検出範囲」と「実際の regex」の対応がレビューで実測検証される。regex は現存パターンの再現でなく宣言意図（quote/flag バリアント含む）に合わせ、非検出形は Known boundary 節に隠さず列挙する。opt-in flag は実装と call site 配線を同一コミットで行う。guard 自体のテスト（regex 契約の fixture pin）は同一 PR に同梱し、再レビューは mutation 視点で収束確認する。PR #1909 cycle 3-5 + resume cycle の実測。"
created: "2026-07-19T15:00:00+09:00"
updated: "2026-07-19T23:01:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260719T030534Z-pr-1909-c3.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T030743Z-pr-1909-c3.md"
  - type: "reviews"
    ref: "raw/reviews/20260719T031816Z-pr-1909-c4.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T031957Z-pr-1909-c4.md"
  - type: "reviews"
    ref: "raw/reviews/20260719T120555Z-pr-1909.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T121530Z-pr-1909.md"
  - type: "reviews"
    ref: "raw/reviews/20260719T122934Z-pr-1909.md"
tags: []
confidence: high
---

# 再発防止 guard スクリプトは docstring の宣言意図と実装 regex を実測で校正する

## 概要

lint / recurrence-guard 系スクリプトのレビューでは「docstring が宣言する検出範囲」と「実際の regex が検出する範囲」の対応が合成テストで実測検証され、乖離は指摘になる。regex は「現存パターンの正確な再現」だけで校正せず宣言意図（quote/flag バリアント含む）に合わせ、意図的な非検出形は Known boundary 節に完全列挙する。起点事例の cycle 3-5 で実測された連鎖。

## 詳細

起点事例（sandbox 非互換パターンの全域スイープ + tmp-hardcode-check.sh 新設）で観測された 3 つの失敗形:

1. **regex が宣言より狭い**: docstring は「mktemp with a /tmp-prefixed template」「fixed /tmp path hardcode (assignment / redirect / -file option)」と宣言したが、regex は quoted template（`mktemp "/tmp/rite-XXXXXX"`）・flag 介在（`mktemp -d /tmp/...`）・quoted redirect・unquoted 代入の 4 形式を素通しした。皮肉なことに、sweep 自身が教える安全形が quoted スタイル（`mktemp "${TMPDIR:-/tmp}/..."`）のため、「quoted のまま /tmp へ regress する」形式が最も蓋然性の高い将来の回帰形だった。レビュアーは widened regex で 4/4 検出かつ false positive 0 を実測して指摘した。
2. **Known boundary の記載漏れ**: 検出契約の SoT である Known boundary 節に、実測済みの非検出形（refspec 後置 flag `git push origin -u branch`）を書き漏らした。「regex を広げる」より「境界を明記する」が正しいケース — prose への false positive を生む拡張は避け、docstring 追記で契約を誠実にする。
3. **dead option 化**: consumer-repo 用の `--skip-if-no-target` flag を実装したのに、唯一の call site（lint check table）に渡し忘れた。flag の help text が明記するユースケースそのもので配線されておらず、2 reviewer が独立に検出して severity boost（MEDIUM→HIGH）。**opt-in flag の実装と call site への配線は同一コミットで行う**。

4. **guard 自体のテスト欠落（resume cycle, MEDIUM ×2 reviewer 独立検出）**: 再発防止 guard スクリプトを新設する PR に「guard 自体のテスト」を含めないと、再発防止が機械的検証を持たず guard の regex silent regression を検出できない。fix では guard の regex 契約（陽性 / safe form / known boundary）を fixture で pin する回帰テストを追加し、docstring の主張を機械的検証に変換した。既存 guard 群の hooks/tests 慣習を Grep で確認してから追随する。**再発防止 guard を導入する PR には guard 自体のテストを同一 PR で同梱する**。

**付随ヒューリスティック — 再出現推奨の先回り**: 複数 cycle にわたって再出現する actionable 推奨事項は、次 cycle で指摘に昇格する傾向がある（helper docstring drift が cycle 2 推奨 → cycle 3 指摘に昇格した実例）。収束を早めるには、再出現した推奨を指摘昇格前に先回りで潰す。

**付随ヒューリスティック — mutation 視点の再レビュー収束確認（resume cycle 2）**: テスト欠落指摘への fix を再レビューする際は、追加されたテストが「指摘した検証ギャップを実際に塞いでいるか」を mutation 視点（allowlist の arm 削除で fail するか / regex の prefix 緩和で fail するか）で確認すると 1 cycle で収束できる。また `guard --all` の 0 findings 自己検査は「スイープ完全性」の機械的証明として全レビュアーで再利用された。

## 関連ページ

- [機械的一括置換は同一リテラルの役割差を無視すると load-bearing fixture を壊す](../anti-patterns/bulk-substitution-ignores-literal-role.md)
- [テンプレート流用の新規スクリプトは最新兄弟の防御を継承する](./new-script-inherits-latest-sibling-defenses.md)

## ソース

- [PR #1909 review results (cycle 3)](../../raw/reviews/20260719T030534Z-pr-1909-c3.md)
- [PR #1909 fix results (cycle 3)](../../raw/fixes/20260719T030743Z-pr-1909-c3.md)
- [PR #1909 review results (cycle 4)](../../raw/reviews/20260719T031816Z-pr-1909-c4.md)
- [PR #1909 fix results (cycle 4)](../../raw/fixes/20260719T031957Z-pr-1909-c4.md)
- [PR #1909 review results (resume cycle)](../../raw/reviews/20260719T120555Z-pr-1909.md)
- [PR #1909 fix results (test coverage)](../../raw/fixes/20260719T121530Z-pr-1909.md)
- [PR #1909 review results (cycle 2)](../../raw/reviews/20260719T122934Z-pr-1909.md)
