---
type: "heuristics"
title: "アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない"
domain: "heuristics"
description: "「アサーションが存在する」と「そのアサーションが対象コードを通る」は別の事実であり、後者は目視レビューでは判定できない。fixture の順序・配置のせいでガードを一度も通らない、rc が変更前後で同値のため効果が固定されない、といった空振りは、該当 hunk を revert してスイートが赤くなるかを実測して初めて分かる。PR #2051 の 4 サイクルで 3 件が mutation でのみ検出された。"
created: "2026-07-30T01:20:00+09:00"
updated: "2026-08-01T00:21:06+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260729T150808Z-pr-2051-c2.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T153523Z-pr-2051-c3.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T155350Z-pr-2051-c4.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T151517Z-pr-2051-c2.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T153947Z-pr-2051-c3.md"
  - type: "reviews"
    ref: "raw/reviews/20260731T035544Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260731T090329Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260731T041200Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260731T135712Z-pr-2074.md"
tags: []
confidence: high
---

# アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない

## 概要

テストの存在はカバレッジを保証しない。アサーションが書かれていても、fixture の配置や検査対象の選び方によって、そのアサーションが守っているはずのコード行を一度も通らないことがある。この「空振り」は目視レビューでは高い確率で見落とされ、**対象の hunk を revert してスイートが赤くなるかを実測する**ことでしか判定できない。

## 詳細

### 起点事例の 4 サイクルで実測された 3 つの空振り型

**型 1 — fixture の順序でガードが立たない（cycle 2）**

セクション境界ガード（`in_section && /^[a-zA-Z]/ { exit }`）を名指しするアサーションが、fixture で対象セクションを他セクションより**後ろ**に置いていたため `in_section` がそもそも立たず、ガードを削除しても全緑のままだった。アサーションの文言はガードを検証しているように読めるが、実行経路が到達していない。

**型 2 — 分岐 arm のうち 1 本だけテストが無い（cycle 2）**

rc=2 に至る 3 経路（fence 不整合 / awk fatal / ファイル不在）のうち awk fatal の arm だけテストが無く、そのカウンタ加算行を削除しても全 assertion が緑だった。「rc=2 のテストはある」ことと「rc=2 に至る全経路のテストがある」ことは別。

**型 3 — 効果が rc に現れないため rc の assertion で固定できない（cycle 3）**

「走査不能の集約 ERROR を findings 判定より前へ移す」修正は、rc が移動の前後とも 1 で**同値**だった。テストが rc しか見ていなかったため、hunk を revert してもスイートは全緑。修正の観測可能な効果が stdout/stderr にしか現れない場合、そこを assert しない限りリグレッションは検出されない。

```bash
# rc だけでは固定できない → stderr も assert する
assert "findings win the exit code when both are present (exit 1)" "1" "$(run --quiet --all)"
mixed_err="$(bash "$SCRIPT" --quiet --all 2>&1 >/dev/null || true)"
if printf '%s' "$mixed_err" | grep -qF 'could not be scanned'; then
  pass "the unscannable count survives a run that also has findings"
else
  fail "aggregate unscannable line lost when findings are present"
fi
```

### 実施手順

1. 検証したい修正の hunk を特定する（1 コミット内の 1 変更点）
2. **隔離コピー**（`git worktree add --detach` で別ツリーを作る等）でその hunk だけを revert する
3. テストスイートを実行する
4. 赤くなれば load-bearing、緑のままなら空振り

READ-ONLY 制約下のレビューでも、隔離 worktree 内での mutation は working tree を汚さないため実施できる。

### 副次的に見つかる「gate が pin を殺す」型

cycle 4 では、追加した fixture が正しく hunk を pin していることを mutation で確認したうえで、**root 実行環境では `id -u` gate によりブロックごと skip され pin が失われる**という縮小方向の指摘が出た。gate 付きのテストは、gate が発火する環境で mutation を再実行しないと検証範囲が分からない。

```bash
# gate を強制的に有効化して再実測する
# （if [ "$(id -u)" -eq 0 ] を if true に置換して mutation を再実行）
```

### 「0 件」の質を区別する

mutation を回したうえでの「指摘 0 件」と、回さずに出した「0 件」は意味が違う。起点事例の cycle 4 では複数の reviewer が「これは Guardrail によるフィルタ結果のゼロではなく、実測に裏付けられた実質的なゼロである」と明記した。**レビューの収束は指摘件数の減少ではなく、0 件の裏付けの有無で判定する**。

後続の 2 つの PR で、この区別はさらに具体化された。test reviewer は 19 変異中 5 生存を報告しつつ「いずれも 3 ゲートを通らない」として指摘 0 件を選び、生存理由を個別に言語化している。**self-censorship 禁止と水増し禁止を対で prompt に書く**と判定が正直になる。また reviewer prompt に「実際に動かして実測を取れ」と明示すると、blocking 判定に必要な実測アンカーが自然に付き、実測なしによる non-blocking 降格が 0 件になった。

### 追加で観測された「書いてあるが落ちない」形

- `[ "$RC" -eq 0 ] || cmp -s ...` の **OR 短絡**で第 2 項が評価されない
- テスト内に **SoT regex の自前コピー**を再定義して等価性を主張する（実装から語境界を削除しても全緑）
- **同じ exit code を返す gate が複数ある**ため、exit code だけの assert が当の gate を pin しない。gate 固有の診断 marker まで assert する
- **同一行に 2 箇所ある同じ部分文字列**を静的 pin すると片方だけで充足する。守りたい箇所の文脈込みでアンカーする
- **anti-pin**（「この文字列が出ないこと」）は、pin する文字列が実装に実在するかを確かめないと恒久的に緑になる
- **報告文字列の assert に部分一致 glob を使わない**（`*"PR #2047"*` は末尾に残余があっても一致するため trim を削除しても緑）
- **権限を落とす対象の取り違え**（ファイル chmod では親ディレクトリ経由の書き込みが通る）

いずれも「assertion を書いた直後に隔離コピーへ 1 トークン変異を入れて 1 回通す」手順で捕まる。なお **sed による変異はクォート起因で silent に失敗しうる**ため、変異後の該当行を表示して適用を確認してからテストを回す（実際に 1 回目の変異適用が失敗したまま「全 pass」を得た事例がある）。

## 関連ページ

- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](../anti-patterns/locale-dependent-error-message-grep-assertion.md)
- [実装が分岐しているならテストも分岐の数だけ要る](./implementation-branch-count-equals-test-branch-count.md)
- [テンプレート準拠の fixture では、生成器が実データで作る構造的逸脱を検出できない](./template-fixture-misses-generator-real-data-deviation.md)
- [absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する](../patterns/absence-pin-base-present-head-absent-single-line.md)
- [除外契約のテストは境界の両側に対で書く](../patterns/exclusion-test-requires-both-sides-of-boundary.md)
- [累積対策 PR の 3 cycle 収束記録: cross-validation boost + cycle 2 minor drift + cycle 3 mergeable](./accumulated-pr-three-cycle-convergence.md)

## ソース

- [PR #2051 review results (cycle 2)](../../raw/reviews/20260729T150808Z-pr-2051-c2.md)
- [PR #2051 review results (cycle 3)](../../raw/reviews/20260729T153523Z-pr-2051-c3.md)
- [PR #2051 review results (cycle 4, mergeable)](../../raw/reviews/20260729T155350Z-pr-2051-c4.md)
- [PR #2051 fix results (cycle 2)](../../raw/fixes/20260729T151517Z-pr-2051-c2.md)
- [PR #2051 fix results (cycle 3)](../../raw/fixes/20260729T153947Z-pr-2051-c3.md)
