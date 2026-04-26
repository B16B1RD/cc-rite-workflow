# `.rite-flow-state` マルチステート構造再設計 — 並行セッション対応

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

`.rite-flow-state` を「単一 session 専用ファイル」から「複数 session の state を構造的に管理できる形式」へ再設計する。同一リポジトリで複数の Claude Code セッションを並行起動した際に、各セッションの flow-state が独立に保持され、`phase-transition-whitelist` 等の残存 hook 群（`pre-compact.sh` / `post-compact.sh` / `post-tool-wm-sync.sh` / `pre-tool-bash-guard.sh`）が正常動作するようにする。

> **Note**: `stop-guard.sh` は `develop` ブランチの直前 commit (`e2dfae0`, PR #675) で撤去済みのため、本設計ドキュメントの参照対象から除外している。マルチステート構造の整合性は phase-transition-whitelist と各 hook の自 session state 参照経路で担保する。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

### 既存設計の限界

`.rite-flow-state` は当初 1 セッション 1 リポジトリ前提で設計された単一ファイル方式を採用している。しかし、ユーザーが同一リポジトリで複数の Claude Code セッションを並行起動する運用が現実化したことで、1 ファイル運用は構造的に成立しないことが判明した。

Session Ownership 機構（#173 / #206 / #216 / #558 / #660 系列）はこの単一ファイル前提の上に「session_id check」というガード層を追加してきたが、ガード層では root cause（並行書き込み競合）を解消できないため、漏れ経路を逐次塞ぐ N+1 回目の regression が繰り返されている。

### Wiki 経験則からの強い制約

[Wiki 経験則 #660](https://github.com/B16B1RD/cc-rite-workflow/issues/660) によれば、過去 9 件の Issue で導入した 8 種類の防御層 (declarative / sentinel / Pre-check / whitelist / Pre-flight / Step 0 / 4-site 対称化 / case arm) は AND 論理で組まれており、**`.rite-flow-state.active=true` という単一前提条件に依存** していた。当時の運用統計 (`.rite-stop-guard-diag.log` 直近 30 件中 28 件 = 93% が `EXIT:0 reason=not_active`) は撤去前の stop-guard.sh の挙動を示しており、**現行残存 hook 群 (phase-transition-whitelist 等) における同等の前提条件依存の有無は本設計選定時点では未測定**である。

ただし、`.active=true` 前提条件への AND 論理依存自体は phase-transition-whitelist.sh / pre-compact.sh / post-compact.sh / post-tool-wm-sync.sh / pre-tool-bash-guard.sh の `.active` 参照箇所 (各 hook の `jq -r '.active'` 経路) として残存している。マルチステート対応では、これら残存 hook 群でも **同等保証を残す必要がある**。さもなくばマルチステート移行と同時に過去の N+1 patch が部分的にでも無効化されるリスクがある。経験則の射程を「`.active=true` 前提への AND 論理依存」だけに絞り、残存 hook 群への適用は S3 以降の実装フェーズで explicit に検証する。

### 解決方針

本 Issue (#672) では `.rite-flow-state` を **マルチステート構造** へ再設計し、並行セッションを first-class に扱う。Session Ownership 機構（ガード層）はマルチステート構造の上に整理し直し、漏れ経路を個別 patch する戦略から脱却する。

<!-- Section ID: SPEC-CANDIDATES -->
## 候補方式

### Option A: per-session file

`.rite/sessions/{session_id}.flow-state` として session ごとに独立ファイルを持つ。

```
.rite/
└── sessions/
    ├── 34eadf04-8f13-4ce3-adcd-8dc6668a5b9f.flow-state
    ├── 9a8b7c6d-...flow-state
    └── ...
```

**特性**:
- ファイル名 = session_id（UUID）
- 各 hook は自 session の state file のみを読み書き
- session 終了時に該当 file を cleanup
- 横断参照は明示的なディレクトリ走査（`ls .rite/sessions/`）

**State 各 file の構造**: 現行 `flow-state-update.sh:221` の `jq -n create` object を SoT として、以下のフィールド構成で運用する。

**create 時の必須フィールド (現行 11 項目をそのまま継承)**:

`active`, `issue_number`, `branch`, `phase`, `previous_phase`, `pr_number`, `parent_issue_number`, `next_action`, `updated_at`, `session_id`, `last_synced_phase`

**実行時に追加される optional フィールド (現行 hook 群が後付けで patch する)**:

- `wm_comment_id` (`issue-comment-wm-sync.sh` が cache 用に書込)
- `error_count` (`flow-state-update.sh` patch mode が cycle カウンタとして書込)
- `loop_count` (`work-memory-update.sh` 等の循環検出が書込)

> **Note — `needs_clear` の現状**: `needs_clear` フィールドは過去の compact 復旧パス用として議論されたが、**現行 production code では writer も reader も存在しない** (`grep -rln "needs_clear" plugins/rite/hooks/` で `tests/` 配下のみマッチ、本体実装なし)。`pre-compact.test.sh` TC-014 / TC-014b は逆に「pre-compact does NOT set needs_clear」を AC-2 として検証する stale field。`docs/tests/stop-guard.test.md:436` でも「廃止された `needs_clear` フラグ」と明記されているため、新形式 schema には含めず、必要なら S3 で実装方針を確定する後追い検討事項とする。

**新形式で新規追加するフィールド (本 Issue / S3 で導入)**:

- `schema_version` (新形式判定の primary key)。**現行 schema (`flow-state-update.sh:221` の jq -n create) には含まれていない**ため、Migration 検出条件「`schema_version` キー無 or `< 2`」は **現行運用中のすべての `.rite-flow-state` ファイルが migration 対象** になることを意味する (詳細は下記 Migration 戦略参照)。

### Option B: multi-state single file

`.rite-flow-state` を `{"sessions": {"<id>": {...}, ...}}` の構造化単一 JSON として保持。

```json
{
  "schema_version": 2,
  "sessions": {
    "34eadf04-8f13-4ce3-adcd-8dc6668a5b9f": {
      "active": true,
      "issue_number": 672,
      "branch": "fix/issue-672-...",
      "phase": "phase5_lint",
      "...": "..."
    },
    "9a8b7c6d-...": {
      "active": false,
      "...": "..."
    }
  },
  "updated_at": "2026-04-26T...+09:00"
}
```

**特性**:
- ファイル数 = 1 (現状維持)
- 全 hook が単一 file を読み書き
- write 時は file lock (flock or `mkdir` lockdir) を取得
- session 終了時は該当 entry を削除（file 自体は残存）

<!-- Section ID: SPEC-COMPARISON -->
## 6 軸 Trade-off 比較表

| # | 評価軸 | Option A (per-session file) | Option B (multi-state single file) |
|---|--------|----------------------------|--------------------------------------|
| 1 | **並行性** | ✅ 構造的に競合不可（独立ファイル）。lock 不要で race window なし | ⚠️ 全体 lock 必須。lock 取得漏れで競合再発リスク。lock acquisition overhead あり |
| 2 | **Parsing 単純さ** | ✅ 既存 `jq -n` create pattern をほぼ流用可。`.path` の depth は現行と同じ | ❌ `.sessions["<id>"]` 経由で depth +2。全 hook の jq 式を書き換え必要 |
| 3 | **Cleanup 経路** | ⚠️ session 終了時に該当 file 削除。stale file (long-running session, crash 後の取り残し) の検出ロジック追加 | ✅ session entry 削除のみで簡潔。stale entry 検出は file の `updated_at` で済む |
| 4 | **Migration 容易さ** | ⚠️ パス変更 (`.rite-flow-state` → `.rite/sessions/{id}.flow-state`) + 形式は同じ | ⚠️ 同一パスで形式変更（旧の flat → 新の `{sessions: {...}}`）。両方とも自動 migration 機構必要 |
| 5 | **障害耐性** | ✅ 1 session のファイル破損が他に影響しない（障害分離） | ❌ 単一ファイル破損で全 session が影響 |
| 6 | **Hook の自セッション state 参照最適化** (phase-transition-whitelist / pre-compact / post-compact / post-tool-wm-sync / pre-tool-bash-guard) | ✅ session 限定で読込量削減。複数 session 起動時も自分の state のみ参照 | ❌ 全 session 読込必須（自セッション entry を `.sessions[$id]` で取得）。session 数増加で linear scan |

### 補助観点

| 観点 | Option A | Option B |
|------|----------|----------|
| `.gitignore` 影響 | `.rite/sessions/` を ignore に追加 | 現状維持 (`.rite-flow-state` のまま) |
| atomic write 実装 | 既存 mktemp + mv をファイル単位で踏襲 (シンプル) | tmp file + flock + mv の組合せ。lock acquisition 失敗時の handling 必要 |
| post-compact context restore | 自 session の file を read | 全 sessions から自 session entry を抽出 |
| Hook の自 session state 参照 (phase-transition-whitelist 等) | `[ -f .rite/sessions/$id.flow-state ]` で OS が ownership を保証 | jq で entry 存在確認 (現行 logic のほぼ流用) |
| 運用 overhead | ファイル数増加（数十 session 規模で問題化） | ファイル肥大化（1 session entry 当たり ~500 byte * N） |

<!-- Section ID: SPEC-RECOMMENDATION -->
## 採択候補と推奨理由

### 推奨: **Option A (per-session file)**

**主要根拠**:

1. **並行性が構造的に保証される**: lock 不要 = race window なし。Issue #660 で観測された「lock 取得漏れによる race」を構造的に排除できる
2. **障害分離**: 1 session の file 破損が他 session に波及しない（B では単一ファイル破損で全滅）
3. **既存実装の最小修正**: jq -n pattern / atomic write pattern (mktemp + mv) を流用可能
4. **残存 hook 群 (phase-transition-whitelist / pre-compact / post-compact / post-tool-wm-sync / pre-tool-bash-guard) の自 session 参照最適化**: 各 hook が `.rite/sessions/$session_id.flow-state` のみ読込 → session 数増加に対して O(1)。Option B では全 sessions JSON の linear scan が必要
5. **`.rite-session-id` との整合**: session 識別子の SoT がすでにファイルベース (`.rite-session-id`) なので、命名規則として自然

**Option B が有利な唯一のケース**:
- session 数が極めて多く（数百〜）、各 file の inode overhead が問題になる場合
- ファイル数を `.gitignore` で管理することを避けたい場合

このリポジトリでは並行 session 数は通常 2〜3 程度で、上記いずれにも該当しない。

<!-- Section ID: SPEC-DECISION-LOG -->
## Decision Log

### Phase 1: 設計選定 (確定)

> **Status**: ✅ 確定 — Issue #672 / S2 にて user 承認

| 項目 | 値 |
|------|-----|
| 採択方式 | **Option A: per-session file** (`.rite/sessions/{session_id}.flow-state`) |
| 採択理由 | (1) lock 不要で並行性が**構造的に保証**される (Issue #660 で観測された race window 系列の root cause を排除)。(2) 1 session の file 破損が他 session に波及しない**障害分離**。(3) 既存 jq -n create pattern と atomic write (mktemp + mv) を**最小修正で流用可能**。(4) **残存 hook 群** (`phase-transition-whitelist.sh` / `pre-compact.sh` / `post-compact.sh` / `post-tool-wm-sync.sh` / `pre-tool-bash-guard.sh`) **が自 session の file のみを読込むため、session 数増加に対して O(1)** (stop-guard.sh は PR #675 で撤去済みのため対象外)。(5) `.rite-session-id` が既にファイルベースの SoT のため、命名規則として自然 |
| 比較根拠 | 上記「6 軸 Trade-off 比較表」(並行性 / parsing / cleanup / migration / 障害耐性 / Hook の自セッション state 参照最適化) |
| 決定者 | user (Issue #672 / S2 の AskUserQuestion 経由) |
| 決定日 | 2026-04-26 |
| Option B が落選した主因 | 全体 lock の取得漏れリスク (Issue #660 系列で繰り返された race window 問題の構造的再発リスク) と、単一ファイル破損で全 session が影響する障害伝播リスクが、Option A の cleanup ロジック追加コストを上回ると判断 |

### Session Ownership 機構の扱い

**決定**: 単一ファイル前提のガード層（`.session_id` field + 4 状態判定 own/legacy/other/stale）から、マルチステート構造の **前提部品** へ役割転換する。

**詳細**:
- `session_id` は state ファイル名（Option A 採用時）または entry key（Option B 採用時）として **構造的に** ownership を保証
- Stale 検出（`updated_at` 2 時間閾値）は cleanup ロジックに統合し、ガード層独立の判定としては保持しない
- `session-ownership.sh` の helper 関数群は新形式の path/entry 解決ヘルパーへ整理

<!-- Section ID: SPEC-MIGRATION -->
## Migration 戦略

### 旧形式自動 migration

起動時に `.rite-flow-state` 旧形式（flat JSON、`schema_version` キー無 or `< 2`）を検出 → 自動 migration 実行 + 警告表示（silent skip 禁止 / AC-8）。

> **⚠️ Migration scope の明示**: 旧形式検出条件「`schema_version` キー無 or `< 2`」は、現行 `flow-state-update.sh:221` の jq -n create object に `schema_version` フィールドが含まれていない事実から、**現行運用中のすべての `.rite-flow-state` ファイルが migration 対象** になる。S3 実装では in-flight session を中断させない順序で migration を実行する必要がある。具体的には: (a) `session-start.sh` の最も早いタイミングで migration を発火、(b) atomic mv で原子的に新形式へ切替、(c) 既存の `.rite-flow-state` を `.rite-flow-state.legacy.{timestamp}` に rename することで他 session の進行中 hook が古い path を参照していても破壊しない。

**手順** (採択方式 Option A 採用時、5 step 構成、rename 方式):
1. 旧形式 state を検出 (`.rite-flow-state` が存在し、`schema_version` キーが欠落 or `< 2`)
2. 旧 state から `session_id` を読み取る (なければ新規 UUID を生成)
3. 新形式 state file を `.rite/sessions/{session_id}.flow-state` に **atomic write (mktemp + mv)** で書き込み (`schema_version: 2` を必ず含める)
4. step 3 が成功したら、旧 source `.rite-flow-state` を `.rite-flow-state.legacy.{timestamp}` へ **rename** (mv) で確定する。これにより backup 保存と旧 source 撤去を同時に実現する (コピーではなく rename = 1 回の filesystem 操作で原子性を担保)
5. stderr に明示的な migration メッセージ出力 (例: `migrated: .rite-flow-state → .rite/sessions/{id}.flow-state (backup: .rite-flow-state.legacy.{ts})`)

> **Option B 採用時の手順差分**: step 3 で同一パス `.rite-flow-state` に in-place で `{"schema_version": 2, "sessions": {"{session_id}": {<旧 state>}}}` 構造を書き込み、step 4 (rename) は不要 (path が変わらないため)。ただし step 3 実行前に backup として `.rite-flow-state.legacy.{timestamp}` への copy が必須。

**制約**:
- 旧形式に `session_id` がない場合は新規 UUID を生成して付与
- migration 自体が失敗した場合は旧形式を保持 (destructive な変換を回避):
  - **step 3 (atomic write) で失敗**: 新形式 file を残さず exit。旧 source `.rite-flow-state` は無傷 (step 4 未実行のため) → rollback 不要、ユーザーは旧形式で運用継続可
  - **step 4 (rename) で失敗**: step 3 で新形式 file が `.rite/sessions/{id}.flow-state` に存在するため、新形式 file を削除して旧 source を無傷で残す → ユーザーは旧形式で運用継続可
  - いずれも step 5 の migration メッセージは出力せず ERROR ログを出して S3 が次回 retry できるようにする

### Rollback 戦略

`rite-config.yml` に `flow_state.schema_version` を導入 (初期値 `2`)。`schema_version: 1` を明示すると旧形式（flat JSON）で動作する fallback path を保持。

実装は段階的（adapter pattern）に導入：
1. 新 API 内部で `schema_version` を判定し、`1` なら旧 logic、`2` なら新 logic を実行
2. 新 API が安定するまで両 logic を共存
3. 一定期間後（例: v0.5.0）、旧 logic を撤去

<!-- Section ID: SPEC-TESTS -->
## テスト戦略

### Acceptance Criteria 対応マッピング

| AC | テスト ID | テスト内容 |
|----|-----------|-----------|
| AC-1 | T-01 | 並行 2 セッションでの state 独立性 |
| AC-2 | T-02 | 単独運用での全 phase non-regression |
| AC-3 | T-03 | process crash 後の resume 可能性 |
| AC-4 | T-04 | session_id mismatch 時の hook no-op |
| AC-5 | T-05 | 同 Issue 同時 target 時の競合検出 |
| AC-6 | T-06 | hooks 既存テストスイート全 pass |
| AC-7 | T-07 | Session Ownership 系 (#173/#206/#216/#558/#660) AC 再検証 |
| AC-8 | T-08 | 旧形式 state file の自動 migration |
| AC-9 | T-09 | atomic write の整合性 |
| AC-10 | T-10 | session 正常終了時の cleanup（Option A 採用時） |
| AC-11 | T-11 | crash 後の lock 自動解放（Option B 採用時） |
| AC-12 | T-12 | Decision Log 記載確認 |

### 重要なテスト観点

1. **並行書き込み regression**: 2 セッションが同一 sub-second window で write しても両方の state が独立保持される
2. **Wiki 経験則の再現テスト**: `.active=true` 前提への AND 論理依存が新形式でも正しく動作（防御層 8 種が稼働）
3. **silent reset 防止**: `jq -n create` が既存値を読み取って再構築するパターンが新形式でも維持されている

<!-- Section ID: SPEC-RELATED -->
## 関連

- 親系列: #173（Session Ownership 親 Issue — 本 Issue で root cause を解消し、ガード層から構造へ昇格）
- 過去対策（漏れ経路の N+1 patch 履歴）: #206 / #216 / #558 / #660
- Wiki 経験則: 「前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する」
- Wiki 経験則: 「jq -n create mode: 既存値を読み取ってから再構築する」
