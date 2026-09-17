# /rite:setup — 設計理由

`skills/setup/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## dep-check-nonblocking

hook / スクリプトは bash 4+ / jq に依存し、flow-state のロックに flock を使う。導入時点で
欠落を表面化しておかないと、macOS stock bash 3.2 のまま pr-review 系が不可解に失敗する。
setup 自体は依存欠落でも止めない — 案内を出したうえで後続フェーズへ進む。全依存 OK のときは
1 行サマリのみにし、ウィザードを邪魔しない。

bash の判定基準は実行中シェルの `BASH_VERSION`（Decision D-01）。macOS の PATH 解決
（Homebrew bash か `/bin/bash` 3.2 か）が環境依存で不確実なため、実行コンテキスト自身を測る。

`[CONTEXT] DEP_CHECK` は data contract / observability として全ケースで emit するが、現状どの
後続フェーズも機械 parse しない。jq 案内の重複排除は Phase 4.5.0 の NO_JQ メッセージが
Phase 1.0 を文言で参照して達成しており、marker の消費には依存しない。

## plugin-path-before-git-remote

`{plugin_root}` を未解決のまま `git-remote.sh` を呼ぶと経路が silent に失敗し、SSH host alias
環境では fallback の `gh repo view` も失敗する。

## project-link

`gh project link` はリポジトリと Project を関連付け、Issue 作成 helper のフィールド取得
GraphQL（`repository(owner:, name:) { projectV2(number:) }` ルート）を解決可能にする。
link しないままだと初回 `/rite:issue-create` が `project_registration: "partial"` で失敗する。

## wiki-section-new-gen

template は `wiki:` を `# --- Advanced ---` 境界より上の active block として宣言する。
新規生成の抽出（境界より上）がそのまま `wiki:` を含むため、追加の append は不要。
境界が「emit するかコメントアウトするか」の単一 SoT。

## upgrade-branching

schema 同等でもテンプレートは版を bump せずに active セクション / サブキー（`multi_session`・
新規セクション・Wiki 等）を獲得し得る。`current >= latest` でも欠落 drift を back-add して
最新デフォルトへ追従させる。

両経路とも Step 6 が config を変更し得るため Backup を必ず先に置く。`current >= latest` は
Preview/confirm を挟まない — 欠落している active セクション / サブキーのみの冪等 back-add で、
User-customized 値（明示的な `enabled: false` を含む）は保全されるため無確認で適用する。
旧 Wiki 専用救済（Wiki-only Step）はこの一般化に吸収され、Wiki も他の active セクションと
同様に Step 6 item 7 で back-add される。

`current >= latest` で back-add 対象が皆無なら Step 6 は書き換えず最新表示のみ。Phase 4.7 は
そのまま実行され、Wiki 初期化済みなら Skill 呼び出しは skip される（冪等）。

## unknown-key-scope

Step 4 の Unknown key 判定は template の Advanced 境界より上の active section のみを参照する。
境界より下（コメント形式の Advanced + 末尾コメント）は template 側で意図的に省略または注記の
領域であり、ユーザー設定の classification 対象外。

## upgrade-apply-ssot

`multi_session:` / `wiki:` の挿入ブロックは template の active 区間から抽出する。本文に
リテラルを複製しない — デフォルト変更が新規生成と `--upgrade` の両方へ伝播する。

wiki の挿入位置をファイル末尾の非空行にしない。template の複数セクション末尾に繰り返される
`enabled: true` / `auto_query: true` と衝突しうる。

schema bump / 廃止キー削除 / Advanced コメント追加は full-upgrade（`current < latest`）専用。
短絡経路では schema は既に現行のため、schema bump は no-op になる。

## upgrade-step7

Phase 4.7 内部の「次のステップ」案内は Step 7a への再入ではなく、完了後の 7b へ戻ることを
指す。`--upgrade` は Phase 1–3 と Phase 5 の完了レポートをスキップするため、Wiki 状態行と
（該当時）Phase 4.8 / 4.9 案内だけを報告する。新規インストール経路に入らないので Phase 5 と
文面が衝突しない。

## rite-hook-command

「rite hook command」は command path 中で `rite` が hooks ディレクトリ直上の完全な path
segment である場合だけ（間に version segment を 1 個まで許容）。dev/relative の
`…/rite/hooks/` と cache install の `…/rite-marketplace/rite/<version>/hooks/` がマッチし、
`favorite/hooks/`・`prerite/hooks/`・`rite-something/hooks/` のような部分文字列 look-alike
はマッチしない。

正規表現の単一定義実体は `scripts/settings-local-rite-hook-cleanup.py` の `RITE_HOOK_RE`
（`(?:^|/)rite/(?:[^/]+/)?hooks/`）。同名 `.sh` wrapper も `session-start.sh` の
settings.local.json 修復も JSON 変換＝regex 適用をこの `.py` に委譲する（session-start.sh
のインライン複製を解消済み）。素朴な substring `rite/hooks/` は `favorite/hooks/` 等を
over-match するため使わない。

## plugin-path-mismatch

4.5.0 の direct key lookup と、他スキル・hook が使う正準 one-liner（`rite@*` 先頭エントリ）
は、`installed_plugins.json` に複数の `rite@*` があると異なるバージョンのパスを返し、
1 セッション内で hooks と skills が別バージョンを参照する混在が silent に進行する。
照合失敗・不一致は non-blocking。解決結果は従来どおり direct key を採用し、解決フロー自体は
退行させない。

## copy-type-install

copy 型インストールは自動更新を受け取らない。マーケットプレースソース
（`~/.claude/plugins/marketplaces/{name}/`）は runtime の cache
（`~/.claude/plugins/cache/`）とは別ディレクトリ。`{hooks_dir}` は
`.../cache/{marketplace_name}/{plugin_name}/{version}/hooks` なので、末尾 `hooks` を除き
2 階層上が marketplace 名。

## settings-json-conflict

Claude Code は `.claude/settings.json` と `.claude/settings.local.json` の両方から hook を
実行する。同一イベントに非-rite hook があると二重実行になる。チェックは advisory only —
`settings.json` を自動変更せず、結果に依らず init を止めない。

## native-hooks-json

`hooks.json` があるとき Claude Code はプラグイン hook をネイティブ管理し
`${CLAUDE_PLUGIN_ROOT}` を動的解決する。この場合 `settings.local.json` への登録は不要で、
バージョン更新時にパスが壊れる原因になる。

## cleanup-helper-contract

`settings-local-rite-hook-cleanup.sh` は rite hook を実際に除去したときだけ `CLEANED` を返し、
それ以外の安全側（python3 不在・file 不在・対象 hook 不在・不正 JSON・mktemp/mv 失敗を含む）
はすべて `NO_RITE_HOOKS`。ただし **mv 失敗** だけは「変換は成功したが swap-in できず stale な
rite hook が残る」ため、`NO_RITE_HOOKS`（exit 0 非ブロッキング）を保ったまま stderr に
`[rite] WARNING: ... mv failed` を出す。`*.py` を `*.sh` wrapper 経由で呼ぶ先例
`issue-comment-wm-update.py` / `issue-comment-wm-sync.sh` に準拠。

## hook-path-absolute

4.5.0 は `{hooks_dir}` を絶対パス（`cd ... && pwd`）で解決する。既存 hook が相対パス
（例: `bash plugins/rite/hooks/pre-tool-bash-guard.sh`）なら一致せず更新対象になる。
相対→絶対の変換はこの検証の目的の一つ。

4.5.1.1 は既存フックのパス検証のみで、イベント自体の欠落は検出しない。必須フックの存在
チェックは 4.5.1.2。片方だけ通すと「パスは正常だが SessionEnd / PreToolUse が未登録」を
見逃す。

## wiki-init-contract

Phase 4.7 失敗（Skill 呼び出し失敗を含む）で `/rite:setup` を abort しない。Wiki 状態は
完了レポート（Phase 5 / Step 7b）で必ず報告する。

`wiki_status` は LLM 会話コンテキストに保持する。Bash tool は独立 subshell なのでシェル
変数は呼び出しを跨がない。enum は identifier 互換（snake_case、空白・括弧なし）で、
Phase 5 / Step 7b が明示 if/else でリテラルを選ぶ。`wiki_status` から文面を動的組み立て
しない。

## wiki-enabled-sed

`wiki.enabled` の欠落 / キー欠落 / 解釈不能は `true`（opt-out）。`wiki-init` ステップ 1.1
と同じで、typo 検出 WARNING 経路も含む。

`sed -n '/^wiki:/,/^[a-zA-Z]/p'` は次の ASCII 英字始まり行（次のトップレベル YAML キー）で
終わる。template 形状（wiki の次が別トップレベルキーまたは EOF）に依存する。wiki が末尾
ブロックで後続がコメントのみなら EOF まで読むが、それでも正しい。既知の限界は wiki 節の
**内部**に英字始まりコメント行を挿む非標準 config で、template 形状の drift は既知制限であり
blocker ではない。

## wiki-init-delegate

Skill tool は戻り値を表面化しないため、失敗検出は post-check（4.7.4）。Wiki 初期化ロジックを
ここへ再実装しない — 常に Skill へ委譲する。

4.7.4 で `rite-config.yml` を再パースしないのは、Skill が config を変更した場合の drift を
避けるため。4.7.2 で観測した値を literal 埋め込みする。

## sandbox-allowlist

`git rev-parse --show-toplevel` は現 worktree の toplevel を返す。セッション worktree cwd
からの `/rite:setup --upgrade` では worktree パスを誤って返す（`lib/worktree-git.sh` が
同じ理由でこのパターンを避ける）。main checkout root は `state-path-resolve.sh` で解決する。

書込先はユーザーローカル意図のファイルだが、リポジトリ `.gitignore` に明示エントリがなければ
コミット済み扱いになる。開発者個人のグローバル gitignore は他 contributor 環境では効かない。
`.gitignore` を先に保証してから settings を書く。方針転換の (a)/(b)/(c) 比較は
`git-worktree-patterns.md` の Decision Log。

gitignore 追記が sandbox 等で失敗しても silent にしない。旧「案内のみ」フローでは settings に
手動で path 追加済み・gitignore 未対応のユーザーが、gitignore 追記だけ失敗して未保護のまま
放置される回帰があった。

sandbox + multi_session では初回から marker `failed` になるのが既定経路。`jq` リダイレクトが
「読み込み専用ファイルシステムです」等で失敗し、bash 全体は exit 0 のまま `else` に落ちる。
「コマンド自体が失敗したか」を再試行条件にしない。marker `failed` なら理由を問わずブロック
全体を一度だけ `dangerouslyDisableSandbox: true` で再実行する（確認不要。ブロック全体再実行は
`grep -qF` / `unique` により冪等なので、gitignore 追記側だけ再実行するより安全）。

`already_present` で無表示なのは `--upgrade` 再実行毎のノイズを出さないため。

## status-option-union-provision

`updateProjectV2Field` の `singleSelectOptions` は渡した配列で option 集合を全置換する。
4 件リテラル（`Todo` / `In Progress` / `In Review` / `Done`）を毎回送ると (1) `Cancelled`
が永久に作られず (2) 手で足した option が setup 再実行で消える。既存を GraphQL で読み、
rite 管理 5 つとの和集合を送り、既存には `id` を付けて identity を保つ。読み取り失敗時に
4 件リテラルへフォールバックするとユーザー定義 option が無言で消えるため、mutation せず
fail-loud する。

provisioning は setup がその場で新規作成した Project に限定する。既存 Project は利用者の運用中
スキーマであり、足りない field / option を setup が補うと、意図した表示名と標準名が並存する。
既存 Project では設定名の完全一致だけを検証し、不足名と実 option 名を表示して停止する。
検証後に template で config を上書きした場合も最終 config で再検証する。検証時と完了時で
role mapping が変わると、setup が成功した直後から更新 helper が option を解決できないためである。
既存 Project の上書き候補は一時 directory で検証し、成功後だけ root config へ原子的に反映する。
候補と更新先は cwd から推論せず絶対 path で別々に渡す。`TMPDIR` が repository 内でも resolver が
root config を誤読せず、candidate cwd から commit しても更新先を取り違えないためである。失敗後に
旧内容を復元する方式では、signal 中断との間に壊れた config が見えるため採用しない。
`mktemp` の結果は `pwd -P` で物理絶対 path に正規化し、相対 `TMPDIR` も同じ契約へ揃える。
setup 内の絶対 path 判定は POSIX / UNC と Git Bash の drive-letter path を受理する。
commit の cleanup trap は root tempfile と candidate をまとめて回収し、失敗や signal でも生成済み
config を一時領域へ残さない。

Phase 3 は config 生成より前に走るため、既存 `rite-config.yml` があれば resolver を使い、まだ
存在しなければ legacy の標準 5 role と既定フィールド候補を使う。config 不在を invalid として
扱うと、新規導入で既存 Project を選ぶ正規経路が必ず停止するためである。

## status-options-role-migration

legacy 配列には role が無く、表示名から利用者の意図を復元できない。`--upgrade` は配列の内容や
要素数を解釈せず英語標準 5 role へ置換する。これにより、設定が 4 行でも実ボードが 5 列ある
環境で cancelled を誤って省略しない。既に explicit な設定は利用者の対応付けなので保持し、
invalid 設定は一部だけを書き換えず backup を残して停止する。

resolver は config を repository root から読むため、検証と移行の存在判定・書込先も同じ root に
揃える。移行は固定インデントや option の連続配置を前提にせず YAML の階層境界で配列全体を置換し、
resolver で explicit と再判定できた tempfile だけを同一ディレクトリ上で原子的に置き換える。
Status options 自体が無い legacy config は後続の missing-sub-key back-add に委ねる。
一時 config の検証だけは candidate / scratch directory の親を `GIT_CEILING_DIRECTORIES` に指定し、
親 repository の Git root 探索を遮断する。resolver 自体の契約は変更しない。
upgrade の backup も同じ root config を対象にし、backup 成功を後続変更の precondition とする。
解析用の行末 CR は除去する一方、生成行には元の EOL を引き継ぎ、Git Bash の CRLF config も
resolver と同じ入力契約で移行する。

## ssh-alias-sandbox

本問題は SSH alias remote + sandbox の組合せだけで起きる。`multi_session` の有無には依存
しない（Phase 4.8 とは独立ゲート）。

SSH alias 判定は git config の読み取りで bash 可能。sandbox 有効判定は Phase 4.8 と同じく
bash では検出できない（セッション起動設定であり、ファイルから読めない）ため、実行コンテキスト
のネットワーク許可リストを読む。settings の `sandbox.enabled` を `jq` で読む経路は使わない。

settings への自動書き込みは行わない（案内のみ）。`sandbox.excludedCommands` が Linux/WSL2 では
本問題を解消しない理由は `git-worktree-patterns.md` の SSH host alias 節。
