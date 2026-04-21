# Regression fixture: Issue #634 — create-interview sub-skill return 後の implicit stop (self-exemplar)

- **Issue**: #634
- **Previous accumulated fixes**: #525, #444, #475, #552, #561, #622, #628
- **Sibling regression**: #621 (cleanup workflow 内の同型問題)

## 0. このドキュメントの位置づけ

#634 は本リポジトリで 8 回目の同一 protocol violation regression (7 件の累積対策 + #634 fix)。本ドキュメントは #622 fixture (`issue-622-repro.md`) の後継として、#634 で追加した防御層の検証手順と AC 対応表を記録する。

## 1. 再現手順 (baseline: 修正前)

### 1.1 前提条件

- `plugins/rite/hooks/hooks.json` が存在し、Claude Code の native plugin hook discovery (ファイル存在ベース) により `Stop` hook = `stop-guard.sh` が登録されている (init.md Phase 4.5.0.2 / start.md Step 2 参照)
- `jq` がインストールされている
- `.rite-flow-state` が存在しない (fresh start)
- #628 までの全累積対策が適用されている HEAD

### 1.2 実行

```bash
/rite:issue:create "テスト用の bug fix Issue"
```

### 1.3 期待される regression 挙動 (#634 fix 前)

以下が一気通貫で実行される**はず**だが、step 5 と step 6 の間で turn が切れる可能性がある:

1. `create.md` Phase 0.1 で What/Why/Where 抽出
2. Phase 0.3 類似 Issue 検索
3. **Delegation to Interview Pre-write**: `.rite-flow-state.phase = create_interview` に patch
4. `Skill: rite:issue:create-interview` invoke
5. `create-interview.md` が Bug Fix preset を適用 (Phase 0.4.1 → skip Phase 0.5)。`<!-- [interview:skipped] -->` を最終行として emit
6. ⚠️ **turn 境界形成 (implicit stop)** — user に `Crunched for 2m XXs` が表示される (#622 対策後も低頻度で再発)
7. user が `continue` を入力
8. `create.md` の 🚨 Mandatory After Interview → Phase 0.6 → Delegation Routing → `create-register` invoke

### 1.4 Evidence 確認 (回帰検出)

```bash
# diag log で create_post_interview phase の block が記録されているか確認
tail -50 .rite-stop-guard-diag.log | grep -E 'phase=create_post_interview|phase=create_interview'
```

回帰時は `EXIT:2 reason=blocking phase=create_post_interview` が 1 件以上記録されつつ、かつ `create_post_interview → create_delegation` 方向への whitelist 遷移記録がない (= orchestrator が Delegation Routing に進んでいない) 状態。

## 2. 期待動作 (#634 fix 後)

### 2.1 AC-1/AC-2: 同 turn 内完走

step 5 と step 8 が **同 turn 内で連続実行される**。`Crunched for ...` の turn 境界が形成されない。

### 2.2 Evidence 確認 (修正後)

```bash
# 新 marker の grep 検証
grep -F '[CONTEXT] INTERVIEW_DONE=1' plugins/rite/commands/issue/create-interview.md
# 期待: example ブロック内で 2 件 (skipped example + completed example で emit)。
# 説明文中の言及を含めた合計は 4 件以上になる (Line 538 / 544 等で参照される)。
# 判定基準: `>= 2` (example での emit を必須とするが、説明文での言及は将来変動しうる)

# Step 0 Immediate Bash Action の grep 検証
grep -F 'Step 0: Immediate Bash Action' plugins/rite/commands/issue/create.md
# 期待: 1 件以上

grep -F 'Step 0 (Immediate Bash Action' plugins/rite/hooks/stop-guard.sh
# 期待: 2 件以上 (create_interview + create_post_interview case arm)

# error_count escalation hint の存在確認
grep -F 'RE-ENTRY DETECTED' plugins/rite/hooks/stop-guard.sh
# 期待: 2 件以上
```

### 2.3 Test Suite

```bash
bash plugins/rite/hooks/tests/stop-guard.test.sh 2>&1 | grep -E 'TC-634'
# 期待: TC-634-A / TC-634-B / TC-634-C 全て PASS
```

### 2.4 Self-exemplar integration test (AC-3)

同一 session 内で 3+ 件の Issue を `/rite:issue:create` で連続作成したとき、全てのケースで `continue` 手動入力が発生しないこと。手動実施として記録:

1. `/rite:issue:create "テスト A"` → Bug Fix preset → 完走 (continue 不要)
2. `/rite:issue:create "テスト B"` → Bug Fix preset → 完走 (continue 不要)
3. `/rite:issue:create "テスト C"` → Feature (標準 interview) → 完走 (continue 不要)

自動化は 8-1/8-2 Future Work で検討 (本 fixture は再現手順と verification 手段を記録する範囲)。

## 3. 根本原因分析 (#634 向け)

### 3.1 本 regression の追加仮説

| ID | 仮説 | 評価 |
|---|---|---|
| H1 | Bug Fix / Chore preset で sub-skill 側処理が軽く「完了感」が強い → turn-boundary heuristic が発火しやすい | 主因 (#634 Issue body §3 想定) |
| H2 | stop-guard の case arm が発火しても stderr 経由の feedback (exit-2 contract) を LLM が確実に consume していない | 副因 (workflow_incident emit 経路は動作中だが HINT が届かないケース) |
| H3 | HTML コメント sentinel (`<!-- [interview:skipped] -->`) は turn-boundary を弱める効果はあるが排除しきれていない | 副因 (#561 対策の限界) |

### 3.2 #634 fix の対策マッピング

| Fix layer | Target | 仮説への対応 |
|-----------|--------|------------|
| L1: stop-guard HINT に concrete bash 命令を含める | H2 | HINT が届いた時に何をすべきかの cognitive load 最小化 |
| L2: error_count escalation (RE-ENTRY DETECTED) | H2 | 2 回目以降の block で明示的に命令を繰り返す |
| L3: `[CONTEXT] INTERVIEW_DONE=1` plain-text marker | H3 | HTML コメント除去 rendering でも grep 可能な補助 marker |
| L4: create.md Mandatory After Interview に Step 0 Immediate Bash Action 追加 | H1 | sub-skill return 直後の natural completion 感を concrete tool call で上書き |

## 4. Acceptance Criteria 対応表

| AC | 判定手段 | 対応 Test |
|----|---------|-----------|
| AC-1 (Happy path, skipped) | `/rite:issue:create` with Bug Fix preset → continue 不要で完走、`[create:completed:{N}]` が同 turn 内で emit | Manual + Integration (Section 2.4) |
| AC-2 (Happy path, completed) | Feature preset で deep-dive 実施 → continue 不要で完走 | Manual + Integration (Section 2.4) |
| AC-3 (Self-exemplar) | 3+ 件連続作成で `continue` 介入ゼロ | Section 2.4 の manual scenario |
| AC-4 (Error / observable) | stop-guard block → `workflow_incident` sentinel stderr emit | TC-622-B (既存) |
| AC-5 (Non-regression contract phrases) | create.md に `anti-pattern` / `correct-pattern` / `same response turn` / `DO NOT stop` の各 count >= 1 | Section 5 の手動 grep スニペット (下記) — `verify-634-structure.sh` は未実装のため inline grep 手順のみを規範とする |
| AC-6 (Non-regression structure) | HTML コメント sentinel + case arm + whitelist + Pre-flight 4 点保持 | 下記 Section 5 |

## 5. 構造的 non-regression grep 検証

```bash
# AC-5 contract phrases
for p in "anti-pattern" "correct-pattern" "same response turn" "DO NOT stop"; do
  c=$(grep -c "$p" plugins/rite/commands/issue/create.md)
  echo "$p: $c"
  [ "$c" -lt 1 ] && echo "  ❌ MISSING (regression)" || echo "  ✅ present"
done

# AC-6 structural
grep -F '[interview:skipped]' plugins/rite/commands/issue/create-interview.md >/dev/null \
  && echo "✅ interview:skipped sentinel intact" \
  || echo "❌ interview:skipped sentinel missing"
grep -F '[interview:completed]' plugins/rite/commands/issue/create-interview.md >/dev/null \
  && echo "✅ interview:completed sentinel intact" \
  || echo "❌ interview:completed sentinel missing"
grep -E 'create_post_interview\)$' plugins/rite/hooks/stop-guard.sh >/dev/null \
  && echo "✅ create_post_interview case arm intact" \
  || echo "❌ create_post_interview case arm missing"
grep -E '\["create_post_interview"\]=' plugins/rite/hooks/phase-transition-whitelist.sh >/dev/null \
  && echo "✅ whitelist create_post_interview edge intact" \
  || echo "❌ whitelist create_post_interview edge missing"
grep -F 'MANDATORY Pre-flight' plugins/rite/commands/issue/create-interview.md >/dev/null \
  && echo "✅ Pre-flight section intact" \
  || echo "❌ Pre-flight section missing"
```

期待出力: 全 phrase + 構造要素が `✅` 判定。

## 6. Future work

- AC-3 の自動化 (integration test harness で multi-Issue continuous-creation を mock 環境で run)
- PostToolUse(Skill) hook 実装検討 (Claude Code が当該 matcher を support するか未確認)
- workflow_incident sentinel の LLM consume 経路の diagnostics (exit-2 contract 以外の補助経路)

## 7. Decision Log

- **本 Issue を #622 reopen ではなく新規 regression Issue として扱う**: PR 履歴を切り分けて retrospective を容易化
- **Self-exemplar を AC に含める**: 本 Issue 作成プロセスそのものが再現サンプル
- **LLM turn-boundary heuristic 自体を制御しない方針**: externalized enforcement (stop-guard / whitelist / flow-state) で継続補強
- **Step 0 を Step 1 と冗長化する設計**: redundancy がそのまま実装 → idempotent patch を 2 回呼ぶコストは無視できるが、2 つの concrete tool call として LLM に見せることで turn-boundary 感を分割する
