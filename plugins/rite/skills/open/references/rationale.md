# /rite:open — 設計理由

`skills/open/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## defensive-fallback

`flow-state.sh get --default ""` は session 解決失敗 / file 不在 / jq parse 失敗のいずれでも
default を stdout に書く設計。したがってステップ 0 の `|| resume_phase=""` が実際に catch する
のは helper validation 失敗（`--field` 引数欠落 / invalid field name）だけで、通常の「state が
無い」経路では発火しない。

stderr は WARNING channel として残し `2>/dev/null` で握りつぶさない — 想定外の ERROR を会話
コンテキストに残すため。

## branch-gate

旧版はステップ 2.2 / 2.3 の分岐を、ステップ 1.4 が emit した `[CONTEXT] MULTI_SESSION_ENABLED=`
marker の**会話 context 残存**に依存させていた。resume / context 圧縮 / フロー途中入場で marker が
失われると「marker 欠落 → 従来 2.2/2.3」に倒れ、`multi_session.enabled: true` でも main ツリーへ
`git switch -c` する silent fallback が起きた。

対策がステップ 2.1-G で、ブランチ作成という副作用の直前に `multi_session` を rate-config.yml から
Bash で再取得する。パースはステップ 1.4 と同一のものを再利用するだけで、変更していない。
`SOURCE=branch-gate` の marker が最新の真実であり、分岐は必ずその値で行う。

「marker が context に無い」ことを理由に従来経路へ進む経路は**存在しない** — 本ゲートは毎回
marker を再生成するため、分岐時に値が未取得になることはない。

## worktree-invariant

ステップ 2.3-W 末尾の invariant 検証を prose 指示ではなく bash の `exit 1` にしてあるのは、
`echo` の exit code が ok / violated とも 0 で bash 上は区別できず、「main ツリーで
implement/commit を続行する」silent fallback を構造的に止められないため。ステップ 2.1-G が
branch 分岐を Bash で hard 化したのと対称の措置で、git-worktree-patterns.md の "stops the flow"
保証を実装で満たす。

## worktree-entry-failure

`EnterWorktree` の失敗は原因で対処が変わるため、silent fallback ではなく切り分ける。

- **(A) harness の git 誤判定** — `.git` が存在し `git -C {wt_path} rev-parse` は成功するのに、
  起動コンテキストが `Is a git repository: false` で EnterWorktree が「not in a git repository」を
  返す。harness がセッション起動時に launch ディレクトリを git リポジトリと認識できなかったことが
  原因で、プラグインからは直せない。worktree は作成済みのため破壊せず、リポジトリ root から再起動
  すれば 2.2-W が `WT_CASE=reuse` と判定して継続できる。
- **(B) worktree path 消失などの別要因** — recover.md Phase 3.1.5 の再構築経路に委譲する。本
  コマンドでは新規 worktree を作らず、再起動案内へ誤誘導もしない。
- **(C) 従来 `git switch -c` へのフォールバック** — ユーザーが明示選択した場合のみ。worktree 分離を
  破棄するため、他セッション併走中は作業ツリーを破壊し合う。recommended にはしない。

cwd を main checkout に残したまま絶対パスで操作する「Bash 永続 cwd 駆動」は、main tree を誤更新する
リスクがあるため導入しない。

## projects-status-inline

ステップ 2.4(A) の呼び出しを reference へ委譲せず本体に inline してあるのは、`skills/ready/SKILL.md`
Phase 4.2 で「参照のみに留めた multi-stage pipeline は LLM の attention が sub-step 間で途切れると
Status 更新自体が silent skip する」事象（Status が `In Progress` へ進まず `Todo` のまま残留）が
確認されているため。(B) は従来どおり projects-integration.md §2.4.7 に委譲する。

## wm-replica-init

ステップ 2.5 の replica が無いと、以降の全フェーズの `issue-comment-wm-sync.sh update` が
`status=skipped; reason=no_comment` で skip され、compact / cross-session recovery のバックアップ
経路が機能しない。

init は non-blocking 契約: gh 失敗（auth / rate limit / network）でも helper は WARNING を出して
exit 0 を返す。status 行の有無は投稿・検証段が決める — 投稿・検証段まで到達すれば status 行あり
（success / unverified）、投稿本体 `gh issue comment` の失敗では status 行なし。pre-check の
`gh api` 失敗は続行のみで、status 行は後続の投稿結果に従う。replica が既に存在する場合は helper が
冪等に skip する。

## plan-volatile-first

ステップ 3.3 で「要判断ポイント」を計画の先頭に置くのは、承認時にユーザーが本質的な判断へ注意を
集中できるようにするため（出典: Thariq (Anthropic) "A Field Guide to Fable: Finding Your Unknowns"
(2026) — "lead with the decisions I'm most likely to tweak"）。

「実装ステップ」自体の並び順（= 実行順）を変えないのは、issue-implement 側の実行順序決定に影響を
与えないため。

## plan-auto-approval

旧仕様はステップ 3.4 を無条件 AskUserQuestion にしていたため、`/rite:batch-run` が宣言する
「完全自律（無確認）」に反して Issue ごとに必ず 1 回停止していた。batch 時の自動承認で
宣言と実挙動を一致させる。

安全側の担保は batch-run のデフォルトモードが draft PR をレビュー待ちで残すこと・`--merge` が明示
opt-in であることに置き、本ステップでは停止しない。batch 判定は iterate ステップ 6 の run-queue
batch 判定と同型で read-only。helper 失敗 / session_id 解決不可 / キュー不在のときは interactive
（確認を出す）へ fail-safe する。

## autonomous-lint

`/rite:issue-implement` は全 step 完了後に `rite:lint` を自身で invoke する（旧 `start.md` の flat
設計を継承した内蔵動作）。そのため本コマンドのステップ 5 は `[lint:success]` / `[lint:skipped]` では sentinel を読むだけの
no-op であり、`rite:lint` を再 invoke しない（二重実行防止）。`[lint:error]` と sentinel 不在は
1 回だけ invoke する。`phase=lint` も implement が既に書いているため、本コマンドから上書きしない
（二重 write を避ける契約）。

`/rite:issue-implement` 自体は固有 sentinel（`[implement:*]`）を emit しない設計のため、ステップ 4
では `[lint:*]` の context 投入のみを期待し、判定はステップ 5 に委譲する。

## missing-sentinel-recovery

sub-skill（`rite:pr-create` / `rite:issue-implement` / `rite:lint`）のターンが sentinel を 1 つも
emit せず無言で終了することがある。原因は 2 つに分かれる:

- **Cause A**: harness / transport 側のゆらぎによる malformed tool-call。rite 側では除去不能。
- **Cause B**: インライン heredoc / 特殊文字 title による malform 増幅。pr-create Phase 3.4 の
  Write tool 委譲がこれを除去して発生確率を下げる。

Cause A は消せないため、ステップ 6.2 の回復契約（既存 draft PR 検出 → `{pr_number}` 再構成、
未作成なら 1 回自動再試行し、再失敗で停止して `/rite:recover` を案内する）が最終的な堅牢化の
担保となる。flow-state には直前 phase が保持されているため、いずれの経路でも作業は失われない。

## push-no-upstream

ステップ 6.1 で `-u` を付けないのは、sandbox 有効環境で upstream tracking の `.git/config` 書込が
拒否されるため。flow-state が `{branch_name}` を常時保持しているため upstream に依存する必要はない。

`origin` が SSH host alias 経由（例: `git@github.com-work:...`）の環境で sandbox が有効な場合、
`socat` の `Bad Gateway` エラーで push がネットワーク許可リストにブロックされることがある
（`network.allowedDomains` への alias 追加は無効）。因果連鎖と `sandbox.excludedCommands` が
Linux/WSL2 では恒久策として機能しない理由は
[git-worktree-patterns.md](../../../references/git-worktree-patterns.md#ssh-host-alias-経由の-git-pushfetch-が-sandbox-のネットワーク許可リストでブロックされる) を参照。

本回避策（当該コマンドのみ `dangerouslyDisableSandbox: true`）はメインエージェントが直接実行する
push にのみ適用でき、Task で spawn した reviewer subagent の Bash には渡せない。

## plan-self-review

ステップ 3.3.1 を 3.3 と 3.4 の間に置くのは、人間承認が方式選定は見られても検証網・文書同期・
CI 配線の穴は見えないという実測（計画通過後の churn の大半が未設計に起因）に対し、実装より安い
計画段階で潰すため。人間の役割は要判断ポイントだけに残す。

単一 general-purpose agent + 同梱 prompt にするのは、pr-review のマルチ agent / blocking 判定を
計画段階に持ち込まないため。指摘はすべて計画へ反映するか要判断ポイントへ昇格し、ループしない。

発火を「S 以上で常時」にするのは、内容条件の判別自体が揺らぎ源になるため。XS はコスト対効果が
合わないのでスキップし、ユーザー向け追加出力も出さない。

Complexity 未確定は fail-loud で止める。`issue-complexity-lane.sh` はレーン欠落時に `full` へ
倒すが、本ステップの安全側は「レビューを省略する」ことではない — 確定値なしに skip すると
silent skip と同型になる。helper の `complexity=` が取れたときだけ分岐し、欠落は ERROR。

agent 失敗 / 形式不正は WARNING + 未実施明記で 3.4 へ進む。計画レビューは承認の前処理であり、
spawn 失敗で open 全体を止めると batch がストールする。推測補完は形式不正を成功に見せるため禁止。
