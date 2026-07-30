---
title: "同一 PR 内の設計 pivot 後に cross-reference コメントが旧設計の説明のまま残る"
domain: "anti-patterns"
created: "2026-06-10T00:38:14Z"
updated: "2026-06-10T01:19:36Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260610T001830Z-pr-1337.md"
  - type: "fixes"
    ref: "raw/fixes/20260610T002120Z-pr-1337.md"
  - type: "reviews"
    ref: "raw/reviews/20260610T011729Z-pr-1343.md"
tags: ["comment-rot", "design-pivot", "cross-reference", "self-inconsistency", "sweep-test", "helper-delegation", "cross-file-impact-check"]
confidence: high
---

# 同一 PR 内の設計 pivot 後に cross-reference コメントが旧設計の説明のまま残る

## 概要

実装途中で設計を pivot (例: sweep 条件の変更) した際、pivot した実装本体とそのコメントは更新されるが、**同一 PR 内の別箇所にある cross-reference コメント (他の検査・関数を説明する参照文)** が旧設計の説明のまま残り、同一ファイル内で自己矛盾する記述が生まれる。将来のメンテナが誤記述側に合わせて実装を「修正」すると、pivot で獲得した防御 (fail-closed sweep 等) が silent に弱体化する。

## 詳細

### 失敗の構造（実測）

起点事例で sweep test TC-3 を実装する際、初版の「`>&2` 同一行条件 sweep」が mutation 検証で vacuous と判明し、「全行 sweep + 明示 allowlist の fail-closed 設計」へ pivot した。TC-3 自身のコメントは pivot 後の設計を正しく説明していたが、**TC-1 側の cross-reference コメント (「TC-3 が同一行 `>&2` 条件で別途 sweep する」) が pivot 前の説明のまま commit** された:

- TC-3 実装: `>&2` フィルタなしの全行 sweep + allowlist (pivot 後)
- TC-3 コメント: 「`>&2` 同一行条件では構造的に検出できない…そのため全行 sweep」(pivot 後、正しい)
- TC-1 コメント: 「TC-3 が同一行 `>&2` 条件で別途 sweep する」(pivot 前の記述が残留、**正反対**)

review cycle 1 で code-quality reviewer が MEDIUM (current-pr) として検出。リスクは「将来のメンテナ (本リポジトリでは LLM エージェント) が TC-1 側の誤記述に合わせて TC-3 に `>&2` フィルタを追加し、fail-closed sweep が silent 弱体化する」こと。

### root cause

設計 pivot は「実装 + 直近コメント」のペアで行われがちで、**pivot 対象を参照する離れた箇所のコメント**が同期更新の対象から漏れる。pivot 前に書いたコメントは pivot 時点で既に存在しているため、「新規追加分のレビュー」の心理的スコープから外れやすい。

### 防止策

1. **pivot 時の cross-reference grep**: 設計変更した識別子 (TC 名 / 関数名 / モード名) を同一 PR の diff 全体 + 対象ファイル全体で grep し、旧設計を説明する記述が残っていないか確認する
2. **propagation scan に「説明文」も含める**: fix の伝播スキャンはコードの同型 idiom だけでなく、変更対象を説明する prose / コメントも対象にする
3. **コメントは実装の設計判断を二重記述しない**: cross-reference コメントには「TC-3 が別途 sweep する」程度の存在参照に留め、検出方式の詳細 (同一行条件 / 全行 sweep) は TC-3 側コメントに一元化する — 詳細の重複が drift 面積を生む

### helper 委譲後の cross-ref drift と reviewer 横断検出（実測）

bash 実体を helper script へ委譲した後、その実体を説明する離れた箇所の「canonical 確立先」参照が**委譲前の旧 site (command 本体) を指したまま**残る、という同系統の drift が docs でも起きる。docs 版事例は `bash-trap-patterns.md` L236 の canonical 参照に「6.0 / 6.2 の case 文実体は `wiki-lint-skipped-refs.sh` / `wiki-lint-source-refs.sh` へ移設済み」という委譲注記を 1 行追記する修正で、指摘ゼロ・1 cycle で mergeable に到達した。

注目すべきは review の副産物だった。code-quality reviewer が `_reviewer-base.md` の **Cross-File Impact Check #5 (横断検証)** を働かせ、修正対象 L236 と**同型の drift が同一ファイルの L144** (「採用 site (canonical 参照実装)」節が `wiki/lint.md ステップ 2.2 / 6.0 / 6.2 / 8.3` を列挙、うち trap/cleanup 実体は helper 側) に残存していることを発見した。これは「修正対象と同型の参照が同一ファイル内の別箇所に複数存在する」典型で、現 PR スコープ外として別 Issue (#1344) に切り出した。

要点:

- **委譲は drift の発生源**: 実体を helper へ移すと、その実体を指す参照 (canonical 確立先 / 採用 site / cross-reference コメント) はすべて潜在 drift 候補になる。委譲を完了扱いにする前に、移送対象の識別子を同一ファイル全体で grep する
- **同型 drift は単発で終わらない**: 1 箇所の stale 参照を見つけたら、同じファイル内に同型の参照節が他にないか必ず確認する (L236 を直す PR が L144 を見落とす)。reviewer の Cross-File Impact Check はこの「横の漏れ」を発掘する装置として機能する
- **スコープ判断**: 横断検出した同型 drift は、現 PR の最小スコープを守るなら別 Issue 化が適切 (#1344)。「ついでに直す」とスコープが膨らみ review 面積が広がる

### 関連する既知 anti-pattern との区別

- [fix-comment-self-drift](./fix-comment-self-drift.md): fix で書いたコメント自身が convention を破る話。本ページは**設計 pivot による同一 PR 内の記述自己矛盾**で、コメント自体は convention 準拠でも内容が実装と矛盾する
- Asymmetric Fix Transcription (対称位置への伝播漏れ): 対称な実装サイトへの fix 伝播漏れ。本ページはその**説明文 (prose) 版**にあたる

## 関連ページ

- [Fix 修正コメント自身が canonical convention を破る self-drift](./fix-comment-self-drift.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #1337 review results (cycle 1) — TC-1 コメントと TC-3 実装の矛盾を code-quality reviewer が MEDIUM で検出](../../raw/reviews/20260610T001830Z-pr-1337.md)
- [PR #1337 fix results — コメント 4 行の書き換えで解消、root cause は設計 pivot 後の cross-reference コメント追随漏れ](../../raw/fixes/20260610T002120Z-pr-1337.md)
- [PR #1343 review results — helper 委譲後の canonical 参照注記追記。reviewer の Cross-File Impact Check が同型 drift (L236↔L144) を横断検出し別 Issue #1344 化](../../raw/reviews/20260610T011729Z-pr-1343.md)
