---
title: "Asymmetric Fix Transcription (対称位置への伝播漏れ)"
domain: "anti-patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-20T18:15:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260416T173607Z-pr-548-cycle3.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T180658Z-pr-548.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T181846Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T173035Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T180001Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T181357Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T182704Z-pr-548-cycle6.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T214823Z-pr-550.md"
  - type: "reviews"
    ref: "raw/reviews/20260417T002317Z-pr-553.md"
  - type: "reviews"
    ref: "raw/reviews/20260417T003119Z-pr-553-cycle-2.md"
  - type: "fixes"
    ref: "raw/fixes/20260417T083042Z-pr-562.md"
  - type: "fixes"
    ref: "raw/fixes/20260417T083649Z-pr-562.md"
  - type: "reviews"
    ref: "raw/reviews/20260418T113250Z-pr-578.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T113520Z-pr-578.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T123731Z-pr-623.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T124128Z-pr-623.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T180231Z-pr-629.md"
tags: ["fix-cycle", "review-loop", "convergence", "propagation", "symmetric-error-handling", "contract-path-symmetry"]
confidence: high
---

# Asymmetric Fix Transcription (対称位置への伝播漏れ)

## 概要

fix を 1 箇所に適用したとき、同じパターンを持つ「対称位置」（ペア/トリオの兄弟スクリプト、同型 idiom の別 phase、相互参照の Phase 番号等）に同じ fix を伝播させ忘れる failure mode。次サイクルの review で片割れが「新規」findings として浮上し、収束サイクル数を膨張させる。

## 詳細

### 発生条件

以下のケースで発生しやすい:

1. **同型 bash idiom が複数 phase/スクリプトに存在**: 例 — `if ! cmd; then rc=$?` が `ingest.md Phase 1.3` と `init.md Phase 3.5` の両方にある。片方だけ `set +e; cmd; rc=$?; set -e` に直しても反対側に残る
2. **ペア/トリオで対称運用する兄弟スクリプト**: `wiki-ingest-commit.sh` / `wiki-worktree-commit.sh` / `wiki-worktree-setup.sh` のように同じ防御パターン（stderr tempfile 退避、`exec 9>` subshell guard、fail-fast on git error）を共有すべき。片方だけに適用すると次 cycle で reviewer が非対称を検出
3. **Phase 番号書き換え時の相互参照**: 1 箇所の Phase 番号を変えると、他 doc の参照番号も連動して直す必要がある
4. **同一 finding を 3 箇所 literal copy で維持する契約**: 例 — `pr/review.md` Phase 6.5.W.2 / `pr/fix.md` Phase 4.6.W.2 / `issue/close.md` Phase 4.4.W.2 の sentinel emit

### PR #548 での実測収束軌跡

6 cycle の review-fix ループで観測された findings 数: `21 → 17 → 2 → 7 → 3 → 0`

- cycle 3/4/5 はいずれも「前 cycle の fix が対称位置を取りこぼした」失敗で発生
- **cycle ごとに `propagation_applied: 0`** — fix 側が自動伝播を試みていない
- cross-validation (2 人以上の reviewer が独立検出) で初めて非対称が可視化された

### Detection Heuristic

fix 直後に必ず実行する:

```bash
# 同一 anti-pattern の残存を全 *.md/*.sh でスキャン
grep -rn "{anti-pattern-regex}" --include='*.md' --include='*.sh' .

# Phase 番号を変えたら参照漏れチェック
grep -rn "Phase {old_number}" --include='*.md' .
```

### Mitigation — 契約として明示化する

1. **finding 側 metadata**: reviewer は `files_to_propagate_to` に対称ファイルを明示列挙
2. **fix 側 atomic apply**: 1 つの finding に対する Edit は、列挙された全ファイルに同 commit で適用
3. **pair annotation in code**: `# keep in sync with wiki-worktree-commit.sh L215-223` のようなコメントで対称位置を埋め込む（ただし位置ドリフト耐性のため行番号ではなく関数名/セクション名で）
4. **shared lib 抽出が根本解決**: cross-script duplication は個別修正の繰り返しではなく共通 helper 抽出で解消する（PR #548 の F-05/F-06 → Issue #549）

### Cross-validation で確度を boost

同一箇所を 2 人以上の reviewer が独立検出した場合は自動的に severity を boost（triple cross-validation で HIGH に昇格）。reviewer 単独検出より信頼性が高い。

### Symmetric error handling への一般化 (PR #550 での evidence)

PR #550 cycle 3 では `wiki-ingest-commit.sh` 内で同種の `rm -f` operation が rc=0/4 経路では WARNING surface を実装していたのに対し、rc=5 経路では silent にしていた asymmetric silent-fallback を指摘された。**同一ファイル内で同種の operation (特に rm / mktemp / rev-parse 等の失敗経路) が複数分岐にある場合、全分岐で同一の WARNING/sentinel 方針に揃えるのが canonical**。分岐ごとに方針が異なると、障害発生時に部分的な診断情報しか手に入らず root cause 特定が遅れる。

### mktemp pattern 統一への拡張 (PR #553 cycle 1/2 での evidence)

PR #553 cycle 1 レビューで、`cleanup.md` Phase 2.5 内の mktemp 構文が `if ! var=$(mktemp ...); then` 系 (matched_files / state_file) と `var=$(mktemp ... 2>/dev/null) || { ... }` 系 (cycle_state / legacy) で混在している点を複数 reviewer が独立指摘。cycle 2 で統一実装が適用された。**隣接 reference との対称化 (cycle_state 系に揃える)** が優先されるケースでは、Phase 全体での統一を次 PR に分離するのが scope 管理上望ましいが、同一 Phase 内では canonical pattern に揃えるのがレビュー収束コストを下げる。mktemp は `${var:-fallback}` パターンと組み合わせるため、後者 (`2>/dev/null) || { ... }` 形式) の方が signal-specific trap 統合と整合する。

### 用語統一スコープへの拡張 (PR #562 cycle 1-3 での evidence)

PR #562 (workflow identity reference 新規追加) で asymmetric fix transcription が **ファイル内コード分岐**から **同一 blockquote 内の類義語群** に拡張して観測された:

- cycle 1: `workflow-identity.md` で `コンテキスト残量` → `context 残量` 統一。`SKILL.md` / `commands/pr/cleanup.md` / `commands/pr/review.md` の同一表現が drift として残留
- cycle 2: 上記 3 ファイルで `コンテキスト残量` を統一。同一 blockquote 内の類義語 (`コンテキスト効率` / `コンテキスト最適化` / `コンテキスト圧迫`) は手付かず
- cycle 3: 同一 blockquote 内の類義語を統一して収束

**学習**: 本 anti-pattern は「対称位置のコード分岐」だけでなく「**対称位置の用語・類義語**」にも適用される。cycle 1 で単一コミット内に文脈類義語群を列挙・一括統一していれば cycle 2-3 が不要だった。詳細な用語統一スコープ設計は [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](../heuristics/identity-reference-documentation-unification.md) 参照。

### Iteration 方式統一への拡張 (PR #578 cycle 1 での evidence)

PR #578 cycle 1 で、`plugins/rite/commands/wiki/lint.md` Phase 6.2 の partial pollution gate 実装において、**同一 Phase 内で同じ変数を iterate する複数ループが here-string と HEREDOC に分岐**している点が reviewer により独立指摘された。同型 idiom が片方のみ新形式になると、後続実装者は「どちらが canonical か」を判断できず drift が増殖する。fix では here-string 側に統一し canonical 契約を保った。

**学習**: 本 anti-pattern は「エラー処理の対称性」「用語の対称性」に続いて「**iteration 方式の対称性**」にも適用される。同一 Phase / 同一 scope 内の複数ループは、bash 構文 (here-string / HEREDOC / process substitution 等) も揃えるべきで、異なる構文が混在すると「どちらに揃えるべきか」の判断自体が判断逸脱の原因になる。canonical 選択基準は「隣接 reference (lint.md Phase 8.3 等) と同一構文」を優先する。

### 同一 doc 内 propagation scan への適用 (PR #623 cycle 2 での evidence)

PR #623 cycle 1 で docs/anti-patterns/cleanup-wiki-ingest-turn-boundary.md の「PR #611」→「Issue #611」の番号取り違えを 1 箇所修正したが、同 doc の他 2 箇所に同一 invariant (PR/Issue 番号混同) が残存し、cycle 2 reviewer が独立検出した (F-01)。加えて test fixture の assertion 数が cycle 1 fix で 14→17 に変動したが、anti-pattern doc の「4 tests / 9 assertions」記述が更新されず stale 化 (F-02) も同時に検出された。

**学習**: 本 anti-pattern は「**同一 doc 内の複数箇所に散在する同一 invariant**」にも適用される。cross-file propagation (別 file の対称位置) よりも同一 file 内の別所残存のほうが grep scope が狭く検出されにくい structural blind spot を形成する。canonical 対策:

1. **cycle 1 fix 直後に propagation scan を mandatory 化**: `grep -n 'PR #N' <file>` で同 file 内全ヒットを列挙し、修正対象を atomic に洗い出す
2. **数値参照 (assertion 数 / test 数 / line count 等) は footnote 化**: 同一値を複数箇所で literal 書きすると drift 不可避。`[^ref]` で単一 source に集約し、参照側は footnote ID のみ書く
3. **cycle 1 fix の Test Plan に "same-doc propagation scan" を explicit 追加**: reviewer が cycle 2 で独立検出する前に self-check で捕捉

### Contract-Implementation path 対称性への拡張 (PR #629 review での evidence)

PR #629 (Issue #625) で `lint.md` Phase 9.2 に「`--auto` モードの stdout は常にこの三点セットを出力する」contract を追加したが、同 file 内 Phase 1.1 (`wiki.enabled: false`) / Phase 1.3 (wiki 未初期化) の `--auto` 早期 return 経路が従来通り 6 フィールド 1 行のみを emit し、contract と実装が乖離した。prompt-engineer と code-quality の 2 reviewer が独立に同一 file:line (lint.md:151, 217) で MEDIUM 指摘として検出 (2 reviewer 合意による high-confidence finding)。

**学習**: 本 anti-pattern は「**section 内で追加された『常に X を出力する / 常に Y を満たす』契約 vs 同 section 内の全 path (normal / early-return / error-skip / disable) 実装**」の対称性にも適用される。従来の 4 拡張 (エラー処理 / 用語 / iteration / 同一 doc propagation) は「既存実装の drift」だったが、本拡張は「**新規契約宣言時に全 path が契約を満たすか verify し忘れる**」構造的盲点。canonical 対策:

1. **新規契約宣言時の path enumeration mandatory 化**: section 内の全 emit 経路 (normal path + error/skip path + early-return path + disable path) を grep で列挙し、契約充足を `grep -cF` で mechanical 検証する
2. **契約と early-return の scope 明示化**: 契約宣言の prose に「本契約は Phase X 以降の通常経路に限り、Phase 1.1/1.3 の早期 return は例外」のように明示 scope を書くか、早期 return にも同契約を適用する (どちらが canonical かは downstream parser の要求で決める)
3. **scope-irrelevant finding の follow-up Issue 化**: 本 PR scope (Phase 9.2 対応) で対応しないが contract-implementation path drift が観測された場合、Phase 5.3.0 Observed Likelihood Gate で推奨事項降格 → 別 Issue 作成 (PR #629 では Issue #630) で追跡する canonical flow が 2 reviewer 合意経由で確立

## 関連ページ

- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)
- [AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する](../patterns/drift-check-anchor-prose-code-sync.md)
- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](../heuristics/identity-reference-documentation-unification.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](./fix-comment-self-drift.md)

## ソース

- [PR #548 cycle 3 fix: asymmetric fix transcription pattern](raw/fixes/20260416T173607Z-pr-548-cycle3.md)
- [PR #548 cycle 4 fix results](raw/fixes/20260416T180658Z-pr-548.md)
- [PR #548 cycle 5 fix results](raw/fixes/20260416T181846Z-pr-548.md)
- [PR #548 cycle 3 review (2 findings, convergence)](raw/reviews/20260416T173035Z-pr-548.md)
- [PR #548 cycle 4 review results](raw/reviews/20260416T180001Z-pr-548.md)
- [PR #548 cycle 5 review](raw/reviews/20260416T181357Z-pr-548.md)
- [PR #548 cycle 6 mergeable (final lesson)](raw/reviews/20260416T182704Z-pr-548-cycle6.md)
- [PR #550 cycle 3 fix (symmetric error handling 一般化)](raw/fixes/20260416T214823Z-pr-550.md)
- [PR #553 cycle 1 review (mktemp pattern 混在指摘)](raw/reviews/20260417T002317Z-pr-553.md)
- [PR #553 cycle 2 review (mktemp 統一後)](raw/reviews/20260417T003119Z-pr-553-cycle-2.md)
- [PR #562 cycle 2 fix (統一範囲の波及漏れ解消)](raw/fixes/20260417T083042Z-pr-562.md)
- [PR #562 cycle 3 fix (同一 blockquote 内類義語統一)](raw/fixes/20260417T083649Z-pr-562.md)
- [PR #578 cycle 1 review (iteration 方式非対称指摘)](raw/reviews/20260418T113250Z-pr-578.md)
- [PR #578 cycle 1 fix (iteration 方式 here-string 統一)](raw/fixes/20260418T113520Z-pr-578.md)
- [PR #623 cycle 2 review (同一 doc 内 propagation scan miss 指摘)](raw/reviews/20260420T123731Z-pr-623.md)
- [PR #623 cycle 2 fix (footnote 化 + propagation 完了)](raw/fixes/20260420T124128Z-pr-623.md)
- [PR #629 review (Phase 9.2 contract vs Phase 1.1/1.3 early-return drift、2 reviewer 合意)](raw/reviews/20260420T180231Z-pr-629.md)
