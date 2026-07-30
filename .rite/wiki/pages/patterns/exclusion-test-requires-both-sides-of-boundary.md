---
type: "patterns"
title: "除外契約のテストは境界の両側に対で書く"
domain: "patterns"
description: "「この範囲は走査しない」という除外契約のテストで、fixture の検出対象を除外側にしか置かないと、実装がどう壊れても finding が出ず常に pass する恒真アサーションになる。除外されなければ必ず検出される内容を境界の内側と外側に対で置き、除外条件を外す変異で rc が変わることを実測して初めて非恒真と言える。"
created: "2026-07-30T01:20:00+09:00"
updated: "2026-07-30T01:20:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260729T142410Z-pr-2051.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T144345Z-pr-2051.md"
tags: []
confidence: high
---

# 除外契約のテストは境界の両側に対で書く

## 概要

除外契約（「実スクリプトは走査しない」「コードフェンス外は対象外」「このディレクトリは除く」）のテストは、fixture の置き方を誤ると恒真になる。除外側にしか検出対象を置かないと、**実装の走査範囲がどう広がっても finding が出ない**ため、除外ロジックが壊れても pass し続ける。

## 詳細

### 恒真になった実例

起点事例の初期実装では、`dollar-zero-check.sh` が「`.sh` の実スクリプトは走査しない（対象は markdown 内の fenced bash のみ）」という除外契約を持ち、そのテストで fixture の検出対象を**コードフェンスの外**に置いていた。

```bash
# 恒真だった fixture
cat > "$SANDBOX/plugins/rite/skills/demo/script-copy.sh" <<'EOF'
awk '$0 ~ /pattern/ { print }'   # ← フェンス外（.sh ファイルなのでフェンス自体が無い）
EOF
assert "--all leaves the .sh copy unscanned (exit 0)" "0" "$(run --all)"
```

フェンス外の内容は元々検出対象ではないため、`--all` の走査範囲が `.md` から `.sh` へ広がっても finding は出ない。除外契約が壊れても rc=0 のまま緑になる。

### 非恒真にする書き方

**除外されなければ必ず検出される内容**を用意し、境界の両側に対で置く。

```bash
# 1. 除外側: .sh ファイルの中に、検出されるはずの形をフェンス付きで置く
#    （.sh でも markdown fence を含む形にして、走査対象なら必ず hit する状態を作る）
cat > "$SANDBOX/plugins/rite/skills/demo/fenced-copy.sh" <<'EOF'
# ```bash
awk '$0 ~ /pattern/ { print }'
# ```
EOF

# 2. 非除外側: 同じ内容を .md の fenced bash に置く（必ず検出される対照）
printf '```bash\nawk %s\n```\n' "'\$0 ~ /pattern/ { print }'" \
  > "$SANDBOX/plugins/rite/skills/demo/positive.md"

assert "the .md copy IS detected (exit 1)" "1" "$(run --target .../positive.md)"
assert "--all leaves the fenced .sh copy unscanned (exit 0)" "0" "$(run --all)"
rm -f .../positive.md   # 対照を消してから --all を評価する場合は順序に注意
```

対照（`positive.md`）が検出されることを assert しておけば、「そもそも検出ロジックが働いていないから 0 件だった」という縮退を排除できる。

### 検証: 除外条件を外して赤くなるか

fixture を対で置いただけでは十分でない。**実装から除外条件を削る変異**を隔離コピーに適用し、テストが赤くなることを実測する。

```bash
# 隔離 worktree で、拡張子フィルタ（-name '*.md'）を外して再実行
# → fenced-copy.sh が検出され、exit 0 を期待する assert が落ちる
```

赤くならなければ、fixture がまだ除外側で「元々検出されない」内容になっている。

### 適用範囲

同じ落とし穴は以下の除外契約すべてに当てはまる。

- コードフェンス内 / 外の区別（lint の見出し抽出等）
- 自己除外（checker 自身のソースを走査対象から外す）
- ディレクトリ / glob による除外
- コメント行の除外

いずれも「除外されなければ必ず hit する内容」を用意できるかがテスト設計の分岐点になる。用意できない場合、その除外契約はテスト可能な形で表現されていない可能性が高い。

## 関連ページ

- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)
- [Lint の見出し抽出はコードフェンス内行を除外してから行う (検証ツール自身の false-negative 防止)](./lint-strip-code-fence-before-extraction.md)
- [absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する](./absence-pin-base-present-head-absent-single-line.md)

## ソース

- [PR #2051 review results](../../raw/reviews/20260729T142410Z-pr-2051.md)
- [PR #2051 fix results](../../raw/fixes/20260729T144345Z-pr-2051.md)
