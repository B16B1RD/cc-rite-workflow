# Stop-Loop Continuation Contract — handoff 機構の単一解説

`stop-loop-continuation.sh`(Stop hook)と flow-state `handoff` フィールドによる「turn 早期終了の構造的差し戻し」機構の設計解説。**本ファイルが機構解説の単一の置き場**であり、各スキル(iterate / pr-review / fix / cleanup / ready)は操作指示 + 本ファイルへの 1 行ポインタのみを持つ(rationale 退避規約: CLAUDE.md スキル行数原則)。

## mechanism

ステップ遷移の「次のコマンドへ進む」(継続点)と完了通知(終了点)は本来 LLM が prose 指示 ("Do NOT stop") に従って自走するが、LLM が sentinel を出した直後に turn を終了する中断が観測された (継続点では次コマンドへ進まず停止し、終了点では `[review:mergeable]` 到達後に完了通知を出さず停止)。これを防ぐため、prose に依存しない **構造的な層** を `Stop` hook で実装している。継続点と終了点で **対称** に handoff をセットする:

- **継続 handoff (one-shot)**: 継続 sentinel を出す sub-skill が flow-state に `/rite:...` handoff をセットする。
  - `[review:fix-needed:N]` → pr-review.md Step 8.0 が `--handoff "/rite:fix {pr}"`
  - `[fix:pushed]` / `[fix:pushed-wm-stale]` → fix.md Step 5.1 が `--handoff "/rite:pr-review {pr}"`
- **終了 handoff (FINALIZE, one-shot)**: 終了 sentinel を出す sub-skill が flow-state に `FINALIZE:{result}:{pr}` handoff をセットする。
  - `[review:mergeable]` → pr-review.md Step 8.0 が `--handoff "FINALIZE:review:mergeable:{pr}"`
  - `[fix:replied-only]` → fix.md Step 5.1 が `--handoff "FINALIZE:fix:replied-only:{pr}"`
  - `[fix:cancelled-by-user]` → fix.md Step 1.4 cancel が `--handoff "FINALIZE:fix:cancelled-by-user:{pr}"`
  これらは sub-skill 内の defense-in-depth set で行われるため、**LLM が turn を終える前に確実に実行される**。
- **Stop hook が consume + prefix 分岐で再注入**: `stop-loop-continuation.sh` が turn 終了時に `flow-state.sh consume-handoff` で handoff を読み取り + 削除し、非空なら `decision:block` で停止を差し戻す。prefix で分岐し、`/rite:...` は次コマンド (`/rite:fix` / `/rite:pr-review`) を、`FINALIZE:...` は「iterate ステップ5 完了通知を出力してから終えよ」を再注入する。
- **`[fix:error]` は handoff を持たない**: clean terminal ではなく iterate ステップ4 で AskUserQuestion (再試行/中止) に分岐するため、`--handoff` を付けない (`flow-state.sh set` がデフォルトクリア) → Stop hook は停止を許可する。
- **サーキットブレーカー発火 (iterate ステップ 1 fire 分岐) も handoff を能動的にクリアする**: fire は直前の `[fix:pushed]` が set した継続 handoff (`/rite:pr-review {pr}`) の直後に到達しうる。iterate ステップ 6 は review/fix を回さず終端するため、この pending handoff を消さないと Stop hook が `/rite:pr-review` を再注入してブレーカーを無視する。したがって fire 分岐は `flow-state.sh set`（`--handoff` なし）でデフォルトクリアしてからステップ 6 へ進む（`[fix:error]` と同型の「set で handoff クリア」終端）。ステップ 6 は batch / 対話とも停止で終端し、共有前段の counter reset も `--handoff` を伴わないため handoff は再セットされない。よって**fire 分岐の set が成功していれば**発火後に Stop hook がループを再開させる経路は存在しない（#2026）。set が失敗した場合は handoff が残るため再注入されうる。fire 分岐はその失敗を `[CONTEXT] ITERATE_CB=fire; ...; HANDOFF_CLEAR=failed` として surface する（counter reset の成否は別軸で、ステップ 6 共有前段が `FIRE_RESET=` として emit し、ステップ 6.2 が停止通知に注意行を出す）。
- **無限 block ループ防止**: handoff は consume で one-shot 消費される。進捗 (次コマンド実行 / 完了通知出力) の後に再度停止すれば handoff は空 → block しない。handoff 自体は counter ではない (無限ループの自動安全網は別途 cycle counter サーキットブレーカー = iterate ステップ 6 が担う)。終了 handoff も同じ one-shot 契約で **1 回だけ** block するため、完了通知を強制しても無限 block にはならない。
- **resume との二層構造**: flow-state の `next_action` は Ctrl+C 中断後の `/rite:recover` 用の secondary な網。Stop hook は自動継続・完了通知強制の primary 層。

## wikichain-handoff

cleanup → wiki-ingest → wiki-lint の 2 段ネスト skill return 直後に LLM が turn を閉じる implicit stop が累積再発している。iterate ループの Stop-hook 継続保証と同型の one-shot handoff (`WIKICHAIN:cleanup:{pr}`) を移植し、チェーン途中で turn が閉じた場合は Stop hook が `WIKICHAIN:*` を consume して停止を差し戻し、残り step (ingest 残処理 → cleanup ステップ 10-12) の継続を強制する。チェーンがステップ 12 まで完走した場合はステップ 12 末尾の `flow-state.sh set` (`--handoff` なし) が handoff を default-clear するため block は発生しない。consume は one-shot のため無限 block しない。

## why-ready-sets-no-handoff

`Stop` hook は handoff マーカー (review↔fix ループ / cleanup wiki チェーン) が set されている時だけ停止を差し戻すが、ready は handoff をセットしない — ready はループの出口でありユーザー判断で merge へ進むためである。ready の継続保証は flow-state の `next_action` (resume 用) に委ねる。fork context の return 直後に LLM が turn を終了しても、state file に正しい `next_action` が残るため `/rite:recover` で復帰できる (defense-in-depth)。
