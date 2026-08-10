# マルチセッション Git Worktree 対応 — セッション別作業ツリー分離

> **Status**: ✅ 実装完了 + E2E 検証完了（S1–S9 + S11 land 済み・CLOSED、S10 でドキュメント整備 + 2 セッション E2E 実施 → V-1〜V-8 反映済み）
>
> **関連 Issue**: 親 Epic Issue の下に S1〜S11 の Sub-Issue として分解（末尾の「Sub-Issue 分解」参照）
>
> **本ドキュメントの位置付け**: 複数の Claude Code セッションを同一リポジトリで同時起動する運用（マルチセッション）を、
> Git worktree によるセッション別作業ツリー分離で first-class サポートするための設計選定 + 詳細設計の single source of truth。
> 実装完了後の canonical 仕様は `docs/SPEC.md` へ反映し、本ドキュメントは Decision Log として保守する。
> 先行設計: [multi-session-state.md](./multi-session-state.md)（状態レイヤの分離 — Option A per-session file、実装済み）。

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

rite workflow は per-session flow-state（`.rite/sessions/{session_id}.flow-state`）・session-ownership・work-memory lock により
「状態」のマルチセッション分離を既に達成している（[multi-session-state.md](./multi-session-state.md) の per-session 分離系列）。
しかし **git 作業ツリーとカレントブランチは全セッションで共有**されており、複数セッションが別 Issue を並行で進めると
`pr:open` の `git switch -c` や `pr:cleanup` の `git switch {base} && git pull` が相互に作業ツリーを破壊し合う。

本設計では `/rite:pr:open` がセッションごとに Git worktree（`.rite/worktrees/issue-{N}`）を作成し、
Claude Code 組み込みツール `EnterWorktree(path)` でセッションの作業ディレクトリを worktree へ切り替えることで、
作業ツリーレイヤの分離を完成させる。

**スコープ**: コア lifecycle（pr:open → iterate → merge → cleanup）+ Wiki 並行 ingest の完全排他 + sprint 系の Issue claim 衝突防止（最小対応）。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

### 既存設計の到達点と残ブロッカー

| レイヤ | 現状 | 多重起動時の安全性 |
|---|---|---|
| flow-state | per-session file（Option A、lock 不要の構造的分離） | ✅ |
| work memory | mkdir lock（stale 120s + PID liveness）+ Issue コメント同期 | ✅ |
| wiki worktree | `.rite/wiki-worktree` 永続 worktree + advisory flock | ⚠️ flock はあるが LLM Write/Edit フェーズと push 競合は未保護 |
| **git 作業ツリー / カレントブランチ** | **全セッション共有** | ❌ **本設計の対象** |

### 具体的な衝突点（シングルセッション前提の残存箇所）

- `commands/pr/open.md` Step 2.3: `git switch {base} && git pull --ff-only && git switch -c {branch}` — セッション A が switch した直後にセッション B が switch すると、A の以降のコミットが B のブランチに乗る
- `commands/pr/cleanup.md` Step 4: `git switch {base} && git pull` — 他セッションの作業中ブランチから作業ツリーを引き剥がす
- `hooks/state-path-resolve.sh`: `git rev-parse --show-toplevel` のみ — worktree 内では worktree root を返し、状態・ロック・wiki worktree が checkout ごとに分裂する（ロックの排他が inode 分裂で無効化）

<!-- Section ID: SPEC-CONSTRAINTS -->
## 前提と制約

### EnterWorktree / ExitWorktree ツール仕様（設計が依拠する要点）

- `EnterWorktree(path)`: **手動 `git worktree add` で作成済み**の worktree に入場できる（`git worktree list` 登録済みが条件）。
  `name` 指定は `.claude/worktrees/` 配下に origin/<デフォルトブランチ> 起点で新規作成され、branch 命名・base ref（rite は `origin/develop`）を制御できないため**使わない**。
- `ExitWorktree(action)`: 元のディレクトリへ戻る。**path 入場した worktree は `remove` でも削除されない** → 常に `keep` で戻り、main checkout 側から `git worktree remove` する。
- EnterWorktree のツール側ガード「ユーザーまたはプロジェクト指示で明示された場合のみ」は、`rite-config.yml` の `multi_session.enabled: true`（リポジトリにコミットされたプロジェクト指示。後続でテンプレートのデフォルトが ON 化されたが、値がテンプレートのデフォルト由来かユーザーの明示編集由来かに依らずプロジェクト指示として成立する）+ コマンド定義内の明示指示で満たす。pr:open は marker 経由で `enabled: true` を確認した分岐内でのみ EnterWorktree を呼ぶため、ガードの根拠は default off 時と変わらない。
- セッションのクラッシュ/再起動後、新セッションはリポジトリルートで開始される → `/rite:recover` が再入場経路を持つ（§5）。

### Git の構造的制約（設計が守るルール）

1. **branch は同時に 1 worktree でしか checkout できない**。checkout 中の branch は他所から削除・fetch 更新も不可。
   → branch 削除は **worktree 削除後**にのみ実行。新 branch の base は `git fetch origin` 後の **`origin/{base}` を直接指定**（local develop を経由しない）。
2. worktree から `git switch {base}` は不可（main checkout が保持）→ **規約: multi_session モードで rite は main checkout のカレントブランチを切り替えない**。動かすのは人間のみ。
3. refs / objects / config は全 worktree 共有、index は worktree ごとに独立。同時 `git fetch` は ref lock 競合で一時失敗しうる → 3 回リトライパターン（`references/git-worktree-patterns.md` に記載）。

### Worktree 名前空間の棲み分け（4 種）

| 名前空間 | 用途 | ライフサイクル |
|---|---|---|
| `.rite/worktrees/issue-{N}` | **セッション worktree（本設計で新設）** | pr:open 作成 → cleanup 削除（異常時は reap） |
| `.worktrees/{issue}/{task}` | parallel / team-execute のサブエージェント worktree（従来） | バッチ単位で作成・削除 |
| `pr-{N}-cycle{X}` 等 | reviewer の transient worktree（従来） | pr-cycle-cleanup.sh が冪等掃除 |
| `.rite/wiki-worktree` | wiki branch 永続 worktree（従来） | 手動削除のみ・reap 除外 |

`.worktrees/` を続用しない理由は Decision Log D-2 参照。

<!-- Section ID: SPEC-DESIGN -->
## 設計詳細

### §1 共有 State Root の統一（全体の基盤）

`plugins/rite/hooks/state-path-resolve.sh` の `resolve_state_root()` が hook payload `.cwd` / `$PWD` 経由の全 hook・スクリプトの漏斗になっている。
ここに linked-worktree 検出を追加し、**セッション cwd が worktree 内でも main checkout の root を返す**:

```bash
common=$(git rev-parse --path-format=absolute --git-common-dir)
# common != "$root/.git" なら linked worktree → dirname "$common" (= main checkout root) を返す
# ガード: [ -e "$main_root/.git" ] のときのみ（bare repo / submodule では現行どおり root を返す）
# git < 2.31 fallback: cd "$(git rev-parse --git-common-dir)" && pwd で正規化
```

- 非 worktree セッションでは `common == "$root/.git"` となり出力は現行と **byte 一致** → 後方互換は構造的に保証（pin テストで固定）。
- resolver 非経由で `git rev-parse --show-toplevel` を直叩きする 4 スクリプトを resolver 経由化:
  `pr-cycle-cleanup.sh` / `wiki-worktree-setup.sh` / `wiki-worktree-commit.sh` / `wiki-ingest-commit.sh`。
  **flock の排他は同一 inode が前提**のため、wiki 系 3 スクリプトの root 統一はロック実効化の必須要件。
- **例外**: `post-tool-wm-sync.sh` の `git diff origin/{base}...HEAD`（進捗テーブル用）は**セッションの作業ツリー**で実行する必要がある
  → 状態ファイルアクセスは STATE_ROOT（共有）、git diff は `git -C "$CWD"`（セッション cwd）に分割。

状態ファイル配置の決定:

| 状態 | 配置 | 根拠 |
|---|---|---|
| `.rite/sessions/` / `.rite-work-memory/`（+lockdir） / `.rite/state/`（flock 群 + issue-claims） / `.rite/wiki-worktree` / `.rite-session-id` / `.rite-plugin-root` | **共有 root**（main checkout） | セッション横断の整合・排他に必要。WM の mkdir lock は WM パス由来のため WM が共有なら自動的に共有 |
| `.rite/review-results/` / `.rite/fix-cycle-state/` / `.rite/state/accepted-fingerprints-*` | **共有 root**（state-path-resolve 基準） | 保存 (worktree 内 pr-review) と読取・削除 (main checkout の fix 再開 / cleanup) がセッションを跨ぐため、cwd 相対だと削除 no-op・読取不発になる。書込/読取/削除の 3 者を state-path-resolve.sh で同一パスに解決する |
| `.rite/tmp/` | **セッション cwd 相対のまま**（= worktree-local） | 同一セッション内で書いて読む一過性アーティファクト。worktree 削除と同時に消え、セッション間の混線を構造的に防ぐ |

`.rite-plugin-root` は cwd 相対 `cat` する command スニペット（8 ファイル）のため、pr:open の worktree 作成時に worktree root へ**コピー配置**する
（8 ファイル改修より 1 writer 追加を採択。既存スニペットには fallback があるため、コピーは決定論化のための defense-in-depth）。

### §2 rite-config.yml / flow-state 拡張

```yaml
multi_session:
  enabled: true                      # デフォルト true。false で 1 セッション 1 作業ツリー（単一セッション動作）
  worktree_base: ".rite/worktrees"   # セッション worktree 配置（issue-{N} サブディレクトリ）
```

> **デフォルト ON 化**: 新規 `/rite:setup` 生成 config は `enabled: true` を含む。`multi_session:` ブロックを持たない旧 config では pr:open の parse fallback が `false` となり、既存プロジェクトの挙動は不変（後方互換）。`false` を明示設定すれば単一セッション動作となり挙動は変わらない。

- `parallel:` セクションと**統合しない**: `parallel.mode/worktree_base` は「1 Issue 内の並列実装サブエージェント」の軸、
  `multi_session` は「セッション全体のライフサイクル分離」の軸で直交する。
- flow-state に `worktree` field（optional・絶対パス）を additive 追加。`flow-state.sh set --worktree <path>`。
  semantics は `branch` と同じ **merge-preserve**（`handoff` の default-clear とは逆）。additive のため flow-state の schema bump 不要。
- `.gitignore` に `.rite/worktrees/` を追加（本リポジトリ）+ `commands/init.md` Phase 4.6 のエントリループに追加 +
  `gitignore-health-check.sh` に `multi_session.enabled=true` 時の非ブロッキング検査（`git check-ignore`、exit 1 warning）を追加。

### §3 pr:open の改修（commands/pr/open.md）

- **Step 0.5（新設）Worktree Re-entry**: Resume Dispatch 時、flow-state の `worktree` と cwd が不一致なら `EnterWorktree(path)` してから復帰先ステップへジャンプ。
- **Step 1.6 で Issue claim 取得**（§7。副作用＝branch/worktree 作成前の fail-fast）。
- **Step 2.2-W / 2.3-W（multi_session 有効時、従来 Step 2.2/2.3 を置換）**:
  1. `git fetch origin {base}`（ref lock 競合対策の 3 回リトライ）
  2. 冪等 5 ケース分岐:

     | 状態 | アクション |
     |---|---|
     | worktree 登録済 + branch 一致 | 再利用（resume 相当） |
     | パスは存在するが worktree 未登録（残骸） | `git worktree prune` → 残存なら AskUserQuestion（削除して再作成 / 中止） |
     | branch 存在・worktree なし | `git worktree add {path} {branch}`（`-b` なし） |
     | branch も worktree もなし | `git worktree add --no-track -b {branch} {path} origin/{base}`（`--no-track`: sandbox 環境での tracking 書込拒否回避） |
     | branch が**別の worktree** で checkout 中 | **中止**（他セッション作業中の可能性を表示 — git が構造的に保証する二重着手ガード） |
  3. `.rite-plugin-root` を worktree root へコピー → `EnterWorktree(path: {path})`
  4. **EnterWorktree 不在/失敗時**: **silent fallback はしない**。失敗原因を切り分ける — (A) harness の git 誤判定（`.git` 存在 + `git -C {path} rev-parse` 成功 + 起動コンテキスト git=false / 「not in a git repository」）＝推奨。リポジトリ root から Claude Code を再起動し再実行すれば worktree は `WT_CASE=reuse` で継続（worktree は保持され破壊しない）/ (B) worktree 消失等の別要因＝S8 / `/rite:recover` 再構築経路へ委譲 / (C) 従来 `git switch -c` は recommended にせず、worktree 分離を破棄する明示エスケープとしてのみ残す（併走時の危険を警告）。Bash 永続 cwd 駆動は導入しない。
- Step 2.6 / 6.3 の flow-state set に `--worktree {path}` を追加。
- Step 3〜6（implement / lint / push / PR create）は cwd 相対で完結するため**無変更**（§1 の state root 統一が前提）。

### §4 pr:cleanup の改修（commands/pr/cleanup.md）

- **Step 4-W（multi_session 時、worktree 内から呼ばれた場合）**:
  1. `git status --porcelain` で dirty 確認。dirty なら AskUserQuestion（stash して続行 / 中止）。stash は common git dir 格納のため worktree 削除後も `git stash pop` 可能。
  2. `ExitWorktree(action: "keep")` で main checkout に復帰（path 入場 worktree は remove でも消えない仕様のため常に keep）。
  3. main から `git worktree remove {path}` → `git worktree prune`。
  4. 削除失敗時は `WORKTREE_REMOVE_FAILED` を表示して**続行**（non-blocking。遅延 reap §8 へ委譲）。sandbox が admin dir の `config.worktree` にマスクマウントを張っている場合は remove 試行自体が admin dir を半壊させるため、削除前に検知して remove を**一切実行せず** `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` を表示して遅延 reap へ委譲する。
  5. 冪等性: main から再実行された場合は cwd 判定で 1〜2 をスキップ。worktree 既削除なら 3 もスキップ。
- **Step 4（base pull）の安全化**: main checkout が `{base}` 上にある場合のみ `git pull --ff-only origin {base}`（index.lock 競合 3 回リトライ）。
  別 branch 上なら **switch せず WARNING + skip**（WARNING 文面に「main checkout を {base} に戻す」復旧手順を含める）。従来モード（enabled=false）は現行動作を維持。
- **Step 5**: branch 削除は worktree 削除後にのみ成功する（Git 制約 1）ことを本文に明記。
- Step 9 以降（wiki ingest / WIKICHAIN チェーン）は Step 4-W で main 復帰済みのため**無変更**。Step 11-12 で claim release（§7）。
- Step 12 完了報告にセッション worktree 削除のチェック行を追加（失敗時は手動コマンドを案内）。

### §5 resume の改修（commands/resume.md）

- **Phase 1.1**: 引数なし・branch 抽出失敗時の fallback に `git worktree list` から `{worktree_base}/issue-*` を列挙
  （1 件 → 提案、複数 → AskUserQuestion で選択）。
- **Phase 3.1.5（新設・git/PR 状態クロスチェックより前）**: flow-state `worktree` → 無ければ issue 番号からパス導出（discovery fallback）→ `EnterWorktree(path)`。
  クロスチェック（`git rev-list origin/{base}..HEAD` / `gh pr view` 等）はカレントブランチ依存のため、**再入場後に実行する順序が本質**。
- **worktree 消失時の再構築**: branch ローカル有 → `git worktree add`（-b なし）/ リモートのみ → `git fetch origin {branch}` + `--track -b` /
  どこにも無 → 矛盾サマリ + AskUserQuestion（新規セッション扱い / 中止）。
- **Phase 5.1**: worktree モードでは `git switch` を「検証のみ」（worktree 内カレントブランチ = state branch の確認、不一致は WARNING）に変更。
- **authority scope**: session ⇄ worktree は 1:1 でない（クラッシュで session_id が変わる）。
  issue 番号 → worktree パス導出の discovery fallback が正規の対応関係であり、flow-state `worktree` は同一セッション内のヒントに留まる（SPEC.md に明記）。

### §6 iterate / review / fix / merge / ready — 変更不要（確認済み）

- flow-state set + Skill invoke のみで `git switch` 系の作業ツリー操作なし。
  `stop-loop-continuation.sh` の handoff 再注入も §1 の resolver 統一後は共有 root の per-session state を正しく consume する。
- reviewer の `pr-{N}-cycle{X}` worktree は worktree 内セッションからでも動作（worktree 登録はリポジトリグローバル）。
  `pr-cycle-cleanup.sh` の strict regex はセッション worktree の branch（`{type}/issue-...`）にマッチしないため誤削除なし。
- 追加は `references/git-worktree-patterns.md` への「Multi-Session Patterns」節のみ（名前空間 4 種の表 / fetch リトライ / main checkout 不可侵規約）。

### §7 Issue claim 機構（新ヘルパー hooks/issue-claim.sh）

同一 Issue への二重着手防止。**`multi_session.enabled` に依らず常時有効**（Decision Log D-3）。

- パス: `<共有root>/.rite/state/issue-claims/issue-{N}.json`（`.rite/state/` は gitignore 済みのため新 gitignore エントリ不要）。
- 内容: `{"schema_version":1, "issue_number":N, "session_id":"...", "worktree":"<abs path|''>", "claimed_at":"ISO8601Z"}`。
- サブコマンド: `claim | release | check --issue N`。CLI 規約・診断出力は `flow-state.sh` を踏襲、session_id 解決は既存ヘルパーを再利用。
- **原子性**: noclobber（`set -C`）での claim ファイル作成。stale 奪取パスのみ `issue-claims/.lock` への flock（`_atomic_write` と同型）。
- **liveness 判定（新ヒープビートを作らない）**: claim 存在 ∧ 保持セッションの flow-state が `active=true` ∧ `updated_at` が 7200s（2h）以内。
  `session-ownership.sh` の stale 閾値と `parse_iso8601_to_epoch` を source 再利用。`flow-state.sh set` が全 phase 遷移で `updated_at` を更新する既存挙動がそのまま heartbeat。
- **取得**: pr:open Step 1.6。**解放**: cleanup Step 11-12。**session-end では解放しない**（クラッシュ後の再開可能性を残す。残骸は stale 判定 + reap が回収）。
- 他セッションの live claim 検出時は**常に AskUserQuestion**（無人での奪取はしない）。
- **既知の限界**: phase 遷移なしで 2h を超える implement 中は stale 誤判定しうる → 自動奪取は reap（§8）のみ、かつ clean worktree 条件付き。

#### S3 確定 CLI 契約（S6/S7/S9 配線仕様 — S3 で確定）

`bash hooks/issue-claim.sh {claim|release|check} --issue N [--worktree PATH] [--session UUID]`

| サブコマンド | stdout | exit code | 挙動 |
|---|---|---|---|
| `claim` | `claimed` / `own` / `other` | `0`（claimed/own/stale-steal）/ `10`（other=live または stale-steal の CAS 中止）/ `1`（usage/env エラー） | free→noclobber 取得 / own→冪等 refresh / stale→flock 内 CAS 再検証付き奪取（並行奪取の敗者・ロック内で live に転じた holder は奪取せず `other` rc 10）/ **other(live)→取得せず rc 10**（呼び出し側が AskUserQuestion） |
| `release` | `released` / `skipped` | `0`（冪等。不在でも `released`）/ `1` | 自セッションの claim のみ削除。他セッション保持時は `skipped`（触らない） |
| `check` | `own` / `free` / `other` / `stale` | `0` | 読み取りのみ。corrupt/空 holder は `stale`（再取得可能） |

- **session_id 解決**: `_resolve-session-id-from-file.sh`（`.rite-session-id` ファイル優先）→ env（`CLAUDE_CODE_SESSION_ID` / `CLAUDE_SESSION_ID`）の順で、`flow-state.sh` の解決順と**一致**させる（claim の session_id が holder の per-session flow-state ファイル名と一致することが liveness 判定の前提）。テスト・明示制御は `--session` override。
- **配線挿入点**: pr:open Step 1.6 = `claim`（rc 10 → AskUserQuestion / rc 0 → 続行、`--worktree {path}` で worktree path も記録）。cleanup Step 11-12 = `release`。sprint execute/team-execute = `check`（`other` のみスキップ、`stale` はスキップせず pr:open の claim に委ねる）。

### §8 セッション worktree の遅延 reap（pr-cycle-cleanup.sh Step 5 追加）

責務分担: **正常系は cleanup.md が即時削除**、reap は**異常終了の残骸回収のみ**。

3 ゲート全通過時のみ reap:

1. `{worktree_base}` 配下かつディレクトリ名が `^issue-[0-9]+$` に**完全一致**（strict regex doctrine 踏襲）
2. claim liveness（§7 の述語）が **live でない**（claim 不在時は mtime > 24h の既存 age guard を再利用）。例外: checkout 中 branch が **reap manifest に記録済み**（= cleanup.md が PR merged を確認して記録した deferred worktree — cleanup は claim を無条件解放するため必ず claim 不在でここに到達する）なら age guard を**バイパス**して即 reap する。ハーネスが worktree root の mtime をセッション毎に更新（`.claude/.cc-writes` churn）するため、age guard 単独では merged 済み deferred worktree が永久リークする
3. `git -C <wt> status --porcelain` が**空**（**dirty worktree は絶対に auto-reap しない** — WARNING + 手動コマンド提示で skip）。例外: **corpse**（admin dir の `HEAD` 欠落 + git 非認識の AND — sandbox マスク下の remove が半壊させた残骸）は status 判定が構造的に不可能なため本ゲートをバイパスし、claim 非 live + 24h age guard 通過後に `rm -rf`（working tree + admin dir）+ `prune` で回収する（HEAD 存在で status rc≠0 のものは従来どおり安全側 skip）

**Gate 0 — self-exclusion（後続で追加された第 4 の保護層）**: 上記 3 ゲートの**前段**に、実行中の自セッション worktree（起動時 cwd、または `RITE_WORKTREE` env が候補 worktree と一致/配下）を reap 対象から除外するガードを設ける。long-lived セッションが review 開始時（review.md Step 1.0.0）に**自分の作業中 worktree**（clean かつ claim free/stale で 3 ゲートを全通過しうる）を削除する事故を防ぐ。dirty(3)/claim(2) 保護とは独立した第 4 の保護層。

処理は既存 `_reap_mutation_worktree` と同型: `git worktree remove --force` → fallback `rm -rf` → `git worktree prune` + 対応 claim ファイル削除。

**branch recovery（安全な遅延回収へ精緻化）**: 初期設計は「branch は削除しない（作業保全）」だったが、これだと cleanup.md が別 live セッションの在席で削除を遅延した feature ブランチが回収経路を持たず永久残置（dead-letter）した。現在は worktree reap 後にその branch を**安全に回収**する: `git branch -d`（safe — 未マージは拒否するため**未マージ作業は破壊しない**）を第一手とし、`-d` が squash-merge 残渣で拒否しても **reap manifest に記録された branch**（cleanup.md が PR merged を確認して `rite-tmp-artifact.sh record --type branch` で記録）のみ `git branch -D` で強制削除する。manifest 未記録の未マージ branch は WARNING を出して保持する。これにより「branch は保全」方針は「**merge 確認済み branch のみ回収・未マージ作業は破壊しない**」へと精緻化された。manifest 記録は branch の強制削除だけでなく **worktree reap 自体の free-claim age guard バイパス**もライセンスする（ゲート 2 の例外を参照）。branch 回収の成功時（`-d` / `-D` のいずれも）は manifest エントリを**同一 run 内で即時消費**する — バイパス導入後は残存エントリが不活性でなくなる（同名 branch が claim-free の新 worktree に再作成された場合にバイパスを継承しうる）ため、従来の「次 run の Step 4.5 verify-drop による自己修復」依存をやめた。消費は best-effort（mktemp / 書き戻し失敗時は WARNING を出して自己修復にフォールバック。silent には失敗しない）。

トリガー: cleanup.md の既存 `pr-cycle-cleanup.sh` 呼び出しに内包 + `session-start.sh`（main checkout 起動時）から `|| true` の best-effort 呼び出し
（worktree list + status check のみの軽量処理で hook timeout 30s 内に収まることをテストで担保）。

### §9 Wiki 並行 ingest の完全排他

- **wiki worktree の一意性**: §1 の resolver 統一で、worktree 内セッションからも `.rite/wiki-worktree` が main root の 1 箇所に解決される。
  （現状のままだと worktree 内で第二の wiki-worktree 作成を試み「already checked out」で exit 3 — V-7 で実機確認）
- **push 競合リトライ**: `lib/worktree-git.sh` の push 失敗分岐に non-fast-forward 判別を追加 →
  `fetch origin {wiki_branch}` + `rebase origin/{wiki_branch}` + push 再試行を最大 3 回。
  rebase 失敗 → `rebase --abort` → 既存 rc=4 へ。**exit code 契約 0/3/4/5 は不変**（呼び出し側・sentinel 連鎖は無修正）。
  auth/network 等の非 NFF 失敗は現行どおり即 rc=4。根拠: wiki コミットは append-mostly（新規 raw / 新規ページ / log 追記）で rebase はほぼ無衝突。
- **LLM Write/Edit フェーズの直列化**: flock では複数 Bash 呼び出しに跨る ingest を守れない →
  `.rite/state/wiki-ingest-session.lockdir`（mkdir lock、既存 `acquire_wm_lock` パターン再利用、stale 判定は §7 の liveness 述語を流用）を
  ingest 開始時に取得し、ingest 完了後に解放。他 live セッション保持中は `WIKI_INGEST_SKIPPED reason=concurrent_ingest` で skip —
  **pending raw は wiki branch に残り、次回 ingest が冪等に回収する**（既存の縮退特性をそのまま利用）。
- ingest.md の `.rite/wiki-worktree/...` cwd 相対パス契約 → setup スクリプトの `path=` 出力を capture した**絶対パス契約**へ改訂。

### §10 sprint:execute / team-execute の最小対応

両ファイルとも 2 挿入点のみ:

- (a) Todo フィルタ直後: claim 済（他セッション live）の Issue を除外し、実行計画表に「スキップ（他セッション作業中）」行として表示
- (b) pr:open invoke / worktree 作成の直前: 再チェック（TOCTOU 窓対策。最終ガードは pr:open Step 2.2-W の branch 衝突検出）

teammate の git 禁止・team lead の `git -C` 集約は無変更。

### §11 後方互換とマイグレーション

- `multi_session.enabled: false`（明示 opt-out、または `multi_session:` ブロックを持たない旧 config）で worktree 経路・EnterWorktree・reap Step 5 の対象がすべて不活性。後続でテンプレートのデフォルトは `true` に変更されたが、ブロック欠落時の parse fallback は `false` のままのため既存 config の挙動は不変。
- §1 の resolver 変更は非 worktree セッションで出力 byte 一致 → 状態ファイルの移動・migration は一切発生しない。
- claim のみ常時有効（衝突がない限り無音。`.rite/state/` 配下へのファイル作成のみで既存ユーザーの体験は不変）。
- rite-config.yml top-level `schema_version` bump（2→3）で session-start.sh の既存 upgrade prompt 機構が自動案内。
- 移行期リスク: main checkout を feature branch に置いたまま有効化 → cleanup の base pull が skip され続ける → WARNING 文面に復旧手順を含める（§4）。
- ディスクコスト: worktree は作業ツリーのフル複製。ビルド環境（`node_modules` 等）の再構築が必要な点を getting-started FAQ に記載。

<!-- Section ID: SPEC-DECISION-LOG -->
## Decision Log

> **Status**: ✅ 確定 — 2026-06-10 user 承認（AskUserQuestion 経由 3 件 + プランモード承認）

| ID | 項目 | 決定 | 根拠 / 落選案 |
|---|---|---|---|
| D-1 | セッション開始モデル | **EnterWorktree 自動方式**: 全セッションをリポジトリルートで起動し、`/rite:pr:open N` が `git worktree add` + `EnterWorktree(path)` で自動入場 | 手動 cd 方式（worktree 作成 + パス案内 → ユーザーが新ターミナルで起動）は EnterWorktree 非依存だが UX が重い。両対応（自動優先）は判定ロジック増。`EnterWorktree(path)` が手動作成 worktree への入場をサポートするため branch 命名 / base ref の制御と自動入場を両立できる |
| D-2 | worktree 配置先 | **`.rite/worktrees/issue-{N}`** | `.worktrees/` 続用案は team-execute の stale 検出 `ls -d {worktree_base}/*/*`（team-execute.md L198-205）がセッション worktree の内部ディレクトリに誤マッチし削除提案を出すため不採用。`.rite/wiki-worktree`（worktree を `.rite/` 配下に置く前例）に整合 |
| D-3 | Issue claim のゲート | **`multi_session.enabled` に依らず常時有効** | 同一 checkout での複数セッションは per-session flow-state により現行でもサポートされており、二重着手リスクは worktree 機能と独立に存在する。claim は衝突がない限り無音で後方互換を壊さない |
| D-4 | EnterWorktree の name/path | **`path` 入場のみ使用** | `name` 指定は `.claude/worktrees/` + origin/<デフォルトブランチ> 固定で、rite の branch 命名規則（`{type}/issue-{number}-{slug}`）と base（`origin/develop`）を表現できない |
| D-5 | state root resolver | **新 lib を作らず `state-path-resolve.sh` 自体を worktree-aware 化** | 既に全 hook の漏斗（分類 A/B が全て経由）であり、新 lib の並存は drift ベクタになる（シンプルさを死守） |
| D-6 | 一過性アーティファクトの配置 | ** で改訂**: `review-results` / `fix-cycle-state` / `accepted-fingerprints-*` は**共有 root（state-path-resolve 基準）**、`tmp` のみセッション cwd 相対 | 当初決定（cwd 相対）は worktree 削除と同時に消える利点を採ったが、worktree 内保存 ↔ main checkout 読取/削除のパス分裂（cleanup no-op・cross-session 読取不発）が実害として顕在化したため見直した。当初懸念した衝突管理は review-result-schema.md の `~<hex>` suffix で対処済み。配置の現行 SoT は上記「状態ファイル配置」表 |
| D-7 | claim の heartbeat | **新機構を作らず flow-state `updated_at` を再利用** | `flow-state.sh set` が全 phase 遷移で更新する既存挙動がそのまま heartbeat。session-ownership.sh の 2h 閾値と判定関数も再利用 |
| D-8 | スコープ | コア lifecycle + Wiki 完全対応 + **sprint 系は claim スキップのみ** | 複数セッションでの sprint 分担実行（協調スケジューリング）はスコープ過大。将来 Issue に切り出す |
| D-9 | rite-config.yml top-level `schema_version` bump（2→3） | **省略**（S2 で 2 のまま据え置き） | `multi_session` は additive で migration 不要（S2 時点では `enabled: false` default、後続でデフォルト ON 化された後も `multi_session:` ブロック欠落時の parse fallback は `false` のままで既存 config の挙動は不変）。bump すると session-start.sh の upgrade prompt が全既存ユーザーに発火するが、S2 時点では pr:open/cleanup 統合（S6/S7）が develop 未マージで機能が半完成。半統合機能を全ユーザーに告知する弊害が告知価値を上回るため bump しない。`flow-state` の `worktree` field も conditional-write で非 worktree セッションの state を byte 不変に保つため schema 系のいかなる bump も不要。後続のデフォルト ON 化はテンプレート config 経由の配布であり schema 変更を伴わないため、本判断は維持される |

<!-- Section ID: SPEC-AC -->
## Acceptance Criteria

| AC | 内容 | 対応 Sub-Issue |
|----|------|----------------|
| AC-1 | `multi_session.enabled=false` で全コマンド・hook の挙動が現行と完全一致（resolver 出力の非 worktree byte 一致 pin テスト含む） | S1, S2 |
| AC-2 | 2 セッションが別 Issue を pr:open → iterate → merge → cleanup まで並行完走（相互の branch / 作業ツリー破壊なし） | S6, S7, S10 |
| AC-3 | pr:open の冪等 5 ケース（再利用 / 残骸 prune / branch のみ / 新規 / 他 worktree checkout 中断）が仕様どおり分岐 | S6 |
| AC-4 | クラッシュ後の `/rite:recover` が worktree へ再入場し、worktree 消失時は branch から再構築する | S8 |
| AC-5 | 同一 Issue への二重着手で claim 検出 → AskUserQuestion（無人奪取なし） | S3 |
| AC-6 | アクティブセッションの worktree が reap されない（3 ゲート）。異常終了の残骸（claim stale + clean）は回収される | S4 |
| AC-7 | 並行 wiki ingest で commit/push が直列化され、NFF push 競合はリトライで吸収、ingest lock 競合時は skip + 次回回収 | S5 |
| AC-8 | multi_session モードで rite が main checkout のカレントブランチを切り替えない（cleanup base pull は on-base 時のみ） | S7 |
| AC-9 | sprint:execute / team-execute が他セッション claim 中の Issue をスキップし、計画表に明示する | S9 |
| AC-10 | 検証項目 V-1〜V-8 の実機確認が完了し、結果が本ドキュメントに反映されている | S1, S10 |

<!-- Section ID: SPEC-VERIFICATION -->
## 検証項目（実装フェーズ冒頭 S1 で実機確認し、結果を本表に追記する）

> **検証ステータス凡例**: ✅ = 自動テスト or 実機で確認済 / 🔬 = resolver 層で構造的に担保（EnterWorktree 依存の実値は S10 の 2 セッション E2E で確認） / ⬜ = 未検証（S10 へ委譲）
>
> **S1 時点の総括（2026-06-10）**: resolver 層で検証可能な V-6 / V-7 はいずれも設計どおりに動作し、§1 の前提を**確認**した（設計前提を崩す発見はなし）。EnterWorktree のツール挙動に依存する V-1/V-2/V-3/V-5/V-8 は live セッションでの観察が必要なため、S10の 2 セッション E2E に委譲する。post-tool-wm-sync.sh の git diff 分割（§1、V-1 が影響する唯一の作業ツリー依存箇所）は `git -C "$CWD"` で実装済。V-4 は既知ギャップで S11へ切り出し済。
>
> **S10 時点の状況（2026-06-10）**: S1–S9 がすべて land し（CLOSED）、EnterWorktree 依存経路（pr:open Step 2.2-W / 2.3-W = S6、cleanup Step 4-W = S7、resume 再入場 = S8）も実装済み。残る V-1/V-2/V-3/V-5/V-8 の live 観察は本 Issue（S10）の 2 セッション E2E で実施し、結果を下記「[E2E 検証手順と結果](#e2e-検証手順と結果s10)」に記録した上で本 V 表へ転記する（AC-10）。
>
> **S10 E2E 完了（2026-06-10）**: 2 セッション（`1b5dbaef…` / `e6171fd1…`）の並行 lifecycle を実施し、2 つの Issue → それぞれの PR が並行マージ・セッション worktree 残骸ゼロ・並行 wiki ingest の skip 縮退を**痕跡で確認**。EnterWorktree 依存の crash→resume（V-5）と非回帰（V-1）は `crash-resume.test.sh` 7 PASS / `state-path-resolve.test.sh` 6 PASS / `issue-claim` 20 / `pr-cycle-cleanup-session-reap` 11 / `worktree-git-nff-retry` 9 PASS の自動テストで担保。V-4 は S11の compact-state per-session 化で解消。V-1〜V-8 を下表へ反映済み（AC-10 達成）。V-3（worktree 内 `/clear`）は本 E2E で明示実施せず — 構造的担保に留める。

| ID | 検証項目（推測を含む） | 設計上の担保 | 結果 |
|----|----------------------|--------------|------|
| V-1 | EnterWorktree 後の hook payload `.cwd` が worktree を指すか main のままか | state 解決は git ベースでどちらでも安全。`post-tool-wm-sync.sh` の git diff 分割（§1）のみ作業ツリー依存のため実機確認必須 | ✅ S10 E2E で確認。2 セッション並行 lifecycle が完走し state は破壊なく main root に解決。git diff 分割は `git -C "$CWD"` で実装済。`state-path-resolve.test.sh` 6 PASS（非 worktree byte 一致 pin） |
| V-2 | `${CLAUDE_PLUGIN_ROOT}` が EnterWorktree 後も plugin install パスを指すか | cwd 非依存のはずだが未検証 | ✅ 間接確認。worktree 内で pr:open〜cleanup（plugin file を読む）が解決エラーなく完走 → plugin root は worktree 入場後も正しく解決。`.rite-plugin-root` の worktree コピー + fallback が機能 |
| V-3 | worktree 内での `/clear`（SessionStart source=clear）の ownership 判定 | per-session パス形状 fast-path は root 非依存で機能する想定 | 🔬 構造的担保（per-session パス fast-path は root 非依存）。本 E2E では worktree 内 `/clear` 経路を明示的には実施せず。`crash-resume.test.sh` の後続セッション起動（TC-3.1）で隣接経路を担保 |
| V-4 | `.rite-compact-state` が単一ファイル（セッション間 last-writer-wins）の既存ギャップ | 統一 root 化で顕在化しうる → per-session 化を S11（optional）に切り出し | ✅ S11 で per-session 化を実装。`.rite/sessions/{sid}.compact-state` を pre/post-compact・preflight・session-start・cleanup-work-memory で統一ルール（flow-state パスから suffix-swap、解決不能時のみ legacy fallback）で参照。レガシー共有ファイルは session-start / cleanup が移行用に reap。S10 E2E: `crash-resume.test.sh` 7 PASS が並行 SIGKILL 下の state 整合を担保 |
| V-5 | ExitWorktree 失敗 / 不可時の縮退 | worktree を残して終了 → reap（§8）が回収する縮退経路を仕様化済み | ✅ reap 縮退経路を `pr-cycle-cleanup-session-reap.test.sh` 11 PASS で担保。live E2E でも cleanup 後にセッション worktree 残骸ゼロ（正常系で ExitWorktree→remove 成功） |
| V-6 | git < 2.31 での `--path-format=absolute` 非対応 | cd + pwd 正規化 fallback を実装に含める | ✅ 検証済。`state-path-resolve.test.sh` T-5 が git<2.31 を shim で再現し worktree→main root を自動テスト化 |
| V-7 | worktree 内からの wiki-worktree-setup.sh が「already checked out」exit 3 になる経路 | §1 の resolver 統一で根治。実機再現で裏取り | ✅ 根治確認。worktree 内から `wiki-worktree-setup.sh` を実行すると repo_root が main checkout に解決され（resolver 経由化）、第二 wiki-worktree の作成を試みない。`state-path-resolve.test.sh` T-2/T-3 が解決を固定 |
| V-8 | ExitWorktree(keep) の戻り先 = EnterWorktree 時の cwd（サブディレクトリで起動した場合の挙動） | リポジトリルート起動が前提（D-1）だが、逸脱時の挙動を確認 | ✅ live E2E で cleanup が main checkout へ復帰しセッション worktree を削除（戻り先 = 起動時 main root）。リポジトリルート起動前提（D-1）は維持。サブディレクトリ起動の逸脱挙動は範囲外 |

<!-- Section ID: SPEC-E2E -->
## E2E 検証手順と結果（S10）

> **実施方法**: マルチセッションは 2 つの独立した Claude Code ターミナルの並行起動を要するため、単一の自動エージェントでは完遂できない。以下の手順を人手（坂口さん）が実行し、結果を本節の結果表に記録する。実施前提として `rite-config.yml` の `multi_session.enabled: true` を設定する（検証後に `false` へ戻す手順 5 を含む）。dogfood 有効化（恒久的な `enabled: true`）は本 E2E の結果を踏まえて別途判断する（S10 当時は検証後に既定 `false` へ復帰した）。**追記**: その後の作業でテンプレートのデフォルトを `true` に変更し、dogfood リポジトリの `rite-config.yml` も恒久的に `enabled: true` 化した（決定根拠は D-9 / デフォルト ON 化を記録した CHANGELOG エントリ参照）。

### 手順

1. 2 つのターミナルで Claude Code をリポジトリルートから起動する（両者とも main checkout = base ブランチ上で開始）。
2. 各ターミナルで**別々の Issue** に対して `/rite:pr:open` → `/rite:pr:iterate` → `/rite:pr:merge` → `/rite:pr:cleanup` を並行完走させ、相互の作業ツリー / ブランチ破壊が起きないことを確認する（AC-2 / AC-8）。
3. 両セッションがほぼ同時に cleanup → wiki ingest に到達するよう仕向け、並行 ingest が直列化 / skip / 次回回収のいずれかで安全に縮退することを確認する（AC-7）。
4. 片方のセッションを実装中にクラッシュ（プロセス kill / ターミナル強制終了）させ、新ターミナルで `/rite:recover {issue}` を実行 → セッション worktree への再入場、worktree 消失時のブランチからの再構築を確認する（AC-4）。
5. `multi_session.enabled: false` に戻し、従来フロー（単一セッション）が非回帰であることを確認する（AC-1）。

### 結果（2026-06-10 実施 — 坂口さんの 2 セッション並行実施 + 痕跡 / テストによる裏取り）

> 凡例: ✅ = pass / ⚠️ = 発見事項あり（別 Issue 化）。「痕跡」= `git worktree list` / merged PR / `.rite/state/issue-claims/` / wiki branch log の事後検証、「テスト」= `plugins/rite/hooks/tests/` の自動テスト実走。

| 手順 | 対応 AC / V | 結果 | 根拠・発見事項 |
|---|---|---|---|
| 1 起動 | — | ✅ | 2 セッション（`1b5dbaef-96ec-4fdb-815c-f5ad345fb9ca` / `e6171fd1-d921-43b6-9b0d-d4ca0bd71e30`）がリポジトリルートから起動し、別 Issue を並行実行 |
| 2 並行 lifecycle | AC-2 / AC-8 / V-1 / V-2 / V-8 | ✅ | 2 つの Issue → それぞれの PR が約 7 分差で develop に並行マージ（相互の branch / 作業ツリー破壊なし）。`git worktree list` にセッション worktree（`.rite/worktrees/issue-*`）の残骸ゼロ＝cleanup Step 4-W が正常削除。worktree 内で pr:open〜cleanup が plugin file 解決エラーなく完走（V-2 間接確認） |
| 3 並行 ingest | AC-7 | ✅ | wiki branch に `ingest 1 raw source(s) (worktree path)` 連続コミット + `ingest 0 new / 0 updated …(skipped: 1)` のスキップ事象＝直列化 / skip 縮退が発火、絶対パス契約も動作。`worktree-git-nff-retry.test.sh` 9 PASS で NFF push リトライを担保 |
| 4 クラッシュ→resume | AC-4 / V-5 | ✅（テスト + コードパス担保） | `crash-resume.test.sh` 7 PASS（TC-2.1: resume path で active/phase/issue/branch を復元、TC-3.1: セッション A の SIGKILL 後にセッション B 起動成功）。resume.md Phase 3.1.5 の worktree 再入場・再構築（reenter / residue / missing+branch_local）コードパス確認。真のプロセス crash の live 実施は本 E2E では未実施 |
| 5 false 復帰の非回帰 | AC-1 | ✅ | `multi_session.enabled: false` へ復帰。`state-path-resolve.test.sh` 6 PASS（非 worktree で resolver 出力が byte 一致する pin テスト）。本ドキュメント整備セッションも非 worktree 標準フローで正常動作 |

**補助テスト**: `issue-claim.test.sh` 20 PASS（AC-5 claim/release/check + stale 判定）/ `pr-cycle-cleanup-session-reap.test.sh` 11 PASS（AC-6 reap 3 ゲート）も全 green。

> **V 表への転記**: 上記結果を「[検証項目](#検証項目実装フェーズ冒頭-s1-で実機確認し結果を本表に追記する)」の V 表 結果欄（V-1 / V-2 / V-3 / V-5 / V-8）へ転記済み（AC-10 達成）。本 E2E で blocking な発見事項はなし（V-3 の `/clear` live 経路のみ未実施で構造的担保に留置）。

<!-- Section ID: SPEC-SUBISSUES -->
## Sub-Issue 分解

| # | タイトル | 主スコープ | 依存 |
|---|---|---|---|
| S1 | feat(hooks): state-path-resolve.sh の linked-worktree 対応 — 共有 state root 統一 | resolver 変更 + 直叩き 4 スクリプト経由化 + wm-sync diff 分割 + pin テスト + V-1〜V-8 実機検証 | なし（基盤・最優先） |
| S2 | feat(config): multi_session 設定スキーマ + flow-state worktree field + gitignore 整備 | config schema bump + `--worktree` + init.md / health-check | S1 と並行可 |
| S3 | feat(hooks): Issue claim 機構（issue-claim.sh） | claim/release/check + stale 判定の session-ownership 再利用 | S1 |
| S4 | feat(hooks): セッション worktree 遅延 reap（pr-cycle-cleanup Step 5） | 3 ゲート reap + session-start 配線 | S1, S3 |
| S5 | feat(wiki): 並行 ingest 排他（push リトライ + ingest セッション lock + 絶対パス契約） | worktree-git.sh NFF リトライ + ingest.md + lockdir | S1 |
| S6 | feat(pr-open): worktree 作成 + EnterWorktree 入場 | Step 0.5 / 2.2-W / 2.3-W、冪等 5 ケース、claim 配線 | S1, S2, S3 |
| S7 | feat(pr-cleanup): worktree 退出・削除 + base pull 安全化 + claim release | Step 4-W / Step 5 順序 / Step 12 報告 | S4, S6 |
| S8 | feat(resume): worktree 再入場・消失時再構築 | Phase 1.1 fallback / 3.1.5 / 5.1 検証化 | S6 |
| S9 | feat(sprint): claim 済 Issue のスキップ判定 | execute / team-execute 各 2 挿入点 | S3 |
| S10 | docs: マルチセッション運用ドキュメント + 2 セッション E2E 手動検証 | SPEC.md / git-worktree-patterns.md / workflow.md / getting-started.md + E2E 手順 | S6–S8 |
| S11 | fix(hooks): compact-state の per-session 化（optional hardening） | `.rite-compact-state` → per-session 化（V-4 の既存ギャップ） | S1 |

**実装順**: S1 → (S2, S3, S5 並行) → S4 → S6 → (S7, S8, S9 並行) → S10。S11 は S1 以降の任意タイミング。

<!-- Section ID: SPEC-RELATED -->
## 関連

- 先行設計: [multi-session-state.md](./multi-session-state.md) — flow-state の per-session 分離（Option A、先行系列で実装済み）
- 先行設計: [session-ownership-flow-state.md](./session-ownership-flow-state.md) — session ownership 機構（2h stale 閾値を本設計の claim liveness が再利用）
- 先行設計: [clear-per-command-flow-state-decoupling.md](./clear-per-command-flow-state-decoupling.md) — `/clear` 跨ぎの状態権威の整理（flow-state は session-scoped hint の原則）
- worktree 操作の canonical パターン: `plugins/rite/references/git-worktree-patterns.md`
- Wiki worktree 設計: `.rite/wiki-worktree` 永続化の設計
