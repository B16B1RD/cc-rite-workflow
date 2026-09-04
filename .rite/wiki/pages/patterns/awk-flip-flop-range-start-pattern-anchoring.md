---
type: "patterns"
title: "テストヘルパーの awk flip-flop レンジは start pattern をコード行に一意なプレフィックスでアンカーする"
domain: "patterns"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/patterns/awk-flip-flop-range-start-pattern-anchoring.md"
description: "`assert_grep_in_section` のようなテストヘルパーが awk flip-flop レンジ (`$0 ~ start, $0 ~ end`) で SKILL.md 内の特定セクションを抽出する場合、start pattern が生の marker 名（例: `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1`）だけだと、その marker 名を引用する散文の説明行にも一致してしまう。"
created: "2026-07-23T04:14:28Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260723T031622Z-pr-1974-cycle3.md"
  - type: "reviews"
    resource: "raw/reviews/20260829T153702Z-pr-2466.md"
tags: ["awk", "flip-flop-range", "test-helper", "section-scoping", "gawk-escaping", "no-journal-comment"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-29T15:42:53Z" }
---

# テストヘルパーの awk flip-flop レンジは start pattern をコード行に一意なプレフィックスでアンカーする

## 概要

`assert_grep_in_section` のようなテストヘルパーが awk flip-flop レンジ (`$0 ~ start, $0 ~ end`) で SKILL.md 内の特定セクションを抽出する場合、start pattern が生の marker 名（例: `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1`）だけだと、その marker 名を引用する散文の説明行にも一致してしまう。文書内で同一文字列が複数回出現すると、awk flip-flop レンジは最初の end 一致後に散文行で再起動し、意図せず EOF までレンジが伸びる。cycle 3 で application / error-handling reviewer が独立に検出し、mutation test（section 抽出範囲の実測 127/118 行 vs 意図した 20/16 行）で過検出を実証した。

## 詳細

### 過検出の構造

`assert_grep_in_section` の実装は以下のような awk flip-flop パターンを使う:

```awk
$0 ~ start, $0 ~ end { print }
```

start pattern に生の marker 名（`WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1` 等）だけを渡すと、SKILL.md 内でこの文字列は以下の 2 箇所に出現しうる:

1. 実際に marker を emit する bash コード行（`echo "[CONTEXT] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1; ..."`）
2. 後続ステップでこの marker をバッククォート引用して説明する散文行（「`WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1` のとき...」）

awk flip-flop レンジは最初の start-end ペアの後、次の start 一致（= 散文の引用行）で再起動し、以降の end 一致まで（多くの場合ファイル末尾まで）を section として抽出してしまう。section scoping が実質無効化され、コード側のガードが regression してもテストは silent pass しうる。

### 修正: start pattern をコード行専用のプレフィックスでアンカーする

`echo "[CONTEXT] ` のような接頭辞は bash コード行にしか出現しない（散文の引用は通常バッククォートで囲むだけで `echo "` を伴わない）。start pattern をこの接頭辞込みで指定することで、散文行への誤爆を構造的に排除できる:

```bash
assert_grep_in_section "..." "$CLEANUP" \
  'echo "\\[CONTEXT\\] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1' \
  '^     else$' \
  'record --type session_worktree'
```

### awk -v の C 風エスケープ二重解釈への対処

`assert_grep_in_section` の start/end 引数は内部で `awk -v` に渡される。gawk の `-v` オプションは値を **C 風エスケープとして 1 段階解釈してから** 正規表現エンジンに渡す仕様がある。そのため ERE のリテラル bracket (`\[` / `\]`) を正規表現エンジンまで届けるには、`-v` 側の解釈で 1 段階消費される分を見越して `\\[` / `\\]`（バックスラッシュ 2 つ）を渡す必要がある。

- `\[` を渡すと: `-v` 解釈で「不要なエスケープ」として警告付きで `[` に潰され、bracket 式として解釈されて match しなくなる、あるいは過剰マッチの温床になる
- `\\[` を渡すと: `-v` 解釈で 1 段階消費されて `\[` になり、正規表現エンジンにリテラル bracket として正しく届く

### end pattern の一意性も同格に要る（start とは非対称に、未マッチが検出されない）

start と end で fail-loud 性が非対称である。`assert_grep_in_section` は start がどの行にも一致しないとき抽出結果が空になり `empty section` として fail するが、**end がどの行にも一致しないケースは検出しない** — awk flip-flop レンジがそのまま EOF まで伸び、section 限定のはずの assert が無言で file-wide 判定に劣化する。start だけを一意にしても、end に文書内で多数出現する汎用トークン（Markdown の水平線 `^---$` 等）を使うと、その 1 本が将来の cosmetic cleanup で消えた瞬間に劣化する。

したがって end も **文書内で一意な見出し**にする。start が `^## Placeholder Legend`（一意）でも、end が `^---$`（同一ファイル内に 10 箇所出現）なら degrade 経路は開いたままで、`^## ステップ 0` のような一意見出しに変えて初めて閉じる。「start が一意なら安全」ではない。

この一意性は grep で機械的に検査できる（end pattern の対象ファイル内マッチ数を数えるだけ）ため、検出器化の候補になる。

### テストコメントにも no_journal_comment 原則が適用される

同 cycle 3 で、テストヘルパーのコメント中に「cycle 2 test reviewer 指摘」「the error-handling reviewer reproduced」等のレビュー経緯・reviewer 言及が残っていることが prompt-engineer reviewer から HIGH 指摘された。no_journal_comment 原則（cycle 番号・reviewer 名の言及禁止）はプロダクションコードだけでなくテストコメントにも同様に適用される。修正は該当箇所を現在形の Why のみに書き換えることで解消した。

## 関連ページ

- [awk negative-class + greedy + literal の組み合わせは backtracking で literal を silent miss する](../anti-patterns/awk-regex-backtracking-trap-with-greedy-literal.md)
- [bash code block 終端は固定 +N 行 window ではなく awk state machine で動的追跡する](./awk-bash-block-termination-tracking.md)

## ソース

- [awk flip-flop レンジ過検出の修正](../../raw/fixes/20260723T031622Z-pr-1974-cycle3.md)
- [end 境界の一意性と degrade 経路](../../raw/reviews/20260829T153702Z-pr-2466.md)
