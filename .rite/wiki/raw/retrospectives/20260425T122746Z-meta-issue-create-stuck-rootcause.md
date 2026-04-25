---
type: retrospectives
source_ref: "meta-investigation-issue-create-stuck-rootcause-20260425"
captured_at: "2026-04-25T12:27:46+00:00"
title: "/rite:issue:create が累積 9 件の対策後も止まり続けた meta-retrospective — 防御層は『前提条件 + 実装』の両方が機能して初めて成立する"
ingested: true
related_issues: [3, 4, 76, 79, 123, 200, 205, 444, 475, 525, 552, 561, 622, 634, 651]
related_prs: [527, 554, 582, 624, 636, 654]
---

## Meta Retrospective

- **対象**: `/rite:issue:create` の sub-skill return 後 implicit stop が 2026-03-02 (#3) から 2026-04-24 (#651) まで **累積 9 件の Issue + PR で対策**されたにもかかわらず再発し続けた問題
- **Type**: meta-retrospective — 過去 9 件の対策がなぜ機能しなかったかを **一次情報** (`.jsonl` の `stop_reason`、`stop_hook_summary.preventedContinuation`、`.rite-stop-guard-diag.log`) で究明した結果
- **Discovered at**: 2026-04-25
- **Investigation context**: ユーザー (坂口さん) の指摘「そもなぜ止まるのかが究明できていないのではないかと考えます。それなのに、止まった時に継続させることに注力しているような気がしてならないのは、気のせいでしょうか。」が出発点

### 1. 失敗の連鎖 (完全 reconstruction、一次情報による)

```
[step 1] session-start.sh:267-294
         → 新セッション起動時に .rite-flow-state.active を false に強制 reset
         (前セッションの残存 active=true から保護する設計)

[step 2-4] commands/issue/create.md:516-520 / create-interview.md:41-58 / Return Output 直前 re-patch
         → bash flow-state-update.sh patch --phase ... を 8 回実行
         (★ どの site も --active true を指定していない)

→ .rite-flow-state.active = false のまま保持

[step 5] LLM が <!-- [interview:skipped] --> sentinel を emit
         caller HTML コメント内の "DO NOT stop" "IMMEDIATELY" を読み込んだ上で
         stop_reason: end_turn を選択

[step 6] Stop hook fire → stop-guard.sh:79-84
         ACTIVE != "true" → log_diag "EXIT:0 reason=not_active" → exit 0
         (case arm / WORKFLOW_HINT / RE-ENTRY DETECTED escalation には到達しない)

[step 7] stop_hook_summary: preventedContinuation: false / hasOutput: false
         → Claude Code は LLM の end_turn をそのまま受理

[step 8] UI: ✻ Churned for X → ユーザー手動 continue で再開
```

### 2. 一次情報 (証拠)

| 観測 | 値 | ソース |
|---|---|---|
| 現在の `.rite-flow-state.active` | false | リポジトリ直接確認 (2026-04-25) |
| `f0d8791d` セッション 2026-04-24 15:32 の `stop_reason` | end_turn | `.jsonl` line 65 |
| 同セッション同時刻の `preventedContinuation` | false | `stop_hook_summary` line 66 |
| 同セッション同時刻の diag log | `EXIT:0 reason=not_active` | `.rite-stop-guard-diag.log` |
| `f7afee09` (PR #636 マージ前) でも同パターン | end_turn × 2 / EXIT:0 × 2 | 別セッションでも再現 |
| diag log 直近 30 件中 EXIT:0 reason=not_active | **28/30 (93%)** | 本番で stop-guard が機能していなかった頻度 |
| `f0d8791d` 内の `flow-state-update.sh` 呼び出し | 8 件 | tool_use grep |
| そのうち `--active true` を指定したもの | **0 件** | 全件で omit |

### 3. なぜ過去 9 件の対策が単体テスト PASS しても本番で機能しなかったか

#### 3.1 テストカバレッジの設計欠陥

Issue #634 / #651 の `stop-guard.test.sh` (TC-634-A〜P 60+ TC) は完璧に PASS していたが、TC は **`phase=create_post_interview` + `active=true` を pre-set** してから stop-guard を起動する設計。本番では `active=false` のまま hook が起動するので **case arm に到達する前に early return**。テストが本番動作を保証していなかった。

#### 3.2 防御層の AND 論理 + 1 link 欠落

過去 9 件で導入した 8 種類の防御層は **AND 論理**で組まれていた:
- declarative enforcement (Anti-pattern / Correct-pattern / DO NOT stop)
- HTML コメント sentinel (#561)
- Pre-check list dispatcher (#552)
- whitelist transition (#622)
- Pre-flight flow-state 前倒し (#622)
- Step 0 Immediate Bash + INTERVIEW_DONE marker (#634)
- 4-site 対称化 (#651)
- stop-guard case arm + WORKFLOW_HINT (#622, #634)

これらすべてが「前提条件: `.rite-flow-state.active=true`」が成立した時のみ機能する。**1 link (`--active true` の omit) で連鎖全体が無効化**されていた。

#### 3.3 累積路線の盲点

過去 9 件の対策はすべて step 5/6 (LLM の end_turn 選択 / stop-guard の block 試行) を変えようとしていた。**step 1-4 (前提条件のチェーン)** を誰も検証していなかった。「直前の対策が効かない → さらに防御層を積む」という reactive な反応で、一次情報による根本仮説検証が常に Out of scope に追いやられていた。

### 4. Lessons for Wiki

#### Lesson 1: 防御層は「前提条件 + 実装」の両方を同時に検証する

新しい防御層 (hook / case arm / WORKFLOW_HINT) を追加する際、その防御層が **fire するための前提条件**を明示し、本番でその前提条件が成立しているかを **一次情報で確認** すること。

**具体策**:
- hook の早期 return 条件 (`if active != "true"; then exit 0` など) を hook 単体テストの **マイナス条件** として明示的にカバー
- 本番ログ (`.rite-stop-guard-diag.log`) を定期的に集計し、`exit 0` の理由分布を可視化
- diag log で `EXIT:0 reason=*` の割合が一定以上になった場合の alert / escalation

#### Lesson 2: テストカバレッジは「本番前提条件」まで再現しないと意味がない

単体テストが pre-set した状態と本番起動時の状態が乖離していると、PASS していても本番で動かない。

**具体策**:
- テストの `setUp()` で `active=true` を強制設定するなら、本番でも同じ前提が成立することを統合テストで確認
- 「単体 TC PASS = 本番動作 OK」という認識を捨てる
- `.rite-flow-state` の生成経路 (どの commands がいつ patch するか) を **データフロー図**として明文化

#### Lesson 3: 累積路線は根本仮説検証なしに N+1 regression を必然的に生む

「直前の対策が効かない」が観測された時、即座に「さらに防御層を積む」のではなく、まず **一次情報で根本仮説を検証** すること。

**具体策**:
- regression が 3 件以上累積したら、修正フェーズに入る前に **必ず究明フェーズ**を経る
- 究明では `.jsonl` の `stop_reason`、`stop_hook_summary`、hook diag log を一次情報として確認
- 「なぜ止まるか」を解像度高く問い直し、ハーネス側 / モデル側 / plugin 側のどの階層で起きているかを分離

#### Lesson 4: LLM の `stop_reason: end_turn` は declarative enforcement で抑制不可

caller HTML コメントに `IMMEDIATELY` `DO NOT stop` `SAME response turn` `Step 0 Immediate Bash Action` と書いても、LLM はこれらを **読み込んだ上で turn を閉じる**選択をすることがある (一次情報で実証)。

**具体策**:
- declarative enforcement は「LLM が正しい挙動を選ぶ確率を上げる」ものであって「強制する」ものではない
- 強制継続が必要な場合は **proactive な構造改訂** (sub-skill の inline 化 / PostToolUse hook + additionalContext injection / hook 層からの context injection) を検討
- declarative + hook reactive enforcement の **両方**が機能して初めて防御として成立する

#### Lesson 5: silent 防御無効化のリスク (前提条件 omit)

`--active true` の omit のような **silent な前提条件無効化**は、grep で検出しにくく、テストでも見つかりにくい。

**具体策**:
- `flow-state-update.sh patch` 系のコマンドで `--active` 省略時のデフォルト挙動を明示的に文書化
- Phase 2 案: patch mode で phase が "non-terminal" なら `--active` 省略時に自動で `true` にする (デフォルト挙動の安全側統一)
- もしくは Phase 1 案: 各 patch site に `--active true` を網羅的に追加して symmetric に保つ
- いずれの案でも、`flow-state-update.sh` の `--active` 省略時の挙動を明確に固定する

#### Lesson 6: Plugin Stop hook の `decision: block` JSON parse bug (#10412)

Claude Code の plugin hooks では `exit 2 + JSON stderr {"decision": "block"}` が parse されない bug が報告されている (https://github.com/anthropics/claude-code/issues/10412)。

本件では stop-guard.sh が exit 2 を出していなかったので bug を踏んでいないが、Phase 1 修正で exit 2 を出すようになった後にこの bug を踏むリスクがある。

**具体策**:
- 修正後に本番セッションで `preventedContinuation: true` が記録されるかを **必ず確認**
- `true` にならない場合、bug #10412 を踏んでいる → direct hook 化 (`.claude/hooks/`) または `additionalContext` injection への切り替えを検討

### 5. 関連 Issue / PR タイムライン

| Issue | PR | Closed | 対策の本質 | 機能していたか |
|---|---|---|---|---|
| #3, #4 | — | 2026-03-02 | 初期報告 | — |
| #76, #79 | — | 2026-03-11 | 文章 enforcement | ❌ |
| #123 | — | 2026-03-12 | 文章 + context 圧縮 | ❌ |
| #200, #205 | — | 2026-03-16 | Defense-in-Depth flow-state 導入 | ❌ |
| #444 | — | 2026-04-12 | Terminal Completion pattern | ❌ |
| #475 | — | 2026-04-14 | Mode A/B hook 強制 | ❌ |
| #525 | #527 | 2026-04-15 | 3 層自動継続契約 | ❌ |
| #552 | #554 | 2026-04-17 | Pre-check list + Anti/Correct-pattern | ❌ |
| #561 | #582 | 2026-04-18 | HTML コメント sentinel | ❌ |
| #622 | #624 | 2026-04-20 | whitelist + Pre-flight 前倒し | ❌ |
| #634 | #636 | 2026-04-21 | Step 0 + INTERVIEW_DONE marker | ❌ |
| #651 | #654 | 2026-04-24 | 4-site 対称化 | ❌ |

### 6. 経験則として残すべき principle

1. **防御層 = 前提条件 + 実装** — 両方が同時に機能して初めて成立する
2. **テスト pre-set ≠ 本番起動条件** — gap がある状態で単体 TC PASS は意味がない
3. **累積 ≠ 究明** — N 件の regression は防御層の追加では解決しない
4. **declarative ≠ proactive** — LLM の選択を変えるのは確率的、強制ではない
5. **silent omit がもっとも検出困難** — デフォルト挙動を明示的に固定する
6. **一次情報で確認する** — `.jsonl` の `stop_reason`、`stop_hook_summary`、hook diag log
7. **隣接フローへの伝播を予測する** — 同じ pattern (sub-skill return + Pre-flight + active=false) は `pr:cleanup` (#604, #618, #621, #625, #650), `wiki:ingest` (#552 系列) でも再発し続けている

### 7. 推奨される構造改訂方針

| 案 | 内容 | 短期/中期 |
|---|---|---|
| **Phase 1** | 各 `flow-state-update.sh patch` 呼び出しに `--active true` を網羅追加。本番条件再現 TC を追加。 | 短期、即効 |
| **Phase 2A** | `flow-state-update.sh patch` mode で `--active` 省略時、phase が non-terminal なら自動で `true`。 | 中期、構造改善 |
| **Phase 2B** | stop-guard.sh の `active=false` early return を「current session が書いた flow-state なら block 試行」に緩和。 | 中期、設計改修 |
| **Phase 3** | sub-skill inline 化 / PostToolUse hook + additionalContext / Skill matcher による proactive な手当 | 長期、研究フェーズ |

### 8. このメタ retrospective が wiki ingest 後に統合されるべきページ候補

- `pages/anti-patterns/declarative-enforcement-and-llm-end-turn.md` (新規) — 「LLM の end_turn は declarative では抑制不可」を anti-pattern として記録
- `pages/heuristics/defense-layer-precondition-validation.md` (新規) — 「防御層追加時の前提条件検証手順」を heuristic として記録
- `pages/heuristics/test-coverage-vs-production-precondition.md` (新規) — 「テスト pre-set と本番起動条件の gap 検証」を heuristic として記録
- `pages/anti-patterns/cumulative-fix-without-rootcause.md` (新規) — 「累積路線の N+1 regression リスク」を anti-pattern として記録
- 既存ページ: `pages/anti-patterns/sub-skill-return-implicit-stop.md` (もし存在すれば) を本 retrospective の知見で更新
