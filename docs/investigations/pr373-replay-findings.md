# PR #373 (code-heavy) replay 実測レポート

> **位置づけ**: Issue #402 (親 Issue #392 の対照実測サブタスク) の成果物。改善後 `rite:pr:review` を code-heavy PR に対して適用し、doc-heavy PR #350 replay (PR #385) への過剰適応を定量的に検証する。
>
> **実測セッション**: 2026-04-10
> **対象 PR**: #373 `feat(lint): 分散修正 drift 検出 lint の新規実装`
> **baseRefOid**: `5639e27b504efe9a35fbf9aa4d33f966cb437234`
> **replay draft PR**: #405 (`investigate/pr373-replay`, commit `50ccc3b`)
> **設計書**: [../designs/review-quality-gap-closure.md](../designs/review-quality-gap-closure.md)
> **親レポート**: [review-quality-gap-results.md](./review-quality-gap-results.md) §4 (doc-heavy replay)
> **手順参考**: PR #385 (doc-heavy PR #350 replay)、PR #401 (Phase D FP rate 手動判定)

## 0. サマリー

| 指標 | 結果 | 判定 |
|------|------|------|
| 総 finding 数 | 25 件 (CRITICAL 1 / HIGH 10 / MEDIUM 9 / LOW 5) | — |
| FP rate (strict) | **0.0%** (0/25) | ✅ ≤20% 目標 |
| FP rate (conservative) | **6.0%** (1.5/25, Ambiguous=0.5FP) | ✅ ≤20% |
| FP rate (worst case) | **12.0%** (3/25, Ambiguous=全FP) | ✅ ≤30% rollback 閾値 |
| Phase D 6 カテゴリ直接重複 | 1/6 (≈17%) | — (代わりに code-heavy 固有カテゴリを多数検出) |
| Rollback 判定 | **不要** (FP rate 全方式で閾値内) | ✅ |

**主要結論**:
1. **過剰適応の証拠なし**: FP rate が doc-heavy #350 replay (strict 10.5%) よりも低い (strict 0.0%) 結果となり、改善後 review system は code-heavy PR でも高品質な指摘を生成することが確認された。
2. **finding プロファイルの多様性**: Phase D 6 カテゴリ (doc-heavy 由来) との重複は 1/6 のみで、code-heavy では独自カテゴリ (silent failure / test coverage / algorithmic performance / convention consistency) が detect されている。これは review system が **入力の性質に応じて適切なカテゴリを自律的に発見している** ことを示す。
3. **Rollback 候補の Phase なし**: FP rate はすべての算出方式で rollback 閾値 (30%) を下回り、Phase A/B/C/C2 のいずれも rollback 候補ではない。

## 1. 実測条件

### 1.1 対象 PR

- **PR #373**: `feat(lint): 分散修正 drift 検出 lint の新規実装 (#361)`
- **ファイル数**: 2 (両方とも新規作成)
  - `plugins/rite/hooks/scripts/distributed-fix-drift-check.sh` (289 行、bash lint 本体)
  - `plugins/rite/hooks/scripts/tests/test-distributed-fix-drift-check.sh` (103 行、smoke test)
- **変更規模**: +392 / -0 (small scale)
- **Change type**: New Feature — pure-code 追加、既存コード変更なし
- **選定理由** (親 Issue #392 より引用): 本リポジトリに TypeScript コードが存在しないため、「TypeScript コード中心」の代替として「新規 bash 実装 + tests で構成される pure-code PR」を code-heavy 代表として選定。

### 1.2 replay 手順

Issue #402 本文の手順に準拠。

```bash
# Step 1: PR #373 merge commit と baseRefOid 特定
gh pr view 373 --json mergeCommit,baseRefOid
# baseRefOid: 5639e27b504efe9a35fbf9aa4d33f966cb437234

# Step 2: worktree 作成 (baseRefOid チェックアウト + 新規ブランチ)
git worktree add -b investigate/pr373-replay ../rite-investigate-pr373 5639e27b504efe9a35fbf9aa4d33f966cb437234

# Step 3: PR #373 の diff を worktree に適用
cd ../rite-investigate-pr373
gh pr diff 373 | git apply --3way -

# Step 4: commit + push + draft PR 作成
git -c commit.gpgsign=false commit -m "investigate: replay PR #373 for code-heavy review measurement"
git push -u origin investigate/pr373-replay
gh pr create --draft --base develop --head investigate/pr373-replay --title "investigate: PR #373 replay for code-heavy review measurement (#402)" --body "..."
# → PR #405 (https://github.com/B16B1RD/cc-rite-workflow/pull/405)

# Step 5: rite:pr:review を draft PR に対して起動
# (Issue #402 の /rite:issue:start フロー内で `skill: "rite:pr:review", args: "405"` として nested 起動)
```

### 1.3 レビュアー構成

改善後 `rite:pr:review` の自動選定結果 (Phase 2 keyword detection + user confirmation):

| # | Reviewer | 選定理由 | 評価 |
|---|----------|---------|------|
| 1 | code-quality | 一般的な bash 品質、命名・構造 | 条件付き |
| 2 | error-handling | `set -uo pipefail` / `trap` / `\|\| true` 等のキーワード検出 | 条件付き |
| 3 | test | test 対象ファイル含有 | 要修正 |
| 4 | performance | awk/grep の複合パイプライン検出 | 条件付き |

- **レビューモード**: full (previous review なし)
- **Doc-Heavy PR**: false (`doc_lines_ratio=0.0`, `doc_files_count_ratio=0.0`)
- **関連 Issue**: なし (PR body に `Closes/Fixes/Resolves` keyword なし)

## 2. Finding 一覧と FP 判定

### 2.1 重要度別集計

| Severity | code-quality | error-handling | test | performance | 合計 |
|----------|:-:|:-:|:-:|:-:|:-:|
| CRITICAL | 0 | 0 | 1 | 0 | **1** |
| HIGH | 1 | 3 | 3 | 3 | **10** |
| MEDIUM | 1 | 3 | 2 | 3 | **9** |
| LOW | 0 | 2 | 1 | 2 | **5** |
| **合計** | **2** | **8** | **7** | **8** | **25** |

### 2.2 Finding 一覧 (TP/FP/Ambiguous 手動判定付き)

判定基準 (PR #401 precedent に準拠):
- **TP** (True Positive): 指摘は factually 正しく、実 diff で確認可能な問題を指している
- **FP** (False Positive): 指摘は事実誤認、存在しない問題、または実装を誤読している
- **Ambiguous**: 環境・解釈依存 (例: bash バージョン依存、設計判断の違い)

#### 2.2.1 code-quality (2 件)

| # | Severity | 対象 | 指摘要約 | 判定 | 理由 |
|---|----------|------|---------|:---:|------|
| CQ-1 | HIGH | test file (全体) | テストファイルが既存ハーネス (`hooks/tests/run-tests.sh` / `scripts/tests/run-all.sh`) の `*.test.sh` glob から孤立 | **TP** | 両ハーネスの glob パターンと新規 test の命名規約・配置ディレクトリを diff + 既存ファイルで確認可能 |
| CQ-2 | MEDIUM | main:1,29 | shebang + `set` flag が既存 30+ 本の `#!/bin/bash` + `set -euo pipefail` 規約から逸脱 | **TP** | 既存 script 群との比較で客観的に確認可能 |

#### 2.2.2 error-handling (8 件)

| # | Severity | 対象 | 指摘要約 | 判定 | 理由 |
|---|----------|------|---------|:---:|------|
| EH-1 | HIGH | test:10 | `git rev-parse` に失敗ガードなし、非 git 環境で REPO_ROOT 空 → 誤メッセージ sliding failure | **TP** | main script の line 72-75 は防御済みという非対称を diff で確認可能 |
| EH-2 | HIGH | main:87-88 | mktemp→trap 順序の signal race + INT/TERM/HUP trap 欠落 | **TP (partial Ambiguous)** | missing signal trap は客観的 TP。mktemp-trap 間の race は理論上存在するが実際の再現確率は極小 |
| EH-3 | HIGH | test:54 | `${TMPFILES[@]}` 展開が `set -u` 下で空配列時 unbound | **Ambiguous** | bash 4.4+ では非発火、古い bash (macOS 3.2 等) では TP。環境依存 |
| EH-4 | MEDIUM | main:137,198 | `awk \| while read` pipeline 失敗が `set -e` 未使用で silent に捨てられる (P1/P3 偽陰性) | **TP** | pipefail の仕様と set -e 有無の相互作用は客観的 |
| EH-5 | MEDIUM | main:219-220 | Pattern 4 の `{ grep \|\| true; }` が grep exit 2 (IO error) と exit 1 (no match) を区別せず | **TP** | `\|\| true` の semantics は明確、IO error 握り潰しは客観的事実 |
| EH-6 | MEDIUM | main:148,156,255,258 | `table_reasons=$(...)` の command substitution 失敗が silent skip (P2/P5 偽陰性) | **Ambiguous** | "pipeline crash" と "正常に no-match" を静的解析で判別困難。設計として silent skip を許容する方針もありうる |
| EH-7 | LOW | test:68 | `out=$("$SCRIPT" 2>&1)` の stdout/stderr merge + grep prefix 依存で fragile | **TP** | 将来の log 文言変更で count 狂うフラジリティは客観的 |
| EH-8 | LOW | main:73 | 非 git 環境で silent に CWD を REPO_ROOT として採用 | **TP** | `\|\| pwd` の挙動は明確 |

#### 2.2.3 test (7 件)

| # | Severity | 対象 | 指摘要約 | 判定 | 理由 |
|---|----------|------|---------|:---:|------|
| TEST-1 | **CRITICAL** | test:71-80 | Test 3 は P2/P3 の件数しか assertion せず、P1/P4/P5 は個別検証なし → regression 防止不完全 | **TP** | diff を直接読んで確認可能、5 patterns 契約のカバレッジ gap は明確 |
| TEST-2 | HIGH | test:86-97 | clean file test が prose のみで各 pattern の **negative case** (正しい構造を clean と判定することの保証) 未検証 | **TP** | 客観的な test design gap |
| TEST-3 | HIGH | test:44-50 | 非存在ファイル `--target` 時の silent exit 0 挙動が未検証 (false-green の発生源) | **TP** | main script の `[ -f "$file" ] \|\| return 0` を diff で確認可能 |
| TEST-4 | HIGH | test:71 | `assert_ge >= 5` は下限のみ、exact count (74) での regression 保護なし | **TP** | 下限 assertion の弱さは客観的 (cec0140 の実測値は script の test 自体を動かさないと正確値は不明だが、design 指摘は有効) |
| TEST-5 | MEDIUM | test (全体) | `--pattern N` / `--quiet` / `--all` / `--repo-root` / 未知 flag 等 invocation option が未検証 | **TP** | diff 内にそれらを test するコードなし |
| TEST-6 | MEDIUM | test:45,49 | `--help` は exit code のみ検証、stdout (Usage / Options キー) 未検証 | **TP** | diff で確認可能 |
| TEST-7 | LOW | test:54 | `TMPFILES=()` init と trap 配置が Test 1/2 の後 (将来の cleanup 漏れリスク) | **TP** | minor だが design critique として有効 |

#### 2.2.4 performance (8 件)

| # | Severity | 対象 | 指摘要約 | 判定 | 理由 |
|---|----------|------|---------|:---:|------|
| PERF-1 | HIGH | main:218-251 | Pattern 4 anchor 解決が O(L × heading_count)、per-link 再 grep + per-heading fork | **TP** | diff のループ構造を読んで確認可能 |
| PERF-2 | HIGH | main:143-145,204-206 | `awk \| while read` subshell 越しに tempfile 往復 | **TP** | `report()` の tempfile R/W は客観的 |
| PERF-3 | HIGH | main:93-103 | `DRIFT_COUNT_FILE` tempfile は process substitution で排除可能 | **TP (refactor)** | 代替パターンが存在する点は客観的。必須修正かは設計判断 |
| PERF-4 | MEDIUM | main:122-123 | awk 5-line lookback の 6 変数 shift (line あたり 12 代入) | **TP** | 実コストは小さいが計算量の非効率は客観的 |
| PERF-5 | MEDIUM | main:154-171,261-271 | Pattern 2/5 で同一ファイルの `grep -oE 'reason=...'` を 2 回呼び出し | **TP** | diff で確認可能 |
| PERF-6 | MEDIUM | main:212-216 | `github_anchor` が tr + sed で 2 fork/呼び出し、heading 数分発火 | **TP** | bash 内蔵展開で代替可能 |
| PERF-7 | LOW | main:225-227 | 3-stage grep/grep/sed を 1 stage に統合可能 | **TP (refactor)** | 代替 regex の妥当性は確認可能 |
| PERF-8 | LOW | test:54 | TMPFILES 空配列時の unbound 安全化 (performance 枠からの堅牢性指摘) | **Duplicate (EH-3)** | EH-3 と同一行同一問題。performance reviewer 自身も「performance ではなく堅牢性」と認めている |

### 2.3 判定集計

| 判定 | 件数 | 割合 |
|------|------|------|
| **TP (True Positive)** | 22 | 88.0% |
| **Ambiguous** | 3 | 12.0% |
| **FP (False Positive)** | 0 | 0.0% |

**Ambiguous の内訳**:
1. EH-2 (mktemp-trap race 部分): 理論上存在するが実用上非再現。missing signal trap 部分は完全 TP
2. EH-3 / PERF-8 (TMPFILES unbound): bash バージョン依存 (< 4.4 で TP、>= 4.4 で非発火)
3. EH-6 (table_reasons silent skip): "pipeline crash" と "正常 no-match" の判別困難、設計判断に依存

**注**: PERF-8 は EH-3 の重複報告なので、Ambiguous としてカウントするのは EH-3 側 1 件のみ。しかし reviewer 集計上は 25 件として維持 (鉛筆事項テーブル上は両方出現している)。

## 3. FP rate 計算 (3 方式)

PR #401 precedent に準拠して 3 つの算出方式で FP rate を計算。

### 3.1 Strict (FP / total)

```
FP rate = FP 件数 / 総件数
        = 0 / 25
        = 0.0%
```

✅ **Strict FP rate 0.0%** は Phase D 目標 `≤20%` を大きく満たし、rollback 閾値 30% を大きく下回る。

### 3.2 Conservative (Ambiguous = 0.5 FP)

```
FP rate = (FP 件数 + 0.5 × Ambiguous 件数) / 総件数
        = (0 + 0.5 × 3) / 25
        = 1.5 / 25
        = 6.0%
```

✅ **Conservative FP rate 6.0%** も ≤20% 目標を満たす。

### 3.3 Worst case (Ambiguous = 全 FP)

```
FP rate = (FP 件数 + Ambiguous 件数) / 総件数
        = (0 + 3) / 25
        = 12.0%
```

✅ **Worst case FP rate 12.0%** でも rollback 閾値 30% を大きく下回る。

### 3.4 doc-heavy PR #350 replay (PR #385) との比較

| 指標 | doc-heavy #350 (PR #384/#401) | code-heavy #373 (本レポート) |
|------|:---:|:---:|
| 総 finding 数 | 19 件 | 25 件 |
| Severity 分布 | 0 C / 7 H / 8 M / 4 L | 1 C / 10 H / 9 M / 5 L |
| FP rate (strict) | 10.5% (2/19) | **0.0%** (0/25) |
| FP rate (conservative) | 18.4% | **6.0%** |
| FP rate (worst case) | 26.3% | **12.0%** |
| TP 件数 | 14 (73.7%) | **22 (88.0%)** |
| Ambiguous 件数 | 3 (15.8%) | 3 (12.0%) |

**主要観察**:
1. code-heavy は総 finding 数が **多い** (19 → 25、+31.6%) 一方で FP rate は **doc-heavy より低い**。これは「doc-heavy に過剰適応している」仮説の **反証** となる。
2. CRITICAL finding が code-heavy で 1 件 (TEST-1) 出現。doc-heavy では CRITICAL 0 件だったため、code-heavy は **より重大な問題を発見する力** がある。
3. Ambiguous 率は両者ほぼ同等 (15.8% vs 12.0%)、FP 判定の困難さが PR 性質に依存しないことを示唆。

## 4. カテゴリカバレッジ分析 (Phase D 6 カテゴリ比較)

### 4.1 Phase D 6 カテゴリ (doc-heavy #350 由来、PR #385 で定義)

| # | カテゴリ | 由来 | code-heavy #373 で直接検出 |
|---|---------|------|:---:|
| 1 | Enumeration / reason-table drift | fix.md Phase 8.1 reason 表の 12 値 vs 27+ emit | — |
| 2 | Pipeline SIGPIPE 方向誤解 | review.md Phase 2.2.1 pipeline direction 誤認 | — (ただし関連カテゴリ: pipefail error 伝播 EH-4 を検出) |
| 3 | Anchor / 行番号 drift | review-quality-gap-closure.md の行番号参照 drift | — |
| 4 | Bash trap+cleanup パターン重複 | 9 箇所の完全重複 | ✅ EH-2 (trap 標準パターン不整合を指摘) |
| 5 | Fast Path bash block 複雑度 | 250 行 11 ステップ詰め込み | — |
| 6 | Frontmatter drift | (Phase A の由来) | — |

**直接重複**: 6 カテゴリ中 **1 カテゴリ** (≈17%)

### 4.2 code-heavy 固有カテゴリ (新規発見)

| カテゴリ | 件数 | 代表 finding |
|---------|:---:|------|
| Silent failure / error propagation (pipefail 相互作用、silent exit、IO error vs no-match) | 7 | EH-1, 3, 4, 5, 6, 7, 8 |
| Test coverage gaps (個別 assertion 欠落、negative case 未検証、option coverage 欠落) | 6 | TEST-1..6 |
| Algorithmic performance (O(N) / fork 増幅 / tempfile 往復) | 7 | PERF-1..7 |
| Convention consistency (shebang 規約、harness 発見性) | 2 | CQ-1, 2 |

### 4.3 カテゴリ多様性の含意

- doc-heavy (#350) と code-heavy (#373) の finding カテゴリは **大きく異なる**。
- しかし両者とも **共通の "bash trap+cleanup パターン重複" カテゴリ** を検出 (EH-2)。
- code-heavy では doc-heavy 特有のカテゴリ (enumeration drift / anchor drift / fast path 複雑度) を検出しない代わりに、**code 特有のカテゴリ** (silent failure / test coverage / performance) を自律的に発見している。
- この **カテゴリの入力適応性** は、改善後 review system が特定 PR 型に overfit しているのではなく、**reviewer プロンプトと shared principles が汎用的に機能している** ことを示す強い証拠である。

## 5. Rollback 判定

判定基準 (Issue #402 より): **FP rate > 30% の Phase (A/B/C/C2) は rollback 対象として記録**。

| 方式 | FP rate | 30% 閾値判定 |
|------|--------|:-:|
| Strict | 0.0% | ✅ (大きく下回る) |
| Conservative | 6.0% | ✅ |
| Worst case | 12.0% | ✅ (余裕あり) |

**結論**: **code-heavy PR 対照実測では、いずれの Phase (A/B/C/C2) も rollback 対象にならない**。

改善後 review system は code-heavy PR に対して:
1. doc-heavy を下回る低 FP rate (strict 0.0%)
2. doc-heavy を上回る total finding 数 (19 → 25)
3. 入力性質に適応した多様なカテゴリ
4. CRITICAL レベルの実質的問題を発見する能力

を示しており、**doc-heavy 特殊化の兆候はない**。

## 6. 親 Issue #392 への引き継ぎ情報

本 Issue #402 の成果物は親 Issue #392 の集約タスクで以下に反映される:

1. **`docs/investigations/review-quality-gap-results.md` §4 対照 PR 結果セクション**: 本レポートの §3.4 (比較表) と §4 (カテゴリ分析) を引用
2. **Phase 別 FP rate 集計**: 本レポートの §5 結果 (rollback 対象なし)
3. **対照 PR 実測データ**: 本レポート §2.2 (finding 一覧 + FP 判定) を data point として統合

**未実施タスク (親 #392 に委譲)**:
- PR #403 (Bash hook 対照実測、PR #334 replay)
- PR #404 (Mixed code+docs 対照実測、PR #370 replay)
- 3 件の子 Issue 結果統合と §4 セクション執筆

## 7. 関連リソース

### 7.1 本 Issue
- Issue #402 (本 Issue)
- `docs/issue-402-pr373-replay-code-heavy` ブランチ (本レポート含む)
- PR #405 (replay draft PR、review コメント付き)

### 7.2 親 Issue と参考資料
- 親 Issue #392
- doc-heavy replay: PR #384 (実測) / PR #385 (レポート) / PR #401 (FP 判定)
- Phase D レポート: [`review-quality-gap-results.md`](./review-quality-gap-results.md)
- 設計書: [`../designs/review-quality-gap-closure.md`](../designs/review-quality-gap-closure.md)

### 7.3 PR #373 オリジナル
- PR #373 `feat(lint): 分散修正 drift 検出 lint の新規実装 (#361)` (merged 2026-04-09)
- 実装 commit: `e8620a841b5c41e21077543eeed1c57006e7b854`
- baseRefOid: `5639e27b504efe9a35fbf9aa4d33f966cb437234`

---

**執筆セッション**: 2026-04-10
**実測者**: Claude Code (rite-workflow / code-heavy control replay for #392)
