# Sub-skill Handoff Contract — 4-site 対称化の正規定義

> **Source of Truth**: 本ファイルは `/rite:issue:create` ワークフローにおける orchestrator (`create.md`) と sub-skill (`create-interview.md`) 間の hand-off で発火する `flow-state-update.sh patch` 系 bash literal の **4-site 対称化契約** の SoT である。`create.md` 🚨 Mandatory After Interview Step 0 の DRIFT-CHECK ANCHOR / `create-interview.md` 🚨 MANDATORY Pre-flight + Return Output re-patch の DRIFT-CHECK ANCHOR は本ファイルへ参照する。
>
> **抽出経緯**: 4-site 対称化のメタ説明 (DRIFT-CHECK ANCHOR / `--if-exists` 非対称性 / path 表現非対称性) が `create.md` / `create-interview.md` 双方に長大 blockquote として重複展開されていた状況を、Issue #773 (#768 P1-3) で本 reference に集約。bash literal 自体 (Step 0 / Step 1 / Pre-flight / Return Output re-patch の `flow-state-update.sh patch ...` 呼び出し) は **機能コードであり 4-site test (`hooks/tests/4-site-symmetry.test.sh`) の監視対象** のため、各 caller に引き続き残置する。本 reference は機能コードの **メタ契約のみ** を集約する。
>
> **DRIFT-CHECK ANCHOR (semantic, 4-site)** — Issue #651 / #660 / #773: 本セクションの記述は (1) `create.md` 🚨 Mandatory After Interview Step 0 / (2) `create-interview.md` 🚨 MANDATORY Pre-flight / (3) `create-interview.md` Return Output re-patch / (4) `stop-guard.sh` `create_post_interview` case arm WORKFLOW_HINT の **4 site 対称契約** を一元管理する。各 caller の anchor は本 reference へ semantic 参照する。

## Overview

`/rite:issue:create` orchestrator は `rite:issue:create-interview` sub-skill を呼び出し、return 後に Phase 0.6 → Delegation Routing → terminal sub-skill へ進む。この hand-off では LLM が sub-skill return tag (`[interview:skipped]` / `[interview:completed]`) を turn 境界と誤解釈して implicit stop する failure mode が #525 / #552 / #561 / #622 / #634 で繰り返し再発しており、4 site で同一 bash literal を **declarative に冗長配置する** ことで防御層チェーンを構成している。

| # | Site | 役割 |
|---|------|------|
| 1 | `commands/issue/create.md` 🚨 Mandatory After Interview **Step 0 Immediate Bash Action** | sub-skill return 直後の最初の tool call として idempotent patch を実行し、turn 境界感を解消 |
| 2 | `commands/issue/create-interview.md` 🚨 MANDATORY **Pre-flight** | sub-skill 開始時に flow state を `create_post_interview` へ pre-write (file 不在時は create / 存在時は patch) |
| 3 | `commands/issue/create-interview.md` **Return Output re-patch** | Return Output Format 直前で再度 patch し、`[CONTEXT] INTERVIEW_DONE=1` marker と caller HTML inline literal を整合させる |
| 4 | `hooks/stop-guard.sh` `create_post_interview` **case arm WORKFLOW_HINT** | implicit stop 発生時に LLM が次に実行すべき bash command literal を stderr に emit し、stop-guard 経由再入経路を提供 |

## bash 引数 symmetry — 4 必須引数

各 site の `flow-state-update.sh patch` 呼び出しは、以下 **4 引数を共通で含む** ことが契約:

| 引数 | 必須 | 役割 |
|------|------|------|
| `--phase` | ✅ | `create_post_interview` (sub-skill 完了直後の post phase) を指定 |
| `--active` | ✅ | `true` を明示。これがないと旧値 (例: `false`) が残存し stop-guard が early return する (Issue #660) |
| `--next` | ✅ | LLM が次に進むべき step を自然言語で記述 (`Proceed to Phase 0.6 ...`) |
| `--preserve-error-count` | ✅ | これがないと `flow-state-update.sh` の patch mode JQ_FILTER が `error_count = 0` でリセットし、RE-ENTRY DETECTED escalation + THRESHOLD bail-out 層が永久に unreachable になる (verified-review cycle 3 F-01 / #636) |

`hooks/tests/4-site-symmetry.test.sh` は各 site (`create.md` / `create-interview.md`) でこの 4 引数の `grep -c >= 1` を assert する。1 引数でも欠落すると test が fail する。bash 引数 symmetry を破壊する変更は厳禁。

## `--if-exists` の非対称性 (意図的)

`--if-exists` 引数は **3 site のみ** に存在し、`create-interview.md` の Pre-flight / Return Output re-patch には付与しない (意図的非対称):

| Site | `--if-exists` の有無 | 理由 |
|------|---------------------|------|
| (1) `create.md` Step 0 / Step 1 | 付与 | Step 0/1 実行時には sub-skill (Pre-flight) が既に flow state file を生成済みのため、`--if-exists` は no-op safety net として無害 |
| (2) `create-interview.md` Pre-flight | **付与しない** | flow state file 不在時は `create` mode で新規生成し、存在時は `patch` mode で更新する **2 経路分岐** を `_resolve-flow-state-path.sh` 経由で `[ -f "$state_file" ]` 形式で明示処理する。`--if-exists` (= patch mode 専用 silent skip flag) では 2 経路分岐を実装できない |
| (3) `create-interview.md` Return Output re-patch | **付与しない** | (2) と同じ理由 |
| (4) `stop-guard.sh` WORKFLOW_HINT | 付与 | (1) の literal copy として LLM が cwd=repo_root でそのまま実行する想定 |

`--if-exists` の非対称性は **bash 引数 symmetry 違反ではない**。symmetry 対象は `--phase` / `--active` / `--next` / `--preserve-error-count` の 4 引数のみであり、`--if-exists` は責務の違いを反映した意図的な差分。本 reference の本セクションが drift check の正規根拠であり、将来の symmetry 拡張案で `--if-exists` を 4 site 全てに揃える PR が出た場合は本 reference の rationale を再確認の上で慎重に判断すること。

## path 表現の非対称性 (意図的)

各 site の bash literal における `flow-state-update.sh` の path 表現は **2 形式で非対称** であり、これは意図的な設計:

| Site | path 表現 | 解決経路 |
|------|----------|---------|
| (1) `create.md` Step 0 / Step 1 | `{plugin_root}/hooks/flow-state-update.sh` | Claude Code plugin loader が `{plugin_root}` を expand してから LLM へ提示 |
| (2) `create-interview.md` Pre-flight / re-patch | `{plugin_root}/hooks/flow-state-update.sh` | (1) と同じ |
| (4) `stop-guard.sh` WORKFLOW_HINT | `bash plugins/rite/hooks/flow-state-update.sh ...` (relative path literal) | LLM が stderr の HINT 文字列をそのまま読んで cwd=repo_root で実行する想定。placeholder 展開経路を持たない |

stop-guard.sh の HINT 内に `{plugin_root}` を埋め込むと LLM が literal `{plugin_root}` をシェルへ渡してしまい動作しない。**4 site 対称契約は bash 引数 / semantics の対称性であり、path 表現の対称性ではない**。本注記は将来の drift check で path 非対称を false positive として flag しないための明示的契約。

## DRIFT-CHECK ANCHOR pattern

本契約に従う各 caller の anchor コメントは以下のルールで記述する:

1. **Semantic name 参照のみ**: `(L1331-1332)` のような literal 行番号は禁止 (Wiki: PR #586/#600/#605/#617/#619/#624/#626/#661/#756 経験則)。`### Step 0 Immediate Bash Action` のような section heading 名で参照する
2. **本 reference への semantic anchor**: 各 caller の DRIFT-CHECK ANCHOR は「本契約の SoT は `references/sub-skill-handoff-contract.md`」を semantic に明示し、契約の詳細は本 reference に集約する
3. **Bidirectional backlink**: 本 reference 冒頭の DRIFT-CHECK ANCHOR ブロックは 4 site への逆参照を semantic name で列挙する (上記「Overview」表が該当)
4. **Pair 同期契約**: `create.md` と `create-interview.md` の anchor は **pair で同時更新**。Wiki 経験則「Asymmetric Fix Transcription」(PR #548 等) より、片方だけの修正は厳禁

## 関連 Issue / PR (regression history)

本契約の各層は過去の incident で段階的に強化されてきた。詳細は `regression-history.md` (本 PR ではまだ未抽出、Issue #773 PR 6 で integrate 予定) に集約予定。短期的な参照ポインタ:

| 関連 Issue | 強化内容 |
|-----------|---------|
| #525 | AC-3 grep 検証 phrase 4 つ (`anti-pattern` / `correct-pattern` / `same response turn` / `DO NOT stop`) を `create.md` 本体に永続化 |
| #552 | Pre-check list (Item 0/1/2/3) を導入 (本 PR 範囲外、Issue #773 PR 2 で `pre-check-routing.md` へ抽出予定) |
| #561 | sentinel 形式を bare bracket → HTML comment に移行 (`<!-- [create:completed:{N}] -->`) |
| #622 | `stop-guard.sh` `create_interview` case arm を導入 (3 site 対称化) |
| #634 | `[CONTEXT] INTERVIEW_DONE=1` marker と Step 0 Immediate Bash Action を導入。turn 境界感を解消 |
| #636 | `--preserve-error-count` を 4 引数 symmetry list に追加。silent failure を防ぐ exit code 明示 check も導入 |
| #651 / PR #654 | 3 site → 4 site 対称化に拡張 (`stop-guard.sh` WORKFLOW_HINT に bash literal を含める) |
| #660 | `--active true` を 4 引数 symmetry list に追加。`active=false` 残存による stop-guard early return を防ぐ |
| #771 (#768 P4-12) | `hooks/tests/4-site-symmetry.test.sh` を新設し 4 引数 symmetry を機械検証 |
| #773 (#768 P1-3) | 本 reference を新設し 4 site 対称化のメタ契約を集約 (本 PR) |

## 関連 Wiki 経験則

- **Asymmetric Fix Transcription**: `create.md` と `create-interview.md` の anchor は必ず同 commit で更新。片肺更新は #548 / #688 / #708 / #711 等で繰り返し再発している pattern
- **DRIFT-CHECK ANCHOR は semantic name 参照で記述する (line 番号禁止)**: 本 reference が semantic anchor の canonical 例
- **前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する**: `--active true` / `--preserve-error-count` 等の引数 1 つの欠落で 4 site の防御層が連動して機能しなくなる事例 (#660 で実測)
- **極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる**: 本 PR のような sibling site refactor は `grep` で対称性を網羅的に検証することで 0 findings 高確信レビューが可能
