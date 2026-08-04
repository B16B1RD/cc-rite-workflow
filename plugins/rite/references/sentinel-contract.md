# Sentinel Contract (SoT)

rite workflow のスキル間連携は、各 sub-skill が bash 出力に埋め込む機械可読な sentinel 文字列（`[skill:action]` 形式）を通じて行われる。emitter（emit する skill）と consumer（読み取って分岐する skill）は文字列一致という暗黙の契約で結合しており、型・enum による保証はない。本ファイルは全 sentinel の emitter/consumer 対応を列挙する唯一の SoT である。

新しい sentinel を追加・変更・削除する場合は、本ファイルの表と実体（emit 側 skill / consume 側 skill）を同一 PR 内で同期させること。同期の機械検証は [`sentinel-contract-check.sh`](../hooks/scripts/sentinel-contract-check.sh)（`/rite:lint` から実行）および CI（`.github/workflows/sentinel-contract-check.yml`）が行う。

## 表記規約

- **Sentinel**: `[skill:action]` 形式のリテラル文字列。可変部分（PR 番号・cycle 番号等）は `N` で表す
- **Emitter**: その sentinel を emit する責務を持つ skill（`plugins/rite/skills/{emitter}/SKILL.md`）
- **Consumer**: sentinel を読み取って分岐する skill。`rite-workflow` は個別に invoke される skill ではなく orchestrator 共有のルーティング表（`references/`）であるため、Consumer 列には計上しない（除外する）
- **意味**: sentinel が示す状態・結果
- **Numbered Sentinel（`:N]` で終わる行）の emitter 表記**: emitter 側の SKILL.md 本体は実際に emit する際の bash 変数置換前提のため、`{number}` / `{pr_number}` / `{issue_number}` のようなテンプレート placeholder で表記する（リテラル `N` はコンシューマ側ドキュメントが「任意の数値」を表すための表記規約であり、emitter 自身の実装コメントには現れないことがある）。`sentinel-contract-check.sh` の emitter 存在確認は `:N]` サフィックスを検出すると `[prefix:(\{[A-Za-z_]+\}|[0-9]+|N)]` パターンの正規表現一致に切り替え、テンプレート placeholder 表記・具体的な数値例（例: `[pr:created:123]`）・リテラル `N` のいずれも許容する

## Sentinel 一覧

| Sentinel | Emitter | Consumer | 意味 |
|----------|---------|----------|------|
| `[review:mergeable]` | pr-review | iterate, batch-run | レビュー結果が mergeable（blocking finding 0 件） |
| `[review:fix-needed:N]` | pr-review | iterate | レビューで N 件の blocking finding を検出、fix へ。iterate のループ内部状態のため batch-run へは bubble しない |
| `[review:error]` | pr-review | iterate | review 実行中にエラー発生。iterate 内部で処理され batch-run へは bubble しない |
| `[fix:error]` | fix | iterate, batch-run | fix 実行中にエラー発生 |
| `[fix:pushed]` | fix | iterate | fix 完了・push 済み、review へ再突入。iterate のループ内部状態のため batch-run へは bubble しない |
| `[fix:pushed-wm-stale]` | fix | iterate | fix push 完了だが work memory 更新が失敗（non-blocking）。iterate 内部で処理され batch-run へは bubble しない |
| `[fix:replied-only]` | fix | iterate, batch-run | 対応不要判定のみで push なし（コメント返信のみ） |
| `[fix:cancelled-by-user]` | fix | iterate, batch-run | ユーザーが fix 実行をキャンセル |
| `[lint:success]` | lint | open, pr-create, ready | lint 全チェック pass |
| `[lint:error]` | lint | issue-implement, open | lint でエラー検出、修正が必要 |
| `[lint:skipped]` | lint | open | lint 未設定のためスキップ |
| `[lint:aborted]` | lint | issue-implement, open | lint 実行が中断 |
| `[lint:returned-to-caller:auto]` | wiki-lint | wiki-ingest | `--auto` モードでの wiki-lint 完了、caller (wiki-ingest) へ制御を返す |
| `[ready:returned-to-caller]` | ready | batch-run | Ready for review 化完了、caller へ制御を返す |
| `[ready:error]` | ready | batch-run | Ready 化中にエラー発生 |
| `[merge:returned-to-caller]` | merge | batch-run | マージ完了、caller へ制御を返す |
| `[merge:not-ready]` | merge | batch-run | PR が draft または mergeable でないため merge 不可 |
| `[merge:error]` | merge | batch-run | merge 実行中にエラー発生 |
| `[cleanup:returned-to-caller]` | cleanup | batch-run | クリーンアップ完了、caller へ制御を返す |
| `[cleanup:outstanding:N]` | cleanup | batch-run | 完了報告の「未完了事項」件数（N 件、0 も明示）。batch-run は N>0 のとき run-queue の `outstanding[]` に記録する（Issue #1946） |
| `[ingest:returned-to-caller]` | wiki-ingest | (caller の turn 継続マーカー、literal consumer なし) | Wiki ingest 完了。cleanup 側は本 sentinel を literal grep で consume せず、独自の `[CONTEXT] WIKI_INGEST_DONE/FAILED` 等で成否判定する。sentinel 自体は turn-boundary heuristic 誤発火を防ぐ active disambiguation 目的 |
| `[create:returned-to-caller:N]` | issue-create | (terminal、consumer なし) | Issue #N 作成完了。issue-create は他 skill から呼ばれない flat workflow のため、caller への継続ルーティングは持たない terminal sentinel |
| `[pr:created:N]` | pr-create | open, recover, batch-run | PR #N を作成完了 |
| `[pr-create-failed]` | pr-create | open, batch-run | PR 作成に失敗 |
| `[iterate:max-cycles-reached]` | iterate | batch-run | review⇄fix ループのサーキットブレーカーが発火（収束トレンドの発散検出、または `safety.max_review_cycles` 到達 = backstop）。**sentinel は発火理由に依らず同一 literal**（batch は理由を問わず failed 記録するため） |
| `[iterate:max-cycles-stopped]` | iterate | (iterate 内部完結) | サーキットブレーカー発火（発散検出 または `safety.max_review_cycles` backstop）でループを停止した最終状態表示。理由は停止通知の「理由」行が担う |
| `[run:all-completed]` | batch-run | (batch-run 内部完結、最終出力) | バッチ処理対象の全 Issue が完了 |
| `[run:stopped]` | batch-run | (batch-run 内部完結、最終出力) | サーキットブレーカー等でバッチ処理を中断 |
| `[projects:fetch-failed]` | issue-list | (issue-list 内部完結) | GitHub Projects からのフィールド取得に失敗 |
| `[learn:complete]` | learn | (learn 内部完結) | 学習セッション完了 |

## Non-Sentinel な類似記法（検証対象外）

以下は本表の対象外であり、`sentinel-contract-check.sh` は固定 denylist で無視する:

- `[CONTEXT] key=value` 形式（`skills/wiki-lint/references/bash-cross-boundary-state-transfer.md` の state 伝達パターン。sentinel ではなく任意の key=value ペア。先頭大文字のため検出 regex が自然に除外する）
- ドキュメント内の汎用プレースホルダ例: `[file:line]`（`fix/SKILL.md` の `scope_map[file:line]` データ構造キー表記）、`[tag:value]`（`rite-workflow/references/workflow-identity.md` の HTML コメント化を説明する抽象例）。なお `[skill:returned-to-caller]` / `[name:returned-to-caller]` のような抽象 skill 名は `hooks/tests/sentinel-disambiguator-adjacency.test.sh`（テストフィクスチャ）でのみ使われ、I3 スキャン対象（`plugins/rite/skills/` 配下の `*.md` および `plugins/rite/hooks/` 直下の `*.sh` — `hooks/scripts/` と `hooks/tests/` は lint-check ユーティリティ／テストフィクスチャのため対象外）の外にあるため、そもそも denylist に含める必要がない
- コード中の正規表現文字クラス（例: `[a-z_-]`、`[A-Za-z0-9_]`）。検出 regex はコロン必須のため自然に除外される
- 検証スクリプトの denylist は `plugins/rite/hooks/scripts/sentinel-contract-check.sh` 冒頭の `NON_SENTINEL_DENYLIST` 配列を参照（本節と同期させること）
