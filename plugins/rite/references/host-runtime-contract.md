# Host Runtime Contract

共通スキルが要求する操作と、実行ホストが提供する手段を対応付ける契約。スキル名・工程順・成功/失敗 sentinel・state schema は各スキルの定義を維持する。ホスト別に workflow 全体を複製しない。

本書は実行経路の適合条件と、同梱 helper の入口を定義する。Claude Code の既存 native 経路を保ち、他ホストでは呼出し可能性と下記の事後条件を確認してから選択する。Skill / task / reviewer / 質問の手順は [Host workflow operations](host-workflow-operations.md)。

## 共通操作

| 操作 | 入力 | 必須の結果・保護対象 |
|---|---|---|
| コマンド・ファイル操作 | コマンド/差分、対象絶対パス、作業先 | stdout/stderr、終了コード、実際の変更を回収。非同期処理は完了まで追跡する。読取・編集・検索の権限を保持 |
| 作業先指定 | repository、branch、既存/新規 worktree | 実行と編集が同じ worktree を指す。claim、dirty 衝突、branch の他 worktree 使用を既存手順で検査 |
| スキル読込・継続 | 配布内の SKILL.md、引数、caller | 本文と必要な参照を読み、同じ工程を実行して caller に実際の sentinel を返す。読込だけで実行完了にしない |
| 委譲 | reviewer 本文、対象差分、制約、作業先 | 独立した子の識別子、完了出力、失敗を回収。必要人数・並列性・読取専用制約・timing 記録を保持 |
| 質問 | 不足情報/正規ゲート、選択肢、停止位置 | 実際のユーザー回答を得る。未回答・タイムアウトを承認にしない。batch 計画承認等の既存自動承認条件は維持 |
| hook | イベント、payload、cwd、session、plugin root | 対象 hook の入力・出力・終了コード・阻止/継続・一度だけ実行する契約を保持。単なる検出は実行証跡ではない |
| セッション識別 | ホストが保証する現在セッションの識別子 | flow-state / claim / queue / work memory が同じ所有者を参照し、別セッションと分離。再開時も同じ所有者と照合 |
| 承認・権限 | 具体的操作、対象、必要な権限 | ホストの正式な承認結果を待ち、拒否時に変更を加えない。batch の無確認指定は sandbox やホストの拒否を解除しない |

## 実行経路の選択

状態の意味は、`native` = ホストの直接機能、`検証済み代替` = 別手段で上表の結果を観測済み、`未対応` = 必要な意味を満たせないことが確認済み、`未検証` = 判断する証拠不足。native という機能分類だけで当該セッションの利用可能性を保証しない。

各操作の直前に、対象版・公開ツール schema・現在のモード/権限・配布ファイルを確認する。`RITE_HOST`、CLI の起動成功、別版の資料だけでは能力を決めない。

1. 当該セッションに公開され、必要な引数・完了通知・権限・事後条件を満たす native 経路を選ぶ。
2. native 不在なら、同じ版・実行面・必要条件で検証した代替を選ぶ。下表の順で最初に適合する経路を使い、採用経路と根拠を work memory に記録する。未検証の候補は副作用のない probe で先に検証する。
3. 適合経路なし、同順位で意味が異なり解消不能、probe 失敗なら当該操作の前で停止する。工程を省略して成功 sentinel を作らない。

| 共通操作 | native の代表例 | native 不在時の代替候補（条件を満たす場合のみ） |
|---|---|---|
| コマンド・ファイル操作 | Claude: Bash / Read / Edit / Write / Grep。Codex: 公開された exec_command / apply_patch。Grok: 公開された実ツール | shell で読取/検索、ホストの patch 機能で編集。対象・終了コード・変更を検証。拒否された操作を別ツールに置換しない |
| 作業先指定 | Claude: EnterWorktree(path)。ホストが既存 worktree へ入場する機能 | 各実行の workdir を固定 → 各実行で明示的に cd。編集は絶対パス、子にも作業先を渡す。下記 invariant を満たせない実行面では停止 |
| スキル読込・継続 | Claude: Skill。他ホスト: 公開された skill loader | 解決済み配布パスの SKILL.md を読み、引数を渡して同じ手順を親が実行。子スキルの完了条件を検証して caller の次工程へ進む |
| 委譲 | Claude: Agent（旧呼称 Task）。Codex: spawn_agent と結果回収。Grok: 公開された subagent 機能 | 配布された reviewer 本文を子の指示へ明示して native 子に渡す。独立子・必要な並列性を作れなければ停止。親の自己レビューで人数を水増ししない |
| 質問 | Claude: AskUserQuestion。Codex: 当該モードで公開された質問ツール。Grok: 検証済み質問 UI | 通常の会話で質問し、回答到着まで依存工程を停止。権限昇格はこの代替で済ませず、ホストの承認機構を使う |
| hook | ホストに登録され、対象イベントで意味が一致する handler | 明示的な工程境界で同じ helper を一度実行し、結果を検証できる場合のみ。後述の自動イベントは別途検証が必要 |
| セッション識別 | ホストが渡す session/thread ID | 現在ホストIDを既存 helper の明示引数/プロセス限定入力に渡す。全 consumer の一貫性を検証できなければ停止。共有 marker の他人の値を借りない |
| 承認・権限 | 各ホストの permission / approval 機構 | 代替なし。拒否・承認不可なら診断を返す |

### 作業先と所有者

`git rev-parse --show-toplevel` が意図した worktree と一致し、branch と `git worktree list --porcelain` も一致することを確認する。これは shell の cd 成功だけでは足りない。後続の全実行・編集・子エージェントに同じ作業先を指定し、復旧後にも再検証する。main checkout の dirty を破棄・自動搬送せず、既存の衝突ゲートに従う。

共有 state root は [state-path-resolve.sh](../hooks/state-path-resolve.sh) で解決し、session ID の検証は [Session ID Validation Contract](session-id-validation-contract.md) に従う。非対応 ID を UUID らしく加工したり、共通の固定値に落としたりしない。helper ごとの受理条件が異なる場合は全 consumer が受理する経路だけを採用する。

[session-identity.sh](../hooks/session-identity.sh) が現在 runtime の ID を選択し、flow-state / claim / work memory / wiki lock に接続する。`RITE_HOST=claude|codex|grok` を指定した場合はそのホストの ID が必須。未指定なら1ホスト分だけ存在する環境変数を採用する。Claude は `CLAUDE_CODE_SESSION_ID` / `CLAUDE_SESSION_ID`、Codex は `CODEX_THREAD_ID`、Grok は `GROK_SESSION_ID`。複数ホストの env があって選択されていない場合、または選択先 ID が欠落・不正なら停止する。共有 marker への降格で復旧しない。

Claude の native SessionStart は payload の ID を当該 hook process へ渡し、ホストが `CLAUDE_ENV_FILE` を提供する場合は後続 Bash へ安全に永続化する。ファイルが無い実行面で未確認の ID を共有 marker から借りない。

明示 `--session` は既存 consumer の契約を維持する。通常のホスト操作では現在の実 ID を使い、他人の ID を明示引数に入れない。`RITE_HOST` はセッション選択だけの入力であり、hook・委譲・承認能力の証拠ではない。Layer 1 の opaque 受理と Layer 2 の UUID 検証は [既存の責務分担](session-id-validation-contract.md) を維持する。

### hook の適合境界

イベント名だけで互換を判断しない。payload のフィールド名、tool matcher、plugin root 展開、追加コンテキストの注入、deny、Stop の再継続、compact 後の復帰を個別に検証する。Claude Code の [hooks.json](../hooks/hooks.json) と各 helper が既存動作の基準となる。

工程内で caller が観測できる処理は下記の明示経路で実行できる。ユーザーによる中断、ホストによる compact / session end、Stop の差し戻しは「後で同じ shell を叩く」だけでは同値にならない。これらの自動イベント効果は別途検証し、必須となる操作の前で不足を診断する。明示経路では工程前の guard・工程後の保存・flat な次工程実行で継続し、中断時は最後の checkpoint から recover する。ホストの fail-open を rite の成功に変換しない。

### 入口と工程境界

最外側 skill の最初の state / queue 操作より前に、配布 plugin root と実際の cwd を解決する。native hook の登録・発火・事後条件を確認できるときだけ `auto`、自動発火がない実行面では `explicit` を選ぶ。同じ session / event で両方を実行しない。登録状況が不明なら、まずホストの hook 一覧で確認する。ホストの trust/permission は正式な UI に従い、helper は設定を書き換えない。

```bash
bash {plugin_root}/hooks/host-runtime.sh init --mode {runtime_mode} --cwd "{execution_cwd}"
```

`{runtime_mode}` は上記の `auto|explicit`、`{execution_cwd}` は実行・編集に固定した絶対パス。nested skill は caller の選択を引き継ぐ。別 tool call でも同じ実 session env と作業先を渡す。`explicit` の init は同梱 helper で plugin marker と state 用 ignore を準備し、開発 launcher を必要としない。

| 境界 | explicit で実行する操作 | 検証 |
|---|---|---|
| Bash の前 | `host-runtime.sh before-bash --mode explicit --cwd "{execution_cwd}" --payload-file "{tool_payload}"` | 既存 bash guard の拒否なら対象コマンドを実行しない |
| 編集の前 / 後 | `before-edit` / `after-edit` を同じ引数で実行 | 編集 guard と bang-backtick 検査。失敗を成功にしない |
| phase 更新後、子 skill を返す前 | `host-runtime.sh checkpoint --mode explicit --cwd "{execution_cwd}"` | 現 session の local WM と必要な replica 同期を確認。失敗なら保存済み phase を保持して caller の失敗経路へ |
| 次工程または recover | `host-runtime.sh next --mode explicit --cwd "{execution_cwd}"` | phase / next / handoff を読み、各 skill の分岐表を実行。読取りだけで工程完了にしない |

表の command はすべて `bash {plugin_root}/hooks/` 配下の helper を呼ぶ。`{tool_payload}` は呼出し直前の tool 入力を保存した絶対 JSON パスで、`tool_name` と `tool_input` を含む。shell は `Bash` / `command`、編集は実操作に対応する `Edit|Write|MultiEdit` / `file_path` 等へ正確に対応付ける。複数ファイル patch は各対象を guard する。Grok の camelCase payload を無変換で通さず、公開 schema から上記入力を構成する。入力が対応付けられない操作は実行前に停止する。

guard 自身・checkpoint の内部 helper を再帰的に guard しない。helper の診断・終了コード・JSON deny を読み、拒否時は保護対象を変更しない。`auto` は native に委ねるだけで、明示 helper の成功証跡ではない。

### hook の棚卸し

| 既存 hook | 明示経路 / 自動イベントとの境界 |
|---|---|
| SessionStart | `init` の限定初期化。自動 startup の migration / reap を無条件に再実行しない |
| PreToolUse Bash / Edit | 操作前の `before-bash` / `before-edit`。拒否を守る caller が必須 |
| PostToolUse WM / bang | `checkpoint` / `after-edit`。既存同期済み phase と冪等 init を使う |
| Stop | flat caller が sentinel を判定して継続。`next` は handoff を消費しない。自動差し戻しの実証とは別 |
| PreCompact / PostCompact | 各工程 checkpoint と recover。予告なし compact への自動復帰能力は未検証のまま |
| SessionEnd | 最外側 skill の正常/失敗終了処理。強制終了イベントの自動 cleanup を保証しない |

## 診断・停止・再開

不足能力時は次を人間に読める形で返す（新しい成功 sentinel / state phase を追加しない）:

```text
実行能力不足: {操作} / {native・代替を使えない根拠}
環境: {ホスト、版、実行面、モード}
停止位置: {skill、step、Issue/PR}
保持した状態: {branch、worktree、stateの場所、最後に検証できた工程}
復旧: {必要能力または権限を整える方法} → /rite:recover {issue}
```

state 自体が読めない場合は「状態未確認」とし、取得できた情報だけ返す。他セッションの state を上書きしない。既存 caller の失敗 sentinel / missing-sentinel 処理を使い、batch は queue の cursor を保持して停止する。能力不足を同じ操作の再試行だけで直ったことにしない。

再開は [recover](../skills/recover/SKILL.md) の phase→step 対応を使い、まず所有者、既存 PR、worktree と能力を照合する。異なるホスト/セッションへの移動は同一セッション再開ではなく、所有権移管の検証が必要。別セッションの active queue を引き継がない。

## 配布境界

実行時の SoT は本書と同梱の skills / hooks / references。root 解決は [Plugin Path Resolution](plugin-path-resolution.md)。参照は配布された plugin root 内で完結させ、開発用 launcher、開発プロファイル、repository 外のグローバル設定変更を必須にしない。版別の調査記録を利用できない配布先でも、上記条件と実行時 probe で選択し、根拠不足なら停止する。
