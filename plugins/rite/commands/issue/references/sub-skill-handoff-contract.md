# Sub-skill Handoff Contract — 4-site 対称化の正規定義

> **Source of Truth**: 本ファイルは `/rite:issue:create` ワークフローにおける orchestrator (`create.md`) と sub-skill (`create-interview.md`) 間の hand-off で発火する `flow-state-update.sh patch` 系 bash literal の **4-site 対称化契約** の SoT である。`create.md` 🚨 Mandatory After Interview Step 0 の DRIFT-CHECK ANCHOR / `create-interview.md` 🚨 MANDATORY Pre-flight + Return Output re-patch の DRIFT-CHECK ANCHOR は本ファイルへ参照する。
>
> **抽出経緯**: 4-site 対称化のメタ説明 (DRIFT-CHECK ANCHOR / `--if-exists` 非対称性 / path 表現非対称性) が `create.md` / `create-interview.md` 双方に長大 blockquote として重複展開されていた状況を、Issue #773 (#768 P1-3) で本 reference に集約。bash literal 自体 (Step 0 / Step 1 / Pre-flight / Return Output re-patch の `flow-state-update.sh patch ...` 呼び出し) は **機能コードであり 4-site test (`hooks/tests/4-site-symmetry.test.sh`) の監視対象** のため、各 caller に引き続き残置する。本 reference は機能コードの **メタ契約のみ** を集約する。
>
> **DRIFT-CHECK ANCHOR (semantic, 3-site + historical 4th)** — Issue #651 / #660 / #773: 本セクションの記述は (1) `create.md` 🚨 Mandatory After Interview Step 0 / (2) `create-interview.md` 🚨 MANDATORY Pre-flight / (3) `create-interview.md` Return Output re-patch の **3 site 対称契約 (現状)** を一元管理する。旧 site (4) `stop-guard.sh` `create_post_interview` case arm WORKFLOW_HINT は撤去済み (commit `e2dfae0`、2026-04-26、Overview 表参照)。「4-site 対称化」「4 site」表記は historical な呼称 (旧 4 site 構成時代の固有名) として保持し、現状の対称契約は 3 site で維持する。各 caller の anchor は本 reference へ semantic 参照する。

## Overview

`/rite:issue:create` orchestrator は `rite:issue:create-interview` sub-skill を呼び出し、return 後に Phase 0.6 → Delegation Routing → terminal sub-skill へ進む。この hand-off では LLM が sub-skill return tag (`[interview:skipped]` / `[interview:completed]`) を turn 境界と誤解釈して implicit stop する failure mode が #525 / #552 / #561 / #622 / #634 で繰り返し再発しており、4 site で同一 bash literal を **declarative に冗長配置する** ことで防御層チェーンを構成している。

| # | Site | 役割 |
|---|------|------|
| 1 | `commands/issue/create.md` 🚨 Mandatory After Interview **Step 0 Immediate Bash Action** + **Step 1** | sub-skill return 直後の最初の tool call として idempotent patch を実行し、turn 境界感を解消 (Step 0 / Step 1 の 2 occurrence) |
| 2 | `commands/issue/create-interview.md` 🚨 MANDATORY **Pre-flight** | sub-skill 開始時に flow state を `create_post_interview` へ pre-write (file 不在時は create / 存在時は patch) |
| 3 | `commands/issue/create-interview.md` **Return Output re-patch** (2 sub-site: (3a) bash block 1 occurrence + (3b) caller HTML inline literal 2 occurrence、計 3 occurrence) | (3a) Return Output Format 直前で `_resolve-flow-state-path.sh` 経由 bash block により `create_post_interview` を再 patch (機能コード)、(3b) Output format example 内の caller HTML コメント literal で orchestrator-side 実行想定の inline bash command を提供 (`<!-- caller: IMMEDIATELY run ... -->`、interview:skipped/completed の 2 example) |
| ~~4~~ (historical) | ~~`hooks/stop-guard.sh` `create_post_interview` case arm WORKFLOW_HINT~~ | **撤去済み** (commit `e2dfae0`、2026-04-26、`refactor(hooks): stop-guard.sh を撤去（途中停止問題の根本対策）`)。Stop hook 自体が実装方針として撤去されたため、本 site (4) は **無効化**。撤去前は 4-site 対称契約として機能していたが、現状は **2 ファイル / 3 site (うち site (3) は (3a)/(3b) の二重構造) / 6 occurrence (詳細は下記「`--if-exists` の非対称性」セクションの occurrence 集計表参照)** で対称契約を維持する。`hooks/tests/4-site-symmetry.test.sh` も SCOPE adjustment コメントで「`stop-guard.sh`: file does not exist」を明記 (verified 2026-05-03) |

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

`--if-exists` 引数は **occurrence 単位で計 4 箇所** に存在し、`create-interview.md` の Pre-flight bash block / Return Output re-patch bash block (機能コード経路) には付与しない (意図的非対称)。site (3) は **二重構造** (3a Pre-flight bash block / 3b caller HTML inline literal) を持つため、表は site/sub-site 単位で記述する:

| Site | sub-site | 種別 | `--if-exists` の有無 | 理由 |
|------|---------|------|---------------------|------|
| (1) `create.md` Step 0 / Step 1 | — | 機能コード (orchestrator 自身の bash block) | 付与 (2 occurrence) | Step 0/1 実行時には sub-skill (Pre-flight) が既に flow state file を生成済みのため、`--if-exists` は no-op safety net として無害 |
| (2) `create-interview.md` Pre-flight bash block | — | 機能コード (sub-skill 自身の bash block) | **付与しない** | flow state file 不在時は `create` mode で新規生成し、存在時は `patch` mode で更新する **2 経路分岐** を `_resolve-flow-state-path.sh` 経由で `[ -f "$state_file" ]` 形式で明示処理する。`--if-exists` (= patch mode 専用 silent skip flag) では 2 経路分岐を実装できない |
| (3a) `create-interview.md` Return Output re-patch bash block | — | 機能コード (sub-skill 自身の bash block) | **付与しない** | (2) と同じ責務 (file 存在分岐の 2 経路実装が必要) |
| (3b) `create-interview.md` Return Output Format 内 caller HTML inline literal | `interview:skipped` example + `interview:completed` example | orchestrator-side 実行想定 literal (HTML コメント内) | 付与 (2 occurrence) | sub-skill return 後に orchestrator が cwd=repo_root で本 inline literal を実行する時点では Pre-flight が既に完了しており flow state file 存在は保証済み。`--if-exists` は no-op safety net として無害 |
| ~~(4) `stop-guard.sh` WORKFLOW_HINT~~ | — | (historical) | ~~付与~~ | **撤去済み** (commit `e2dfae0`)。本 site は無効化 |

**Occurrence 単位の集計** (`--if-exists` を含む箇所を occurrence 単位で列挙):

| Site / sub-site | occurrence 数 | `--if-exists` 付与 |
|----------------|--------------|-------------------|
| (1) `create.md` Step 0 | 1 | ✅ |
| (1) `create.md` Step 1 | 1 | ✅ |
| (2) `create-interview.md` Pre-flight bash block | 1 | ❌ |
| (3a) `create-interview.md` Return Output re-patch bash block | 1 | ❌ |
| (3b) `create-interview.md` interview:skipped example caller HTML inline literal | 1 | ✅ |
| (3b) `create-interview.md` interview:completed example caller HTML inline literal | 1 | ✅ |
| **合計** | **6 occurrence** | **付与 4 / 非付与 2** |

**Site 単位の集計** (sub-site を 1 site とまとめる場合):

| Site | 種別 | `--if-exists` 付与 |
|------|------|-------------------|
| (1) `create.md` Step 0/Step 1 | 機能コード (orchestrator-side) | ✅ (2 occurrence) |
| (2) `create-interview.md` Pre-flight bash block | 機能コード (sub-skill 自身) | ❌ |
| (3a) `create-interview.md` Return Output re-patch bash block | 機能コード (sub-skill 自身) | ❌ |
| (3b) `create-interview.md` Return Output caller HTML inline literal | orchestrator-side 実行想定 literal | ✅ (2 occurrence) |

stop-guard.sh 撤去により旧仕様の site (4) は無効化されたため、現状の対称契約は **3 site (1)(2)(3) で構成**、site (3) は (3a)/(3b) の二重構造を持つ。`--if-exists` は **機能コード経路 vs caller-literal 経路** で付与判断が分かれる: orchestrator-side (1) と caller-side literal (3b) は Pre-flight 完了後に実行されるため safety net として付与、sub-skill 自身が実行する (2)(3a) は file 不在時の create mode 分岐が必要なため非付与。

`--if-exists` の非対称性は **bash 引数 symmetry 違反ではない**。symmetry 対象は `--phase` / `--active` / `--next` / `--preserve-error-count` の 4 引数のみであり、`--if-exists` は機能コード/caller-literal の責務の違いを反映した意図的な差分。本 reference の本セクションが drift check の正規根拠であり、将来の symmetry 拡張案で `--if-exists` を全 occurrence に揃える PR が出た場合は本 reference の rationale を再確認の上で慎重に判断すること。

## path 表現の非対称性 (意図的)

各 site の bash literal における `flow-state-update.sh` の path 表現は **2 形式で非対称** であり、これは意図的な設計:

| Site | path 表現 | 解決経路 |
|------|----------|---------|
| (1) `create.md` Step 0 / Step 1 | `{plugin_root}/hooks/flow-state-update.sh` | Claude Code plugin loader が `{plugin_root}` を expand してから LLM へ提示 |
| (2)(3a) `create-interview.md` Pre-flight bash block / Return Output re-patch bash block | `{plugin_root}/hooks/flow-state-update.sh` | (1) と同じ機能コード経路 |
| (3b) `create-interview.md` Return Output Format 内 caller HTML inline literal | `bash plugins/rite/hooks/flow-state-update.sh ...` (relative path literal) | LLM が HTML コメント内の inline literal をそのまま読んで cwd=repo_root で実行する想定。placeholder 展開経路を持たない (orchestrator-side 実行想定) |
| ~~(4) `stop-guard.sh` WORKFLOW_HINT~~ | (historical, removed in commit `e2dfae0`) | 撤去前は `bash plugins/rite/hooks/flow-state-update.sh ...` 形式の relative path literal を保持していた |

caller HTML inline literal (3b) や旧 stop-guard.sh HINT (撤去済み) のような **literal 文字列に `{plugin_root}` を埋め込むと LLM がそのまま literal `{plugin_root}` をシェルへ渡してしまい動作しない**。**対称契約は bash 引数 / semantics の対称性であり、path 表現の対称性ではない**。本注記は将来の drift check で path 非対称を false positive として flag しないための明示的契約。

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
| **stop-guard.sh 撤去** (commit `e2dfae0`、2026-04-26) | `refactor(hooks): stop-guard.sh を撤去（途中停止問題の根本対策）` — Stop hook の exit 2 block で LLM が thinking ループに陥る構造的問題を根本解決するため、Issue #561〜#651 系列の累積 9 回以上の対策が拠って立つ前提（「block + 誘導」モデル）を撤去。これにより site (4) は無効化され、現状は **2 ファイル / 3 site / 6 occurrence** (上記「`--if-exists` の非対称性」セクションの occurrence 集計表参照) で対称契約を維持する |
| #771 (#768 P4-12) | `hooks/tests/4-site-symmetry.test.sh` を新設し 4 引数 symmetry を機械検証。SCOPE adjustment コメントで `stop-guard.sh: file does not exist as of Issue #771 work (verified 2026-05-03)` を明記 |
| #773 (#768 P1-3) | 本 reference を新設し対称契約のメタ契約を集約 (本 PR)。stop-guard.sh 撤去後の現状を反映し site (3) の二重構造 (3a 機能コード bash block / 3b caller HTML inline literal) を表で明示 |

## 関連 Wiki 経験則

- **Asymmetric Fix Transcription**: `create.md` と `create-interview.md` の anchor は必ず同 commit で更新。片肺更新は #548 / #688 / #708 / #711 等で繰り返し再発している pattern
- **DRIFT-CHECK ANCHOR は semantic name 参照で記述する (line 番号禁止)**: 本 reference が semantic anchor の canonical 例
- **前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する**: `--active true` / `--preserve-error-count` 等の引数 1 つの欠落で 4 site の防御層が連動して機能しなくなる事例 (#660 で実測)
- **極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる**: 本 PR のような sibling site refactor は `grep` で対称性を網羅的に検証することで 0 findings 高確信レビューが可能
