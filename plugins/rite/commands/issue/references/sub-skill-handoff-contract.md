# Sub-skill Handoff Contract

> **SoT**: `/rite:issue:create` における orchestrator (`create.md`) と sub-skill (`create-interview.md`) 間の hand-off で発火する `flow-state-update.sh patch` 系 bash literal の対称化契約。機能契約の機械検証は `plugins/rite/hooks/tests/4-site-symmetry.test.sh` が担う (本 reference は機能契約の SoT ではなく、test の解釈根拠)。

## 対称契約の構成 (3 site)

| # | Site | 役割 |
|---|------|------|
| 1 | `commands/issue/create.md` 🚨 Mandatory After Interview Step 0 + Step 1 | sub-skill return 直後の最初の tool call として idempotent patch を実行 (2 occurrence) |
| 2 | `commands/issue/create-interview.md` 🚨 MANDATORY Pre-flight | sub-skill 開始時に flow state を `create_post_interview` へ pre-write (file 不在時は create / 存在時は patch の 2 経路分岐) |
| 3 | `commands/issue/create-interview.md` Return Output | (3a) bash block での re-patch + (3b) caller HTML inline literal (`interview:skipped` / `interview:completed` の 2 example、合計 2 occurrence) |

## 4 必須引数

各 site の `flow-state-update.sh patch` 呼び出しは以下 4 引数を共通で含む:

| 引数 | 役割 |
|------|------|
| `--phase` | `create_post_interview` を指定 (sub-skill 完了直後の post phase) |
| `--active` | `true` を明示。欠落すると旧値が残存し stop-guard が early return |
| `--next` | LLM が次に進むべき step を自然言語で記述 |
| `--preserve-error-count` | 欠落すると patch mode JQ_FILTER が `error_count = 0` でリセットし、RE-ENTRY DETECTED escalation + THRESHOLD bail-out 層が unreachable になる |

`hooks/tests/4-site-symmetry.test.sh` は各 site でこの 4 引数の `grep -c >= 1` を assert する。1 引数欠落で test fail。

## `--if-exists` の非対称性 (意図的)

機能コード経路 (sub-skill 自身が実行する bash block: site 2, site 3a) は `--if-exists` を **付与しない** — file 不在時の `create` mode 分岐を `[ -f "$state_file" ]` で明示処理するため、`--if-exists` (= patch mode 専用 silent skip flag) では 2 経路分岐を実装できない。

orchestrator-side (site 1) と caller-literal (site 3b) は Pre-flight 完了後に実行されるため file 存在が保証済み。`--if-exists` を no-op safety net として付与。

| Site | `--if-exists` |
|------|---------------|
| (1) `create.md` Step 0 / Step 1 | ✅ (2 occurrence) |
| (2) `create-interview.md` Pre-flight bash block | ❌ |
| (3a) `create-interview.md` Return Output re-patch bash block | ❌ |
| (3b) `create-interview.md` Return Output caller HTML inline literal | ✅ (2 occurrence) |

`--if-exists` の非対称は **bash 引数 symmetry 違反ではない**。symmetry 対象は `--phase` / `--active` / `--next` / `--preserve-error-count` の 4 引数のみであり、`--if-exists` は機能コード/caller-literal の責務の違いを反映した意図的差分。

## path 表現の非対称性 (意図的)

機能コード (site 1, 2, 3a) は `{plugin_root}/hooks/flow-state-update.sh` (Claude Code plugin loader が `{plugin_root}` を expand してから LLM へ提示)。caller HTML inline literal (3b) は `bash plugins/rite/hooks/flow-state-update.sh ...` (relative path、cwd=repo_root で実行想定)。

HTML コメント内 literal に `{plugin_root}` を埋め込むと LLM がそのまま literal をシェルへ渡し動作しないため、site 3b は relative path literal を使用する。

| Site | path 表現 |
|------|----------|
| (1) `create.md` Step 0 / Step 1 | `{plugin_root}/hooks/flow-state-update.sh` |
| (2)(3a) `create-interview.md` 機能コード | `{plugin_root}/hooks/flow-state-update.sh` |
| (3b) `create-interview.md` caller HTML inline literal | `bash plugins/rite/hooks/flow-state-update.sh ...` |

## DRIFT-CHECK ANCHOR pattern

各 caller の anchor コメントは以下のルールで記述する:

1. **Semantic name 参照のみ**: literal 行番号 (`(L1331-1332)` 等) は禁止。`### Step 0 Immediate Bash Action` のような section heading 名で参照する
2. **本 reference への semantic anchor**: 各 caller の anchor は「本契約 SoT は `references/sub-skill-handoff-contract.md`」を semantic に明示
3. **Bidirectional backlink**: 本 reference 「対称契約の構成」表が 3 site への逆参照を semantic name で列挙
4. **Pair 同期契約**: `create.md` と `create-interview.md` の anchor は **pair で同時 commit** で更新 (片肺更新は Asymmetric Fix Transcription anti-pattern)
