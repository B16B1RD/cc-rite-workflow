---
type: "anti-patterns"
title: "境界での無害化は下流ツールの別エスケープ意味論までは保証しない（quoted heredoc → awk -v 伝播）"
domain: "anti-patterns"
description: "quoted heredoc でコマンド置換・変数展開を防いだ直後、同じ値を awk -v へ渡すと今度は awk 自身のバックスラッシュエスケープ解釈（\\n→改行 / \\t→タブ / \\d→d）で複数行分割・文字破壊が起きる。1 つの脆弱性クラス（shell injection）の修正が、別の脆弱性クラス（データ破損・不変条件違反）を別ツールの境界に持ち込む典型例。"
created: "2026-07-09T00:40:00+09:00"
updated: "2026-07-09T00:40:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260708T153610Z-pr-1802.md"
tags: []
confidence: high
---

# 境界での無害化は下流ツールの別エスケープ意味論までは保証しない（quoted heredoc → awk -v 伝播）

## 概要

自由入力（reviewer 指摘の要約、ユーザー入力等）をシェルに渡す際、quoted heredoc (`<<'EOF'`) でコマンド置換 (`` ` `` / `$(...)`) や変数展開 (`$VAR`) を無害化しても、その「無害化済み」の値を次の境界（別のツール、例えば `awk -v var=value`）へそのまま渡すと、そのツール固有のエスケープ解釈によって別種の破損が起きる。実測例では、quoted heredoc で shell injection を正しく防いだ直後、同じ変数を `awk -v line="$new_line"` で awk に渡していた。awk の `-v` はコマンドライン代入値のバックスラッシュエスケープを解釈する仕様（POSIX 準拠）のため、`\n` → 実改行、`\t` → タブ、`\d` → `d`（+警告）に変換され、「1 行 append」という呼び出し元の不変条件（AC-3）を破壊した。

## 詳細

**発生した経緯**:
1. cycle 1: reviewer 指摘の free-text (`{decision}`/`{reason}`/`{impact}`) を直接シェル変数へ代入していたコードが、バッククォートや `$(...)` 混入時にコマンド置換を起こすリスクを指摘され、quoted heredoc 経由に修正した（shell injection 対策として正しい）。
2. cycle 2: 同じ無害化済みの値 `$new_line` を、Decision Log 行を Section 9 の適切な位置へ挿入する awk スクリプトへ `awk -v line="$new_line"` で渡していたところ、正規表現例 (`\d+`) や Windows パス (`C:\temp`) のようにバックスラッシュを含む現実的な入力で、awk 自身がエスケープシーケンスとして解釈し、意図しない改行・タブ・文字置換を引き起こすことが実機検証で確認された。

```
入力: - 2026-07-09 D-05: Fix regex \d+ and path C:\temp\new and tab\there
awk -v の出力（破損）: - 2026-07-09 D-05: Fix regex d+ and path C:  emp
                        ew and tab  here     ← \t→タブ、\n→実改行、\d→d
```

quoted heredoc は「シェルの」展開・置換を防ぐスコープに限定されており、その後で値を別のインタプリタ（awk / sed / perl 等）に渡す際、そのインタプリタ独自のエスケープ規則までは一切カバーしない。「1 箇所で無害化した」という安心感が、次の境界での検証を省略させる典型的な落とし穴になる。

**修正**: `awk -v` を避け、環境変数 + `ENVIRON[]` 配列経由に変更した。`NEW_LINE="$new_line" awk '... print ENVIRON["NEW_LINE"] ...'` は awk のコマンドライン代入経路を通らないため、エスケープシーケンスの解釈を受けない（実機検証で `\d+` / `C:\temp` / タブ / 改行のいずれも verbatim 保持を確認）。

**一般化した教訓**: 自由入力を複数のツール境界（シェル → awk、シェル → sed、awk → 正規表現エンジン 等）を跨いで受け渡す実装では、**各境界ごとに個別のエスケープ意味論を検証する**必要がある。ある境界での無害化（例: quoted heredoc）が別の境界（例: `awk -v`）の安全性を暗黙に保証するわけではない。レビュー・修正時は「この値は最終的にどのツールに、どの受け渡し機構（コマンドライン引数 / 環境変数 / stdin）で渡るか」を最後まで追跡し、各機構固有のエスケープ・解釈規則を個別に確認すること。

この失敗モードは [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) が記録する「fix の対称化レイヤーごとの byte-exact 一致検証契約が未確立だと recursive recurrence が発火する」パターンの一種であり、対称位置の伝播漏れではなく「異なる層（シェル層 → インタプリタ層）での再解釈」という axis で発生する点が特徴的。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1802 review results](../../raw/reviews/20260708T153610Z-pr-1802.md)
