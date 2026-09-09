# 3 ホスト実機検証の手順

Claude Code・Codex・Grok Build の 3 ホストで rite workflow を実際に動かし、同じ結果に到達することを確かめる手順。
読者は検証を実施する人（以下「実行者」）。

## この検証で分かること・分からないこと

| 区分 | 実行入口 | 証明する範囲 | CI で自動実行 |
|---|---|---|---|
| ランチャー契約 | `bash tests/rite-dev.test.sh` | `scripts/rite-dev` が引数・設定・終了コードをスタブへ正しく渡す | する |
| 配布 shell 契約 | `bash plugins/rite/hooks/tests/run-tests.sh` | runtime helper、state/claim/queue、レビュー回収ゲート、worktree の内部契約 | する |
| 検証道具の契約 | `bash tests/runtime-e2e.test.sh` | `prepare.sh` の隔離と `results.py` の集計（pass / fail / unverified の区別） | する |
| **実ホスト E2E** | **この README の対話セッション** | **ホストが共通 skill を実行し、GitHub とローカル状態が期待どおりになる** | **しない** |

この README が扱うのは最後の「実ホスト E2E」だけである。CI はモデルを起動しないので、実機成功は人が実行して記録するしかない。
`results.py` も実機を起動するものではなく、実行者が記入した結果 JSON の検査・集計道具である。

関連文書:

- 実行契約: [Host Runtime Contract](../../plugins/rite/references/host-runtime-contract.md)
- 能力の根拠と自動 hook の制約: [multi-host-runtime](../../docs/designs/multi-host-runtime.md)（以下「能力表」）

## 全体の流れ

検証の単位は **ホスト × 実行面** の 1 組み合わせ。3 ホスト × 2 実行面 = 最大 6 回、それぞれ専用の fixture リポジトリと結果 JSON を使う。

| 実行面（`surface`） | 起動方法 | 意味 |
|---|---|---|
| `development` | `scripts/rite-dev <host>` | 開発 launcher 経由で動くこと |
| `distribution` | ホスト CLI を直接起動 | 配布物 `plugins/rite` 単体で動くこと |

1 回の検証は次の 6 stage からなり、それぞれ `pass` / `fail` / `unverified` を結果 JSON に記録する。

| stage | 確認すること | 対応する節 |
|---|---|---|
| `installation` | 配布 root の skill / reference が読め、runtime が初期化できる | 3 |
| `issue_create` | シナリオ用の Issue を 3 つ作れる | 4 |
| `draft` | `batch-run` が draft PR で止まる | 4 Draft |
| `merge` | `batch-run --merge` が merge と cleanup まで完走する | 4 Merge |
| `recover` | 中断したセッションを同じ会話で復旧できる | 4 Recover |
| `isolation` | 他セッションの作業と自分のグローバル設定が壊れない、拒否が正しく効く | 4 Isolation |

手順の順番:

1. 準備（fixture 作成、GitHub リポジトリ作成、設定スナップショット）
2. ホストを起動する
3. 最初の共通指示を渡す（`installation`）
4. 4 つのシナリオを実行する
5. 結果 JSON を記入し、集計する

## 1. 準備

### 必要なもの

- Bash 4 以上、Git、Python 3、jq、GitHub CLI
- 検証するホストの CLI と認証
- 検証用リポジトリ（新規作成する）への Issue / PR 作成・push・merge 権限
- ホスト側の能力: ファイル読取 / 編集 / コマンド実行、独立した子エージェントの起動と結果回収、実セッション ID、正式な承認手順

これらが揃わない場合の扱いは「揃わないときの記録」を参照。

### 1-1. 検証用ディレクトリを作る

rite の **コミット済みで clean な checkout** から始める。`E2E_ROOT` は作業リポジトリの外に新しく作る専用ディレクトリ。以下は全て Bash で実行し、値は自分の環境に置き換える。

```bash
RITE_SOURCE=/home/akiyoshi/Projects/personal/cc-rite-workflow   # 検証する rite の checkout
E2E_ROOT=/home/akiyoshi/Projects/personal/rite-validation       # 証跡と fixture の置き場（新規。作業リポジトリの外）
E2E_OWNER=B16B1RD                                               # 検証用リポジトリを作る GitHub アカウント（gh api user --jq .login で確認）

mkdir "$E2E_ROOT"
mkdir "$E2E_ROOT/evidence"
git -C "$RITE_SOURCE" rev-parse HEAD > "$E2E_ROOT/evidence/rite-commit.txt"
test -z "$(git -C "$RITE_SOURCE" status --porcelain)"   # clean でなければ失敗する
```

### 1-2. ホスト × 実行面ごとに fixture を作る

`E2E_HOST` は `claude` / `codex` / `grok`、`E2E_SURFACE` は `development` / `distribution`。`E2E_NAME` は GitHub 上で未使用の名前にする。

```bash
E2E_HOST=claude
E2E_SURFACE=development
E2E_NAME=rite-validation-$E2E_HOST-$E2E_SURFACE-run1
E2E_REPO="$E2E_ROOT/$E2E_NAME"
E2E_RECORD="$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE.json"

# ローカル fixture と結果 JSON の雛形を作る（GitHub には触らない）
bash "$RITE_SOURCE/tests/runtime-e2e/prepare.sh" "$E2E_REPO"
python3 "$RITE_SOURCE/tests/runtime-e2e/results.py" init "$E2E_HOST" "$E2E_RECORD"

# fixture のテストが通ることを確認してから git / GitHub を初期化する
cd "$E2E_REPO"
python3 -m unittest -v
git init -b main
git add .gitignore app.py test_app.py rite-config.yml
git commit -m 'chore: initialize runtime validation fixture'
gh auth status
gh repo create "$E2E_OWNER/$E2E_NAME" --private --source . --remote origin --push
```

`prepare.sh` が作るもの:

- 小さな Python アプリ（`app.py` / `test_app.py`）と `rite-config.yml`（Projects と Wiki は無効）
- `plugins/rite` のコピー（元 checkout への symlink ではない独立した配布物）と `scripts/rite-dev`
- Grok 用の `.grok/config.toml` と `.grok/plugins/rite`
- `.runtime-e2e-source.json`（元の commit と `dirty` フラグ）

`prepare.sh` は既存ディレクトリを上書きしない。`.runtime-e2e-source.json` の commit が `rite-commit.txt` と一致し、`dirty` が `false` であることを確認する。
fixture は Projects と Wiki を無効にしているため、この検証はそれらの連携が動くことを示さない。

### 1-3. グローバル設定のスナップショットを取る

`isolation` stage では、検証がユーザーのグローバル設定（Claude settings、Codex config、Grok config、Git config）を変えていないことを証明する。
そのため **ホスト起動前** に各設定ファイルの SHA-256 を保存し、検証後に比較する。

次の関数を準備用の Bash に定義する。出力はパスとハッシュだけで、設定本文や認証情報は含まない。独自の設定パスを使うなら `paths` に追加する。

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

検証が終わったら同じ Bash で after を取り、差分を見る（手順 5 で使う）。

```bash
snapshot_settings > "$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE-settings-after.json"
diff -u "$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE-settings-before.json" \
        "$E2E_ROOT/evidence/$E2E_HOST-$E2E_SURFACE-settings-after.json"
```

差分があれば原因を確認するまで `isolation` を `pass` にしない。セッション履歴が増えるのは正常、設定の内容が変わるのは異常として区別する。

### 揃わないときの記録

CLI・認証・権限が揃わないホストは、無理に補わず `unverified` のまま残す。

- 各未実行 stage の `reason` に `host_missing` / `authentication_missing` / `permission_unavailable` などの種別と、止まった位置、復旧方法を書く
- 版を確認できなければ `host_version` は空欄のままにする
- 認証情報のコピーやグローバル設定の変更で補わない
- 自動 hook が使えない実行面では、共通契約の `explicit` 経路を検証する

## 2. ホストを起動する

この手順は CLI の対話実行（`execution_mode: cli-interactive`）を対象にする。GUI / IDE / headless で試す場合は別の `execution_mode` として記録し、対話実行の結果を流用しない。

起動前に各 CLI の `--version` と `--help` の出力を `evidence/` に保存する。
CLI が受け付けることを確認済みの版は Claude Code `2.1.263`、Codex CLI `0.153.4`、Grok Build `1.0.21`。これは受付確認であり、全工程成功の認定ではない。

### development: 開発 launcher 経由

fixture の root（`$E2E_REPO`）で、対象ホストの行を 1 つ実行する。

```bash
scripts/rite-dev claude
scripts/rite-dev codex
scripts/rite-dev grok
```

Codex は fixture 内の `.codex-dev` を使うため、専用プロファイルでの認証を求められることがある。既存の認証を使えなければ `unverified` として止め、ホストの正式な認証手順を案内する。
launcher の自動承認モードは、ホスト側の権限拒否を解除するものではない。

### distribution: 配布物を直接利用

`distribution` 用に別の fixture（手順 1-2 を `E2E_SURFACE=distribution` で再実行）を用意し、`scripts/rite-dev` を使わず起動する。
可能なら開発 checkout を参照できない環境でも試し、全 reference が fixture 内の `plugins/rite` で解決する証跡を残す。

Claude Code:

```bash
RITE_HOST=claude claude --settings '{"enabledPlugins":{"rite@rite-marketplace":false}}' --plugin-dir "$PWD/plugins/rite"
```

Codex: プロジェクトの skill 検出ディレクトリ `.agents/skills` に各 skill への symlink を作る（[OpenAI の skill 文書](https://learn.chatgpt.com/docs/build-skills) に基づく）。`.agents` が既にある fixture では実行せず、既存設定を上書きしない。

```bash
mkdir .agents
mkdir .agents/skills
for skill in "$PWD"/plugins/rite/skills/*; do
  test -f "$skill/SKILL.md" || continue
  ln -s "$skill" ".agents/skills/${skill##*/}"
done
RITE_HOST=codex codex --cd "$PWD"
```

skill が検出されただけでは不十分で、子 skill 本文の実行と reviewer 全員の結果回収まで実測する。

Grok Build: `prepare.sh` が作った `.grok/plugins/rite` と `.grok/config.toml` を使う（[Grok の plugin 文書](https://docs.x.ai/build/features/skills-plugins-marketplaces) と [設定 scope](https://docs.x.ai/build/settings) に基づく）。

```bash
RITE_HOST=grok grok --cwd "$PWD"
```

`inspect` 系の出力は対象 plugin のパスと検出状況だけを記録し、設定全体は保存しない。plugin が検出されたことと hook が動くことは別の話として扱う。

## 3. 最初に渡す共通指示（`installation`）

起動したホストに次の文をそのまま貼る。`<...>` は準備した絶対パスに置き換える。
ホストが slash command を受け付けない場合は、配布内の対応する `SKILL.md` を読んで同じ手順を実行するのが共通契約上の代替になる。
Codex は slash command ではなく `$` で skill を mention する。launcher と手順 2 の symlink は `rite:` 接頭辞なしの名前で登録するため、`/rite:issue-create` は Codex では `$issue-create` と読み替える。

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

ここで確認できるのは読込と初期化の範囲だけ。hook・レビュー・復旧が効くかは次のシナリオで確かめる。

## 4. 共通シナリオ

4 つのシナリオを順に実行する。共通ルール:

- シナリオごとに別の Issue を使う。開始時に、その Issue の PR・claim・worktree が未作成で、現在セッションに別 Issue の active queue がないことを確認する
- **Draft のセッションは閉じない。** 別端末で開いたまま残し、Merge と Recover は新しい端末・新しい会話で共通指示を再度渡してから実行する。Draft で残った worktree が Merge の cleanup に巻き込まれないことが `isolation` の証跡になる
- Recover だけは中断前後で **同じ会話・同じ実 session ID** を維持する

### Draft: `batch-run` が draft PR で止まる

Issue を作る:

```text
/rite:issue-create app.pyにfarewell(name)を追加し、farewell("Rite")が"Goodbye, Rite!"を返す。
変更対象はapp.pyとtest_app.py。unittestで期待値を検証する。小さな単一Issueとして作成してください。
```

返された Issue 番号で実行する:

```text
/rite:batch-run <draft用Issue番号>
```

期待結果:

- `open → iterate` が実行され、独立 reviewer 全員の結果を回収して draft PR で終了する
- `ready / merge / cleanup` は実行されない
- PR は `OPEN` かつ `isDraft=true`、Issue は OPEN、queue は処理済みで非 active

保存する証跡: `gh pr view <PR番号> --json number,url,state,isDraft,headRefOid` の出力、queue、レビュー出力。

このセッションは開いたままにし、worktree に無害な未コミットのマーカーファイルを作ってハッシュを記録しておく（Merge の後で保持を確認する）。

### Merge: `batch-run --merge` が完走する

新しい会話で共通指示を渡してから、別の Issue を作る:

```text
/rite:issue-create app.pyのgreet(name)で空文字列なら"Hello, world!"を返す。
既存の通常名の結果を維持する。変更対象はapp.pyとtest_app.py。両方をunittestで検証する。
```

```text
/rite:batch-run --merge <merge用Issue番号>
```

期待結果:

- `open → iterate → ready → merge → cleanup` が完走する
- PR は `MERGED`、対象 Issue は閉じている
- 対象 Issue の worktree / branch / claim が片付き、queue が完了している
- **Draft セッションの worktree・マーカーファイル・claim はそのまま残っている**

保存する証跡: `gh pr view <PR番号> --json number,url,state,mergedAt,mergeCommit`、`gh issue view <Issue番号> --json state`、`git worktree list --porcelain`、Ready 化の証跡。

### Recover: 中断したセッションを同じ会話で復旧する

新しい会話で共通指示を渡してから、別の Issue を作る:

```text
/rite:issue-create app.pyにgreet_twice(name)を追加し、greet(name)の結果を改行で2回返す。
変更対象はapp.pyとtest_app.py。unittestで検証する。
```

`open` を途中で止めるよう指示する:

```text
/rite:open <recover用Issue番号>
実装計画を保存し、専用worktreeが確定した時点で、中断試験用に状態を記録して待機してください。
記録する値は実session ID、Issue番号、phase、branch、worktree、PR番号、最後のcheckpointです。
```

記録を確認したら、ホストの中断操作で処理を止める。同じ会話で再開できればそのまま続ける。会話が終了した場合は **記録した session ID** で同じ会話を再開する。

development（fixture root から launcher を使う）:

```bash
E2E_SESSION=記録したsession-ID
scripts/rite-dev claude --resume "$E2E_SESSION"
scripts/rite-dev codex resume "$E2E_SESSION"
scripts/rite-dev grok --resume "$E2E_SESSION"
```

distribution: 手順 2 と同じ直接起動コマンドと環境に、Claude / Grok は `--resume <ID>`、Codex は `resume <ID>` を付ける。
新規会話・fork・Grok の `--session-id` は別会話になるので使わない。

再開後に復旧を指示する:

```text
/rite:recover <recover用Issue番号>
復旧直後、変更前に実session ID・Issue・branch・worktreeが中断前の記録と一致する証跡を保存し、
保存phaseの未完了工程からdraft PR作成まで続行してください。新たなIssue/worktree/PRで置換しないでください。
```

期待結果:

- 中断前と同じ所有者・Issue・branch・worktree から継続し、draft PR を作る
- PR が重複して作られていない

保存する証跡: 中断前後の ID / Issue / branch / worktree / phase の照合、再開操作、PR 一覧。

この試験は保存済み checkpoint からの復旧を確かめるもので、予告なしの compact や強制終了で自動 hook が発火することは証明しない。それらは能力表の個別 probe として別に記録する。

### Isolation: 他セッションと設定を壊さない、拒否が効く

`isolation` stage には次の 3 つの証跡を入れる。

1. **他セッションの保持**: Merge の cleanup 後も Draft セッションの worktree・マーカーファイル・claim・state が残っていること（Merge で確認済み）
2. **グローバル設定の保持**: 手順 1-3 の before / after の差分がないこと
3. **正式な拒否**: 専用の無害なファイルへの編集をホストの正式な機構で拒否し、対象が不変で phase / queue が保持され、停止診断が出ること。拒否された操作を別のツールで実行し直さない

拒否試験を実施できない環境では、この stage は `unverified` のままにする。

## 5. 結果を記録して集計する

### 結果 JSON の記入

`results.py init` が作った JSON を実行者が記入する。構造は `metadata` と 6 つの `stages`。

`metadata`:

| キー | 値 |
|---|---|
| `host` | `claude` / `codex` / `grok`（init で設定済み） |
| `host_version` | 確認したホスト CLI の版 |
| `rite_commit` | `rite-commit.txt` の 40 桁 commit |
| `surface` | `development` / `distribution` |
| `execution_mode` | この手順では `cli-interactive` |

モデル・OS・日時・承認 / runtime モード・検証 repo URL は JSON ではなく証跡ファイルに書く。

各 stage:

| キー | 値 |
|---|---|
| `status` | `pass` / `fail` / `unverified` |
| `reason` | 期待値と実測の比較、または未検証の理由 |
| `evidence` | 証跡ファイルのパス（JSON からの相対パスか絶対パス）。`pass` なら実在する非空ファイルが 1 つ以上必要 |

記入例（実測結果で置き換える。サンプルを成功証跡にしない）:

```json
{"status":"unverified","reason":"authentication_missing: merge未実行。正式な認証後に専用Issueで再実行する。","evidence":[]}
```

各 stage に最低限必要な観測:

| stage | 必要な観測 |
|---|---|
| `installation` | 配布 root、親 / 子 skill と reference の解決、runtime 初期化、設定の保持 |
| `issue_create` | 3 シナリオ分の Issue 作成のツール実行と、GitHub 上の本文 / URL |
| `draft` | open / iterate の工程、reviewer の実 ID と結果、draft PR、queue の終端 |
| `merge` | ready / merge / cleanup の各工程、MERGED PR と Issue close、branch / worktree / claim の整理 |
| `recover` | 中断前後の ID / Issue / branch / worktree / phase、再開操作、既存 PR の照合 |
| `isolation` | 他セッションの変更と所有者の保持、設定ハッシュの比較、正式な拒否と対象不変 |

### 集計

実行面ごとに 3 ホスト分をまとめて検査する。

```bash
python3 "$RITE_SOURCE/tests/runtime-e2e/results.py" check \
  "$E2E_ROOT/evidence/claude-development.json" \
  "$E2E_ROOT/evidence/codex-development.json" \
  "$E2E_ROOT/evidence/grok-development.json"
```

| 終了コード | 意味 |
|---|---|
| `0` | 同一条件（commit・surface・execution_mode）の 3 ホストが全 stage `pass` |
| `1` | `fail` がある、記録が不正、または比較条件が混在している |
| `2` | `unverified` がある、またはホストが足りない |

`distribution` の 3 件も同じ形で別に集計する。両実行面の証跡が揃うまで「全ホスト対応」とは宣言せず、統合検証の完了条件は開いたままにする。
`unverified` を成功に数えない。`results.py` はファイルの存在と形式を検査するだけで、証跡の内容が本当かどうかは実行者が確認する。

## 6. 後始末

- 証跡と、復旧に必要な状態は削除せず保持する
- 残した draft PR / Issue をどうするかは、検証結果を確認してから決める
- active な worktree を含むディレクトリを一括削除しない
