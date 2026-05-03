---
title: "canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する"
domain: "patterns"
created: "2026-04-18T17:40:00+09:00"
updated: "2026-05-03T18:46:59Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T072254Z-pr-564-rerun.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T071459Z-pr-564.md"
  - type: "reviews"
    ref: "raw/reviews/20260418T113250Z-pr-578.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T113520Z-pr-578.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T035346Z-pr-586-cycle7.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T094545Z-pr-596.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T104043Z-pr-598.md"
  - type: "reviews"
    ref: "raw/reviews/20260503T181256Z-pr-799.md"
  - type: "fixes"
    ref: "raw/fixes/20260503T181755Z-pr-799.md"
tags: []
confidence: high
---

# canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する

## 概要

reference 文書 (bash-trap-patterns.md / bash-cross-boundary-state-transfer.md 等) のサンプルコードはコピペ利用される前提のため、canonical 実装と一字一句揃っていなければ silent failure を下流に伝播させる。新規 reference を追加する際は、example を「canonical 実装 site から直接切り出す」「差分レビューで逐語照合する」を厳守する。

## 詳細

### 発生事例 (PR #564)

新規追加した `plugins/rite/commands/wiki/references/bash-cross-boundary-state-transfer.md` の Pattern 3 example で、canonical 実装 (lint.md Phase 6.0) が持っている `else rc=$?` を欠落させ、未定義 `$rc` を参照する模範例を残してしまった (F-07 検出)。reference 文書は後続実装者がコピペ origin として使うため、欠落したまま新しい site に複製されると silent regression が増殖する。

### 失敗の構造

1. 著者は canonical 実装 (lint.md Phase 6.0) を「脳内で抽象化」して reference 文書に書く
2. 抽象化の過程で細部 (`else rc=$?` 等) が "気づかず" 脱落する
3. reference を読んだ下流実装者は「reference が正」と信じてコピペする
4. 結果として canonical 実装と drift した sample が拡散する

### 対処の canonical pattern

- **切り出し原則**: reference 追加時は canonical 実装 site から「行コピー」する。抽象化・書き直しは禁止
- **差分 lint**: reference 文書と canonical 実装 site の両方を grep で発見できる anchor (例: `>>> DRIFT-CHECK ANCHOR: ...`) で明示契約し、将来的に `/rite:lint` で機械検証する
- **逐語照合**: PR レビュー時に「reference 文書の全 bash code block」と「canonical site の bash code block」を diff で突き合わせる手順を checklist 化する
- **reference 文書の example 粒度**: Minimal Working Example ではなく Complete Canonical Example (全 error handling / trap / cleanup を含む) を載せる。抜粋すると必ず抜け漏れが起きる

### 関連パターン

- **Asymmetric Fix Transcription**: 既存 site への fix を他 site に伝播し忘れるのと同型の失敗モード。本パターンは「reference ↔ canonical site」という異なる書式間での drift に特化した sub-pattern
- **散文で宣言した設計は対応する実装契約がなければ機能しない**: 「reference 文書は canonical 実装と同期しているはず」という prose-only 宣言だけでは drift 検出には不十分

### ID 採番時の grep 全件検証への拡張 (PR #578 での evidence)

PR #578 cycle 1 で reviewer が F-ID 採番の推奨値 (F-16) を提示したが、既存 F-IDs との衝突を `grep` で検証していなかった。盲信して採用すると既存の F-20 と衝突する潜在リスクがあり、fix 側で全件 `grep -oE 'F-[0-9]+' | sort -u` を経て最大値 +1 (F-21) を選択する pattern に修正された。

**学習**: reference 文書の「コード」同期だけでなく、**既存 ID / 識別子との衝突検証も canonical 同期の一種**である。reviewer 推奨値 × grep 検証の省略は、canonical 実装状態（既存 F-IDs の使用状況）との silent drift を生む。以下を習慣化する:

- 新規 ID / 識別子を採番する際は、ファイル全体を `grep` で走査して既存最大値を確定してから +1 する
- reviewer 推奨値が evidence anchor（grep コマンド出力 / 既存 IDs の列挙）を伴っていない場合は、Observed Likelihood Gate に準拠して降格扱いし、fix 側で再検証する

### 「一字一句同期」宣言は 3 観点すべてを揃えて初めて成立する (PR #586 cycle 5-7 での evidence)

PR #586 cycle 4 fix で「canonical reference (`gitignore-health-check.sh` L270-277) と一字一句揃える」とコメントで宣言したが、cycle 5-7 review で以下 3 観点の drift が段階的に検出された:

1. **rc capture 構造**: canonical は `if cmd; then rc=0; else rc=$?; fi` 形式の if-wrapper。fix 側は簡略な `var=$(cmd); rc=$?` パターンに留めた (cycle 5 F-01)
2. **コマンド引数** (`--` セパレータ等): canonical は `git add --dry-run -- <path>` と `--` 引数区切りを使用。fix 側は `--` 欠落 (cycle 7 LOW-1)
3. **変数の事前宣言**: canonical は `add_dry_out=""` / `add_dry_rc=0` を事前宣言。fix 側は欠落 (cycle 7 LOW-2)

それぞれ functional impact は軽微だが、「一字一句」を謳ったためレビューサイクルで 3 回連続境界 finding として可視化された (cycle 5 → 6 → 7)。

**学習**: 「canonical 一字一句同期」を commit message やコメントで宣言する場合、以下 3 観点すべてを揃える:

| 観点 | 具体例 |
|------|--------|
| (a) rc capture 構造 / 制御フロー | `if cmd; then rc=0; else rc=$?; fi` vs `var=$(cmd); rc=$?` |
| (b) コマンドの引数・オプション (`--` セパレータ含む) | `git add -- <path>` の `--` 有無 |
| (c) 変数の事前宣言 | `var=""` / `rc=0` などの defensive initialization |

3 観点の**いずれかでも drift していれば「一字一句同期」と主張してはならない**。代替として、「stderr 退避部分のみ揃える」「if-wrapper 構造だけ揃える」とスコープ限定を明示すれば silent over-claim を避けられる。

### scope 外 drift → 別 Issue 化 → 後続 minimal PR で解消する canonical flow (PR #596 / PR #598 での evidence)

PR #586 cycle 7 で残った観点 (b) `-- ` 引数区切りの drift は、PR #586 の scope ではなく**別 Issue #587 として切り出され**、後続 PR #596 で +1/-1 の minimal diff (literal 1 文字 ` -- ` 追加) として解消された。review は 0 findings / 1 サイクルで mergeable 判定。

同じ PR #586 で残っていた観点 (c) `dry_run_out=""` / `dry_run_rc=0` の事前宣言欠落も、**別 Issue #588 として切り出され**、後続 PR #598 で +2/-0 の minimal diff (2 行の defensive initialization 追加) として解消された。review は 0 blocking findings / 1 non-blocking (PR 本文の表記ゆれ) / 1 サイクルで mergeable 判定。canonical reference (`gitignore-health-check.sh` L270-277) との 8 行構造同期を両レビュアーが Read ツールで実測確認し、bash `if var=$(cmd); then ...` による assignment 保証を踏まえた上での defense-in-depth な事前宣言として位置付けた。

PR #596 / #598 の 2 連続で観点 (b)(c) が minimal PR により完全解消され、「canonical 一字一句同期 3 観点のうち scope 外残留分を個別 Issue + minimal PR で順次解消する」flow が 2 回実測された (3 観点 = (a) rc capture / (b) 引数 / (c) 事前宣言 のうち (a) は PR #586 cycle 5 本体で解消済み、(b)(c) は後続 minimal PR で解消)。

**学習**: canonical 一字一句同期の 3 観点のうち 1 つだけが残留した場合、同 PR 内で無理に fix を広げるより「現 PR の scope を保ち残り観点を別 Issue 化 → 後続 PR で minimal fix」の flow が以下の理由で優位:

- scope expansion による review-fix サイクルの肥大化を避けられる
- minimal diff (1-2 行) は sibling site grep 照合と機械検証 (`grep -n` で 1 行一致確認) で short-time / high-confidence レビューが可能
- Issue 本文の「完了条件」として観点を個別に明文化することで、後続 PR の成否判定が決定的になる

参考フロー: PR #590 (別例、+4 lines) と同型の「極小対称化 PR」パターンの appilcation。`極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる` heuristic (heuristics) と組み合わせて運用するのが canonical。

### canonical reference は caller の precondition 契約まで含めて完成させる (PR #799 での evidence)

PR #799 で新規 canonical reference (`broken-ref-resolution.md`) を追加し `realpath -m` ベースの相対パス解決 sample bash を載せたが、reference の sample が要求する precondition 変数 (`pages_list_normalized` / `wiki_root` / `page_path` 絶対パス) を caller (`lint.md` Phase 7.x) で生成する Phase が存在せず、両 reviewer が cycle 1 で CRITICAL 指摘した。reference 単独は「完成形」に見えるが、caller 側の bash 実行コンテキストでは実行不能な broken reference になる。

**学習**: canonical reference を新設する際は **reference 単独の完成度** ではなく **caller (= reference を呼び出す既存契約) と reference のサンプルが要求する precondition 変数の整合** までを完成条件とする。具体的には:

| 観点 | 検証手順 |
|------|----------|
| (a) reference の bash sample が依存する変数 / 関数 / 関数 import | sample 内の `${VAR}` / `func_name` を全列挙し、caller 側で生成 / import される箇所を grep で確認 |
| (b) reference の precondition (「呼び出し前に X が確定している必要」) | caller 側の Phase 番号 / 行範囲で X が generate される段階を明示 |
| (c) reference の sample exit code / 戻り値の caller 側消費契約 | caller 側で sample 戻り値を受け取り条件分岐 / fail-fast する箇所が存在 |

3 観点いずれかが欠落していれば「reference は完成」と主張してはならない。reference の bash sample は **caller の既存契約と動作整合する範囲でのみ canonical** であり、precondition を caller 側で勝手に invent するのを禁じる契約まで含めて初めて「同期」が成立する。

「呼び出し側責務」「同様」のような prose 委譲表現で caller 側実装を後回しにすると、次 cycle で PARTIAL fix として再指摘される (詳細は [委譲表現を含む fix は次サイクルで PARTIAL fix として再指摘される](../anti-patterns/delegation-phrase-induces-partial-fix.md))。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)
- [委譲表現を含む fix は次サイクルで PARTIAL fix として再指摘される](../anti-patterns/delegation-phrase-induces-partial-fix.md)

## ソース

- [PR #564 re-review (11th cycle)](../../raw/reviews/20260418T072254Z-pr-564-rerun.md)
- [PR #564 fix results (11th cycle)](../../raw/fixes/20260418T071459Z-pr-564.md)
- [PR #578 cycle 1 review (F-ID 衝突 / iteration 非対称)](../../raw/reviews/20260418T113250Z-pr-578.md)
- [PR #578 cycle 1 fix (F-ID 全件 grep + 最大値 +1)](../../raw/fixes/20260418T113520Z-pr-578.md)
- [PR #586 cycle 7 review (一字一句同期 3 観点の実測)](../../raw/reviews/20260419T035346Z-pr-586-cycle7.md)
- [PR #596 review (観点 (b) `-- ` 引数区切り残留を別 Issue #587 → minimal PR で解消した成功例)](../../raw/reviews/20260419T094545Z-pr-596.md)
- [PR #598 review (観点 (c) `dry_run_out=""` / `dry_run_rc=0` 事前宣言残留を別 Issue #588 → minimal PR で解消した成功例)](../../raw/reviews/20260419T104043Z-pr-598.md)
- [PR #799 review (cycle 1 — reference precondition 契約乖離 CRITICAL)](../../raw/reviews/20260503T181256Z-pr-799.md)
- [PR #799 fix (cycle 1 — reference 単独修正、cycle 2 で PARTIAL 指摘)](../../raw/fixes/20260503T181755Z-pr-799.md)
