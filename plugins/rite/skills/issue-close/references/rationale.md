# /rite:issue-close — 設計理由

`skills/issue-close/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## projects-status-delegate

`gh api graphql` + `field-list` + `item-edit` を substep に分けて inline すると、LLM attention が
途切れ Status 更新が silent skip する（open ステップ 2.4 / ready Phase 4 と同因）。共通
スクリプトへ委譲する。

## auto-add-false-closed

既 CLOSED の Issue を auto-add すると、本来 open 時点で登録されているべき欠落を masking する。
close 時点でも `skills/open/SKILL.md` ステップ 2.4 が登録済みという前提を崩さない。

## wiki-raw-page-split

本 Phase は raw の蓄積だけを担う。page 統合は後続 `/rite:wiki-ingest` が冪等に行う。分離しないと
page 統合の skip / 失敗が raw ごと消す。E2E 出力最小化で本 Phase を skip すると、orchestrator
経由の parent close で retrospective が永久に残らない。

## content-write-fail-loud

`/tmp` full / permission / inode 枯渇で heredoc が truncate されると、欠けた retrospective が
silent に ingest される。write 失敗は trigger を起動せず、`WIKI_INGEST_FAILED
reason=content_write_failed` を gate-visible に出す。W Phase の消費者は `WIKI_INGEST_*` だけを
見るため、`WIKI_CONTENT_WRITE_FAILED` だけでは足りない。close は Step 2 と trigger が同一
bash ブロックなので carry-forward は不要（pr-review / fix は別呼び出しのため必要 — 唯一の
構造差）。

## three-method-parent

過去に `trackedIssues` だけ残す簡略化が、body meta / tasklist で繋がった親子の close を
silent に壊した。3-method OR と Method 3 の検証ループ（自己マッチ除外・候補 body 再検証・
`--limit 10`）を open / projects-integration と揃えないと、同じ回帰が再発する。GitHub code
search は `[` / `]` を無視しほぼ全 Issue を返すので、先頭 1 件の盲目採用は standalone が自分
自身や無関係 Issue を親にする。`--state all` は親が既 closed の可能性を拾う（open 側の
`--state open` は着手対象を open に限る意図的差異）。3 method 失敗は standalone として正常
（AC-4）。debug log を残すのは silent-skip 回帰を観測するため。

## commit-delegate-single-process

stash→checkout→add→commit→push→checkout-back→stash-pop を LLM の multi-step に任せた旧設計は
E2E で fragile だった。`wiki-ingest-commit.sh` が 1 プロセスで完結する。本 block は raw のみ
commit し、page 統合は `/rite:wiki-ingest`。

## push-retry-sandbox

exit 4 は local commit 済み・push 失敗。同じ sandbox で同じ push を繰り返しても、SSH host-key /
network 許可リスト制約は解けない。別 Bash call + `dangerouslyDisableSandbox: true` を 1 回
だけ試す（open ステップ 6.1 と同型）。完了報告の未完了行は **現在の `WIKI_PUSH_ATTEMPT` と同じ
`attempt=`** にスコープする — 過去 attempt の失敗 marker が今回の成功を上書きしない。

## parent-direct-only

祖父母まで再帰すると three-level nesting の close 連鎖が本スキルのスコープを超える。直接の親
だけ処理する。

## single-block-p460

冪等チェックと子列挙を別 bash に分けると、block 間で shell state が消え `parent_number` /
`children_json` が空になる。`2>/dev/null` は silent-skip の温床なので stderr は tempfile へ
退避して surface する。空配列は「子ゼロ = 全部終わった」ではなく判定不能。

## step3-inconsistency-summary

Status 更新と `gh issue close` を別 block にすると、片方成功・片方失敗が観測されず board と
Issue state が食い違う。Step 3 summary を必ず emit するのが silent corruption を不可能にする
invariant。
