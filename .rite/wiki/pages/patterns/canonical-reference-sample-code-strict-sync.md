---
title: "canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する"
domain: "patterns"
created: "2026-04-18T17:40:00+09:00"
updated: "2026-04-19T03:30:00+00:00"
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

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)

## ソース

- [PR #564 re-review (11th cycle)](../../raw/reviews/20260418T072254Z-pr-564-rerun.md)
- [PR #564 fix results (11th cycle)](../../raw/fixes/20260418T071459Z-pr-564.md)
- [PR #578 cycle 1 review (F-ID 衝突 / iteration 非対称)](../../raw/reviews/20260418T113250Z-pr-578.md)
- [PR #578 cycle 1 fix (F-ID 全件 grep + 最大値 +1)](../../raw/fixes/20260418T113520Z-pr-578.md)
- [PR #586 cycle 7 review (一字一句同期 3 観点の実測)](../../raw/reviews/20260419T035346Z-pr-586-cycle7.md)
