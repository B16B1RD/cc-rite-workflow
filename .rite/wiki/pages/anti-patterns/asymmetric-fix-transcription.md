---
title: "Asymmetric Fix Transcription (対称位置への伝播漏れ)"
domain: "anti-patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-29T13:33:00+09:00"
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
  - type: "reviews"
    ref: "raw/reviews/20260420T185124Z-pr-631.md"
  - type: "reviews"
    ref: "raw/reviews/20260420T225458Z-pr-631.md"
  - type: "fixes"
    ref: "raw/fixes/20260420T224940Z-pr-631.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T030627Z-pr-636-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T033906Z-pr-636-cycle-4.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T031214Z-pr-636-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T074416Z-pr-659.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T081422Z-pr-659-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T165246Z-pr-661.md"
  - type: "fixes"
    ref: "raw/fixes/20260425T165546Z-pr-661.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T171440Z-pr-661-cycle-4.md"
  - type: "reviews"
    ref: "raw/reviews/20260426T080650Z-pr-677.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T081122Z-pr-677-cycle-1.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T081939Z-pr-677-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260426T233323Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T233931Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260427T050731Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T050216Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T051514Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T194949Z-pr-708.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T200123Z-pr-708-cycle-2.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T200424Z-pr-708-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T234537Z-pr-711.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T235452Z-pr-711-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260429T000301Z-pr-711-cycle4.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T234911Z-pr-711.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T235605Z-pr-711-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260429T000017Z-pr-711-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260429T041942Z-pr-713.md"
tags: ["fix-cycle", "review-loop", "convergence", "propagation", "symmetric-error-handling", "contract-path-symmetry", "pipeline-step-addition", "three-site-symmetry", "propagation-scan-pattern-coverage", "split-config-drift", "enumeration-multi-location-drift", "writer-reader-fallback-symmetry", "severity-extension-cross-file", "same-file-adjacent-line-drift", "caller-side-strictness-drift"]
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

### Pipeline 新規 step 追加時の 4 site 対称更新契約 (PR #631 review/fix での evidence)

PR #631 (`/rite:lint` への backlink-format check 追加) の cycle 1 review で 2 CRITICAL findings が 4 reviewer (prompt-engineer / code-quality / error-handling / security) により独立検出された:

1. **`--quiet` flag 契約 drift**: 新規 `backlink-format-check.sh` の `--quiet` 実装が summary line を suppress する一方、既存 Phase 3.8/3.9 scripts (`wiki-growth-check.sh` / `gitignore-health-check.sh`) の `--quiet` は summary を必ず emit する契約。invocation 側で `--quiet` を付けて呼び出したため、lint.md prompt の regex count 抽出が常に failure → silent 0 表示の silent failure 経路を形成。**「同じパターンで書いた」だけでは契約 drift を発見できない** — peer script の flag 実装を runtime で確認する必要がある
2. **Phase 4.1 appendix paragraph 増設漏れ**: 既存 6 種 lint check (Drift / Bang-backtick / Doc-heavy / Wiki growth / Terminal output / Gitignore health) は Phase 4.1 に「warning/error 時に findings を appendix で表示する」段落を持つが、新規 Phase 3.10 の追加だけで Phase 4.1 への追記を忘れた。result mapping table と display は **対称的に新設すべき**

cycle 2 re-review では fix commit `2cd475e` (11 lines minimum diff) が 2 reviewer 独立承認で 0 findings 収束。fix 側観察: 最小差分 (`--quiet` 削除) と sibling 6 箇所 appendix paragraph の **word-for-word 整合** により 1 cycle で収束。

**学習**: 本 anti-pattern は「pipeline (lint / review / sprint 等) に **新規 step / check を追加する時の N site 対称更新契約**」に拡張される。lint-pipeline の場合、新規 check 追加 PR は以下 **4 site** を対称的に同期更新しなければならない:

1. **Phase 3.X**: 新 check の手順本体 (condition / skip / execution table / result handling / recording の 5 要素 sub-section)
2. **Phase 4.1 appendix display**: warning/error 時に findings を visual output に反映する段落
3. **Phase 4.3 summary table**: 集計表への行追加
4. **Note 段落 policy 列挙**: 全 check の policy 一覧

canonical 対策:

1. **review checklist mandatory 化**: 新規 lint/pipeline step 追加 PR の review checklist に「(a) Phase 3.X 手順 / (b) Phase 4.1 appendix / (c) Phase 4.3 summary row / (d) Note policy 列挙」の 4 site mechanical verification (grep による同数確認) を必須化
2. **peer flag 契約の runtime 検証**: 新規 script が既存 peer script と「同じ pattern」を採用する場合、**実際に invocation して stdout/stderr を grep で確認** する (`bash new-check.sh --quiet | grep -c 'Total'` で summary emit 有無を mechanical 検証)。copy-paste 同形性は契約一致を保証しない
3. **fix は最小差分 + sibling word-for-word 整合が canonical**: 契約違反 fix は「invocation 側最小修正 (`--quiet` 削除)」と「script 側契約整合 (summary emit 保証)」の 2 択のうち reviewer 推奨に従い最小差分を採る。新 appendix paragraph は sibling 6 箇所のテンプレートに word-for-word 整合させる (PR #631 cycle 2 で 11 lines minimum diff + sibling word-for-word consistency が 2 reviewer 独立承認で 0 findings 収束を実測)
4. **fix 側 lesson の symmetry**: script 側の contract 違反 (`--quiet` で summary suppress) と invocation 側の不整合 (`--quiet` を付けて呼び出し) は双方で起こりうる。どちらを修正するかは scope/最小差分/canonical 整合性で判断する (PR #631 では invocation 側削除を採用)

### 3-site 対称セット drift の N 回目再発 (PR #636 cycle 1-4 での evidence)

PR #636 (Issue #634 = implicit stop regression の 8 回目累積対策) の cycle 1-4 で、「1 箇所の fix が他 2-3 箇所の sibling site に伝播しない」パターンが複数箇所で再発した:

- **HINT bash 例の path prefix 非対称** (cycle 1 F-12 → cycle 2 F-01 HIGH): stop-guard.sh の `cleanup_pre_ingest` / `create_post_interview` / その他 phase の HINT bash 例 (L310 / L325 / L331) で 1 箇所だけ path prefix を短縮し、他 2 箇所と drift
- **TC-634-A/B/C の対称性不徹底** (cycle 1 F-07 → cycle 2 F-06 MEDIUM): cycle 1 で TC-634-B のみに fresh_ts fallback を追加、TC-634-C と create_interview case arm に伝播漏れ
- **Architectural fix の sub-skill 側未適用** (cycle 3 → cycle 4 HIGH x2): cycle 3 で `--preserve-error-count` flag を create.md (orchestrator) + stop-guard HINT の 2 site に適用したが、**create-interview.md (sub-skill) の Pre-flight + Return Output re-patch という symmetric 2 site への伝播漏れ**。DRIFT-CHECK ANCHOR コメントを cycle 3 で追加したにもかかわらず anchor 自身が片方向 (orchestrator 側のみ) で、sub-skill 側には未配置

**学習**: 本 anti-pattern は累積対策 N 回目 PR (特に 5 回目以降) で頻度と severity が両方 escalate する。3-site 以上の対称セットは 1 箇所修正時に必ず grep で sibling 全列挙 + atomic 修正が必須。DRIFT-CHECK ANCHOR を配置する場合は **anchor 自身も全 sibling site に対称配置** しなければ片方向 drift を防げない。詳細な cumulative-defense PR の quality signal 基準は [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md) 参照。

### 5 sister sites 中 1 site のみ canonical 化漏れ + その後の skip guard 連鎖 drift (PR #659 cycle 1-4 での evidence)

PR #659 (Issue #658 = `/rite:pr:cleanup` 完了後の Projects Status 停留 regression の根本対策) は inline GraphQL+gh project の 3 段 pipeline を `projects-status-update.sh` への共有 script delegate に置き換える refactor。複数 cycle に渡って同型 drift が連鎖した:

- **cycle 1 review**: 6 つの delegate site (`cleanup.md` 経由 `archive-procedures.md` Phase 3.2 / 3.7.2.1, `ready.md` Phase 4.2, `close.md` Phase 1.3.3 / 4.2 / 4.6.3) のうち、1 箇所のみ `failed)` で `*)` catch-all なし、`|| status_json=""` fallback 欠落、jq の `2>/dev/null` 抑制欠落 — 4 sister sites と byte-for-byte で drift。3 reviewer (prompt-engineer / code-quality / error-handling) が独立検出
- **cycle 3 fix (本 PR fix)**: drift していた `archive-procedures.md` Phase 3.2.2 skeleton を 4 sister sites と byte-for-byte 整合させた
- **cycle 4 review**: cycle 3 fix が完了した Phase 3.2.2 において、別観点の guard (「related Issue が特定できない場合」の skip clause) が欠落していたことが新たに surface。`ready.md` Phase 4.2 line 325 が両 guard (`projects.enabled: false OR no related Issue`) を持つのに対し、`archive-procedures.md` Phase 3.2 は `projects.enabled` 単独 guard だけ — 本 PR base commit (9ba5249) で inline → delegate refactor 時に元の `If a related Issue has been identified:` wrapper guard が削除され、新文に片方の clause しか残らなかった経路。同 file 内の Phase 3.6.1 (line 305) と Phase 3.7.2.1 (Phase 3.7 implicit guard 経由) は別ロジックで保護されていたため drift が目立たず、3 cycle にわたる reviewer も見落としていた structural blind spot

**学習**: 本 anti-pattern は「**1 PR 内での連鎖 drift fractal**」として再定式化される。inline → delegate refactor で wrapper 文を解体する際、wrapper が複数の skip 条件 (config check + state check + その他) を持つ場合、新文への移行で片方を落とす経路がある。最初の review-fix サイクルで 1 種類の drift (本件: defensive shape の byte-for-byte 不一致) を解消した直後の next cycle で、別観点の drift (本件: state check guard の欠落) が surface する fractal pattern。canonical 対策:

1. **refactor 前の guard 条件 enumeration mandatory 化**: wrapper を解体する前に、wrapper が持つ全 guard 条件 (`If A AND B AND C has been identified:` 等) を箇条書きで列挙し、新文への移行で各条件をどう扱うか (preserve / split / drop) を 1 行ずつ checklist 化する
2. **sibling site との side-by-side diff 検証**: ready.md / close.md / archive-procedures.md の同種 phase が同種 guard 構造を持つ場合、refactor 後に 3-way side-by-side diff を取り、guard 条件が byte-for-byte 整合しているかを mechanical verification する
3. **連鎖 drift fractal の cycle escalation 認識**: 同種 refactor PR で cycle 1 で defensive shape drift、cycle 2 で guard 条件 drift、cycle 3 で reference drift と段階的に surface する場合、cycle 1 fix 時点で「他観点の drift も同 site に潜む可能性が高い」と認識し、追加の grep / 全 guard 条件 enumeration を mandatory 化する。本 anti-pattern は単独 cycle ではなく 1 PR 全体の review-fix loop 履歴で観測する fractal pattern として認識する

### PR #661 (Issue #660) で実測された Propagation scan pattern coverage 不足

PR #661 cycle 2 で `cleanup.md:1674` の hardcoded line-number reference (`(line 1659, 1680)`) を structural reference (`wiki/ingest.md Phase 9.1 Step 3` 等) に修正したが、cycle 3 review で **同型 drift が cycle 1 で同時導入された create-interview.md:605 にも存在**することを cross-validation で発見。具体的には:
- `本セクション直前の line 588 / 597 caller HTML inline literal も --active true を含む 4-arg symmetry に揃え済み`
- `create.md:580 / create-interview.md:22 の DRIFT-CHECK ANCHOR と pair 同期する`

**cycle 2 propagation scan が見落とした原因**: cycle 2 fix の scan logic は `(line N, M)` parenthesized form を grep していたが、create-interview.md:605 は **散文形式**の hardcoded reference を含むため pattern が異なり検出できなかった。

**canonical 拡張**: drift-check-anchor lint pattern を以下の **5 種表記すべて**に対応させる:

| 表記形式 | 例 |
|---------|------|
| `(line N, M)` parenthesized form | `(line 1659, 1680)` |
| `(L<num>)` short form | `(L156-160)` |
| `<file>:<num>` colon form | `cleanup.md:1674` |
| `本セクション直前の line N` 散文形式 | `本セクション直前の line 588 / 597` |
| `Line <num>` capitalized form | `Line 605 を参照` |

**cross-validation の威力**: create-interview.md:605 の 散文形式 line-number reference は単独 reviewer なら見逃した可能性 (LOW Confidence) だが、prompt-engineer + code-quality の 2 名が独立に同じ問題を発見し、Phase 5.2 cross-validation で High Confidence + severity boost (LOW + MEDIUM → MEDIUM) として確定。本 PR が解決しようとしている root cause (silent 単一障害点) と、cycle 2 / cycle 3 で発見された finding は、共に「文書間 / 文書内の reference drift」という同型構造で、self-meta drift の典型例。

### Split-config drift (project ↔ template) と hook 列挙の multi-location drift (PR #677 cycle 1-4 での evidence)

PR #677 (Issue #672 = `.rite-flow-state` multi-state Decision Log Phase 1) で 2 つの asymmetric-fix-transcription 派生形が観測された:

**1. Split-config drift (project ↔ template)** — cycle 1 P3 + cycle 2 F-05:

プロジェクトローカル `rite-config.yml` で `flow_state.schema_version: 2` を追加したが、`plugins/rite/templates/config/rite-config.yml` (template) への反映を忘れた。新規プロジェクト bootstrap (`/rite:init`) 時に template default が drift する silent regression。さらに cycle 2 で template config への配置箇所も drift: Active セクションに置くべきなのに **Advanced marker 配下に commented-out で配置** → `/rite:init` 生成時に omit される。

**2. Hook 列挙の multi-location drift** — cycle 2 F-02 + cycle 4:

概要 (L6) の hook list を 5 hooks に updated したが、他 4 箇所が 4 hooks のまま残った。cycle 4 で hooks.json を grep evidence として再評価したところ、`phase-transition-whitelist.sh` の library 性誤認 + `session-end.sh` 漏れで全 6 箇所が再 drift していたことが判明。design doc の hook list を SPEC-OVERVIEW セクションで一度定義し、他は参照のみにする方が drift 防止になる。

**学習**: 本 anti-pattern は (a) **project local config と plugin template の split-config drift** および (b) **同一 doc 内の列挙系 (hook list / field list) の multi-location drift** にも適用される。canonical 対策:

1. **Split-config の対称更新**: project local config (`rite-config.yml`) を変更する PR は **同 commit で plugin template (`plugins/rite/templates/config/rite-config.yml`) も更新** する。意図的な scope separation で template 更新を follow-up にする場合は PR description で明示し、後続 Issue を起票する
2. **template config 配置 semantics の明文化**: Active セクション (Advanced marker の上) と Advanced commented-out セクションは `/rite:init` 生成時の挙動が異なる (前者は生成、後者は omit)。template README / convention で配置 semantics を明文化し、新規 schema 追加時の判断基準を残す
3. **列挙系は registration ファイルを単一 SoT に**: hook 列挙は `hooks.json`、command 列挙は `plugin.json`、field 列挙は `jq -n create` を SoT として参照する。design doc は SoT 参照を inline 注釈 (`(grep evidence: hooks.json L42)`) として残す。詳細は [Design doc は現 HEAD の SoT を verify してから書く](../heuristics/design-doc-current-head-verification.md) 参照
4. **Library vs hook の区別**: SOURCED library は registered hook と意味が異なる。hook 列挙では `hooks[]` array を SoT とし、library は除外する旨を Note 化する

### Writer/Reader fallback symmetry への拡張 (PR #688 cycles 1-11 での evidence)

PR #688 (multi-state-aware flow-state read helper) で本 anti-pattern が **helper 経由 caller migration の writer/reader 非対称** に拡張されて 38+ cycle にわたり繰り返し observation:

- **cycle 1**: reader (`state-read.sh`) で `set -euo pipefail` + grep no-match の silent kill を `|| v=""` で defensive 吸収。writer (`flow-state-update.sh:_resolve_schema_version`) は `local v=$(...)` の `local` builtin mask で偶然救われていた非対称 → cycle 3 で writer 側にも対称化。詳細: [function 内 `local v=$(...)` と top-level `v=$(...)` の `set -e` 伝播差](./bash-local-vs-toplevel-pipefail-asymmetry.md)
- **cycle 11**: cycle 10 commit が「F-02 HIGH AC-4 caller migration」を謳いながら、**同一ファイル同一関数内 line 72 の同型 skip-check が migration から漏れていた** 自己矛盾 (partial migration の典型例)。同一関数内の同型パターンは grep で全数確認する必要がある
- **cycle 29-32 (writer/reader fallback)**: state-read.sh は per-session→legacy fallback を実装するが flow-state-update.sh の `_resolve_session_state_path` は持たなかった非対称が AC-4 reproduction scenario の silent regression の根本原因 (28 cycle 経ても empirical 再現で初顕現)。reader と完全対称な fallback (per-session 不在 + legacy 存在 → legacy にフォールバック) を writer に追加。「対称化」claim と実装の strict diff 比較 verification discipline が必須

**学習**: helper 経由化リファクタの caller 列挙では、(a) **同一ファイル内の同型 pattern を全数 grep で確認** + (b) **commit message の claim と実装の strict diff 比較** + (c) **writer / reader 双方の fallback path を symmetric に確認** の 3 段階を必須化する。特に "対称化" を claim する commit は、reader 側の guard (`[ ! -s ]` size guard 等) を writer 側で literal rep しているか strict 比較する。詳細は [`2>&1` と `2>&1 | head -N` で sentinel/exit code が silent suppression される](./stderr-merge-silent-sentinel-suppression.md) も参照。

### Writer 中核 sweep 責務 + Documentation count grep evidence 同期 (PR #688 cycle 42 累積 14 回目での evidence)

PR #688 cycle 42 (累積 14 回目 PR の 42 cycle 目) で本 anti-pattern の writer/reader 対称化 doctrine が、cycle 38 F-06 で reader 側 (`state-read.sh`) に確立した「mktemp 失敗時 3 行 WARNING」「helper WARNING pass-through」「signal-specific 4-line trap」の 3 pattern が writer 中核 4 箇所 (`flow-state-update.sh:269/323/385/324`, `state-read.sh:137 + flow-state-update.sh:168`) に未到達のまま merged されかけた状態が cycle 42 review で初検出された。同 cycle で multi-location undercount 再発 (`workflow-incident-emit-protocol.md` L56/L80 の「15 invocation sites」が `cleanup.md` 3 sites を見落とし → 実測 18 sites / 4 files) も同時に observed。

**学習**: 累積対策 PR で writer/reader 対称化 doctrine を **declaration として打ち立てる cycle** で、その doctrine が writer 中核の **既存箇所** (新規追加した箇所だけでなく previously-shipped 箇所) に対しても同 PR 内で **全件 sweep される責務** がある。「reader 側に新 pattern を導入した」cycle と「writer 側で既存箇所への横展開を完遂する」cycle が分離していると、merge 後に writer 側 silent regression が残留する。canonical 対策:

1. **reader 側 fix 直後の writer 全件 sweep mandatory 化**: reader (`state-read.sh` 等) に 3 行 WARNING / signal-specific trap / pass-through 等の新 pattern を導入したら、**同 PR 内で writer 中核 (`flow-state-update.sh` 等) の同型 pattern 箇所を全数 grep で列挙** + 同型 pattern を **同 commit で対称適用** する。reader 単独 PR + writer follow-up PR の 2 段運用は writer 側 silent regression を merge 後に残す経路となる
2. **Documentation の invocation site count は grep evidence ベースで literal SoT と同期**: `workflow-incident-emit-protocol.md` の「N invocation sites across M files」のような literal count claim は、**該当 sentinel emission 行を grep evidence (`grep -rn` の matched count) で再評価** してから書く。記憶ベースの「14 sites」「15 sites」claim は cleanup.md / archive-procedures.md / 等の派生 site が PR 累積で追加されるたびに drift する典型箇所
3. **N site claim は drift 検出アンカーとして併用**: 「15 invocation sites」を literal で書く場合、grep verification 結果を inline 注釈 (`(grep evidence: workflow_incident= の matched count)`) で残し、後続 reviewer が `grep -rcF 'workflow_incident=' --include='*.md' --include='*.sh' .` で再検証可能にする。numeric claim 単独は次の sites 追加で silent drift する
4. **Self-referential learned 節 vigilance**: cumulative-defense PR (5+ 回目) では「learned 節で言及した anti-pattern を同 commit 内で再演する」self-referential drift が頻発する (詳細は [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md) 参照)。learned 節を書いたら **同 commit の全 file diff を再 grep** して learned 節違反を pre-merge gate で捕捉する

### Severity 等級拡張時の同ファイル内 5 箇所 + cross-file 5 種類同期 (PR #708 cycle 1-2 での evidence)

PR #708 (`severity-levels.md` に COMMENT_QUALITY 軸 + LOW-MEDIUM 等級追加) で本 anti-pattern が **severity 等級の拡張** という運用層 invariant に拡張されて 4 cycle 観測:

- **cycle 1 review (HIGH 1件)**: 同一概念 (Hypothetical Exception Categories の 4 reviewer 名) が SoT (`_reviewer-base.md`) と severity-levels.md と Category 表で異なる表記 (`devops infra` vs `devops` vs `Infrastructure`) を持つ cross-file consistency drift。検出は cross-file grep で機械的に可能だが、3 ファイル間の表記等価性は手動同期が必要
- **cycle 1 review (HIGH 1件)**: agent file (`tech-writer-reviewer.md`) に Detection step (Step 5.5) を追加した際、対応する skill checklist (`skills/reviewers/tech-writer.md`) に self-audit エントリを追加し忘れる Detection-checklist sync 漏れ。reviewer agent file (Detection Process) と skill file (Self-audit Checklist) は対応関係にあり、片側のみの追加は self-audit pass 経路を silent skip させる
- **cycle 2 review (MEDIUM 2件 = cycle 1 fix で導入された regression)**: 概要表に新 severity level (LOW-MEDIUM) を追加しても、同ファイル内の Severity Levels 表 / Impact × Likelihood Matrix / Evaluation Criteria flowchart に対応する分岐を追加しないと self-consistency 違反になる。cycle 1 fix 時に「概要表のみ追加」したことで cycle 2 で新たに同ファイル内 5 箇所 (Severity Levels 定義表 / Impact × Likelihood Matrix / Evaluation Criteria flowchart / Evaluation 表 / Impact 軸を列挙する他箇所) の同期漏れが surface した

**学習**: 本 anti-pattern は「**severity / enum 等の運用 invariant の同ファイル内多箇所 + cross-file 派生** への対称更新契約」にも適用される。同ファイル内 5+ 箇所と cross-file 5 種類 (write spec / JSON schema / read parser / extract regex / measure dict) の合計 10+ sites を atomic に同期しないと silent severity fallback 経路が成立する。canonical 対策:

1. **概要表追加だけで終わらせない sub-checklist mandatory 化**: severity 等級 / enum を**追加する** PR は、概要表 update を 1 step とし、その直後に「同ファイル内 (Severity Levels 表 / Matrix / flowchart / Evaluation 表 / 列挙箇所) 5+ 箇所」「cross-file (write spec / JSON schema / read parser / extract regex / measure dict) 5 種類」の合計 10+ sites を grep で列挙してから commit する
2. **agent file ↔ skill file 対応関係の grep verification**: `agents/{name}-reviewer.md` の Detection step / Cross-File Impact step を追加する PR は、対応する `skills/reviewers/{name}.md` の Self-audit Checklist にも対称的にエントリを追加する。grep で `Step N.M` の存在を両 file で確認する
3. **Inline annotation → blockquote pattern**: Procedure / 手順説明に長文注釈を追加する際は、本文行末に packed せず next-line `> **Note**: ...` blockquote 形式で分離する。SoT への back-reference link も併せて追加することで根拠 traceability を確保 (cycle 2 fix で実測)
4. **Numerical claim factual check**: 「N 個に細分化」のような具体的数値主張を inline 補足に書く際、SoT 実態 (1:1 マッピング vs N:1 マッピングの分布) と数値が一致しているかを必ず check する。一致しない場合は数値を排して定性的説明に置換する (cycle 2 fix で実測)

詳細な severity 拡張時の closed-loop 6 段階 verification は [Severity 等級拡張は read/write/parse/measure の closed-loop 6 段階を verify する](../heuristics/severity-extension-closed-loop-verification.md) 参照。

### 同一ファイル内・隣接行の enumeration drift と caller 側 strict 化 drift (PR #711 cycle 1-3 での evidence)

PR #711 (`comment-update(scope)` action-type 追加) で本 anti-pattern が 4 cycle で段階収束し、2 種類の新 sub-pattern を実測:

- **cycle 1 review (CRITICAL 1 + HIGH 4 + MEDIUM 1)**: SoT (`contextual-commits.md` Action Types テーブル) のみ更新し、6 ファイル以上の caller 側 enumeration コピー (`recall.md` Validate / regex / コメント / サマリー、`implement.md` / `team-execute.md` / `pr/fix.md` Output rules、`i18n/{ja,en}/issue.yml` `issue_recall_invalid_action`、`contextual-commits.md` Queryability grep 例) を未同期で残した古典的 cross-file enumeration drift。発見の決定的要因は「`/rite:issue:recall` regex から `comment-update` を silent drop する」UI レベル破綻の trace
- **cycle 2 review (HIGH 3件)**: cycle 1 fix で `Output rules` enumeration 行 (L696/L369/L3090) を是正したが、**同一ファイル内・3 行上の `Filter to 10-line limit` trim order 行** (L693/L366/L3087) は 5 要素のまま残った。「同形 enumeration が同ファイル内に複数箇所 (隣接 / 3-5 行違い) に存在する」場合、ファイル単位 grep でも見落としやすい新 sub-pattern (**same-file adjacent-line drift**)。さらに `pr/fix.md` の Phase 3.2.1 Root Cause Gate との論理矛盾を併発: trim order に root-cause が無いため LLM が 11 行超 commit body の trim 時に root-cause 行を最初に切り捨てて Gate が自己崩壊する経路
- **cycle 3 review (HIGH 1件)**: cycle 2 fix で `pr/fix.md` L3087 trim order に追加した rationale 注記 (`MUST retain at least one root-cause(scope): line`) が SoT (`contextual-commits.md` L145) の permissive 表現 (`してよい`) より stricter で、Gate L3145-L3149 の 3 通り OR 通過条件 (`root-cause(scope)` action line / `decision(scope)` のテキスト中で root cause 明示 / 自由記述 `Root cause:` 段落) と矛盾する **caller-side strictness drift**。「caller 側で SoT より厳しい契約を導入する」自己 introduce drift で、cycle 4 で 0 件確定するまでの 4 cycle 段階収束を要した

**学習**: 本 anti-pattern は以下 2 種類の sub-pattern にも拡張される:

1. **Same-file adjacent-line drift**: 同形 enumeration が**同一ファイル内に 3-5 行違いの近接位置**に複数存在する場合、ファイル単位 grep では片方を更新した時点で「該当 enumeration を見つけた」と認識し、隣接の同型 enumeration を見落とす。canonical 対策: enumeration を repeat する **全箇所** を `grep -n` で行番号付き列挙し、SoT 行と caller 行の **行レベル diff チェック** で 1:1 対応を確認してから commit する
2. **Caller-side strictness drift**: SoT が permissive 表現 (`してよい` / `prefers`) で記述している契約を caller 側で `MUST` / `mandatory` として強化すると、Gate / 通過条件 / API 契約の正規定義と矛盾する自己 introduce drift が発生する。canonical 対策: caller 側で SoT より strict な制約を新設する場合、(a) SoT を先に同 strict に更新する、または (b) caller 側の rationale 注記を SoT を**補足する形** (e.g., `prefers ... as the canonical pass signal — other pass forms also satisfy the gate`) に留める。**MUST / mandatory への強化は禁止**

3 段階収束 (cross-file → file 内隣接 → rationale 強度) は 4 cycle 通じて drift class が**より細かい粒度**へ移動するパターン。各 cycle で 1 つの drift class を集中是正することで段階的に解消可能だが、cycle 1 で「同一ファイル内・隣接行も同時に grep する」習慣があれば cycle 2 を回避でき、cycle 2 で「rationale 注記は SoT を補足する形のみ許可」の sub-rule を意識していれば cycle 3 を回避できた。

### 累積対策 PR の cycle 4 follow-up としての cross-file impact 同期 (PR #713 cycle 1-2 での evidence)

PR #713 (PR #708 = LOW-MEDIUM first-class 化 cycle 4 review で発見された 9 件 cross-file impact (F-20〜F-28) を follow-up で同期した PR) で本 anti-pattern が **「累積対策 PR の cycle 4 で発見された cross-file impact が、原 PR ではなく follow-up PR で別管理される」運用層に拡張** されて 2 cycle で収束 (`3→0`):

- **元 PR #708 cycle 4 の発見**: severity 等級拡張 (LOW-MEDIUM 追加) の同ファイル内 5 箇所同期は cycle 1-2 で解消したが、**cycle 4 で reviewer が cross-file 9 sites の追加 drift を発見** — review.md Phase 5.3.0 demotion_destination spec、extract-verified-review-findings.sh docstring、measure-review-findings.sh JSON 例 + reviewer_row_re regex (4→5 numeric column 拡張)、severity ordering 9 箇所 (assessment-rules / fix-relaxation-rules / fact-check / fix.md)、prompt-engineer-reviewer.md 等級 hardcode、13 reviewer skill files の particle 統一 (`Whitelist 外造語` → `Whitelist 外の造語`)、review-result-schema.md alias 検証注記。**原 PR #708 ではなく follow-up PR #713 で別 Issue (#709) として処理される運用** が観測された
- **PR #713 cycle 1 review (HIGH×2 + MEDIUM×1)**: F-20〜F-28 のうち主要修正は適用したが、**cycle 1 fix 自身が新たな cross-file 4 値表記を遺した**。具体的には review.md の demotion_destination spec を 5 値化したが、assessment-rules.md の Priority mapping / review.md の他 2 箇所が依然 4 値表記のままで、F-20 と矛盾する状態。**累積対策 PR の follow-up cycle でも本 anti-pattern が同型再発する** ことを示す
- **PR #713 cycle 2 (mergeable, 0 件)**: cycle 1 指摘 + 内部一貫性 1 件すべて修正で完了。`同ファイル内 5+ 箇所 + cross-file 5 種類` の同期契約 (PR #708 の learning) を 9 finding に対して再適用することで 2 cycle で収束

**学習**: 累積対策 PR (例: PR #708 = LOW-MEDIUM first-class 化) の **cycle 4 以降で発見された cross-file impact** は、原 PR が既に多 cycle を経て収束済みのため、別 Issue + follow-up PR で処理されることが多い。このとき:

1. **Follow-up PR でも本 anti-pattern が同型再発する**: 「累積対策」自体が cross-file 同期契約を前提とするため、follow-up PR の fix も「同ファイル内 5+ 箇所」「cross-file 5 種類」を atomic に同期しないと cycle 1 で必ず drift が surface する
2. **3 階層 drift の細粒度化が cycle ごとに進行する**: PR #713 では (a) cross-file 同期 (9 sites)、(b) 同ファイル内多箇所 (review.md 6→9 箇所、fix.md 5→7 箇所など内部一貫性で追加箇所 surface)、(c) rationale 強度 (regex 順序 rationale の正確化、prompt-engineer-reviewer.md の hardcode 抽象化) の 3 階層 drift が **cycle 1 で同時 surface** した。原 PR の 4 cycle 観測と follow-up PR の 2 cycle 観測を合算すると、severity 等級拡張という運用 invariant に対する **6 cycle 累積観察** となる
3. **Follow-up PR の scope 設計**: cycle 4 以降の cross-file impact を follow-up PR にまとめる際、**「9 finding すべてを 1 PR で同期」する scope 設計** が canonical。個別 PR に分割すると `Asymmetric Fix Transcription` のリスクが finding 間の境界に分散し、収束サイクル数が finding 数 × 2-3 cycle に膨張する。PR #713 は 9 finding を 1 PR に bundle して 2 cycle で収束させた

## 関連ページ

- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)
- [AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する](../patterns/drift-check-anchor-prose-code-sync.md)
- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](../heuristics/identity-reference-documentation-unification.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](./fix-comment-self-drift.md)
- [Severity 等級拡張は read/write/parse/measure の closed-loop 6 段階を verify する](../heuristics/severity-extension-closed-loop-verification.md)

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
- [PR #631 cycle 1 review (`--quiet` 契約 drift + Phase 4.1 appendix 欠落、4 reviewer 合意)](raw/reviews/20260420T185124Z-pr-631.md)
- [PR #631 cycle 2 review (mergeable convergence, 11-line minimum diff fix の word-for-word 整合評価)](raw/reviews/20260420T225458Z-pr-631.md)
- [PR #631 fix results (invocation 側 `--quiet` 削除 + sibling 6 箇所 appendix word-for-word 整合)](raw/fixes/20260420T224940Z-pr-631.md)
- [PR #636 cycle 2 review (3-site 対称セット HINT path drift + TC 対称性不徹底)](raw/reviews/20260421T030627Z-pr-636-cycle-2.md)
- [PR #636 cycle 2 fix (path prefix drift 修正 + TC 対称性完全適用)](raw/fixes/20260421T031214Z-pr-636-cycle-2.md)
- [PR #636 cycle 4 review (architectural fix の sub-skill 側未適用、DRIFT-CHECK ANCHOR 自身が片方向)](raw/reviews/20260421T033906Z-pr-636-cycle-4.md)
- [PR #659 cycle 1 review (5 sister sites 中 1 site のみ canonical 化漏れ、3 reviewer 独立検出)](raw/reviews/20260425T074416Z-pr-659.md)
- [PR #659 cycle 2 review (cycle 1 fix と test の同期義務 + 初期値 silent fall-through risk)](raw/reviews/20260425T081422Z-pr-659-cycle2.md)
- [PR #661 cycle 3 review (create-interview.md:605 散文形式 line-number reference の cross-validation 検出)](../../raw/reviews/20260425T165246Z-pr-661.md)
- [PR #661 cycle 3 fix (propagation scan pattern coverage 拡張)](../../raw/fixes/20260425T165546Z-pr-661.md)
- [PR #661 Cycle 4 Review (mergeable, REC-04 で drift-check-anchor lint pattern 拡張提案)](../../raw/reviews/20260425T171440Z-pr-661-cycle-4.md)
- [PR #677 cycle 1 review (split-config drift + hook list multi-location drift の cluster 発見)](raw/reviews/20260426T080650Z-pr-677.md)
- [PR #677 cycle 1 fix (split-config drift の template 配置 semantics 認識)](raw/fixes/20260426T081122Z-pr-677-cycle-1.md)
- [PR #677 cycle 2 fix (Active vs Advanced marker placement bug + hook 列挙 multi-location drift)](raw/fixes/20260426T081939Z-pr-677-cycle-2.md)
- [PR #688 cycle 2 review (helper 化 caller migration scope rule + load-bearing test 検証)](raw/reviews/20260426T233323Z-pr-688.md)
- [PR #688 cycle 3 fix (writer/reader 同 PR 完遂 user scope expansion)](raw/fixes/20260426T233931Z-pr-688.md)
- [PR #688 cycle 11 review (同関数内 line 72 partial migration 自己矛盾)](raw/reviews/20260427T050731Z-pr-688.md)
- [PR #688 cycle 42 review (writer 中核 4 箇所 sweep 責務 + multi-location undercount 再発)](raw/reviews/20260428T050216Z-pr-688.md)
- [PR #688 cycle 42 fix (reader 3 行 WARNING pattern を writer 中核 4 箇所に対称適用)](raw/fixes/20260428T051514Z-pr-688.md)
- [PR #708 cycle 1 review (Hypothetical Categories 表記 cross-file drift + Detection-checklist sync 漏れ)](raw/reviews/20260428T194949Z-pr-708.md)
- [PR #708 cycle 2 review (severity 概要表追加で同ファイル内 5 箇所 self-consistency 違反 surface)](raw/reviews/20260428T200123Z-pr-708-cycle-2.md)
- [PR #708 cycle 2 fix (同ファイル内 5 箇所同期 + Inline annotation → blockquote pattern)](raw/fixes/20260428T200424Z-pr-708-cycle-2.md)
- [PR #713 review (PR #708 cycle 4 follow-up cross-file 9 sites 同期、2 cycle 収束)](raw/reviews/20260429T041942Z-pr-713.md)
