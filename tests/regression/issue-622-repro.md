# Regression fixture: Issue #622 — create-interview sub-skill return 後の implicit stop

- **Issue**: #622
- **Sibling**: #621 (cleanup workflow 内の同型問題)
- **Original**: #552 (CLOSED — 対策導入時)

## 1. 再現手順 (baseline: 修正前)

### 1.1 前提条件

- `plugins/rite/hooks/hooks.json` が native plugin hook として登録されている (`Stop` hook = `stop-guard.sh`)
- `jq` がインストールされている
- `.rite-flow-state` が存在しない (fresh start)

### 1.2 実行

```bash
/rite:issue:create "テスト用の bug fix Issue"
```

### 1.3 期待される regression 挙動 (修正前)

以下が一気通貫で実行される**はず**だが、step 5 と step 6 の間で turn が切れる:

1. `create.md` Phase 0.1 で What/Why/Where 抽出
2. Phase 0.3 類似 Issue 検索
3. **Delegation to Interview Pre-write**: `.rite-flow-state.phase = create_interview` に patch
4. `Skill: rite:issue:create-interview` invoke
5. `create-interview.md` が Bug Fix preset を適用 (Phase 0.4.1 → skip Phase 0.5)。`<!-- [interview:skipped] -->` を最終行として emit
6. ⚠️ **turn 境界形成 (implicit stop)** — user に `Crunched for 2m XXs` が表示される
7. user が `continue` を入力
8. `create.md` の 🚨 Mandatory After Interview → Phase 0.6 → Delegation Routing → `create-register` invoke

### 1.4 Evidence 確認

```bash
# stop-guard diag log を確認
tail -30 .rite-stop-guard-diag.log | grep -E 'phase=create_'
```

修正前は `phase=create_interview` / `phase=create_post_interview` の blocking record が**皆無** — stop-guard が fire していない。

## 2. 期待動作 (AC-2: 修正後)

step 5 と step 8 が **同 turn 内で連続実行される**。`Crunched for ...` の turn 境界が形成されない。

### 2.1 Evidence 確認 (修正後)

```bash
# stop-guard diag log に create_* phase の block が記録される
tail -30 .rite-stop-guard-diag.log | grep -E 'phase=create_'
# 期待: 少なくとも create_interview or create_post_interview phase での EXIT:2 reason=blocking 行が存在
```

## 3. 根本原因分析 (AC-4)

本 regression の根本原因を 4 仮説で分析 (Issue body 参照):

| ID | 仮説 | 評価 |
|---|---|---|
| H1 | sentinel 最終 3 行が turn-boundary heuristic を強化 | **部分支持** — 3 行の順序 (plain-text blockquote → HTML comment → sentinel HTML comment) は heuristic に影響するが、stop-guard が fire すれば打ち消される |
| H2 | stop-guard の case 分岐に `create_interview` arm が不在 / sub-skill Defense-in-Depth が skip される | **主要原因** — diag log に create_* phase の block record が皆無であることから、stop-guard が fire していない実態が裏付けられる |
| H3 | Pre-check list Item 0 が LLM self-introspection に依存 | **二次要因** — 本質的には Markdown 指示による soft enforcement であり、強制力は stop-guard に依存 |
| H4 | sub-skill loading mechanism が独立ブロックとして提示 | **未検証** — Claude Code 内部の Skill loading 挙動に依存、本 Issue のスコープ外 |

**結論**: H2 が主因。副次的に H1/H3 が寄与。

## 4. 修正の主要ポイント

| 修正 | 場所 | 狙い |
|---|---|---|
| 1 | `plugins/rite/hooks/stop-guard.sh` に `create_interview` case arm 追加 | sub-skill mid-execution / Pre-flight 未実行状態での stop 試行を block し、WORKFLOW_HINT で継続指示を emit |
| 2 | `plugins/rite/commands/issue/create-interview.md` の Defense-in-Depth を sub-skill 冒頭の 🚨 MANDATORY Pre-flight として移動 | Bug Fix / Chore preset (Phase 0.5 skip) 経路でも必ず `create_post_interview` に patch され、stop-guard の `create_post_interview` case arm に routing される |

## 5. #621 との合同分析 (AC-7)

| 項目 | #622 (create) | #621 (cleanup) |
|---|---|---|
| Caller workflow | `/rite:issue:create` | `/rite:pr:cleanup` |
| Sub-skill | `rite:issue:create-interview` | `rite:wiki:ingest` |
| 停止ポイント | `<!-- [interview:skipped] -->` 出力後 | `<!-- [ingest:completed] -->` 出力後 |
| Root cause 分類 (Decision Log) | H2 (stop-guard の case arm 不足) が主因 + H1/H3 が副因 | H1 (ingest.md 三点セットが turn-boundary heuristic 強化) + H3 (Pre-check list の self-introspection 依存) の複合 (#621 Decision Log 参照) |
| 対策パターン | **冒頭 🚨 MANDATORY Pre-flight (create-interview.md)** + **stop-guard `create_interview` case arm 追加** (case arm 不在が主因のため新規追加) | **既存 5 層防御の補強**: (a) cleanup.md Pre-check list Item 0 の機械化 (`[routing-check] ingest=matched\|unmatched` 1 行出力義務化)、(b) ingest.md Phase 9.1 三点セット #2 (caller 継続 HTML コメント) と #3 (sentinel) の間に recap 挿入禁止 MUST NOT 行追加、(c) test-stop-guard-cleanup.sh / docs/anti-patterns/cleanup-wiki-ingest-turn-boundary.md 新規 (既存の cleanup_pre_ingest / cleanup_post_ingest arm は存在するため新規追加不要) |

**結論**: 両 Issue は「sub-skill return 経路での implicit stop」という同型問題を持つが、根本原因と既存防御層の状態が異なるため**対策は非対称**となった:

- **#622 は冒頭 Pre-flight + stop-guard case arm 追加**: 既存 stop-guard に `create_interview` arm が不在だったため、新規防御層を追加する必要があった
- **#621 は既存 5 層防御の補強**: stop-guard arm (`cleanup_pre_ingest` / `cleanup_post_ingest`) は既に存在し、root cause も turn-boundary heuristic 強化と self-introspection 依存の方が主因だったため、Pre-check 機械化と MUST NOT 行の追加で対応

共通根本原因として「sub-skill Defense-in-Depth が Markdown embedded instruction で LLM skip を許す」構造はあるが、既存防御層の欠落箇所が異なるため、同型の fix を両 PR で複製するのではなく、それぞれの workflow の欠落層を個別に補強する設計とした。

## 6. テスト

| Test ID | AC | 実装 |
|---|----|------|
| T-03 | AC-3 | `plugins/rite/hooks/tests/stop-guard.test.sh` の TC-622-A / TC-622-B (新規追加) |
| T-01 (baseline) | AC-1 | 本 fixture の Section 1 を手動実行 |
| T-02 (e2e) | AC-2 | 修正後 commit で本 fixture の Section 1 を実行し Section 2 の evidence を確認 |
| T-05 | AC-6 | 本ファイルの存在を `tests/regression/issue-622-repro.md` で確認 |
| T-06 | AC-7 | 本ファイル Section 5 に cross-issue 分析を記録 |
