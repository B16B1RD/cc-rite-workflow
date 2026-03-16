# `.rite-flow-state` Session Ownership — 複数インスタンス競合対策

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

`.rite-flow-state` に `session_id` フィールドを追加し、各 hook が「自セッションの state か」を確認してから操作するようにする。これにより、同一リポジトリで複数の Claude Code インスタンスが同時に rite workflow を使用しても、state の相互上書きを防止する。

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

同一リポジトリで複数の Claude Code インスタンスを起動し rite workflow を使用すると、`.rite-flow-state`（リポジトリ root に1つだけ存在する JSON）が相互に上書きされて混乱する。

**具体的な問題**:
1. Instance B の `session-start.sh` が Instance A の `active: true` をリセット
2. Instance B の `session-end.sh` が Instance A の進行中 state を `active: false` に変更
3. Instance B の `stop-guard.sh` が Instance A の state を読んで自セッションを誤ブロック
4. `flow-state-update.sh create` が他セッションの active な state を無条件上書き

**解決の鍵**: Claude Code は全 hook JSON ペイロードに `session_id` を自動付与（現在未使用）。

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

1. **Session ID 記録**: `flow-state-update.sh create` 時に `--session` パラメータで `session_id` を `.rite-flow-state` に保存
2. **所有権チェック**: 各 hook が state 操作前に自セッションの state かを判定
3. **上書き保護**: `create` モードで既存 active state が他セッションに属する場合（2h 以内）、エラー終了
4. **Stale 検出**: `updated_at` が 2 時間超の state は stale とみなし、上書きを許可
5. **Session ID 通知**: `session-start.sh` が `rite_session_id: {id}` を stdout 出力し、Claude がコマンド実行時に使用可能にする
6. **所有権移転**: `resume.md` 実行時に新セッションの `session_id` で所有権を移転
7. **Compact 再注入**: `pre-compact.sh` の再注入メッセージに `Session: {id}` を追加
8. **Context Counter 所有権チェック**: `context-pressure.sh` がカウンタ操作前に自セッションの state かを確認し、他セッションのカウンタ操作をスキップ
9. **Diag Log セッション識別**: `stop-guard.sh` の診断ログ出力に session_id を付与し、ログエントリのセッション帰属を明確化

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

1. **後方互換性**: `session_id` フィールドがない古い state は全セッションが所有者とみなす（現行動作と同じ）
2. **自セッション ID 不明時**: `session_id` が取得できない場合も所有者扱い（後方互換）
3. **パフォーマンス**: 各 hook に `jq` 1回の追加処理のみ（既存パフォーマンスへの影響は最小限）
4. **信頼性**: 部分的な障害（session_id 取得不可等）でも既存動作にフォールバック

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

1. **session_id の取得元**: hook JSON ペイロードの `session_id` フィールド（Claude Code が自動付与）
2. **Stale 判定閾値**: 2 時間（`updated_at` からの経過時間）
3. **共通ヘルパー**: `session-ownership.sh` を `source` で読み込む方式（関数の重複を排除）
4. **patch/increment モード**: `session_id` フィールドは触らない（所有権維持）
5. **エラーメッセージ**: 「他セッション進行中」ではなく一般的な表現を使用（`/clear` 後の自インスタンスかもしれないため）

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

| コンポーネント | 役割 |
|--------------|------|
| `session-ownership.sh` | 共通ヘルパーライブラリ（session_id 抽出、所有権チェック、ISO8601 パーサー） |
| `flow-state-update.sh` | `--session` パラメータ追加、create 時の上書き保護 |
| `session-start.sh` | session_id 抽出・通知、defensive reset の所有権チェック |
| `session-end.sh` | 終了時の所有権チェック（他セッション state は変更しない） |
| `stop-guard.sh` | 停止判定時の所有権チェック（他セッション state は無視） |
| `post-tool-wm-sync.sh` | 作業メモリ同期の所有権チェック |
| `pre-compact.sh` | compact 時の所有権チェック + 再注入メッセージ更新 |
| `context-pressure.sh` | カウンタ操作の所有権チェック（他セッションのカウンタ更新をスキップ） |
| コマンドファイル群 | 全 `flow-state-update.sh create` 呼び出しに `--session {session_id}` 追加 |

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

```
Claude Code Session Start
  → session-start.sh: hook JSON から session_id 抽出
  → stdout: "rite_session_id: {id}" 出力
  → Claude: session_id を記憶

ワークフロー開始
  → コマンドファイル: flow-state-update.sh create --session {session_id}
  → flow-state-update.sh: 既存 state の所有権チェック → JSON に session_id 記録

各 hook 実行時
  → hook JSON から自 session_id 抽出
  → .rite-flow-state の session_id と比較
  → 一致 or legacy → 操作実行
  → 不一致 → スキップ（exit 0）
```

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

**新規作成**:
- `plugins/rite/hooks/session-ownership.sh` — 共通ヘルパーライブラリ

**Hook ファイル変更**:
- `plugins/rite/hooks/flow-state-update.sh` — `--session` パラメータ、上書き保護
- `plugins/rite/hooks/session-start.sh` — session_id 抽出・通知、defensive reset 改修
- `plugins/rite/hooks/session-end.sh` — 所有権チェック追加
- `plugins/rite/hooks/stop-guard.sh` — 所有権チェック追加
- `plugins/rite/hooks/post-tool-wm-sync.sh` — 所有権チェック追加
- `plugins/rite/hooks/pre-compact.sh` — 所有権チェック + 再注入メッセージ更新
- `plugins/rite/hooks/context-pressure.sh` — カウンタ操作の所有権チェック追加

**コマンドファイル変更** (`--session {session_id}` 追加):
- `commands/issue/start.md` (16箇所)
- `commands/issue/create.md` (3箇所)
- `commands/issue/create-register.md` (1箇所)
- `commands/issue/create-decompose.md` (1箇所)
- `commands/issue/create-interview.md` (1箇所)
- `commands/issue/implement.md` (1箇所)
- `commands/pr/cleanup.md` (1箇所)
- `commands/resume.md` (jq 操作で所有権移転)

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

1. **Step 0 検証が必要**: hook JSON の `session_id` フィールド名を実機で確認してから実装開始
2. **`/clear` 後の挙動**: `/clear` 後は新しい session_id になるため、前セッションの state に対しては「他セッション」扱いになる。エラーメッセージで「他セッション」と断定せず一般的な表現を使用
3. **parse_iso8601_to_epoch の共有**: `stop-guard.sh` から `session-ownership.sh` に移動。既存の `stop-guard.sh` は `source` で参照するよう変更
4. **コマンドファイルの session_id 取得**: `session-start.sh` が出力する `rite_session_id` を Claude が記憶し、コマンド内の `{session_id}` プレースホルダーとして使用
5. **`.rite-context-counter` の競合**: 非アトミックな read-modify-write サイクル（cat → increment → echo）のため、並行セッションでカウンタ増分が消失する。所有権チェックで他セッション時はスキップすることで解決
6. **`.rite-stop-guard-diag.log` の競合**: append + ring buffer truncation が非同期だが、診断用のためデータロスは許容。session_id をログエントリに付与してセッション識別を改善

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

- 複数セッションの state を個別ファイルで管理する方式（例: `.rite-flow-state.{session_id}`）
- session_id の永続的なファイル保存（`.rite-session-id`）— hook JSON から直接取得する方式を採用
- GUI/TUI による複数セッション状態の可視化
- セッション間の state マージやコンフリクト解決機能
