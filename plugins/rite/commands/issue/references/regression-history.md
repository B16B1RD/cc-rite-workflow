# Regression History — `/rite:issue:create` Workflow

このリファレンスは `/rite:issue:create` ワークフロー周辺で発生した実装上の incident と、その対策が段階的に強化されてきた経緯を **Issue 番号別** に集約します。

## 位置づけ

本体ファイル (`create.md` / `create-interview.md` / `create-decompose.md` / `create-register.md`) では短い参照 `(Issue #N)` を維持しつつ、以下の長い経緯解説を本 reference に移動して本体の認知負荷を下げます:

- 「protocol violation 警告」など同一 incident を防ぐためのガード文の重複理由
- 「Drift guard」「DRIFT-CHECK ANCHOR」などの対称化契約の発端と修正履歴
- 「Issue #634 enhancement」「Issue #636 cycle 3 F-01」など review cycle で得られた失敗 mode の文脈

> **対称化契約の正規定義** は [`sub-skill-handoff-contract.md`](./sub-skill-handoff-contract.md) を参照してください。本 reference は incident 駆動の **時系列史** を記録し、契約レイヤーの正規定義は重複しません。

## 集約方針

- **本体に残すもの**: 短い参照 `(Issue #N)` / 実行時に LLM が読む MUST/MUST NOT 条文 / 機能挙動への直接的な参照
- **本 reference に移すもの**: 長い経緯解説 / Drift guard 説明 / cycle 番号付きの review 記録
- **触らないもの**: AC-3 grep 検証 4 phrase (`anti-pattern` / `correct-pattern` / `same response turn` / `DO NOT stop`) は `create.md` 本体に残す (NFR-2)
- **本 reference 内での `🚨` 使用**: `🚨 Mandatory After ...` の section 名引用時のみ使用 (本体側 sentinel との対称性確保)。本体 P1-5 の削減方針 (12 → 4 occurrence) は `create.md` 本体限定で、references 内では引用目的の使用を許容する

## Issue 番号別経緯 (時系列順)

### Issue #444 — Terminal Completion pattern

> **強化内容**: terminal sub-skill (`create-register.md` / `create-decompose.md`) が flow-state deactivation + completion marker emit + next-step output を **内製** する設計を導入。orchestrator (`create.md`) の `🚨 Mandatory After Delegation` は defense-in-depth として残存。

統一完了 marker は `[create:completed:{N}]` に統合され、legacy patterns (`[register:created:{N}]` / `[decompose:completed:{N}]`) は撤去された。`create-decompose.md` Phase 0.9 で sub-Issues が作成された Normal path は本 sub-skill が完了処理を行い、Delegation path (interview cancelled → `create-register` に委譲) では `create-register.md` 側が独自に Terminal Completion を実施する。

### Issue #475 — Mode B defense (Bypass prohibition)

> **強化内容**: Phase 0 と Delegation to Interview の 2 箇所に **同一の MUST NOT ガード文 (Bypass prohibition)** を配置し、orchestrator が `gh issue create` を直接呼ぶ / `rite:issue:create-interview` 起動を skip する / Phase 0.6 等を 1 ステップに collapse する経路を遮断する。

このガード文は当初 `**⚠️ Drift guard**: This same block is repeated verbatim ... Both occurrences MUST stay identical` という drift guard 契約により「両方を identical に保て」というルールで運用された。Issue #773 PR 6/8 (P1-5) で本契約は **解除** され、ガード文を 1 箇所に統合 + 本 reference へリンクする運用に移行した。

> **PR 6/8 (本 PR) 移行方針**: `create.md` の Phase 0 セクションに 1 箇所だけ Bypass prohibition を残し、Delegation to Interview セクションでは「Phase 0 の Bypass prohibition を再確認すること」と本 reference へリンクする 1 行で代替する。

### Issue #514 — MUST NOT: unknown status silent 通過禁止

> **強化内容**: `link-sub-issue.sh` のサブイシューリンク結果 (`ok` / `already-linked` / `failed` / 未知 status) の `case` 分岐において、未知 status を silent に通過させない `*)` ブランチを必須化。

`commands/issue/parent-routing.md` と `commands/issue/create-decompose.md` の両方で同 case ブロックを保持。Wiki 経験則 「Asymmetric Fix Transcription」(PR #548) の対称性契約の現れの一つ。

### Issue #520 — create-decompose.md case 分岐 fix

> **強化内容**: `create-decompose.md` の sub-issues API linkage における case 分岐の修正 (詳細は `create-decompose.md` L578 のインラインコメント参照)。

短い修正であり、本 reference では存在記録のみ保持。

### Issue #525 — Sub-skill return tag implicit stop / 4-site declarative

> **強化内容**: `rite:issue:create-interview` sub-skill 呼び出し後の return tag (`[interview:skipped]` / `[interview:completed]`) を LLM が **turn 境界と誤解釈して implicit stop** する failure mode を発見。これに対する declarative な防御層を 4 site で冗長配置 (現在は 3 site、stop-guard.sh 撤去後)。

特に `create.md` 本体には AC-3 grep 検証 phrase 4 つを永続化:

| AC-3 grep 検証 phrase | 役割 |
|----------------------|------|
| `anti-pattern` | 「sub-skill が return したら turn を閉じる」誤った挙動の例示 |
| `correct-pattern` | 「return 直後に Mandatory After を実行」正しい挙動の例示 |
| `same response turn` | 同 turn 内継続の必須性 |
| `DO NOT stop` | implicit stop 禁止の明示 |

これら 4 phrase は `create.md` 本体から **削除禁止** (NFR-2)。本 reference でも経緯記述上で言及するが、本体の機能契約として保護される。

### Issue #552 — Completion marker + caller continuation hint dual emission

> **強化内容**:
> - **Bug2**: `[create:completed:{N}]` sentinel marker と user-visible 完了メッセージの両立。Sentinel は HTML コメント形式 (`<!-- [create:completed:{N}] -->`) で grep-matchable に維持しつつ、user-visible 末尾を `✅` メッセージ + 次のステップに固定。
> - **Caller continuation hint dual emission**: caller への継続誘導 hint を **plain-text + HTML comment** の dual 形式で emit。HTML comment が rendering で stripped される mode でも plain-text は LLM が観察できる。

`create-interview.md` Return Output Format の caller HTML comment 部分はこの dual emission ルールに準拠。HTML-comment-only への書き換えは regression。

### Issue #561 — HTML comment sentinel UX fix

> **強化内容**: 当初 bare bracket 形式 (`[create:completed:N]`) で emit されていた sentinel が user-visible 末尾の terminal token として表示されていた UX 問題を修正。HTML comment 形式 (`<!-- [create:completed:N] -->`) に変更し、user-visible 末尾を `✅` 完了メッセージ + 次ステップブロックに固定。

LLM の turn-boundary heuristic も弱体化させる効果があり、bare sentinel が「自然な停止点」として誤解釈される #561 系列の regression を防ぐ。同 policy が `[interview:skipped]` / `[interview:completed]` にも適用される。

### Issue #582 — ERE alternation `\|` リテラル誤解釈

> **強化内容**: `pre-check-routing.md` の grep pattern 設計レビューで「ERE では `\|` がリテラル `|` として解釈され alternation として機能しない」failure mode を実測。`grep -E '\[(interview\|create):...]'` ではなく `grep -E '\[(interview|create):...]'` (unescaped pipe) が正解。

加えて `[0-9]+` を BRE で書くと「1 個の数字 + リテラル `+`」と誤解釈されるため `-E` flag が必須。bracket-unescaped 形式 `[create:completed:[0-9]+]` は character class として誤解釈されるため使用禁止。

### Issue #622 — regression of #552: Defense-in-Depth bash skip 防止

> **強化内容**: Bug Fix / Chore preset path (Phase 0.4.1 → skip Phase 0.5) で、`create-interview.md` 末尾に配置されていた Defense-in-Depth bash block を LLM が skip して return Output に直接ジャンプする failure mode を発見。

修正: Defense-in-Depth bash block を sub-skill の **絶対冒頭** に移動し、interview scope に関わらず必ず flow-state write が発火するよう保証。当時 `stop-guard.sh` には `create_interview` case arm が存在せず、orchestrator の implicit stop が block されない経路だった (後続の `stop-guard.sh` 撤去で本 case arm 自体が消失)。

### Issue #634 — `[CONTEXT] INTERVIEW_DONE=1` marker enhancement

> **強化内容**: `create-interview.md` Return Output の **FIRST 行** (LAST 行ではない) として `[CONTEXT] INTERVIEW_DONE=1` plain-text marker を emit。HTML コメント除去 rendering でも grep 可能で、orchestrator の Pre-check Item 0 (routing dispatcher) と Mandatory After Interview Step 0 が両方 consume する。

加えて Step 0 Immediate Bash Action を導入: `create-interview.md` return 直後の **very first tool call** として bash command を実行することで、自然な turn-boundary point (「sub-skill が finished」) を「LLM がまだ tool 実行中」状態に置き換える。LLM の implicit stop 動機を構造的に弱体化する。

### Issue #636 — `--preserve-error-count` silent failure 防止

> **強化内容**: `flow-state-update.sh patch` mode の JQ_FILTER がデフォルトで `.error_count = 0` をリセットすることが判明。これにより、3 site (`create.md` Step 0 / Step 1 / `create-interview.md` Pre-flight) すべてが `--phase create_post_interview` で同一 phase へ idempotent patch する対称契約全体で error_count がリセットされ、`RE-ENTRY DETECTED` escalation counter を毎回ゼロクリアし、`THRESHOLD=3` bail-out 層が **永久に unreachable** になっていた。

修正: `--preserve-error-count` を 4 引数 symmetry list (`--phase` / `--active` / `--next` / `--preserve-error-count`) に追加し、self-patch でも escalation counter を保持。verified-review cycle 3 F-01 で実測確認。同時に exit code 明示 check も導入 (`--if-exists` は file 不在 skip と patch 成功を両方 exit 0 で返すため、真の patch 失敗のみを `STEP_0_PATCH_FAILED` retained flag で区別する)。

### Issue #651 — 3 site → 4 site 対称化拡張 (PR #654)

> **強化内容**: 当時 3 site (`create.md` Step 0 / `create-interview.md` Pre-flight / Return Output re-patch) に集約されていた対称契約を、`stop-guard.sh` `create_post_interview` case arm WORKFLOW_HINT を加えた **4 site** に拡張。

cycle 2 review F-NEW1 で「Stop hook の UI 上は exit 2 後でも `Churned for X` 表示が出る場合があり、ユーザーが『continue 手動入力が必要』と認識する余地がある (技術的には自動継続している)」 Claude Code UI 限界に対する declarative 強化として、いずれの経路でも同一 bash literal が caller に提示されるよう保証。

> **後続: stop-guard.sh 撤去 (commit `e2dfae0`、2026-04-26)**: Stop hook の exit 2 block で LLM が thinking ループに陥る構造的問題を根本解決するため、`stop-guard.sh` 自体が撤去された。これにより site (4) は無効化され、現状は再び **3 site** で対称契約を維持。「4-site 対称化」「4 site」表記は historical な呼称として保持される (旧 4 site 構成時代の固有名)。

### Issue #660 — 8 種防御層 silent omit 検出 (workflow incident detection)

> **強化内容**: 過去 9 件の Issue で導入した 8 種類の防御層 (declarative / sentinel / Pre-check / whitelist / Pre-flight / Step 0 / 4-site 対称化 / case arm) が AND 論理で組まれ、`.rite-flow-state.active=true` という単一前提条件に依存していたことが判明。`commands/issue/create.md` 等の patch site が `--active true` を omit したことで、stop-guard.sh が `EXIT:0 reason=not_active` で early return し、8 種の case arm すべてが到達不能になっていた。

`.rite-stop-guard-diag.log` 直近 30 件中 28 件 (93%) が `EXIT:0 reason=not_active` で防御層は本番で 9 割以上機能していなかったことが実測確認された。修正は短期 (link 修復) → 中期 (デフォルト挙動の固定) → 長期 (前提条件依存の解消)。PR #661 で 17 patch site / 12 ファイルに `--active true` を網羅追加し、post-fix の本番 diag log で `EXIT:2 reason=blocking` 9 件 / `EXIT:0 reason=not_active` 3 件を観測 → stop-guard が正しく blocking 動作することを実証 (累積 11 回目で短期修復の link 全回復)。本番条件再現 TC 5 件 (TC-660-A〜E) を test infrastructure に永続化し、CI で AND 論理 silent omit の再導入を機械検出可能にした。

### Issue #771 (#768 P4-12) — `4-site-symmetry.test.sh` 新設

> **強化内容**: `hooks/tests/4-site-symmetry.test.sh` を新設し、4 引数 symmetry (`--phase` / `--active` / `--next` / `--preserve-error-count`) を機械検証。SCOPE adjustment コメントで `stop-guard.sh: file does not exist as of Issue #771 work (verified 2026-05-03)` を明記し、現状の 3 site 構成を test レイヤーで pin する。

### Issue #773 (#768 P1-3) — references 抽出 + 強調マーカー適正化 (本 PR シリーズ)

> **強化内容**: `commands/issue/references/` ディレクトリを新設し、`create.md` 本体 (835 行) から 8 ファイル抽出 + 本体を ≤ 250 行にスリム化する (PR 1-8 で漸進、PR 7/8 時点での本体行数: 734 行、PR 8 完了で目標達成予定)。同時に強調マーカー (P1-5) と Pre-check list 分離 (P3-9) も実施する。

| PR | スコープ | 抽出 references |
|----|---------|----------------|
| PR 1 (#789) | 4-site 対称化のメタ契約集約 | `sub-skill-handoff-contract.md` |
| PR 2 (#791) | Pre-check list 分離 (P3-9) | `pre-check-routing.md` |
| PR 3 (#792) | EDGE-2/3/4/5 集約 | `edge-cases-create.md` |
| PR 4 (#794) | XS/S/M/L/XL 判定基準 | `complexity-gate.md` |
| PR 5 (#796) | slug 生成ルール SoT | `slug-generation.md` |
| PR 6 (#800) | regression-history 抽出 + 強調マーカー適正化 (P1-5) | `regression-history.md` (本ファイル) |
| **PR 7 (本 PR)** | **Implementation Contract Section 1-9 mapping** | **`contract-section-mapping.md`** |
| PR 8 (予定) | bulk-create 連結パターン | `bulk-create-pattern.md` |

PR 6 で本 reference を抽出すると同時に、`create.md` の `🚨` 強調マーカーを **12 → 4 occurrence** に削減した (P1-5、上限 ≤ 5、PR 7-8 で逸脱しないこと)。Issue #475 由来の重複 protocol violation 警告は、Drift guard 契約 (「両方 identical を保て」) を **解除して** 1 箇所統合し、もう 1 箇所は本 reference へのリンクで代替している。

PR 7 では `create-register.md` Phase 2.2 Step 2-3 の Type → Section 3 Type Core mapping table・Interview Perspective → Target Sections mapping table・Section inclusion rules table を `contract-section-mapping.md` に集約し、本体には `> Moved` 参照ブロックのみ残置する。`create-decompose.md` Phase 0.7.3 cancel path の `create-register.md Phase 2.2 Step 3` への参照リンクも本 reference 経由に更新する。Step 4-6 (AC 生成 / Test 仕様 / Output Validation) は Implementation Contract の **生成手順** であり mapping ではないため、本体に維持する。

## 旧構成: stop-guard.sh `create_post_interview` case arm WORKFLOW_HINT (撤去済み)

> **状態**: 撤去 — commit `e2dfae0` (2026-04-26)
> **撤去理由**: `refactor(hooks): stop-guard.sh を撤去（途中停止問題の根本対策）` — Stop hook の exit 2 block で LLM が thinking ループに陥る構造的問題を根本解決するため、Issue #561〜#651 系列の累積 9 回以上の対策が拠って立つ前提（「block + 誘導」モデル）自体を撤去。

撤去後の現状:
- 対称契約は **2 ファイル / 3 site / 6 occurrence** で維持 (詳細は [`sub-skill-handoff-contract.md`](./sub-skill-handoff-contract.md) の「`--if-exists` の非対称性」セクションの occurrence 集計表を参照)
- `hooks/tests/4-site-symmetry.test.sh` は SCOPE adjustment コメントで `stop-guard.sh: file does not exist as of Issue #771 work` を明記
- 「4-site 対称化」「4 site」表記は historical な呼称として保持 (旧 4 site 構成時代の固有名)

## 関連 Wiki 経験則

- **Asymmetric Fix Transcription**: `create.md` と `create-interview.md` の anchor は必ず同 commit で更新。片肺更新は #548 / #688 / #708 / #711 等で繰り返し再発している pattern
- **前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する**: `--active true` / `--preserve-error-count` 等の引数 1 つの欠落で防御層が連動して機能しなくなる事例 (#660 で実測)
- **散文で宣言した設計は対応する実装契約がなければ機能しない**: protocol violation 警告など散文ガード文だけでは LLM の挙動を変えられない場合があるため、宣言と実装契約 (sentinel / hook check / bash literal) を pair で配置する
- **DRIFT-CHECK ANCHOR は semantic name 参照で記述する (line 番号禁止)**: 本 reference は incident 駆動の時系列史であり、semantic anchor 契約は [`sub-skill-handoff-contract.md`](./sub-skill-handoff-contract.md) を参照
