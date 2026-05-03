# Pre-check List — Sub-skill Return Routing & Turn Termination Gate

> **Source of Truth**: 本ファイルは `/rite:issue:create` ワークフロー orchestrator (`create.md`) の **Pre-check list (Issue #552)** の SoT である。Item 0 (routing dispatcher) と Item 1-3 (state checks) を集約し、4 種類の grep パターン・3 つの sentinel 形式・場面 (a) / (b) の評価意味分岐を 1 ファイルに閉じ込めることで `create.md` 本体の認知負荷を下げる。`create.md` Sub-skill Return Protocol セクションは本ファイルへ参照する。
>
> **抽出経緯**: Pre-check list の Item 0/1/2/3 は 4 種類の grep パターン (`grep -F` / `grep -E` / character-class 誤解釈警告) と 3 つの sentinel 形式 (`[interview:skipped]` / `[interview:completed]` / `[create:completed:{N}]` / `[CONTEXT] INTERVIEW_DONE=1`) + 場面 (a) / (b) で評価意味が反転する仕組みのため、`create.md` 本体に inline 展開すると LLM の一読理解を阻害していた。Issue #773 (#768 P1-3 / P3-9) で本 reference に抽出。
>
> **Enforcement coupling**: protocol violation 時は `manual_fallback_adopted` workflow_incident sentinel が stderr に echo されて Phase 5.4.4.1 で post-hoc 検出される (AC-7)。historical: 旧 `stop-guard.sh` (撤去済み、commit `e2dfae0`) が場面 (b) で機械検証していたが、stop hook 撤去後は post-hoc workflow_incident 検出に責務が集約された。

## Evaluation context (2 場面で同じチェックリストを使う)

| 場面 (a): sub-skill return 直後 | 場面 (b): turn 終了直前 |
|---|---|
| まだワークフロー中途。`NO` は「次の継続ステップを実行すべき」を意味する | 終端到達確認。`NO` は **protocol violation** (工程を飛ばして停止しようとしている) |

場面 (a) では Item 1-3 が `NO` でも正常 (まだ Issue 未作成段階)。場面 (b) では 4 項目すべて `YES` が turn 終了の必要条件。

## Procedure

Item 0 は **routing dispatcher** (YES/NO ではなく tag に応じて経路を選ぶ前段処理)。Item 0 を最優先で evaluate し、該当する経路に進んだ後、場面 (b) では **Item 1-3 が YES/NO で評価される状態チェック**。turn 終了の可否は Item 1-3 のみを集計する。

| # | Check (種別) | If YES/NO / routing, do |
|---|-------------|------------------------|
| 0 | **Routing dispatcher** (状態質問ではない): 直前の sub-skill return tag は何か? | grep the recent output (HTML comments included) for `[interview:skipped]` / `[interview:completed]` / `[create:completed:{N}]` / `[CONTEXT] INTERVIEW_DONE=1` (Issue #634). Both the bare bracket form (legacy) and HTML-comment form (`<!-- [...] -->`, Issue #561 current) match. 推奨形式は 3 回の `grep -F` 呼び出し: `grep -F '[create:completed:'`, `grep -F '[interview:'`, `grep -F '[CONTEXT] INTERVIEW_DONE=1'`。ERE を使う場合は `grep -E '\[(interview\|create):[a-z:0-9]+\]'` **ではなく** `grep -E '\[(interview|create):[a-z:0-9]+\]'` (unescaped pipe — ERE では `\|` がリテラル `|` として解釈されるため alternation として機能しない、#582 で検出)。**Issue #634 補強**: `[CONTEXT] INTERVIEW_DONE=1` grep marker は `create-interview.md` Return Output Format の FIRST 行として emit される plain-text marker で、HTML コメント除去 rendering でも grep 可能。`[interview:skipped]` / `[interview:completed]` のいずれかが matched **または** `[CONTEXT] INTERVIEW_DONE=1` が matched した時点で **continuation trigger** として扱う — immediately run 🚨 Mandatory After Interview (Step 0 Immediate Bash Action → Step 1 → Step 2 → Step 3 → Phase 0.6 → Delegation Routing → terminal sub-skill)。If `[create:completed:{N}]` matched: run 🚨 Mandatory After Delegation self-check (Step 1/2 no-ops when marker is present, Step 3 is idempotent output)。If tag が上記いずれでもない / 無い: 通常の Phase 進行中なので Item 1-3 を評価 (場面 (a) は NO でも legitimate)。未知 tag (unexpected return format): manual 停止して diag log を確認。**本 Item は YES/NO 集計から除外** — ルーティング前段として機能する。 |
| 1 | **State check**: `[create:completed:{N}]` が HTML コメントまたはベアブラケット形式で最終行 (あるいは末尾近傍) に出力済みか? | 推奨形式: `grep -F '[create:completed:'` (fixed string で HTML コメント内の string も matchable)。ERE 使用時は `grep -E '\[create:completed:[0-9]+\]'` (`-E` flag 必須 — BRE では `[0-9]+` が「1 個の数字 + リテラル `+`」と解釈され sentinel にマッチしない、#582 で検出)。**注意**: bracket-unescaped 形式 `[create:completed:[0-9]+]` は character class として誤解釈されるため使用禁止。場面 (a) では `NO` でも legitimate — 次の Pre-write + sub-skill invocation に進む。場面 (b) では `NO` は terminal sub-skill が未完了 — Mandatory After Delegation Step 3 (defense-in-depth として完了メッセージ + 次のステップ + HTML コメント sentinel を出力) を実行。 |
| 2 | **State check**: ユーザー向け完了メッセージが表示済みか? (3 形式のいずれか 1 つを含めば YES) | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は terminal sub-skill の完了メッセージが欠落 — Mandatory After Delegation Step 3 を実行 (idempotent)。**識別 substring**: 3 形式は以下の排他的な substring で識別可能 — register: `を作成しました:` (コロン付き URL), decompose: `を分解して` (中間句), orchestrator fallback: `を作成しました` かつ `:` を含まない。いずれか 1 形式の識別 substring を含めば YES 判定。 |
| 3 | **State check**: flow state が deactivate 済みか? (`active: false`, `phase: create_completed`) | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は terminal state 未到達 — terminal sub-skill を呼ぶか Mandatory After Delegation Step 2 を実行。 |

## Rule

**Item 1-3 すべて `YES`** が turn 終了の必要条件 **ただし場面 (b) においてのみ**。Item 0 は routing dispatcher で YES/NO 集計には含まれない (経路選択が完了すれば Item 1-3 の evaluation に進む)。場面 (a) では Item 1-3 の `NO` は「次のステップに進め」を意味する正常シグナル。Item 1-3 全 `YES` は terminal state (Issue 作成完了 + sentinel 出力 + flow-state deactivate) を保証する。

## Responsibility split

本 Pre-check list は turn 終了直前の手続的検証、`create.md` の Anti-pattern / Correct-pattern sections は sub-skill return 直後の推奨/禁止パターン (重複ではなく補完関係)。Pre-check list の各項目が `NO` の場合は Anti-pattern のルール (「turn を閉じない」) に従い即時継続すること。

## Self-check alias (後方互換)

`Has [create:completed:{N}] been output?` = Pre-check Item 1。下流の Mandatory After sections から本 Pre-check list を参照する際は Item 1-3 の終端条件をまとめて評価する。
