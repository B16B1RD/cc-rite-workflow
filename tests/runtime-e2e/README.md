# 3ホストの実機検証

Claude Code・Codex・Grok Build に同じ検証指示を渡し、開発 launcher 経由と配布物の直接利用を別々に記録する。実行契約は配布物の [Host Runtime Contract](../../plugins/rite/references/host-runtime-contract.md)、能力の根拠と自動 hook の制約は [能力表](../../docs/designs/multi-host-runtime.md) を参照する。

## 検証の区分

| 区分 | 実行入口 | 証明する範囲 |
|---|---|---|
| ランチャー契約 | `bash tests/rite-dev.test.sh` | スタブへの引数・設定・終了コードの受渡し |
| 配布 shell 契約 | `bash plugins/rite/hooks/tests/run-tests.sh` | runtime helper、state/claim/queue、レビュー回収ゲート、worktree の内部契約 |
| 検証道具の契約 | `bash tests/runtime-e2e.test.sh` | fixture の隔離と結果集計の成功・失敗・未検証の区別 |
| 実ホスト E2E | 以下の対話セッション | ホストが共通 skill を実行し、GitHub とローカル状態が期待結果に達すること |

通常 CI は最初の3区分を実行する。モデルを起動せず、実機成功を生成しない。`results.py` も実機を起動する runner ではなく、実行者が記入した結果の検査・集計用である。ファイルの存在だけで証跡内容の真実性までは保証しない。

## 1. 準備

必要なもの: Bash 4 以上、Git、Python 3、jq、GitHub CLI、検証するホストの CLI と認証、検証用リポジトリへの Issue/PR 作成・push・merge 権限。ホストでは読取/編集/コマンド、独立した子の起動と結果回収、実セッション ID、正式な承認手順が必要。自動 hook を利用できない実行面は共通契約の `explicit` 経路を検証する。

検証する rite の **コミット済みで clean な checkout** から始める。下記の `RITE_SOURCE`、`E2E_ROOT`、`E2E_OWNER` を自分の値へ置換する。`E2E_ROOT` は作業リポジトリの外にある新しい専用ディレクトリを選ぶ。コマンドは Bash で実行する。

```bash
RITE_SOURCE=/absolute/path/to/cc-rite-workflow
E2E_ROOT=/absolute/path/to/new-rite-validation
E2E_OWNER=your-github-login
mkdir "$E2E_ROOT"
mkdir "$E2E_ROOT/evidence"
git -C "$RITE_SOURCE" rev-parse HEAD > "$E2E_ROOT/evidence/rite-commit.txt"
test -z "$(git -C "$RITE_SOURCE" status --porcelain)"
```

各ホスト用に下記を実行する。`E2E_HOST` は `claude` / `codex` / `grok`、`E2E_SURFACE` は `development` / `distribution`。リポジトリ名は実行ごとに未使用の名前を指定する。

```bash
E2E_HOST=claude
E2E_SURFACE=development
E2E_NAME=rite-validation-claude-development-run1
E2E_REPO="$E2E_ROOT/$E2E_NAME"
E2E_RECORD="$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE.json"
bash "$RITE_SOURCE/tests/runtime-e2e/prepare.sh" "$E2E_REPO"
python3 "$RITE_SOURCE/tests/runtime-e2e/results.py" init "$E2E_HOST" "$E2E_RECORD"
cd "$E2E_REPO"
python3 -m unittest -v
git init -b main
git add .gitignore app.py test_app.py rite-config.yml
git commit -m 'chore: initialize runtime validation fixture'
gh auth status
gh repo create "$E2E_OWNER/$E2E_NAME" --private --source . --remote origin --push
```

`prepare.sh` はローカルファイルの準備だけを行い、既存ディレクトリを上書きしない。GitHub への変更は上の明示コマンドから始まる。生成された `.runtime-e2e-source.json` の commit と `dirty=false` を確認する。fixture は Projects と Wiki を無効にしており、その連携の実機成功を示すものではない。

認証・CLI・権限がない場合は、そのホストの記録を `unverified` のままにし、各未実行 stage の `reason` に `host_missing` / `authentication_missing` / `permission_unavailable` 等と停止位置・復旧方法を記入する。版を確認できなければ空欄のままにする。認証情報のコピーやグローバル設定の変更で補わない。

検証前後に、利用する既存のグローバル設定ファイル（Claude settings、Codex config、Grok config、Git config）の存在と SHA-256 を比較する。認証ファイルや設定本文は証跡に含めない。正常なセッション履歴の追加と設定の変更を区別する。変更があれば原因を確認するまで `isolation` を成功にしない。

設定比較は次の関数を準備用 Bash に定義し、ホスト起動前と検証後に実行できる。独自の設定パスを使う場合は配列へ追加する。出力はパスとハッシュだけである。

```bash
snapshot_settings() {
  python3 - "$E2E_REPO" <<'PYSETTINGS'
import hashlib, json, os, pathlib, sys
user_root = pathlib.Path.home()
repo = pathlib.Path(sys.argv[1])
paths = [user_root / '.claude/settings.json', user_root / '.gitconfig',
         pathlib.Path(os.environ.get('CODEX_HOME', str(user_root / '.codex'))) / 'config.toml',
         pathlib.Path(os.environ.get('GROK_HOME', str(user_root / '.grok'))) / 'config.toml',
         user_root / '.config/git/config', repo / '.grok/config.toml',
         repo / '.codex-dev/config.toml']
print(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                  if p.exists() else None for p in paths}, indent=2))
PYSETTINGS
}
snapshot_settings > "$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE-settings-before.json"
```

検証後は同じ準備用 Bash で比較する。差分があれば調査し、保存したファイルを `isolation.evidence` に記入する。

```bash
snapshot_settings > "$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE-settings-after.json"
diff -u "$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE-settings-before.json" \
        "$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE-settings-after.json"
```

## 2. ホストを起動する

以下は CLI 対話実行用。GUI/IDE/headless は別の `execution_mode` で記録し、対話実行の結果を転用しない。起動前に各 CLI の `--version` と `--help` を保存する。確認した版は Claude Code `2.1.263`、Codex CLI `0.153.4`、Grok Build `1.0.21`。これは CLI 受付の確認であり全工程成功の認定ではない。

### 開発 launcher 経由

fixture の root で対象ホストの行を一つ実行する。

```bash
scripts/rite-dev claude
scripts/rite-dev codex
scripts/rite-dev grok
```

Codex は fixture 内の `.codex-dev` を使用するため、専用プロファイルでの認証が必要な場合がある。既存の認証が利用できなければ未検証として止め、ホストの正式な認証手順を案内する。launcher の自動承認モードもホストの権限拒否を解除するものではない。

### 配布物を直接利用

別の `distribution` fixture を用意し、`scripts/rite-dev` を呼ばずに以下を実行する。`plugins/rite` は準備時にコピーされた独立した配布物であり、元の checkout への symlink ではない。開発 checkout が参照不能な環境でも試し、全 reference がこの配布 root 内で解決する証跡を残す。

Claude Code:

```bash
RITE_HOST=claude claude --settings '{"enabledPlugins":{"rite@rite-marketplace":false}}' --plugin-dir "$PWD/plugins/rite"
```

Codex はプロジェクトの skill 検出ディレクトリに個別リンクを作る。`.agents` は未作成の fixture で実行し、既存設定を上書きしない。

```bash
mkdir .agents
mkdir .agents/skills
for skill in "$PWD"/plugins/rite/skills/*; do
  test -f "$skill/SKILL.md" || continue
  ln -s "$skill" ".agents/skills/${skill##*/}"
done
RITE_HOST=codex codex --cd "$PWD"
```

プロジェクトの `.agents/skills` と symlink の検出は [OpenAI の skill 文書](https://learn.chatgpt.com/docs/build-skills) に基づく。検出後も、子 skill 本文の実行と reviewer 全員の回収を実測する。

Grok Build は fixture の `.grok/plugins/rite` と `.grok/config.toml` を使用する。

```bash
RITE_HOST=grok grok --cwd "$PWD"
```

プロジェクト配置は [Grok の plugin 文書](https://docs.x.ai/build/features/skills-plugins-marketplaces) と [設定の scope](https://docs.x.ai/build/settings) に基づく。`inspect` は対象 plugin のパス・検出状況だけを記録し、設定全体を公開しない。plugin 検出を hook の互換性と同一視しない。

## 3. 最初に渡す共通指示

全ホストに次をコピーする。山括弧の値は準備した絶対パスへ置換する。slash command をホストが受け付けない場合も、配布内の対応する `SKILL.md` を読み同じ手順を実行することが共通契約上の代替となる。

```text
この検証用リポジトリで rite workflow の実機検証を行います。
検証repo: <E2E_REPOの絶対パス>
配布root: <E2E_REPOの絶対パス>/plugins/rite
結果JSON: <E2E_RECORDの絶対パス>
証跡保存先: <E2E_ROOTの絶対パス>/evidence

配布rootの references/host-runtime-contract.md と
references/host-workflow-operations.md を読み、実際の公開ツールから実行経路を選んでください。
ホスト版・モデル・実行面・権限モード・実session ID・rite commitを記録してください。
登録済みhookの発火と意味が確認できる場合だけauto、確認済みの明示経路はexplicitを使用し、
同一処理を重複実行しないでください。必須能力不足や拒否は停止理由と復旧手順を記録してください。
ユーザーのグローバル設定・認証情報・他セッションの状態は変更しないでください。
fixtureの既存rite-configを使用し、ProjectsとWikiは無効のままにしてください。
実行したツール、子reviewerの実IDと完了出力、sentinel、終了コード、GitHub上の実状態を保存し、
実行していない工程やスタブ結果をpassにしないでください。
まず配布root内の親/子skillとreferenceが読めること、runtime初期化、作業先と所有者を確認し、
installationの結果を記録して次の指示を待ってください。
```

`installation` は読込・初期化の範囲だけを示す。hook/レビュー/復旧の効果は次のシナリオの証跡で確認する。

## 4. 共通シナリオ

シナリオごとに別 Issue を使う。各開始時に、その Issue の PR・claim・worktree が未作成で、現在セッションに別 Issue の active queue がないことを確認する。draft を残したセッションは別端末で開いたまま維持し、その worktree に無害な未コミットのマーカーファイルを作ってハッシュを記録する。merge 用キューは別端末の新しい会話で共通指示を再度渡して実行する。recover の中断前後だけは同じ会話・同じ実 session ID を維持する。

### Draft 終了

```text
/rite:issue-create app.pyにfarewell(name)を追加し、farewell("Rite")が"Goodbye, Rite!"を返す。
変更対象はapp.pyとtest_app.py。unittestで期待値を検証する。小さな単一Issueとして作成してください。
```

返された実 Issue 番号を使って次を渡す。

```text
/rite:batch-run <draft用Issue番号>
```

期待結果: `open → iterate` が実行され、独立 reviewer 全員の結果を回収し draft PR で終了する。`ready/merge/cleanup` は実行されず、PR は `OPEN`・`isDraft=true`、Issue は OPEN。queue は処理済み・非active。`gh pr view <PR番号> --json number,url,state,isDraft,headRefOid` と queue、レビュー出力を保存する。

### Merge と cleanup

新しい会話で共通指示を渡し、別 Issue を作る。

```text
/rite:issue-create app.pyのgreet(name)で空文字列なら"Hello, world!"を返す。
既存の通常名の結果を維持する。変更対象はapp.pyとtest_app.py。両方をunittestで検証する。
```

```text
/rite:batch-run --merge <merge用Issue番号>
```

期待結果: `open → iterate → ready → merge → cleanup` 完走。Ready 化の証跡、MERGED PR、閉じた対象 Issue、対象 worktree/branch のクリーンアップ、解放された claim、完了した queue を確認する。`gh pr view <PR番号> --json number,url,state,mergedAt,mergeCommit`、`gh issue view <Issue番号> --json state`、`git worktree list --porcelain` を保存する。cleanup が他セッションの draft worktree を保持したことも照合する。

### 中断と recover

新しい会話で共通指示を渡し、別 Issue を作る。

```text
/rite:issue-create app.pyにgreet_twice(name)を追加し、greet(name)の結果を改行で2回返す。
変更対象はapp.pyとtest_app.py。unittestで検証する。
```

```text
/rite:open <recover用Issue番号>
実装計画を保存し、専用worktreeが確定した時点で、中断試験用に状態を記録して待機してください。
記録する値は実session ID、Issue番号、phase、branch、worktree、PR番号、最後のcheckpointです。
```

記録を確認してからホストの中断操作で処理を止める。同じ会話で再開できればそこで、終了した場合は以下の対象ホストのコマンドで **記録した ID** の会話を再開する。開発実行では fixture root から launcher を使う。

```bash
E2E_SESSION=記録したsession-ID
scripts/rite-dev claude --resume "$E2E_SESSION"
scripts/rite-dev codex resume "$E2E_SESSION"
scripts/rite-dev grok --resume "$E2E_SESSION"
```

配布実行は最初と同じ直接起動・環境を維持し、Claude/Grok は `--resume <ID>`、Codex は `resume <ID>` を付ける。新規会話や fork、Grok の `--session-id` は同一会話の復帰には使わない。

```text
/rite:recover <recover用Issue番号>
復旧直後、変更前に実session ID・Issue・branch・worktreeが中断前の記録と一致する証跡を保存し、
保存phaseの未完了工程からdraft PR作成まで続行してください。新たなIssue/worktree/PRで置換しないでください。
```

期待結果: 同じ所有者・Issue・branch・worktree から継続し draft PR を作る。中断前後の照合とPR重複なしを保存する。この試験は保存済み checkpoint からの復旧であり、予告なし compact / 強制終了時の自動 hook 発火を実証しない。それらは能力表の個別 probe として別に記録する。

### 分離と拒否

`isolation` には、draft worktree を残した状態で merge/cleanup を実行してもその変更・claim・stateが保持された証跡と、グローバル設定の前後比較を入れる。加えて専用の無害なファイルへの編集をホストの正式機構で拒否し、対象不変・phase/queueの保持・停止診断を確認する。拒否された操作を別ツールで実行しない。拒否試験を実施できなければこの項目は未検証のままにする。

## 5. 結果を記録する

生成した JSON の `metadata` に、確認したホスト版・rite の40桁 commit・`surface`・`execution_mode`（この手順は `cli-interactive`）を記入する。モデル・OS・日時・承認/runtime モード・検証repo URL は証跡ファイルに記録する。同じ集計内で commit、surface、execution_mode を混ぜない。

各 stage は `pass` / `fail` / `unverified`。`reason` に期待値と実測の比較または未検証理由を記入し、`evidence` にその JSON からの相対パスまたは絶対パスで実在する非空ファイルを列挙する。URL は証跡ファイルの中へ記載する。`issue_create` は3つのシナリオで作った Issue の本文・URL・実行ログをまとめる。

stage の記入例（実測結果から置換する。サンプルを成功証跡にしない）:

```json
{"status":"unverified","reason":"authentication_missing: merge未実行。正式な認証後に専用Issueで再実行する。","evidence":[]}
```

証跡の最低内容:

| Stage | 必要な観測 |
|---|---|
| installation | 配布root・親/子skill/reference解決・runtime初期化・設定の保持 |
| issue_create | 各専用Issue作成のツール実行とGitHub本文/URL |
| draft | open/iterateの工程、reviewer実ID/結果、draft PR、queue終端 |
| merge | ready/merge/cleanupの各工程、MERGED PR/Issue close、対象branch/worktree/claim整理 |
| recover | 中断前後のID/Issue/branch/worktree/phase、再開操作、既存PR照合 |
| isolation | 他セッションの変更と所有者保持、設定ハッシュ比較、正式な拒否と対象不変 |

集計:

```bash
python3 "$RITE_SOURCE/tests/runtime-e2e/results.py" check \
  "$E2E_ROOT/evidence/claude-development.json" \
  "$E2E_ROOT/evidence/codex-development.json" \
  "$E2E_ROOT/evidence/grok-development.json"
```

終了コードは `0`: 同一条件の3ホスト全項目pass、`1`: 失敗・不正記録・比較条件混在、`2`: 未検証またはホスト不足。未検証件数を成功へ含めない。distribution の3件も別に集計する。両実行面の証跡が揃うまでは全対応を宣言せず、統合検証の完了条件を開いたままにする。

検証後も証跡と必要な復旧状態を保持する。残した draft PR/Issue の処分は検証結果を確認してから判断し、active worktree を含むディレクトリ全体の一括削除はしない。
