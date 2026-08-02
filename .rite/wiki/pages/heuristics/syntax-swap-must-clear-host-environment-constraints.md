---
type: "heuristics"
title: "穴を塞ぐ構文置換は、新しい構文が実行環境固有の制約に触れないかを検出器のローカル実行で確かめる"
domain: "heuristics"
description: "2 つの欠陥を 1 変更で閉じる構文置換は、置換後の構文が「その構文をどこに置くか」に由来する制約を持つ場合がある。SKILL.md の fenced block に awk の行全体フィールドを持ち込んだ例では、置換自体は正しく 2 つの穴を閉じたが、Skill ローダーの引数展開という host 側の制約に触れて別の壊れ方を導入した。リポジトリに静的検出器があっても fix の時点では実行されず、発覚は CI まで 1 サイクル遅れる。fix の完了条件に「該当検出器のローカル実行」を含める。"
created: "2026-08-02T22:05:00+09:00"
updated: "2026-08-02T22:05:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260802T111323Z-pr-2052.md"
tags: ["skill-md", "static-checker", "fix-verification", "host-environment-constraint", "dollar-zero"]
confidence: high
---

# 穴を塞ぐ構文置換は、新しい構文が実行環境固有の制約に触れないかを検出器のローカル実行で確かめる

## 概要

複数の指摘を 1 つの構文置換で同時に閉じられるとき、その置換は正しい判断であることが多い。分岐が減り、ズレ検査が不要になり、Simplification-First にも合う。しかし置換後の構文が **「その構文をどこに置くか」に由来する制約** を持つ場合、置換は元の穴を閉じながら別の壊れ方を持ち込む。しかもその壊れ方は、コードの意味論ではなく host 側の前処理に由来するため、ロジックをいくら読んでも見つからない。

リポジトリがその制約の静的検出器を持っていても、fix の時点では実行されない。発覚は CI まで遅れ、マージ直前に止まる。**fix の完了条件に「置換した構文を対象とする検出器のローカル実行」を含める**。

## 詳細

### 実測された経路

起点事例の統計内訳カウントで、3 名のレビュアーが独立に同じ防御コードへ到達した。

```bash
printf '%s\n' "$pages_list" | grep -c "/${d}/" || true
```

指摘は 2 系統に分かれた。code-quality は「rc を capture して rc>=2 なら skip」、error-handling / security は「BRE の grep を literal 一致へ」。fix はこの 2 つを 1 変更で閉じる形を選んだ。

```bash
awk -v root="${pages_root}/${d}/" 'index($0, root) == 1 { n++ } END { print n+0 }'
```

この判断自体は正しかった。`index()` は literal 一致なのでチェックアウトパスが正規表現メタ文字を含んでも誤らず、`n+0` は 0 件でも 0 を出すので空値が同期ゲートを素通りする経路も同時に閉じる。`|| true` が不要になり分岐が減った。実 wiki worktree の 342 ページで grep 版と awk 版の内訳が完全一致（90 / 137 / 115）することも確認済みだった。

**それでも壊れた。** このブロックは `wiki-ingest/SKILL.md` の fenced code block の中にある。Skill ローダーは skill 本文の位置パラメータを起動引数へ展開するため、awk の行全体フィールド参照はロード時に別の文字列へ置き換わり、awk プログラムが壊れる。結果として、この fix が塞ごうとした「空値・誤った統計を書き込む」欠陥を、別経路で再導入する状態になった。

CI の 3 ジョブ（hook test suite / tests ubuntu / tests macos）が同一アサーション「real repo skills/ tree is clean」で fail し、マージ直前に発覚した。

### なぜロジックのレビューで見つからないか

この欠陥は 3 つの層のどこにも属さない。

| 層 | 状態 |
|---|---|
| awk プログラムの意味論 | 正しい（literal 前方一致・0 件で 0） |
| 元の指摘との対応 | 正しい（2 つの穴を実際に閉じている） |
| happy path の実測 | 正しい（342 ページで grep 版と一致） |

壊れるのは **「この文字列が SKILL.md の fenced block に置かれる」という配置** に由来する。同じ awk を `hooks/scripts/*.sh` に置けば何の問題もない。だからコードとしてレビューする限り、どの観点からも通ってしまう。

### リポジトリは既にこの制約を知っていた

起点事例の時点で、この制約は 3 箇所に記録されていた。

- `hooks/scripts/dollar-zero-check.sh` — fenced block 内の位置パラメータ参照を検出する専用チェッカー
- `hooks/tests/dollar-zero-check.test.sh` — 実リポジトリの `skills/` ツリーを走査する回帰テスト
- Wiki の既存ページ（[陳腐化した相互参照には「ただ古い」ものと「修正した欠陥へ戻す誘導」がある](./stale-cross-reference-that-guides-back-to-the-defect.md)）— 前 PR で同型の欠陥を塞いだ経緯と、`dollar-zero-check.sh` が静的検出を担うことまで明記

にもかかわらず再発した。既存ページが警告していたのは「陳腐化した相互参照が次の編集者を欠陥へ誘導する」経路であり、今回はその経路ではない。**相互参照とは無関係に、新しく書いたコードが同じ制約に触れた**。記録された知見は、それが警告した経路以外からの再発を防がない。

### 対処: fix の完了条件に検出器のローカル実行を含める

構文を置換したら、置換後の構文が触れうる制約の検出器を fix の時点でローカル実行する。

```bash
# 置換した構文が fenced block に入るなら、その専用チェッカーを回す
bash hooks/scripts/dollar-zero-check.sh --repo-root . --all --skip-if-no-target
```

「CI が拾うから」では 1 サイクル遅い。CI で落ちると、マージ判断の場で止まって修正サイクルが 1 本増える。起点事例では `/rite:merge` が `mergeable: MERGEABLE`（required checks 未設定のため）を返しながら CI が赤という状態で停止し、修正・再検証・再マージが必要になった。

置換の妥当性を実データで確認する手順（本事例では 342 ページでの内訳一致）は既に習慣化されていた。**足りなかったのは「置換後の構文が置かれる場所の制約」を確認する 1 コマンド**であって、検証の厚みではない。

### 是正の形

`awk` を使わず shell の `case` による literal 前方一致へ置き換えた。

```bash
for d in patterns heuristics anti-patterns; do
  n=0
  while IFS= read -r p; do
    case "$p" in "${pages_root}/${d}/"*) n=$((n + 1)) ;; esac
  done <<< "$pages_list"
  printf '%s=%s\n' "$d" "$n"
done
```

`case` パターンのクォートした部分は literal 扱いされるため、awk 版が担保していた性質をすべて保つ。5 ケース（通常パス / glob・正規表現メタ文字を含むパス / 基点より上の同名ディレクトリ / `anti-patterns` と `patterns` の接尾辞衝突 / 空白を含むパス）で実測して確認した。`<<<` はリダイレクトでありパイプではないので `while` がサブシェルにならず、`n` がループ後も残る。

この構文が repo の既存 idiom であることも確認した（`<<<` は 6 ファイル以上、`$((` と `case "$..."` はそれぞれ 8 ファイル以上の SKILL.md で使用済み）。**置換先を選ぶときは「制約に触れないか」だけでなく「同じ場所に置かれている既存構文か」も見る** — 既に多数の SKILL.md で使われている構文は、ローダーがそれを素通しすることの独立した裏付けになる。

### この記録に raw source が無い理由

上記の是正コミット（`dc29bef1`）には対応する raw source が存在しない。`/rite:fix` を経由せず、`/rite:merge` が CI 赤で停止した後にその場で手当てしたためである。`sources` に挙げた cycle 2 の fix raw は awk 版への置換までを「有効だった検証手法」として記録しており、**その後の顛末を持たない**。

このこと自体が知見になる。raw source は fix スキルの実行時に captured されるため、**スキル外で行った修正は Wiki の入力に乗らない**。マージ直前の手当てほどこの経路に落ちやすく、しかもそれは「検証をすり抜けた欠陥」という最も記録価値の高い種類の修正である。

## 関連ページ

- [陳腐化した相互参照には「ただ古い」ものと「修正した欠陥へ戻す誘導」がある](./stale-cross-reference-that-guides-back-to-the-defect.md)
- [SKILL.md 新規セクションでシェル変数を Bash 呼び出し間の値受け渡しに使うと dead code 化する](../anti-patterns/skill-md-shell-var-cross-bash-call-dead-code.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)

## ソース

- [PR #2052 fix results (cycle 2)](../../raw/fixes/20260802T111323Z-pr-2052.md)
