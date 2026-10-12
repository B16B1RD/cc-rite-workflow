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
| `[review:mergeable]` | iterate | batch-run | 非 fatal 移送後の 5.S 成功を外向きに返す（失敗時は返さない） |
| `[review:fix-needed:N]` | pr-review | iterate | レビューで N 件の blocking finding を検出、fix へ。iterate のループ内部状態のため batch-run へは bubble しない |
| `[review:error]` | pr-review | iterate | review 実行中にエラー発生。iterate 内部で処理され batch-run へは bubble しない |
| `[fix:error]` | fix | iterate, batch-run | fix 実行中にエラー発生 |
| `[fix:pushed]` | fix | iterate | fix 完了・push 済み（または本 cycle に accept か PR 本文の修正のいずれかあり）、review へ再突入。iterate のループ内部状態のため batch-run へは bubble しない |
| `[fix:sweep-done]` | fix | iterate | NB digest sweep 完了。`/rite:fix --nb-sweep`（iterate 5.S）からのみ emit する。iterate は 5.S の戻りとして入口の終了理由を保持し、PR 内推奨の修正と完了前確認を経てステップ 5 完了通知へ（sweep の戻りでステップ 1 に戻らない） |
| `[fix:pushed-wm-stale]` | fix | iterate | fix push 完了だが work memory 更新が失敗（non-blocking）。iterate 内部で処理され batch-run へは bubble しない |
| `[fix:non-fatal-only]` | fix | iterate | 通常終了（fix 5.1 row 4.5）: fatal=0、非 fatal 移送が 1 件以上、全指摘に返信済み、push / 本 cycle の accept・PR 本文の修正なし。別経路として、NB digest sweep が current-pr の非 fatal 指摘を PR 内推奨へ登録し、`NB_SWEEP_PR_FIX=pending` かつゲート成功なら、fix 5.1 を実行せず iterate 5.S 専用表へ早期 return する。この場合 sweep は未完了で、入口の `sweep_origin` を保持し、check → mark → 通常 fix → push → 再レビューへ進む。登録だけでは完了・mergeable を通知せず、5.S sweep 成功後の PR 内推奨の修正・完了前確認を経て外向きに review:mergeable を返す |
| `[fix:replied-only]` | fix | iterate, batch-run | push / 本 cycle の accept・PR 本文の修正なしで全返信済み（非 fatal 移送との混在を含む）。5.S 成功後も返信のみで終了し、mergeable へ昇格しない |
| `[fix:cancelled-by-user]` | fix | iterate, batch-run | ユーザーが fix 実行をキャンセル |
| `[lint:success]` | lint | open, pr-create, ready | lint 全チェック pass |
| `[lint:error]` | lint | issue-implement, open | lint でエラー検出、修正が必要 |
| `[lint:skipped]` | lint | open | lint 未設定・未検出のためスキップ（batch は質問なしで選ぶ。batch-run へは bubble しない） |
| `[lint:aborted]` | lint | issue-implement, open | lint 実行が中断 |
| `[lint:returned-to-caller:auto]` | wiki-lint | wiki-ingest | `--auto` モードでの wiki-lint 完了、caller (wiki-ingest) へ制御を返す |
| `[ready:returned-to-caller]` | ready | batch-run | Ready for review 化完了、caller へ制御を返す |
| `[ready:error]` | ready | batch-run | Ready 化中にエラー発生 |
| `[merge:ci-wait-continue]` | merge | merge | CI が進行中のため同じ待ち block を再実行する内部継続。後続ゲートへ進まず、caller へ制御を返さない |
| `[merge:returned-to-caller]` | merge | batch-run | マージ完了、caller へ制御を返す |
| `[merge:not-ready]` | merge | batch-run | PR が draft または mergeable でないため merge 不可。再判定後も `mergeable == CONFLICTING` のときだけ `[CONTEXT] MERGE_NOT_READY=conflicting; pr=N` を併記し、batch-run は base 取り込みから iterate へ戻る。併記がなければ停止 |
| `[merge:error]` | merge | batch-run | merge 実行中にエラー発生 |
| `[cleanup:returned-to-caller]` | cleanup | batch-run | クリーンアップ完了、caller へ制御を返す |
| `[cleanup:outstanding:N]` | cleanup | batch-run | 完了報告の「未完了事項」件数（N 件、0 も明示）。batch-run は N>0 のとき run-queue の `outstanding[]` に記録する |
| `[ingest:returned-to-caller]` | wiki-ingest | (caller の turn 継続マーカー、literal consumer なし) | Wiki ingest 完了。cleanup 側は本 sentinel を literal grep で consume せず、独自の `[CONTEXT] WIKI_INGEST_DONE/FAILED` 等で成否判定する。sentinel 自体は turn-boundary heuristic 誤発火を防ぐ active disambiguation 目的 |
| `[create:returned-to-caller:N]` | issue-create | (terminal、consumer なし) | Issue #N 作成完了。issue-create は他 skill から呼ばれない flat workflow のため、caller への継続ルーティングは持たない terminal sentinel |
| `[pr:created:N]` | pr-create | open, recover, batch-run | PR #N を作成完了 |
| `[pr-create-failed]` | pr-create | open, batch-run | PR 作成に失敗 |
| `[iterate:max-cycles-reached]` | iterate | batch-run | review⇄fix ループのサーキットブレーカーが発火（収束トレンドの発散検出、または `safety.max_review_cycles` 到達 = backstop）。**sentinel は発火理由に依らず同一 literal**（batch は理由を問わず failed 記録するため） |
| `[iterate:nb-sweep-error]` | iterate | batch-run | NB digest sweep が collect / persist に失敗、入口の終了理由が不明、または止まった sweep の入口記録（ステップ 0.7）を検証できない。失敗即停止（`[fix:error]` と同帰結） |
| `[iterate:max-cycles-stopped]` | iterate | (iterate 内部完結) | サーキットブレーカー発火（発散検出 または `safety.max_review_cycles` backstop）でループを停止した最終状態表示。理由は停止通知の「理由」行が担う |
| `[run:all-completed]` | batch-run | (batch-run 内部完結、最終出力) | バッチ処理対象の全 Issue が完了 |
| `[run:stopped]` | batch-run | (batch-run 内部完結、最終出力) | サーキットブレーカー等でバッチ処理を中断 |
| `[projects:fetch-failed]` | issue-list | (issue-list 内部完結) | GitHub Projects からのフィールド取得に失敗 |
| `[learn:complete]` | learn | (learn 内部完結) | 学習セッション完了 |
| `[issue-audit:returned-to-caller]` | issue-audit | batch-run | Issue 監査が完了し、同じ返却ブロックの `監査レポート:` 行にレポートの path がある。caller へ制御を返す |
| `[issue-audit:failed]` | issue-audit | batch-run | 集計または処分に失敗。batch-run は完了通知の `要対応:` に載せて続行する |

## Non-Sentinel な類似記法（検証対象外）

以下は本表の対象外であり、`sentinel-contract-check.sh` は固定 denylist で無視する:

- `[CONTEXT] key=value` 形式（`skills/wiki-lint/references/bash-cross-boundary-state-transfer.md` の state 伝達パターン。sentinel ではなく任意の key=value ペア。先頭大文字のため検出 regex が自然に除外する）
- ドキュメント内の汎用プレースホルダ例: `[file:line]`（`fix/SKILL.md` の `scope_map[file:line]` データ構造キー表記）、`[tag:value]`（`rite-workflow/references/workflow-identity.md` の HTML コメント化を説明する抽象例）。なお `[skill:returned-to-caller]` / `[name:returned-to-caller]` のような抽象 skill 名は `hooks/tests/sentinel-disambiguator-adjacency.test.sh`（テストフィクスチャ）でのみ使われ、I3 スキャン対象（`plugins/rite/skills/` 配下の `*.md` および `plugins/rite/hooks/` 直下の `*.sh` — `hooks/scripts/` と `hooks/tests/` は lint-check ユーティリティ／テストフィクスチャのため対象外）の外にあるため、そもそも denylist に含める必要がない
- コード中の正規表現文字クラス（例: `[a-z_-]`、`[A-Za-z0-9_]`）。検出 regex はコロン必須のため自然に除外される
- 検証スクリプトの denylist は `plugins/rite/hooks/scripts/sentinel-contract-check.sh` 冒頭の `NON_SENTINEL_DENYLIST` 配列を参照（本節と同期させること）

## 設計規則

sentinel / marker を新設・変更・削除する設計とレビューに適用する。条件 → 規則の順で書く。

**定義と経路**

- sub-skill が success sentinel だけを定義すると、caller は abort / error 経路を区別できない。成功・中断・エラーの 3 経路を定義し、caller は排他的に grep する
- 新しい marker は emit・consume・テストの assertion の 3 点が揃って成立する。どれかが欠けた marker は dead signal である。consumer が存在しない marker は emit しない
- コメントや仕様で「機械が parse する」と断定する前に、parse 側の実在を grep で確かめる
- marker の判定表を持つ設計では、新設する fail-loud の出口も marker を emit する。表の外の出口は caller が分類できない
- marker に発行元を足したら、全発行経路で定義文と報告文が真かを確かめる
- 機構を廃止するときは、付随する marker・reason・文言も同時に廃止する。rename では現行の emit 箇所だけを対象とし、退役済みの fixture と設計の記録は保持する
- sentinel の可観測性を成果物とする変更は、自身が足した `2>&1` で sentinel を握りつぶしていないかを確かめる。helper の出力契約を docstring に明記し、caller テストで sentinel の emit と exit code の両方を検証する

**値と照合**

- 主要ツール（awk / grep / diff / sed / jq / find）の予約済み exit code を確かめてから、独自の exit code や sentinel 値を選ぶ。ツール自身の終了コードと衝突させない
- marker 値の照合は区切り文字まで含む完全一致で規定する。前方一致は別の marker を拾う
- emit 側が空を想定する値は、消費側（復旧コマンドの置換など）にも同じ想定を書く。bash 変数の初期値は許容値の集合に含める
- 外部由来の値（ブランチ名など）を無エスケープで marker 値に載せない。契約を満たせない入力は fail-fast する
- bash 変数を rename するときは変数参照 `${var}` だけを書き換える。同形の emit literal（`reason=` の値など）まで置換すると、ファイルをまたぐ grep 契約が壊れる
- sub-skill 内の bash 変数による guard は、別の invocation では常に未設定となる。cross-boundary の状態は明示的な context で渡す

**診断と集約**

- 診断 WARNING は事実だけを述べ、冒頭で原因を断定しない。帰結は機械可読な marker に委ねる
- 同一チャネルに複数の発行元があるときは、判別条件を特定の WARNING literal で閉じる
- 警告を集約するときは、最終試行・同一目的・正規化先の単一性で解消を判定する。別目的の成功で警告を消さない
- degraded と fail の境界は、差し戻しで原因を解消できるかで引く。`find` など外部コマンドの rc は検査して区別する
- 書戻しが失敗した経路で「書戻し済み」と断定しない。識別番号を marker に載せて案内まで運ぶ。追記後の再取得に失敗した場合も、記録の不在と区別して報告する
- helper を別工程から再利用するとき、`| grep -q MARKER || true` は障害と該当なしを同じ扱いにする。marker が無い非ゼロ終了は停止する規約を引き継ぐ
- helper の末尾に marker の echo を足すときは、marker の前に値を確かめ、空なら理由を出して止める。依存の失敗を再現する stub fixture でテストする

**gate と再入**

- 新設する gate は、順序規定・動作後に emit する sentinel・鮮度を確かめる参照値の 3 点を持つ。gate 自身を守られる範囲の内側に置かない
- skip 条件に「queue が active」だけを置かない。cursor が現在の対象を指すことまで含める
- 処理済みの記録は、判定そのものを行う処理が書く。片付け側への flag 受け渡しにしない
- 記録の読み手と書き手は同定規則を 1 か所で共有する。重複を見つけたときに古い記録を引き継がない
- 同じファイルに MUST NOT がある場所へ bash 実行ステップを足すときは、禁止が掛かる層（response text か Bash tool か）を特定し、prose で禁止対象の層を明示する

**pin の置き方**

- 「両側に置いた」と書いたら grep で両側を確かめる。drift 検出の完全一致 pin が片側だけの状態を正解として固定すると、非対称は検出できなくなる
- 隣接箇所との非対称を直すときは、方向を隣に合わせるのでなく、canonical schema の不変条件で cross-check する
