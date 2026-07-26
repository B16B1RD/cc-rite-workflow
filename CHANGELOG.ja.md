# 変更履歴

Rite Workflow の主要な変更を記録します。

フォーマットは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
[Semantic Versioning](https://semver.org/lang/ja/spec/v2.0.0.html) に従います。

<!--
Phase 番号取扱方針: エントリは機能名レベルで変更を記述し、`review.md` /
`fix.md` / `pr/open.md` 等の内部 `Phase X.Y.Z` 識別子には依存しません。Phase
番号はリファクタで採番し直される可能性があるため、CHANGELOG のエントリは
それらの変更に対して安定でなければなりません。位置情報が必要な場合は
内部 Phase 番号ではなくファイル名 (例: `review.md`) を参照してください。
背景・慣行は Keep a Changelog 1.1.0 "Guiding Principles" 参照。

歴史依存表現の取扱方針: エントリは機能名レベルで変更を記述します。
Fixed/Changed/Removed エントリは修正対象の旧挙動を述べてよい（それが変更履歴の
目的）ですが、「従来の挙動」「以前の方式」のような基準点が新規読者に不明な暗黙
参照ではなく、変更対象のキー・機能・挙動名 (例: `multi_session.enabled`、
`max_review_fix_loops`) を明示します。各バージョンセクション自体が比較の基準点
なので、名前付きのキー・機能に紐づかないバージョン跨ぎの「従来は / 以前は」表現は
避けます。アップグレード利用者向けの breaking change 告知・移行ガイドはそのまま
保持します。
-->

## [Unreleased]

## [0.9.2] - 2026-07-24

### 変更

- 紹介動画（日英）のバッジ・エンディングメタのバージョン表記を `v0.8.0` から `v0.9.1` へ更新し、README の Demo 節の動画リンクを BGM 合成済みの最終版へ差し替えた。シーン構成・尺（約125秒）は変更していない。(#1985, #1986)

## [0.9.1] - 2026-07-23

### 追加

- **`cleanup`/`wiki-ingest`/`batch-run`/`recover` の完了報告に「未完了事項」集約セクションを追加** — 非ブロッキングな失敗（wiki push のスキップ・ブランチ削除の見送り等）がチェックリスト各項目の付記としてのみ散在し見落とされやすかった問題を解消する。集約セクションは未完了事項がゼロ件のとき明示的に「なし」と表示する。`cleanup` は `[cleanup:outstanding:N]` sentinel を emit し、`batch-run` が `--merge` モードの完了通知でバッチ全体をロールアップ表示する。`recover` には `resolved_phase` が `cleanup`/`completed` のときのみ、未 push の wiki commit・残存ローカルブランチを git 実態から検出する informational な追加チェックが加わった。(#1946, #1975)

### 修正

- **`setup` Phase 4.8/4.9 の案内メッセージが、実行エージェントによる要約・言い換えを経ずテンプレート通り逐語出力されるようになった** — 各メッセージブロック直前に、テンプレート本文を要約せず逐語出力する旨の明示的な指示を追加した。(#1976, #1978)
- **corpse 化した worktree（admin dir 半壊で git がツリーを認識できない状態）が、24h の age guard を待たずに即座に回収されるようになった** — `cleanup` の Step 4-W は、worktree の削除がスキップされ（busy 失敗または sandbox マスク）かつ PR マージが確認済みの場合、worktree のパスを reap manifest（`.rite/tmp-artifacts.tsv`）へ記録するようになった。corpse 化した worktree は checkout 中の branch を解決できず、既存のブランチ名ベースの manifest bypass（#1966）が適用できないため。(#1945, #1974)
- **`pr-review` の drift 検出（worktree axis）が、sandbox ghost-mount 由来の untracked エントリで誤発火しなくなった** — snapshot 側と verify 側で異なる sandbox 実行コンテキストを跨ぐと、ghost-mount 由来のエントリが片側にのみ現れて実変更が無いのに worktree drift が誤検出されていた。`post-review-state-verify.sh` の `current_worktree_hash` と `pr-review` Step 4.0.A の `ORIG_WTH` の両方を、生の `git status --porcelain` ではなく既存の ghost-mount フィルタ（`lib/git-status-filtered.sh`、#1936）経由で算出するようにした。(#1944, #1973)
- **セッション worktree 作成時に `.claude/settings.local.json` を複製するようになった** — `git worktree add` は gitignore 対象の `.claude/` を複製しないため、ドッグフーディング上書き（`enabledPlugins["rite@rite-marketplace"]: false`）がセッション worktree で失われ、キャッシュされた古い marketplace 版のスキルがロードされてしまっていた。`open` の Step 2.3-W と `ensure_session_worktree` の branch_local/branch_remote 両経路が、ファイル存在時に複製するようになった。(#1943, #1970)
- **セッション開始時の lazy reap（`pr-cycle-cleanup.sh`）の出力が `.rite/logs/pr-cycle-cleanup.log` へ退避されるようになった** — 破棄されていた出力をログファイルへ残すことで、reap が無言でスキップした理由（dirty skip・liveness skip・corpse age guard 等の WARNING）を事後診断できるようにする。(#1968, #1969)
- **マージ済み PR のセッション worktree とローカルブランチが永久にリークしなくなった** — claim 解放後、worktree root の mtime がハーネスの `.claude/.cc-writes` churn によりセッション毎に更新され続けるため、free-claim 経路が「mtime 24h 未満なら無言スキップ」に永遠に吸われていた。manifest 記録済みの free-claim 経路がこの age guard をバイパスするようになり、次回セッションの reap で実際に回収できるようになった。(#1966, #1967)
- **sandbox マスクマウントされた worktree が、`cleanup` の `git worktree remove --force` で半壊しなくなった** — sandbox が admin dir の `config.worktree` に character device をマスクマウントしている場合、Step 4-W は事前にマスクを検知して remove の試行自体をスキップし（`WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` marker + WARNING を出し遅延 reap へ委譲）、admin dir が半壊（`HEAD` 欠落）して「not a git repository」化する回収不能な状態を予防する。遅延 reap の Step 5 にも corpse 判定（admin `HEAD` 欠落 AND git 非認識）を追加し、従来 Gate 3 で永久スキップされていたケースを回収できるようにした。(#1957, #1959)

### 変更

- **`setup` Phase 4.8 が、sandbox write 許可リストの設定をユーザーへの案内のみから自動設定に変更** — `multi_session` が有効かつ filesystem write 制限のある sandbox を検出した場合、`/rite:setup` は `.claude/settings.local.json` がリポジトリの `.gitignore` でカバーされていることを保証し（未カバーなら追記 — 開発者個人のグローバル gitignore だけでは他の contributor を守れないため）、main checkout root の絶対パスを同ファイル（コミットされる `.claude/settings.json` は変更しない）の `sandbox.filesystem.allowWrite` へ idempotent に自動追記する。0.9.0 の「既知の制約」に記載された手動設定の負担を解消する。sandbox 起因の書き込み失敗は sandbox 無効化つきで一度だけ再試行し、再試行後も失敗した場合のみ従来の手動案内メッセージにフォールバックする。(#1942, #1965)
- **`wiki-ingest` が `wiki` ブランチへの push を、raw source の commit や lint 追記のたびではなくフロー末尾で 1 回にまとめるようになった** — SSH host alias remote 環境での sandbox バイパス反復を削減する（従来は 1 セッションで最大 8 回の push が発生し、うち一部は 11 秒差で重複実行されていた）。各 raw source の commit は新設の `--commit-only` モードを使い、新設のステップ 8.6 で `auto_lint` の値に関わらず `--push-only` を 1 回だけ実行する。`wiki-lint` の standalone 実行は影響を受けない（引き続き即座に commit+push する）。`--auto`（ingest から呼ばれた場合）の経路のみ push を ingest 側に委ねる。(#1941, #1955)

## [0.9.0] - 2026-07-21

### 追加

- **`setup` が sandbox 関連の 2 つの既知環境制約を、失敗発生後ではなく `/rite:setup` 実行時点で事前検出・案内するようになった** — (1) Phase 4.8（`multi_session` 有効時のみ該当）: `EnterWorktree` 後、セッション worktree の cwd から main checkout 配下への state 書込（`flow-state.sh` / `issue-claim.sh` 等）が拒否される制約、(2) Phase 4.9（`multi_session` の有無には非依存）: sandbox 有効セッションが SSH host alias remote（例: `git@github.com-work:owner/repo.git`）を持つ場合に `git push`/`fetch` が Bad Gateway で失敗する制約。sandbox の有効判定は bash から検出不能なため、両 Phase とも同じ方式（Claude 自身の実行コンテキスト判定）を採る。(#1907, #1925, #1938)

### 変更

- **BREAKING: reviewer read-only 保証の防御層を再配分した — `pre-tool-bash-guard.sh` は working-tree git verb を機械ブロックしなくなり、`.git` 書き込みゲートのみを機械ゲートに残す** — 静的 verb denylist（sub-block (A)–(G)：`checkout`/`reset`/`add`/`commit`/`branch`/`stash`/`fetch` フラグ/`worktree` サブアクションほか 20 超、加えて **その denylist のためのコマンド全体 git グローバルフラグ正規化**・worktree-add 引数走査）を PreToolUse hook から撤去し（約 3 分の 1 削減、922 → 600 行未満、存続する `.git` 書き込みゲート sub-block (N) は 4 サブコマンドに限定した global-flag 正規化を保持する）、繰り返される bypass 穴塞ぎ（3 ヶ月で 11 コミット）を止めて誤検出クラスを構造的に消した。working-tree 変更は `git status` で可視・回復可能なため、その保証は Layer 1（`_reviewer-base.md` の READ-ONLY 契約、不変更）+ Layer 3（各レビュー後の `post-review-state-verify.sh` による branch/stash/branch-list/worktree drift 検出 — 検出ロジックは不変、ヘッダと drift WARNING の案内メッセージは新レイヤリング向けに更新）へ移した。機械ゲートに残すのは、これらの層がカバーできないもののみ（いずれも fail-closed）：redirect / ファイル変更 verb 経由の `.git` ディレクトリ書き込み（`git status` に不可視・不可逆・RCE 級 — sub-block (H)）、redirect/file-verb 検出では見えない native な `.git` 書き込み git サブコマンド — `git config` の書き込み形（`core.hooksPath` / `core.fsmonitor` / `alias.*=!cmd` が RCE ベクタ）・変更を伴う `git remote`・`git update-ref`・`git symbolic-ref` — を 4 サブコマンド固定集合として（sub-block (N)；`git config --list/--get` 等の read 形は許可）、shell-wrapper ブロック（`eval`/`sh -c`/… は `.git` 書き込みを容易に隠せる）、oversized-command 長さガード（timeout→fail-open bypass 防止）。deny pattern 名も変わる：`reviewer-state-mutating-git` は廃止し、存続ゲートは `reviewer-gitdir-write`（(H) と (N) の両方）/ `reviewer-shell-wrapper` / `reviewer-oversized-command` を emit する。回帰が出た場合はハーネス全体を復活させずに個別 verb を再追加できる。(#1879)
- **BREAKING: 観点が相互重複していた 5 つの専門 reviewer（`api` / `frontend` / `performance` / `database` / `type-design`）を単一の `application-reviewer` へ統合した** — 5 体の checklist は相互侵食しており（N+1 は performance / database の両方が、XSS は security / frontend の両方が見る等）、spawn される reviewer ごとに共有原則 `_reviewer-base.md`（約 430 行）が再注入されるため、5 体全選定の混在 PR では base×5 の冗長注入が発生していた。統合後の `application` reviewer は目的（アプリケーションコードの正確性・性能・データ操作・インターフェース設計）をペルソナ + first-suspect lens として持ち、細目チェックポイントの選択はモデル判断に委ねる。Database migration の Hypothetical 例外は migration 関連 finding に限り継承する（`severity-levels.md` は不変更）。reviewer registry は 13 → 9 種に縮小。旧 type 名が入力に現れた場合（rite-config の設定値・保存済みレビュー結果 JSON・手動指定）は WARNING を表示して `application` で代替実行し、silent skip はしない。

  **移行表（旧 reviewer type → 新 type）:**

  | 旧 reviewer type | 新 type |
  |------------------|---------|
  | `api` | `application` |
  | `frontend` | `application` |
  | `performance` | `application` |
  | `database` | `application` |
  | `type-design` | `application` |

### 修正

- **sandbox 有効環境（bubblewrap ベース）での `.git/config` 書き込み拒否に対応した** — worktree 作成時の upstream tracking 設定（`branch.autoSetupMerge`）と `git push -u` の upstream 設定がこの拒否に該当し、open→implement→pr-create のフローがブランチ作成済み・未 push の中途半端な状態で停止していた。worktree 作成に `--no-track` を追加して tracking 書き込みを回避し、`git push -u` / bare `git push` は `git push origin {branch}` に統一（flow-state がブランチ名を常時保持するため upstream 依存が不要）、`gh pr create` に `--head` を明示して upstream 未設定でも正しい head を解決するようにした。(#1898)
- **origin remote が SSH host alias（例: `git@github.com-work:owner/repo.git`）のとき `gh repo view` 等の shorthand コマンドが host を解決できず失敗する問題を修正した** — gh の host allowlist はエイリアスを認識できないため、owner/repo を `git remote` の URL から直接パースする `resolve_owner_repo()`（`hooks/scripts/lib/git-remote.sh`）を新設し `gh repo view` への依存を除去した。内部スクリプト・SKILL.md 手順書内のスニペット・repo コンテキストに依存する復旧手順のコマンドにも `-R`/`--repo` の明示指定を伝播した。(#1913, #1917, #1919, #1921)
- **sandbox 有効環境（書込先が `$TMPDIR` に限定され `/tmp` 直下は読み込み専用）向けに `mktemp` の `/tmp` 直下ハードコードを全域解消した** — 本番コード・テストハーネス双方の `mktemp` テンプレートを `${TMPDIR:-/tmp}/rite-*` 形式に統一し、再発防止のため lint に `tmp-hardcode-check.sh`（check table #16）を追加した。(#1902, #1909, #1910)
- **sandbox の書き込みブロック用マウント（character device による `/dev/null` bind mount）が `git status` の untracked（`??`）として誤検出され、`cleanup`/`recover`/`issue-update`/`pr-create` の dirty チェックが実変更なしでも dirty と誤判定していた問題を修正した** — untracked かつ character device のエントリのみを除外する共有フィルタ `lib/git-status-filtered.sh` を新設し、対象 4 スキルの dirty チェックをこれ経由に置換した。(#1936, #1937)
- **`issue-implement` の `git add .` を明示パス指定（`git add {changed_files}`）に置き換えた** — sandbox の read-deny 対象 dotfile（`~/.ssh`・`.bashrc`・`.gitconfig` 等）がキャラクタデバイスとして untracked 出現し、`git add .` がこれを「regular file でない」として拾おうとし exit 1 で hard fail して実装フェーズのコミットが止まっていた。(#1926)

### 既知の制約

- SSH host alias（例: `git@github.com-work:...`）経由の `git push`/`fetch` は sandbox 有効な Linux/WSL2 環境で恒久策が無い（`sandbox.excludedCommands` はネットワーク sandbox をバイパスできず、上流でも not planned）。公認の回避策は当該コマンドのみ `dangerouslyDisableSandbox: true` で再実行することであり、`/rite:setup` がこれを事前案内するようになった。
- `multi_session` と sandbox の両方が有効な環境では、セッション worktree の cwd から main checkout 配下への state 書込（`flow-state.sh` / `issue-claim.sh` 等）が拒否されることがある。main checkout root の絶対パスを sandbox の書込許可リストへ手動で追加する必要があり、`/rite:setup` がこの対処を事前案内するようになった。
- Task で spawn した reviewer subagent には `dangerouslyDisableSandbox` に相当するバイパスフラグを渡せない。

## [0.8.3] - 2026-07-16

### 修正

- **`/rite:batch-run` の `run-queue.json` をセッションスコープ化し、並行 batch-run の相互破壊を防いだ** — キューファイルを `run-queue-{session_id}.json`（session_id は `flow-state.sh path` から導出、正典 `_resolve_session_id` を再利用）にリネームし、`multi_session` worktree 下で複数セッションが `/rite:batch-run` を並走させても各セッションが独立したキューを持つようにした（従来は repo-global 単一 `run-queue.json` を相互に上書き・削除し、完了通知の誤報告と再開不能を招いていた）。読み書きの全箇所を追従: `batch-run/SKILL.md` ステップ0-8（session_id 解決不可時は global 名へフォールバックせず fail-loud）、`iterate/SKILL.md` ステップ6 のサーキットブレーカー batch 判定、`recover/SKILL.md` Phase 5.5（read-only の2箇所は解決不可時に interactive / 継続なしへ安全側デフォルト）。バッチ再開は同一セッション内に厳格化されるが、単一セッション運用（compact 跨ぎの永続化・引数省略再開・Phase 5.5 検出）は session_id が compact / turn を跨いで安定なため回帰しない。
- **reviewer subagent が parent working tree・`.git` を Edit/Write で書き換える経路を機械的に遮断した** — 新規 `pre-tool-edit-guard.sh`（PreToolUse、matcher `Edit|Write|MultiEdit|NotebookEdit`）が、reviewer subagent の Edit/Write を「対象が repo 内かつ隔離 worktree 外」のとき deny する。隔離判定はパス文字列の substring マッチではなく対象の所属 git worktree root（dirname walk-up + `git -C`）で行うため、`..` 再侵入・token-in-filename の bypass を塞ぎ、worktree 限定の mutation testing（`rite-review-mutation-*` / `rite-revert-test-*`）は誤検出しない。parent `.git` 配下（`.git/hooks/pre-commit`・`.git/config` 等）への書き込みも deny する（非サンドボックスの main session での任意コード実行を招くため）。`post-review-state-verify.sh` に worktree hash 軸（第4軸、advisory）を追加し、`_reviewer-base.md` に Edit/Write/MultiEdit/NotebookEdit の隔離 worktree 限定制約を明記した。(#1860, #1863)
- **reviewer subagent が Bash・symlink 経由で parent `.git` を書き換える残存経路を遮断した** — Edit/Write ガード（#1863）が残したギャップを塞ぐ。`pre-tool-bash-guard.sh` に sub-block (H) を追加し、リダイレクト（`> .git/…`）と位置引数 file-writer（`tee`/`cp`/`mv`/`ln`/`install`/`rsync`/`truncate`/`dd of=`/`sponge`/`patch`）による `.git` 配下書き込みを deny する一方、`.git` 読み取り（`cat`/`ls`/`grep`・`dd if=`）と隔離 worktree 作成は誤検出しない。`.git` パス検査は正規化前スナップショットに対し path・verb 両トークンを full quote/backslash dequote（POSIX quote-removal をミラー）して static obfuscation bypass を閉じ、tokenizer は `set -f`/`set +f` で noglob 化して hook CWD の glob 汚染と timeout→fail-open を防ぎ、verb allowlist は非網羅（COMMON-SET）と宣言した。`pre-tool-edit-guard.sh` も対象パス最終要素が symlink の場合は isolation 判定前に realpath で物理解決する。(#1864, #1865)
- **`pre-tool-bash-guard.sh` の `git worktree add` 引数走査を glob-safe 化した** — `for tok in $WT_ARGS` ループを `set -f`/`set +f` の noglob スコープ（(H) tokenizer と同型）で囲い、2 つの exposure を塞いだ: hook CWD にフラグ名ファイル（`-b` 等）があると `*` が展開され正当な `git worktree add <path> <ref>` が new-branch 形式に誤検出される over-DENY と、大ディレクトリ glob でループが無制限反復し PreToolUse hook が timeout→fail-open して worktree-add branch-leak チェックを bypass する経路。(#1866, #1867)
- **`/rite:batch-run` が `open` の計画承認・`pr-review` の構成確認で停止しなくなった** — batch-run が宣言する「完全自律（無確認）」と実挙動を一致させる。`open` ステップ 3.4 は batch 実行中（run-queue 判定、`iterate` ステップ6 と同型）に実装計画を自動承認し、standalone は従来どおり `AskUserQuestion`。`pr-review` ステップ 3.3 は E2E（iterate 経由）経路では flow-state phase-whitelist 判定（`ready` Phase 2.1 と同型）で reviewer 構成確認の `AskUserQuestion` を skip し、起動/省略 reviewer サマリ行は両経路で維持する。いずれも helper 失敗時は interactive / standalone に fail-safe する。(#1861, #1868)

## [0.8.2] - 2026-07-15

### 追加

- **`setup` が `plugin-path-resolution.md` の2つの解決方式間のバージョン不一致を検出し警告するようになった** — step 4.5.0 の marketplace 分岐に direct key lookup と正準 one-liner の照合を追加し、不一致時は両パス・不一致内容・対処法を WARNING 表示する（non-blocking、一致時の解決結果は変わらない）。`plugin-path-resolution.md` には3つ目の解決方式を追加することを明示的に禁止する記述を追加した。(#1833, #1841)

### 修正

- **`installPath` セマンティクスの consumer 間不整合を修正した** — `rite@rite-marketplace` v0.8.1 に対する実環境検証により、`installPath` はプラグインルートそのものを指す（`hooks/`・`skills/`・`scripts/`・`references/` が直下に存在し、`plugins/rite/` という中間ディレクトリは存在しない）ことを確定した。`hook-preamble.sh` の誤ったパス参照（version-redirect ロジックがサイレントに dead code 化していた）を修正し、`plugin-path-resolution.md` に検証済みのセマンティクスを明記した。(#1842, #1852, #1854)
- **Work Memory (WM) 同期経路を修復した** — `open/SKILL.md` ステップ 2.5 の初回 WM 投稿に `issue-comment-wm-sync.sh init` 呼び出しをステータス分岐表付きの bash block として明示配線した（従来は prose 指示のみで実際の呼び出しが行われていなかった）。また `work-memory-update.sh` がフェーズ遷移更新のたびに `## Detail` 以下の蓄積セクションを消失させていた問題を解消し、既存 stock から蓄積部分を抽出して verbatim に保持するようにした（`Phase:`/`Branch:` 行のみ最新値で再生成する）。(#1830, #1838)
- **WM 同期経路の follow-up を強化した** — `work-memory-update.sh` は `detail_extra` の awk 抽出に失敗した際、silent fallback ではなく rc 付き WARNING を出すようになった。`issue-comment-wm-sync.sh` の init pre-check には non-blocking degrade 契約を pin する回帰テストを追加した。親シェルが直接 mktemp する tempfile 10 個を file-wide cleanup 関数 + EXIT/INT/TERM/HUP trap で一括保護し、WM 同期のアーキテクチャ図も実装に合わせて更新した。(#1844, #1849)
- **レビュー結果と PR-state の保存先を `state-path-resolve.sh` 基準へ統一した** — `review-result-save.sh` の `REVIEW_RESULTS_DIR` 既定値と `review-source-resolve.sh` のローカル JSON 読取優先度を、`wiki-ingest-trigger.sh` が既に使っていたのと同一の state-root anchor で解決するようにし、`multi_session` でセッション worktree が保存したレビュー結果・PR-state（accepted-fingerprints・fix-cycle-state）を main checkout 側の cwd-relative パスから読めない不整合を解消した（`--results-dir`/`--repo-root` の明示指定は従来どおり優先、解決失敗時は cwd-relative フォールバック + WARNING）。(#1831, #1839)
- **state-path-resolve 統一で挙動が変わった観測面 4 種に回帰テストを追加した**（`state-root-observers.test.sh`、11 assertion）。`review-schema-version-check.sh --all` の worktree cwd からの drift 検出、`review-skip-notification.sh` の state-root パス表示、`distributed-fix-drift-check.sh` Pattern 6 の `--repo-root` 非伝搬契約をカバーし、従来 sandbox での手動実測にのみ依存していた検証をテストで pin した。(#1845, #1850)
- **`open`/`cleanup` の GitHub Projects Status 更新を inline 化し silent skip を防止した** — `open/SKILL.md` ステップ 2.4(A)（Status→In Progress）と `cleanup/SKILL.md` ステップ 8（Status→Done）は従来、`projects-status-update.sh` への委譲を prose 記述のみで済ませており実際の bash 呼び出しがなかった。`/rite:batch-run` のような長い自律実行チェーンの中でこの参照のみのステップが読み飛ばされ、Status が最終状態（In Progress / Done）まで進まず Todo 等に残留する不具合があった。(#1846, #1847)
- **`projects-status-update.sh` 呼び出しの `|| status_json=""` フォールバックを残存 4 箇所で除去した** — `ready/SKILL.md`・`issue-close/SKILL.md`・`cleanup/references/archive-procedures.md` で使われていたこのパターンは、script が非ゼロ終了した際に既に出力済みの失敗理由入り JSON（`.warnings[]` 含む）を空文字列で上書き・破棄していた。command substitution は終了ステータスに関わらず stdout を capture するためこの fallback は不要であり、残り 4 箇所から除去した。(#1848, #1851)
- **`multi_session` の dirty main checkout ガードを `open`/`cleanup` に追加した** — `open` ステップ 2.2-W は、セッション worktree 作成前に main checkout の未コミット変更を検出し、それが Issue の Target Files に重なる場合のみ `AskUserQuestion` で搬送・続行・中止を確認する。`cleanup` ステップ 4 は `git merge --ff-only` の 3 回リトライ全滅後に成否を検証し、無確認の破棄や競合状態の放置ではなく、diff 確認済みの破棄提案または stash 案内での終了を行う。(#1832, #1840)
- **`pr-review` ステップ 4.3.1 で reviewer Task 起動時の `run_in_background: false` 明示指定を必須化した** — 従来の禁止表現（「`true` を使うな」）だけではパラメータのデフォルト値が未規定のままで、harness のデフォルトがバックグラウンド実行であるためパラメータ省略時にサイレントに background 起動していた。根拠とともに明示指定を MUST 化した。(#1834, #1843)
- **`issue-create` がラベルを冪等に事前作成し helper 失敗時に result を surface するようになった** — ラベルが既に存在する場合の失敗を防ぎ、helper の失敗を握りつぶさず結果として表面化する。(#1829, #1837)
- **`lint` の `gitignore-health-check` の偽陽性を修正した** — 単純なパターンマッチではなく実効的な ignore 判定を行うようになり、`setup` が生成する到達不能エントリをスキャン対象から除外した。(#1836)
- **`setup` が Project 作成後に `gh project link` を冪等実行するようになった** — 新規作成した Project がリポジトリにまだリンクされていないことに起因する、初回 Issue 作成時の Projects 登録失敗を解消した。(#1835)

## [0.8.1] - 2026-07-11

### 修正

- **`/rite:recover` が中断からの個別スキル復帰後、`/rite:batch-run` 実行中の active batch 中断かを自律判定し、該当時は残りキューの処理を自動継続するようになった** — `recover/SKILL.md` に新設した Phase 5.5 が `run-queue.json` の `active` フラグ・cursor 一致・鮮度（2時間、`session-ownership.sh` の `parse_iso8601_to_epoch` を再利用）で判定し、該当時は `batch-run/SKILL.md` 既存のステップ3-8分岐表を参照して継続する（複製しない）。stale な `run-queue.json` の残骸では誤って継続しない。`run-queue.json` に `updated_at`（ISO 8601）フィールドを追加し、cursor 前進 / active 設定の各書き込みで更新するようにした。(#1820, #1821)

## [0.8.0] - 2026-07-10

### 変更

- **Claude Code 組み込みスラッシュコマンドとの基底名衝突を解消するため、4件のスキルをリネーム** — `run` → `batch-run`、`review` → `pr-review`、`init` → `setup`、`resume` → `recover`。**破壊的変更 — 新しい名前で起動する:** `/rite:run` → `/rite:batch-run`、`/rite:review` → `/rite:pr-review`、`/rite:init` → `/rite:setup`、`/rite:resume` → `/rite:recover`。リポジトリ内の全参照・相互リンク・sentinel contract の識別子も追随して更新した。挙動変更のない純粋なリネームである。(#1788, #1790, #1793, #1794, #1795, #1796, #1800, #1803, #1804)
- **reviewer registry の3-way同期（`agents/*-reviewer.md` ⇔ `pr-review/SKILL.md` の Available Reviewers 表 ⇔ Reviewer Type Identifiers 表）を単一の機械チェックで検証するようにした** — 従来は tech-writer 行の2ファイル等価性しか監視しておらず、agent ファイルのみの追加・表の片側更新・slug 不整合を検出できず素通りしていた。(#1743)
- **非 rite プロジェクトにおける per-call hook に前段 early-exit と `jq` 呼び出しの集約を追加した** — rite プロジェクト内の入出力・副作用は不変のまま、rite を使っていないプロジェクトでの Bash / Edit 1 コールごとのサブプロセスコストを削減する。(#1737)
- **`pr-review/SKILL.md` と `fix/SKILL.md` のコンテキストダイエットを実施** — 設計理由・歴史的経緯・外部仕様解説をスキル本体から `references/` へ退避し、`fix/SKILL.md` を8.2%（4,040→3,709行）、`pr-review/SKILL.md` を13.1%（4,040→3,510行）削減した。「SKILL.md < 500行」原則は、この2層構造の実態に合わせて改定した（入口スキルは500行未満を維持、実行手順書スキルは4,000行を上限とする）。(#1774)

### 追加

- **`/rite:unknowns` スキルを新設** — 明示起動限定の実装前探索セッション（盲点洗い出し・複数アプローチのブレインストーミング・使い捨て HTML プロトタイプ・要件インタビュー）を提供し、最後に探索サマリを出力して `issue-create` 等の後続スキルへ渡す。`wiki-query-inject.sh` を配線し、Wiki に蓄積済みの経験則を盲点洗い出しの材料として活用できるようにした。(#1805)
- **`issue-create` が `/rite:unknowns` の探索サマリを検出し、仮定表面化を軽量化するようにした** — 探索で既に解決済みの問い・発見した盲点は再質問・列挙をスキップし、未解決の問いは既存の3分類へ直接合流させる。(#1806)
- **`issue-create` ステップ4.0に「盲点チェック（unknown unknowns）」サブステップを追加**（見込み Complexity M以上で発動） — 発見項目は既存の derive/ask/defer 3分類へそのまま合流させ、新しい処理経路は作らない。(#1755)
- **`open` ステップ3.3の実装計画テンプレートに volatile-first 提示順ルールを追加** — ユーザーの判断で変わりやすい項目（データモデル変更・型/インターフェース定義・ユーザー可視挙動/UX）を先頭に、機械的なリファクタ・定型作業を末尾に置き、計画承認レビューの注意を本質的判断に集中させる。(#1752)
- **`pr-review` ステップ7を「自動 Issue 化」から「スコープ外指摘のトリアージ」へ再設計** — AskUserQuestion の推奨オプションをエージェント裁量から規則表による機械決定へ移し、「Decision Log に記録」選択肢を新設。承認された記録は元 Issue の Section 9 Decision Log（無ければ作業メモリ）へ追記される。(#1802)
- **`pr-review` に `max_reviewers` 上限と起動前のコスト見積りサマリを導入** — reviewer 選定は既存の下限保証・必須 Security reviewer ガードの後に上限を適用し、絞り込んだ reviewer とその理由を常に提示する（silent cap は禁止）。既定値 `max_reviewers: 6` により、上限以内のマッチでは従来と同一の選定結果を維持する。(#1729)
- **`pr-create` の PR body に Decision Log / 計画逸脱ログの要約を還流するようにした** — Phase 3.2.2 が Issue の Section 9 Decision Log と作業メモリの計画逸脱ログを読み取り、diff だけでは分からない実装中の判断をレビュアーに提示する。両ソースとも0件の場合はセクション自体を省略する。(#1756)
- **`iterate` の review⇄fix ループにサーキットブレーカーを導入** — `safety.max_review_cycles`（既定5）を上限とし、非収束 PR による無限ループを構造的に防ぐ。`batch-run` では上限到達した PR を failed として記録しカーソルを前進させ、バッチ全体のストールを防ぐ。(#1728)
- **`recover` にマージコンフリクト / rebase 中断状態の検出を追加** — unmerged マーカー・`MERGE_HEAD`・`rebase-merge`/`rebase-apply`（worktree でも正しく解決する `git rev-parse --git-path` 経由）をフェーズ推定より優先して提示し、コンフリクト解消をスキップして汎用の「実装途中」復帰へ誘導しないようにした。(#1734)
- **`batch-run` が着手前に処理サマリを表示するようにした** — キュー確定直後に対象件数・実行モード・件数ベースの目安時間・中断/再開方法を1回提示し、各 Issue 完了時に「N/M件完了」の進捗行を表示する。(#1733)
- **`setup` が `safety` セクションを `rite-config.yml` に書き出すようにした** — 従来 `--- Advanced ---` マーカーより下にコメントアウトされていた `safety`（`max_implementation_rounds`・`max_review_cycles` 等）を、`wiki`/`multi_session`/`tdd` と同じく active ブロックへ昇格し、新規生成される config で安全上限が発見できるようにした。(#1732)
- **sentinel contract（約29種の `[skill:action]` 文字列）を SoT 化し CI 常時検証へ引き上げた** — `sentinel-contract.md` に emitter/consumer 対応表を集約し、`sentinel-contract-check.sh` で双方向一致を機械検証する。`lint` Phase 3.20 として統合し、専用の GitHub Actions workflow で push/PR 時にも常時実行する。(#1771)

### 修正

- **`fix.md` ステップ5.1 の sentinel 判定が `accept` 決定を正しく継続分岐できるようにした** — 従来のロジックはコミット `0dee5b22` で削除済みの旧ポリシーに由来する実在しない「別Issue作成件数」を条件にしていた。ステップ2.1.A が既に emit している `ACCEPT_FINGERPRINT_PERSISTED` マーカーを判定シグナルとすることで、accept 決定が suppression の実効性を確認しないまま無条件の正常終了へ落ちることを防ぐ。(#1813)
- **`flow-state.sh` の `cmd_set` が `wm_comment_id` を無警告で消失させないようにした** — `issue-comment-wm-sync.sh` の `cache_comment_id()` が直接書き込む `wm_comment_id` フィールドが、`cmd_set` の JSON 再構築時に使う merge-preserve whitelist から漏れており、直後の無関係な phase-transition set で消えていた。(#1812)
- **`issue-comment-wm-sync.sh` と `cleanup-work-memory.sh` を schema_v2/v3 multi-state aware に対応** — 両スクリプトとも `FLOW_STATE` の解決が legacy 共有ファイル（`.rite-flow-state`）への直書きになっており、セッション別 flow-state ファイル（`.rite/sessions/{sid}.flow-state`）を考慮していなかったため、`wm_comment_id` キャッシュの常時ミス（余分な `gh api` スキャン）や、`/rite:cleanup` 完了後も `active:true`/`phase:cleanup` のまま残存するセッションファイルが `/rite:recover` や Stop hook の誤判定を招いていた。両スクリプトとも `flow-state.sh path`（canonical resolver）経由に変更し、解決失敗時のみ legacy ファイルへ warning 付きでフォールバックする。(#1808, #1809)
- **`pre-tool-bash-guard` の Pattern 4（reviewer subagent の状態変更 git コマンドブロック）を fail-closed化しtimeoutを設定** — Pattern 4 は便宜パターン1-3と fail-open な ERR trap を共有しており、予期せぬ入力によるパースクラッシュが `exit 0`（allow）に収束してしまい、クラッシュ1つで reviewer の read-only ガードが bypass され得た。Pattern 4 を独立した fail-closed 構成に再編し、他の hook にはすべて設定済みだった timeout を `PreToolUse:Bash` にも追加した。(#1736)
- **`test-distributed-fix-drift-check.sh` が shallow clone 環境で失敗しないようにした** — `git fetch --depth=1 origin <full-sha>` によるフォールバックで到達不能な baseline commit（フル SHA 参照に変更）を解決し、フォールバック後も到達不能な場合は silent pass や偽陽性の CI 失敗ではなく明示的な skip メッセージを出すようにした。(#1741)
- **ロック機構の既知の穴3点を堅牢化** — `issue-claim.sh` の stale-steal を、ロック取得後に holder を再読取して検証する compare-and-swap 方式に変更（2セッションが同一 stale claim を両方奪取できる TOCTOU の窓を解消）、PID だけに頼らない PID再利用検出、姉妹スクリプトと対称な eval前検証を追加した。(#1742)
- **`reviewer-registry-drift-check.sh` の診断精度を改善し slug regex の盲点を解消した** — `agents/` 由来のエラーメッセージが `find` の stderr（`EACCES` 等）を握り潰していた問題をソース別分岐で解消し、識別子 regex を拡張して数字入り slug（例: `web3-reviewer.md`）が3つの追跡集合すべてから除外され silent pass する盲点を塞いだ。(#1762)
- **残りの per-call hook にあった `@tsv`+`IFS` read の field-shift hazard を統一** — #1737 での `bang-backtick-edit-hook.sh` 修正に続き、`session-start.sh` の `_reset_active_state()` 等でも unit separator（`\x1f`）による join/read に統一し、空の中間 TSV フィールドが後続フィールドを左シフトしてしまう問題を解消した。(#1767)

### 削除

- **実挙動に一切効果のなかった設定項目2件を削除**: `fix.fail_fast_response`（消費側で一度も参照されず、テンプレート自身が「効かない」と自認していた）、`review.scope_assignment.enabled`（消費側は `auto_demote_low` を直接読み取り `enabled` を一度も参照しておらず、ドキュメント上の opt-out は機能していなかった）。`auto_demote_low` 自体は配線済みのまま影響を受けない。(#1727)

## [0.7.2] - 2026-07-01

### 修正

- `disable-model-invocation: true` を user-invocable スキル14件（`issue-create`・`issue-update`・`issue-close`・`issue-edit`・`wiki-init`・`wiki-query`・`learn`・`skill-suggest`・`template-reset`・`getting-started`・`workflow`・`investigate`・`resume`・`run`）から削除。Claude Code CLI はユーザーが明示的に入力したスラッシュコマンドとモデル自身の Skill ツール呼び出しを同一経路で扱うため、画像添付時などネイティブなスラッシュコマンド dispatch と認識されない場合にモデル側の Skill ツールフォールバックが同フラグに阻まれ、ユーザー自身の直接起動が失敗する不具合があった（[anthropics/claude-code#43660](https://github.com/anthropics/claude-code/issues/43660) 参照）。`workflow`・`investigate` の description には同フラグが担っていた非 auto-activate 文言を補強した。(#1694)

### 変更

- `reviewers/SKILL.md` の frontmatter に `user-invocable: false` を追加し、`docs/SPEC.md` の frontmatter ポリシー表第3区分の記述を実態に合わせて是正した：`user-invocable: false` が `/rite:<name>` 不在を担保し、`disable-model-invocation` は broad description を持つスキルの auto-activate 抑止に使う、という役割分担を明記した。(#1696)

## [0.7.1] - 2026-06-30

### 追加

- 紹介動画の HyperFrames ソースを本リポジトリ管理下（`media/intro-video/`〔日本語〕・
  `media/intro-video-en/`〔英語〕）に取り込み、リポ外ディレクトリではなく当リポ内で
  動画更新が完結するようにした。各プロジェクトにビルド手順・BGM の出所/ライセンスを
  記載した `PROVENANCE.md` を同梱。(#1688)

### 変更

- 紹介動画の内容と README の動画リンクを v0.7.0 仕様へ更新：コマンド名を v0.7 の
  フラットなハイフン記法（`open`・`iterate`・`ready`・`merge`・`cleanup`・
  `issue-create`）に統一し、`scene-goal` を `/rite:run --merge` の自走デモへ差し替え、
  Doc-Heavy PR Mode を扱う `scene-docheavy` シーンを新規追加、README の動画尺記述を
  約115秒へ変更した。(#1688)

## [0.7.0] - 2026-06-30

### 変更

- **ワークフローのエントリポイントを `commands/` からネイティブな Claude Code スキル（`skills/`）へ移行** — 旧 `commands/<group>/<name>.md` は Claude Code が自動検出する `skills/<name>/SKILL.md` に統合され、orchestrator スキル（`open`・`iterate`・`run` 等）が sub-skill（`review`・`fix`・`pr-create`・`issue-implement` 等）を Skill ツール経由で呼び出す構造になった。**破壊的変更 — 起動名前空間がフラット化**：旧グループコロン形式は廃止し、フラットなスキル名で起動する。移行: `/rite:pr:open` → `/rite:open`、`/rite:pr:review` → `/rite:review`、`/rite:pr:create` → `/rite:pr-create`、`/rite:issue:create` → `/rite:issue-create`、`/rite:wiki:ingest` → `/rite:wiki-ingest`（残りの `pr:` / `issue:` / `wiki:` コマンドも同様）。(#1682)
- **SessionStart フックの CRITICAL バナーを `/rite:resume` 案内へ降格** — preflight 機構の削除に伴い、compact 後の回復を無条件の CRITICAL セッション開始ブロックではなく `/rite:resume` に一本化した。(#1682)

### 削除

- **`commands/` ディレクトリを全廃（42 ファイル）** し旧グループ命名を一掃。`skills/` がエントリポイントと実行手順書の単一ソースとなり、`lint` scanner は `commands/` から `skills/` へ repoint した。(#1682)
- **`preflight-check.sh` 機構を削除** — 責務を `/rite:resume` へ統合し、アーキ図と README から Preflight Check の記述を削除した。(#1682)

## [0.6.12] - 2026-06-29

### 修正

- **`multi_session.enabled: true` で作業ブランチが実在するのに session worktree が不在な状態を、フロー入場経路が検出・再構築するようになった** — 作業ブランチがローカルに実在しても session worktree（`.rite/worktrees/issue-{N}`）が不在だと、`/rite:resume`・`/rite:pr:review`・`/rite:pr:iterate`・`/rite:pr:fix` が当該ブランチを存在しない扱いにして `develop` へ silent fallback し、PR 変更を作業ツリーから読めない degraded 動作に陥っていた。`lib/worktree-git.sh` に追加した `ensure_session_worktree` ヘルパーが「ブランチ実在 ∧ session worktree 不在」を検出し worktree を再構築する（local: `git worktree add` / remote: fetch + `--track`）。(#1676, #1677)

## [0.6.11] - 2026-06-28

### 修正

- **`/rite:pr:cleanup` がクリーンアップ対象 Issue の worktree・ブランチ削除を自己ブロッキングする問題を修正** — cleanup の live-cwd guard (`worktree-live-cwd.sh`) は cleanup 実行セッション自身の作業ディレクトリと他セッションを区別できず、自セッションを「live」と検出して削除を遅延させていた。self プロセス木を除外する新しい probe (`worktree-foreign-cwd.sh`, `--self-root`) を導入し、削除遅延は別の live セッションが実際に在席する場合のみに限定した。真に遅延したブランチ（従来は回収経路を持たず永久残置）は reap manifest に記録して次セッションで回収するようにし、未マージ/dirty なブランチは保護を維持する。(#1670, #1671)

## [0.6.10] - 2026-06-26

### 修正

- **multi-session worktree モードで `/rite:wiki:ingest` の raw source 書込先を commit の scan ルートに統一** — `multi_session.enabled: true` のとき、`wiki-ingest-trigger.sh` が raw を `$PWD` 相対の `.rite/wiki/raw/`（セッション worktree 側）へ書き込む一方、`wiki-ingest-commit.sh` は main checkout の `.rite/wiki/raw/` を scan していたため、セッション worktree から収集した raw source が wiki ブランチに commit されず silent に取りこぼされていた。両者が同一の scan ルートを解決するようにした。(#1664, #1665)
- **corrupt/orphaned な `.rite/wiki-worktree` から raw source 蓄積が自己回復** — リポジトリ移動などで gitdir ポインタが stale 化した孤児 `.rite/wiki-worktree` が `[ -d ]` fast-path を通過しつつ `git rev-parse` に失敗し、raw source 蓄積を silent に停止させていた。silent 停止を廃止し自己回復するようにした。(#1662, #1663)
- **罫線 box がヘッダーに全角文字を含むとき右罫線がずれる問題を修正** — 右罫線のパディングをコードポイント数で詰めていたため、全角（East Asian Width `W`/`F`）文字で内側幅が広くなっていた。全角を 2 桁として上罫線の `─` 本数に内側幅を一致させるようにし、ルールを `references/box-display-width.md` に SoT 化した。(#1660, #1661)

## [0.6.9] - 2026-06-25

### 修正

- **`.claude/scheduled_tasks.lock` を gitignore して untrack した** — Claude Code ハーネスがセッションごとに上書きするこのセッション固有 lock ファイルが tracked のままだと working tree が常に dirty になり、`pull.rebase=true` 環境で `git pull` が abort していた。`.claude/skills/release/SKILL.md` は意図的に commit しているため、`.claude/` 全体ではなくファイル単位で除外する。(#1654, #1655)

## [0.6.8] - 2026-06-24

### 修正

- **release skill の Phase 1 最新タグ判定を到達可能性非依存にし、リリースタグ形式 `vX.Y.Z` に限定した** — `git describe --tags --abbrev=0` の代わりに `git tag --sort=-v:refname` を `grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'` でフィルタし（事前に `git fetch --tags --force` を実行）、最新リリースタグが `develop` から到達できない `main` マージコミット上にあっても正しく取得でき、非リリースタグはバージョンソートから除外される。(#1643, #1647)
- **release skill の Phase 1 タグ同期が silent に失敗しなくなった** — `git fetch --tags --force` が失敗した場合、エラーを握り潰さずログを 1 行出力してローカルのタグで続行する。(#1648)

### ドキュメント

- **release skill で `git tag … | head -1` の SIGPIPE が benign である旨を明記した** — 末尾の `head -1` が pipe を早期に閉じ得るが、`latest_tag` は `[ -n "$latest_tag" ]` でガードされ pipeline の終了コードは参照されない。この点を注記し、将来 `set -o pipefail` を導入する際の注意点も明示した。(#1649)

## [0.6.7] - 2026-06-24

### 修正

- **`cleanup.md` の親 Issue 検出が、クローズ対象 Issue 自身や無関係な Issue を親と誤検出しなくなった** — Tasklist fallback が複数候補を取得し、自己マッチを除外し、各候補の body に実際の `- [ ] #N` / `- [x] #N` tasklist 行が存在するか再検証するようになり、GitHub code search の先頭ヒットを盲目採用しなくなった。(#1637)
- **`projects-integration.md` と `close.md` の tasklist search による親 Issue 検出が、自己マッチや無関係な Issue を親と誤検出しなくなった** — 複数候補を取得し、自己マッチを除外し、候補 body を検証してから親を採用するようになった。(#1634)
- **`/rite:pr:open` が `open.md` で親 Issue の GitHub Projects ステータス更新を表面化** — Sub-Issue に着手すると親 Issue のステータスが Todo のままにならず In Progress へ遷移する。(#1630)
- **`projects-integration.md` の standalone 時の親未検出ハンドリングの内部矛盾を解消** — silent skip を禁止するルールに合わせ、skip 前に必ず `[DEBUG] parent not detected` ログを emit するよう統一した。(#1636)
- **standalone 時の親未検出 DEBUG 文言を `close.md`・`projects-integration.md`・`open.md` の 3 サイトで `methods tried:` に統一** — 3 サイトが逐語一致する診断を emit するようになった。(#1635)

## [0.6.6] - 2026-06-24

### 修正

- **GitHub Projects 登録の owner type 判定を撤廃し、Organization 所有の Project に対応** — owner type の事前判定が Organization 所有 Project で失敗していたため、判定を撤廃し user 所有・organization 所有の双方が登録できるようにした。(#1612)
- **GitHub Projects のフィールド名を英日エイリアス + config 上書きで解決し、日本語名 Project に対応** — `Status`/`ステータス` などのフィールド検索が、日本語フィールド名の Project でも追加設定なしで成功する。(#1614)
- **PR cleanup の worktree 検出を物理 cwd ベースに頑健化** — flow state に未記録の worktree が残置していた問題を解消。(#1623)
- **`cleanup.md` のアンカーリンクを main-checkout に修正。**(#1611)

### 変更

- **graphql-helpers の owner type 判定ドキュメントを repository() 非依存の経路に更新** — `repository()` に依存しなくなった登録ロジックにドキュメントを整合させた。(#1615)

## [0.6.5] - 2026-06-22

### 修正

- **`/rite:pr:cleanup` と `/rite:pr:open` の base ブランチ更新を `git pull --ff-only` から `git fetch` + `git merge --ff-only` 方式へ変更** — `pull.rebase=true` かつ作業ツリーが dirty な consumer 環境では、`git pull --ff-only` でも `git pull` が rebase 経路の前処理（clean working tree を要求）に入るため `cannot pull with rebase: You have unstaged changes` で early-abort していた。更新を `git fetch origin {base}` + `git merge --ff-only origin/{base}` に分離することで rebase 経路を一切通らず、fast-forward 可能なら `pull.rebase` 設定や作業ツリーの状態に関係なく base ブランチが確実に更新される。`cleanup.md` の `multi_session` / legacy 両パス、`open.md` のブランチ作成チェーン（`git switch -c` までの `&&` チェーンを維持）、`getting-started.md` / `docs/SPEC.md` の説明に適用。(#1602)

## [0.6.4] - 2026-06-20

### 修正

- **`multi_session.enabled: true` でのブランチ作成 worktree 隔離を hard invariant 化** — `/rite:pr:open` のブランチ作成直前に `multi_session` を `rite-config.yml` から再パースし（resume / context 圧縮 / フロー途中入場で失われうる `[CONTEXT]` marker への依存を排除）、legacy の `git switch -c` 経路は `multi_session.enabled: false` のときのみ到達可能にした。`EnterWorktree` 後にリポジトリ top-level が worktree path と一致するか検証し、不一致なら main ツリー上で silent 続行せず停止する。`flow-state.sh set --require-worktree` は worktree 不在で branch/PR phase を記録しようとした場合に loud warning を emit する。(#1596)

## [0.6.3] - 2026-06-19

### ドキュメント

- README を二言語構成に再編: `README.md`（英語・英語版紹介動画）と新設の `README.ja.md`（日本語・日本語版紹介動画）を、各冒頭の言語切替リンクで相互リンク (#1585, #1587)

## [0.6.2] - 2026-06-19

### ドキュメント

- README 冒頭に紹介動画（日本語字幕）の Demo セクションを追加 (#1580)

## [0.6.1] - 2026-06-18

### 修正

- **`EnterWorktree` の harness git 誤判定失敗時に再起動 remedy を案内** — `multi_session.enabled: true`（デフォルト）で `/rite:pr:open` Step 2.3-W および `/rite:resume` 再入場が harness の git リポジトリ誤判定（`.git` 存在 + `git` CLI 正常だが起動時判定が false）を検出し、リポジトリ root から Claude Code を再起動して作成済み worktree を `WT_CASE=reuse` で継続するよう推奨するようにした。従来の「中止 / `git switch -c`」二択のみだった fallback を改善。`getting-started.md` / `git-worktree-patterns.md` に記載。(#1574)

## [0.6.0] - 2026-06-18

### 追加

- **実装フェーズの Canon TDD サイクル** — `tdd.enabled: true`（デフォルト ON）のとき、`/rite:issue:implement` は実装を Canon TDD ループで進める: テストリストから 1 つ選ぶ → Red を確認 → 最小実装で Green → Refactor → リストが空になるまで繰り返す。graceful degrade に対応し、`commands.test: null` では「Degraded TDD」モード（テストリスト規律は維持・自動実行は警告付きで skip）、`tdd.enabled: false` では従来の非 TDD フローに戻る。(#1567)
- **`tdd:` 設定セクション（デフォルト ON / opt-out）** — 配布版 `rite-config.yml` に `enabled: true` の `tdd:` セクションを追加。`/rite:init --upgrade` は `wiki` / `multi_session` と同じ active-section 方式で既存プロジェクトにも back-add する。(#1566)
- **Canon TDD のドキュメント整備とテストリスト framing** — Issue テンプレートの Section 6「Test Specification」を Canon TDD のテストリスト（T-xx 1 行 = 1 サイクル Red→Green→Refactor）として位置づけ、`skills/rite-workflow`・`docs/SPEC.md`・getting-started・`pr/open.md` に TDD サイクルを反映。(#1568)

## [0.5.5] - 2026-06-17

### 修正

- **`bang-backtick-check.sh` が消費側 repo をハードブロックしなくなった** — `--skip-if-no-target` フラグを追加し、`--all` で走査対象の `plugins/rite/` markdown が無いとき（マーケットプレイス参照のみの消費側 repo）に `rc=2`（invocation error）ではなく clean skip（rc=0）を返すようにした。これにより `/rite:pr:ready` / `/rite:pr:create` での強制手動バイパスを解消。self-host repo では従来の `rc=2` 誤設定診断を維持。(#1551)
- **active-but-idle なセッション worktree を lazy reap から保護** — `pr-cycle-cleanup.sh` が、claim heartbeat が stale 化（`CLAIM_STALE_SECONDS` 超のアイドル）していても claim holder が `active=true` の worktree を reap しないようにし、resume 時の `/clear` "Path does not exist" 再発を防止。(#1553)
- **read-only コマンドが実出力を再びリレーするようにした** — `/rite:issue:list` / `/rite:investigate` / `/rite:workflow` / `/rite:skill:suggest` から `context: fork` を除去し、ハーネスの制御ラッパー文ではなくコマンド本来の出力を inline 表示するようにした。(#1556)
- **`orphan-reference-check.sh --all` がセッション worktree 内で動作するようにした** — `--all` の走査を `REPO_ROOT` 相対にし、`.rite/worktrees/issue-N` worktree から実行しても全ファイルが除外され `exit 2` になる問題を解消。デフォルト構成（`multi_session.enabled: true`）で orphan 検出を復活。(#1557)

## [0.5.4] - 2026-06-16

### 追加

- **Wiki concept ページの OKF v0.1 最小準拠** — concept ページの frontmatter に `type` と `okf_version` フィールドを追加し、Wiki を Open Knowledge Format v0.1 に整合させた。
- **OKF v0.1 同期と上流 visualizer 連携の手引き** — OKF v0.1 準拠の同期手順と上流 visualizer との連携手順をドキュメントに追加。

### 変更

- **`/rite:pr:run` のデフォルトを draft 止まりに変更** — デフォルトで `open → iterate`（draft で停止）を実行し、`ready → merge → cleanup` は `--merge` フラグでオプトインするようにした。
- **Wiki `index.md` を OKF 箇条書き形式へ reshape し query を 2-pass 化** — `index.md` が OKF 箇条書き構造を採用し、`wiki:query` が 2 パスで解決するようにした。
- **Wiki `log.md` を OKF 形式へ reshape** — `log.md` が OKF 構造を採用し、`ingest:skip` 状態を raw frontmatter へ移行した。

### 修正

- **`wiki:close` の heredoc 書き込み失敗ガード** — `close.md` Phase 4.4.W が heredoc の書き込み失敗をガードし、review/fix パスと対称化した。
- **`/rite:pr` review/fix の `$trigger_exit` defensive default** — Step 3 が `$trigger_exit` に defensive default を付与するようにした。
- **live プロセスを持つ worktree を `/clear` の "Path does not exist" から保護** — live プロセスが立つ worktree を保護し、`/clear` 時の "Path does not exist" エラーが再発しないようにした。

## [0.5.3] - 2026-06-14

### 追加

- **`/rite:pr:run`** — 複数 Issue に対して `open → iterate → ready → merge → cleanup` を順次・自律的に実行する PR ライフサイクル一括コマンド。
- **`/rite:lint` の番号参照ガード** — number-free に保つ対象面（`CHANGELOG.md`・`CHANGELOG.ja.md`・`lint.md`）へ再混入した Issue/PR 番号参照（`#NNN`・`Issue #NNN`・`PR #NNN`）を検出する `number-reference-check.sh` lint（非ブロッキング警告）を新設し、整理済みの対象面の再発を防ぐ。

### 修正

- **並行セッションが互いの flow state を汚染しなくなった** — `session_id` の解決を env-first 化し、同時実行セッションが共有 `flow_state` を上書きせず別個の識別子を解決するようにした。
- **`/rite:pr:cleanup` が一時ブランチ・worktree を名前非依存で回収する** — 作成した成果物の探索・削除がブランチ/worktree の命名に依存しなくなった。
- **使用中セッションの worktree を reap から保護** — lazy reap がアクティブなセッションに属する worktree をスキップし、`/clear` が dangling なセッション状態を自己修復するようにした。
- **`drift-check` の過検出を除去** — 誤検出をなくし、check が発行するドキュメント欠落 reason を整合させた。
- **`decompose-issues.sh` が空の `labels_csv` でクラッシュしなくなった** — Sub-Issue 作成が空のラベル集合を扱えるようにした。
- **`/rite:pr:merge` の成功パスが固定の `exit 0` で終了する** — 末尾の no-op により、成功パスが非ゼロの終了ステータスを引き継がないようにした。

### 変更

- **`wiki:ingest` の書き込み失敗処理** — 書き込み失敗パスが汎用の失敗 reason ではなく専用の `content_write_failed` reason を発行するようにした。
- **ドキュメント面を number-free・現在形に統一** — ユーザー対面の設定/ドキュメント、仕様・設計ドキュメント、コマンド/スキル/フック/スクリプトのコメント、テストから、暗黙の歴史依存表現（「従来の挙動」「以前の方式」など）と Issue/PR 番号参照を除去し、根拠を散文で直接述べるようにした。CHANGELOG の歴史依存表現の取扱方針をファイル冒頭に明文化。
- **アカウント移管** — リポジトリのアカウント移管に伴い `B16B1RD` 参照を `asakaguchi` へ更新。

### 削除

- **README の v0.4.0 Breaking Changes セクション** — 歴史的役割を終えたアップグレード告知を README から削除。

## [0.5.2] - 2026-06-12

### 修正

- **`/rite:init --upgrade` の短絡経路が drift back-add を取りこぼす問題を解消** — pending drift が検出されない場合の `--upgrade` 短絡経路が、full path で行う back-add ステップをスキップしていたため、短絡経路を通る既存プロジェクトで新規追加された config セクション・サブキーが取りこぼされていた。短絡経路でも同じ drift back-add ロジックを適用するよう修正し、drift 検出テストを追加した。
- **存在しない `_resolve-flow-state-path.sh` への壊れた参照を修正** — hooks ドキュメント内の stale なスクリプト参照を実在する `flow-state.sh` のパスへ更新した。

### 変更

- **flow state を per-session モデルに一本化** — legacy な `flow_state.schema_version=1`（単一ファイル）経路を hooks（`session-start` / `session-end` / `post-compact` / `pre-compact` / `post-tool-wm-sync`）・`init.md`・config テンプレートから撤去し、per-session flow state に統合した。stale な `schema_version` テスト fixture/ラベルを中立化、SPEC の Deprecated key 一覧に `commit.contextual` を追加、`--upgrade` の drift back-add 挙動変更に `SPEC.md` / `getting-started.md` を追従させた。

## [0.5.1] - 2026-06-12

### 修正

- **`/rite:init --upgrade` が最新の config デフォルトに追従するよう修正** — `--upgrade` が新規トップレベルセクション・既存セクション内の新規サブキー・`multi_session` ブロックを取りこぼし、アップグレード済みプロジェクトが新規 `/rite:init` の生成結果から乖離する二層挙動を解消した。`--upgrade` は `multi_session` を `enabled: true` で back-add（明示的な `false` は保持・冪等）し、欠落したサブキーのみを template default で補完して既存の兄弟値は preserve、新規トップレベルセクションは drift アンカーで追従する。サブキーマージの drift 検出テスト（T-12）を新設し、共有ハーネス `_test-helpers.sh` に統一した。`commands/getting-started.md` に `--upgrade` の `multi_session` back-add 挙動を追記した。

## [0.5.0] - 2026-06-12

### 追加

- **セッション worktree による作業分離** — `multi_session` 設定、`EnterWorktree` によるセッション別 worktree 作成、resume 再入場、cleanup 時の遅延 reap。デフォルト ON 化（opt-in → デフォルト）。
- **Issue claim 機構**（`issue-claim.sh`）— 同一 Issue の二重着手を防ぐ fail-fast ガード。
- **`/rite:learn`** — 完了した Issue/PR セッションの理解度を Socratic 方式で確認するコマンド。
- **仮定表面化（Assumption Surfacing）ステップ**を `/rite:issue:create` に追加 — 暗黙の仮定を表面化し derive / ask / defer に分類。
- **知識ルーティング（4 チャネル）** を coding-principles に追加。コメントの why-over-what と却下案ルーティング基準。
- **レビュー scope 分類** — `scope` / `pre_existing` / `acknowledged` フィールド（review-result-schema 1.1.0）、推奨事項 3 分類、Phase 7 post-condition gate。
- **Wiki lint ヘルパースクリプト**（機械判定 3 カテゴリ）+ 並行 ingest 排他（セッション lock + push リトライ）。
- **`/rite:lint` の新ガード** — ハードコード行番号 drift、CLOSED+COMPLETED board 非 Done drift、operational bash ブロック heaviness。
- Artifacts schema 1.1.0 マイグレーションスクリプト + version-drift hook。

### 変更

- 新規プロジェクトで `multi_session.enabled` のデフォルトを `true` に変更。
- commands / references / templates 全体での Source-of-Truth 統合（Type crosswalk、contract section mapping 等）。
- reviewer base / severity-levels に Scope Assignment 責務を追加。

### 修正

- review-fix ループ、hooks（flow-state マルチステート API、旧 `.rite-flow-state` migration、bang-backtick ガード、drift-check）、Issue/PR オーケストレーション、Wiki ingest/query 全体にわたる安定化（v0.4.0 以降 300 件超の修正を統合）。

> 本リリースは大規模な統合リリース（v0.4.0 以降 644 コミット）。エントリはプロジェクトの CHANGELOG ポリシーに従い feature レベルで要約している。

## [0.4.0] - 2026-04-22

### 破壊的変更

- **サイクル数ベースの review-fix 縮退を全廃し、品質シグナル 4 要素に刷新** — **BREAKING CHANGE**
  - **削除された設定キー** (`rite-config.yml` から 3 キー削除。これらのキーは `plugins/rite/templates/config/rite-config.yml` には元々存在していなかった):
    - `review.loop.severity_gating_cycle_threshold`
    - `review.loop.scope_lock_cycle_threshold`
    - `safety.max_review_fix_loops`
  - **削除されたロジック**:
    - `plugins/rite/commands/pr/references/fix-relaxation-rules.md` の convergence strategy override テーブル (`severity_gating` / `scope_lock` / `batched` を strategy として扱う表) と Loop Termination の hard limit 行。
    - `plugins/rite/commands/pr/fix.md` Phase 0.4 Convergence Strategy Load (`.rite-flow-state` から `convergence_strategy` を読み込むブロック全体)。
    - `plugins/rite/commands/issue/start.md` Phase 5.4.6 Step 3.5 Review-Fix Loop Hard Limit Check (`上限延長 (+5) / 本 PR 内で再試行 / escalate` の 3 択ダイアログ)。
    - `plugins/rite/commands/issue/start.md` Phase 5.4.1.0 のサイクル trajectory パターン分析 (Converging / Stalled / Diverging / Oscillating) と `convergence_strategy` の `.rite-flow-state` 書き込み。
  - **新しい挙動**: review-fix ループは 2 つの出口しか持たなくなった — (a) 0 findings → `[review:mergeable]` / (b) 4 品質シグナルのいずれか発火 → `AskUserQuestion` escalate (`本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション`)。サイクル数による hard limit は完全に存在しない。
  - **4 つの品質シグナル**:
    1. 同一 finding 循環 — `start.md` Phase 5.4.1.0 で `file + category + normalize(message)` の SHA-1 fingerprint により検出。1 回の再出現で escalate。
    2. root-cause 不明 fix — `fix.md` Phase 3.2.1 で commit body に `root-cause(scope):` action line または `decision(scope):` で root cause を明示した行があるかを LLM が意味的に判定。欠落時は AskUserQuestion で「Root cause を追記して再コミット（推奨）/ 意図的な補足コミットとして通過 / Abort」の 3 択。
    3. cross-validation 不一致 — `review.md` Phase 5.2 で 2 人以上の reviewer が同一 `file:line` に severity 2 段階以上の差異で指摘し、debate でも解消しない場合に escalate。
    4. finding quality gate 不通過 — `_reviewer-base.md` に新規追加された `Finding Quality Guardrail` が bikeshedding / 防衛コード / hypothetical / style-only findings を output 前にフィルタ。survivor が 0 件になった reviewer は `### Reviewer self-assessment` セクションで "degraded" を明示的に self-report し escalate する。
  - **finding fingerprint 仕様**: `sha1(normalize(file_path) + ":" + category + ":" + normalize(message))`。identifier マスキングと Jaccard token 類似度 > 0.7 による near-match 検出を含む。完全仕様は `start.md` Phase 5.4.1.0 を参照。
  - **minor version bump**: 0.3.10 → 0.4.0 (6 version files 同期)。
  - **削除キーの扱い**: 削除済み 3 キーは runtime で silent に無視される。これらに対する `/rite:lint` の deprecation scan や警告は行われない。
  - **サイクル数の安全上限は設けない (意図的)**: 非公開ガードを含めて cycle-count ベースの上限は一切存在しない。4 品質シグナルが唯一の終了メカニズムとして設計されており、隠し iteration counter の導入は本リリースのコア目的 (サイクル数縮退の全廃) と矛盾するため採用しない。

### 移行ガイド

`rite-config.yml` に以下のいずれかが残っている既存ユーザーは該当行を削除してください:

```yaml
# 以下 3 キーをすべて削除:
review:
  loop:
    severity_gating_cycle_threshold: 5
    scope_lock_cycle_threshold: 7
safety:
  max_review_fix_loops: 7
```

v0.4.0 では値は silent に無視されます。機能的な代替はありません — 非収束は 4 つの品質シグナルが自動検出するため、サイクル数の閾値設定は不要になりました。

これまで `max_review_fix_loops` の hard limit で暴走ループから脱出していた場合、同等の安全性は Quality Signal 1 (fingerprint 循環検知) が提供します。**2 回目**の同一 finding 出現で発火するため、cycle-count による抑制よりも早く escalate します。

### 変更

- **レビュー修正サイクル 根本見直し (Fail-Fast Response + 別 Issue 化ユーザー確認必須化 + 設定層)** — **BREAKING CHANGE** (ロールアウトの最終層。原則ドキュメント層・reviewer 出口層・Fact-Check 拡張層に続く最終 PR)。`fix` 応答層と設定層を先行 3 層に接続し、review-fix サイクルの根本見直しを完成させる。
  - `plugins/rite/commands/pr/fix.md` Phase 2 冒頭に **Fail-Fast Response Principle** 節を追加。修正方針決定前に 4 項目チェックリスト (throw/raise 伝播 / 既存エラー境界 / null チェックが隠蔽でないか / テスト側修正が正しくないか) を通過させる。fallback 採用時は commit message に選択理由を明示させ、無思考な防御コード追加を Phase 5 re-review で再検出する運用へ変更。
  - `plugins/rite/commands/pr/fix.md` Phase 4.3.3 から **E2E `AskUserQuestion` スキップを撤廃**。別 Issue 化は呼び出し元 (E2E `/rite:issue:start` ループ / standalone) を問わず常にユーザー確認必須。オプションは `本 PR 内で再試行 / 別 Issue 化 / 取り下げ` の 3 択に統合され、いずれも `findings == 0` に収束するため review-fix ループの終了条件は維持される。
  - `plugins/rite/commands/pr/fix.md` および `plugins/rite/commands/issue/start.md` から `"severity_gating"` convergence strategy を **廃止**。本 PR 起因 findings は severity 問わず本 PR 内で対応する方針（本 PR 完結原則）に統一。`rite-config.yml` の `fix.severity_gating.enabled` は後方互換のためキー自体は残置しているが `false` 固定扱い。非収束時は fix.md Phase 4.3.3 の `AskUserQuestion` ルートに統合。非収束対応は `"batched"` / `"scope_lock"` strategy を使用してください。
  - `plugins/rite/templates/config/rite-config.yml` に **設定 scaffolding キー** 追加 (宣言のみ、runtime wiring は follow-up): `review.observed_likelihood_gate.*`, `review.fail_fast_first.*`, `review.separate_issue_creation.*`, `fix.fail_fast_response`。`fix.severity_gating.enabled: false` は deprecated compatibility shim として残置され、実際に `false` 固定扱いで honored される。**既知の制限**: 非 deprecation 系の scaffolding キー (`observed_likelihood_gate`, `fail_fast_first`, `separate_issue_creation`, `fail_fast_response`) は `commands/` / `agents/` / `skills/` / `hooks/` 内で条件分岐として **まだ参照されていない**。新しい挙動 (Fail-Fast Response Principle、別 Issue 化の常時確認) は `fix.md` Phase 2 / Phase 4.3.3 の prose にハードコードされており、現時点では config で無効化できない。これらのキーは意図された設定面をユーザーに示すために提供されており、条件分岐への配線は follow-up Issue として追跡される。
  - `plugins/rite/i18n/{ja,en}/pr.yml` に i18n メッセージキー 4 件追加 (`review_fail_fast_first_warning`, `review_observed_likelihood_demotion_notice`, `review_separate_issue_user_confirmation_question`, `fix_fail_fast_response_checklist_prompt`)。ja/en parity 維持。**既知の制限**: これらのキーは `commands/` / `skills/` / `agents/` 内で `{i18n:key_name}` 経由で **まだ参照されていない**。`fix.md` / `review.md` 内の対応するプロンプトは現時点では直接テキストを埋め込んでいる。call-site 配線は follow-up として追跡される。
  - **移行ガイド**: 既存ユーザーで `fix.severity_gating.enabled: true` を設定していた場合、本キーは silent に `false` 固定扱いとなります。非収束時は fix.md Phase 4.3.3 の `本 PR 内で再試行 / 別 Issue 化 / 取り下げ` `AskUserQuestion` で解決されます。severity 別の自動 defer が必要だった場合は `"batched"` または `"scope_lock"` strategy を採用してください。**Opt-out の制限**: その他の新規 config キー (`observed_likelihood_gate`, `fail_fast_first`, `separate_issue_creation`) は **現時点では opt-out として機能しません** — 新しい挙動は prose に無条件で強制されています。いずれかを無効化するには、wiring PR が landing するまで `fix.md` / `review.md` の対応する prompt セクションを直接編集する必要があります。

- **`/rite:pr:review` の reviewer 呼び出しを named subagent 化** — **BREAKING CHANGE**。`plugins/rite/commands/pr/review.md` で reviewer を `subagent_type: general-purpose` から `subagent_type: "rite:{reviewer_type}-reviewer"` (スコープ付き named subagent) に切り替え。named subagent 呼び出しでは各 reviewer の agent file body (`plugins/rite/agents/{reviewer_type}-reviewer.md`) が sub-agent の **system prompt** として自動注入され、YAML frontmatter (`model`, `tools`) が runtime に反映される。これにより reviewer の役割定義が system prompt レベルで強制され (user prompt 注入では agent body の優先度が低く希釈される問題を解消)、reviewer ごとの model pin (9 reviewer が `model: opus` 固定) が実効化される。13 reviewer の `reviewer_type` → `subagent_type` 対応表を `review.md` に追加。`rite:` プレフィックスが必須であることを実機検証済み (bare 形式 `{reviewer_type}-reviewer` は `Agent type not found` エラーで解決失敗)。**ユーザー影響**: これまで sonnet で reviews を実行していたユーザーは 9 reviewer が強制 opus upgrade となりコスト増加する (個別 agent frontmatter から `model: opus` 行を削除することで opt-out 可能)。詳細な migration guide、opus 推奨の背景、3 つの rollback シナリオ (全 reviewer 解決失敗 / tech-writer Bash 権限喪失 / verification mode 出力形式破綻) は `docs/migration-guides/review-named-subagent.md` を参照
- **`{agent_identity}` プレースホルダを `{shared_reviewer_principles}` にリネーム** — **BREAKING CHANGE** (rite plugin 開発者向け、`review.md` テンプレート編集時に影響)。`review.md` は `_reviewer-base.md` から共通原則 (Reviewer Mindset / Cross-File Impact Check / Confidence Scoring) のみを抽出するよう変更。Part B (agent-specific identity) の抽出ロジックは削除 (named subagent の system prompt が agent 固有の discipline を直接配信するため不要)。これは **hybrid approach** で、agent body → system prompt (named subagent 経由)、共通原則 → user prompt (`{shared_reviewer_principles}` 経由) の 2 経路に分離する。代替案 (13 agent file に共通原則を inline) は `_reviewer-base.md` を単一ソースとして維持するため却下。レビューテンプレートの `## あなたのアイデンティティと検出プロセス` セクションは `## 共通レビュー原則` にリネームしてスコープを反映。Part A bug fix (Cross-File Impact Check の reviewer 到達) を維持する
- **Retry classification に `subagent resolution failure` 行を追加** (`review.md`) — Task ツールが scoped subagent 名を解決できない場合 (例: `Agent type 'rite:code-quality-reviewer' not found. Available agents: ...`) の新規 retry classification エントリ。Retry: **No**。Action: 即 fail、使用した scoped 名とエラーメッセージを表示する。named subagent 化による品質改善効果を損なうため、`general-purpose` への silent fallback は禁止。全 reviewer がこのエラーになる場合は orchestrator が `AskUserQuestion` で対応を確認 (retry / `general-purpose` への一時 rollback / レビュー中止)。判定パターン: Task ツール応答に `Agent type '{scoped_name}' not found` が含まれる

- **docs: develop 実装を SPEC / README / CLAUDE.md / CHANGELOG に反映** — v0.4.0 後の複数 PR によるドキュメント整合化スイープ:
  - Commands 表 + Agent File Format Note — README / README.ja / SPEC / SPEC.ja の Commands 表に `/rite:issue:recall` を追加、README.ja に `/rite:init --upgrade` 行を追加、`subagent_type: general-purpose` の Note を named-subagent 記述に差し替え
  - SPEC の Plugin Structure ツリーを v0.4.0+ 実装に合わせて全面書換 (commands/issue のサブスキル、commands/pr/references、commands/wiki、agents/_reviewer-base、skills/{investigate,wiki}、hooks/{scripts,tests}、templates/{config,review,wiki}、scripts 拡充、references 拡充)、Configuration セクションを `docs/CONFIGURATION.md` ポインタに圧縮、Hook Specification に post-compact / phase-transition-whitelist / verify-terminal-output (削除) / session-ownership / issue-comment-wm-sync / wiki-ingest-trigger + wiki-query-inject / workflow-incident-emit / hook-preamble / helper-scripts のサブセクションを追加
  - CLAUDE.md アーキテクチャ図を刷新、`docs/BEST_PRACTICES_ALIGNMENT.md` を v0.1–v0.3 期の歴史文書として `docs/archive/` 配下に退避
  - CHANGELOG Unreleased を v0.4.0 後の develop 活動で整備
  - repo 全体の version rename 1.0.0 → 0.4.0 (次期リリースは v1.0.0 ではなく v0.4.0 として出す方針)。version ファイル、README バッジ、CHANGELOG [1.0.0] エントリ → [0.4.0]、内部の `v1.0.0` 参照を更新
- **`commands/` 全体で bidirectional backlink format をコロン記法に統一** — `refactor(commands)` によるプロジェクト全体の Wiki 相互参照スタイル整列 および `wiki/ingest.md` / `wiki/lint.md` の既存 DRIFT-CHECK ANCHOR ブロックに bidirectional backlink エントリを追加。
- **semantic anchor 移行** — `commands/init.md:145` と `hooks/scripts/gitignore-health-check.sh:298` に残存していた line 番号 literal を将来の編集に耐性のある semantic anchor に置換。
- **`/rite:wiki:lint` `--auto` 早期 return の整列** — Phase 1.1 / 1.3 の早期 return 経路を Phase 9.2 三点セット規約に整合させ、sentinel / status-line / continuation-hint の出力を統一。
- **Wiki スキル整備** — `skills/wiki/SKILL.md` EN description を canonical と整列、`wiki/lint.md` 完了レポート UX 出力順を canonical frontmatter 順に整列。

### 追加

- **workflow incident 自動 Issue 登録機構** — `/rite:issue:start` が実行中に発生する workflow blocker (Skill ロード失敗 / hook 異常終了 / 手動 fallback 採用) を自動検出し、Issue として登録することで silent loss を防止する機構を追加。新規 `plugins/rite/hooks/workflow-incident-emit.sh` が sentinel パターン (`[CONTEXT] WORKFLOW_INCIDENT=1; type=...; details=...; iteration_id=...`) を skill 内部 failure path および orchestrator fallback prompt から emit。`start.md` の新規 workflow incident 検出ロジックが context grep で sentinel を検出し、`AskUserQuestion` で確認した上で既存の `create-issue-with-projects.sh` を `Status: Todo / Priority: High / Complexity: S / source: workflow_incident` で呼び出す。同 session 内の同 type incident は重複排除。登録失敗は non-blocking。新規 `workflow_incident:` 設定セクションでデフォルト有効 (`enabled: false` で opt-out)。`plugins/rite/hooks/tests/workflow-incident-emit.test.sh` に 11 件の単体テストを追加。AC-1 ~ AC-10 を全て実装 (Skill ロード失敗 / hook 異常終了 / 手動 fallback 検出、重複制御、default-on、opt-out、recommendation flow 非干渉、non-blocking エラーハンドリング)。過去の PR cycle で発覚した meta-incident (Skill loader bug が Edit ツール手動 fallback で silent に bypass された問題) が直接の動機
- **tech-writer Critical Checklist 具体化** — 文書-実装整合性 5 項目を追加: `Implementation Coverage`, `Enumeration Completeness`, `UX Flow Accuracy`, `Order-Emphasis Consistency`, `Screenshot Presence`。各項目に Grep/Read/Glob での検証手段を併記し、内部のドキュメント中心 PR 事例 (private repository, organization name redacted) を出典とする Prohibited vs Required Findings テーブルにサンプル行 3 件を追加
- **internal-consistency.md reference 新設** — `fact-check.md` (外部仕様) と対の内部事実検証プロトコル。5 項目の Verification Protocol、Confidence 80+ ゲート、severity マッピング、および `tech-writer.md` / `review.md` / 関連 agent ファイルを参照する Cross-Reference セクションを定義
- **Doc-Heavy PR Detection** — `review.md` でドキュメント中心 PR を自動判定 (判定式: `(doc_lines / total_diff_lines >= 0.6)` または `(doc_files_count / total_files_count >= 0.7 かつ total_diff_lines < 2000)`)。rite plugin 自身の `commands/`, `skills/`, `agents/` 配下の `.md` **および `plugins/rite/i18n/**` 配下の `.md` / `.mdx` 翻訳ドキュメント**は除外 (prompt-engineer 専管 / dogfooding artifact。`plugins/rite/i18n/` 配下の `.yml` / `.json` / `.po` など非 Markdown の翻訳リソースはそもそも `doc_file_patterns` の分子候補に含まれないため除外処理は no-op)。`rite-config.yml` に optional schema `review.doc_heavy.*` (キー: `enabled`, `lines_ratio_threshold`, `count_ratio_threshold`, `max_diff_lines_for_count`) を追加
- **Doc-Heavy Reviewer Override** — `{doc_heavy_pr == true}` のとき tech-writer を recommended → mandatory に昇格、code-quality を co-reviewer 追加。追加経路は以下の 3 つで構成され、最終状態は常に ≥2 reviewers が保たれる:
  - **Normal path**: diff 内に fenced code block (` ```bash ` / ` ```yaml ` / ` ```python ` 等) が検出された場合に追加。純粋散文 PR ではこの経路は発火しない
  - **Fail-safe path**: diff スキャン自体が失敗した場合 (`git diff` IO エラー / grep IO エラー等)、fenced block 検出有無に関係なく追加 (検出シグナル不在時の検証強度維持)
  - **Fallback path**: fenced block が検出されず Doc-Heavy override で追加されなかった場合、sole-reviewer guard が後段で fallback として追加する

  tech-writer に `{doc_heavy_pr=true}` フラグを伝達し、`internal-consistency.md` の 5 カテゴリ verification protocol (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) を mandatory 化、各 finding に `Evidence:` 行を必須化、`review.md` の Doc-Heavy post-condition check で検証
- **`/rite:pr:fix` に PR URL / comment URL 直渡しサポート** — `/rite:pr:fix` が PR 番号に加え PR URL / コメント URL 引数を受け付け、`/verified-review` など外部レビューツールのコメントから直接 findings をパースして fix ループに投入可能に。受理可能な URL 形式は trailing path (`/files`)、query string (`?tab=files`)、fragment (`#diff-...`) を含み、すべて引数 ingest 時に正規化される。対象コメントには最低 4 カラム (optional 5 列目 confidence) の markdown テーブルが必要。詳細な引数仕様・ヘッダー検出キーワード・severity 別名マッピングは `plugins/rite/commands/pr/fix.md` の引数パース関連セクションを参照
- **`[fix:pushed-wm-stale]` 出力パターン** — `/rite:pr:fix` が work memory 更新で soft failure を検出した場合に新規出力する。発火条件は `commands/pr/fix.md` の reason 表と 1:1 対応しており、以下に自然言語表現と `reason` ラベルの mapping を示す。完全な一覧は reason 表参照:
  - `current_body` 空 → `current_body_empty`
  - `issue_number` 抽出失敗 → `issue_number_not_found`
  - PATCH 4xx/5xx → `patch_failed`
  - `pr_body` grep IO エラー → `pr_body_grep_io_error` (stderr tempfile mktemp 失敗は `mktemp_failed_pr_body_grep_err`)
  - branch grep IO エラー → `branch_grep_io_error` (同上 `mktemp_failed_branch_grep_err`)
  - `gh api comments` 取得失敗 → `gh_api_comments_fetch_failed` (同上 `mktemp_failed_gh_api_err`)
  - Python script 異常終了 (汎用) → `python_unexpected_exit_$py_exit`
  - `git diff` 失敗 (Python sentinel 検出) → `python_sentinel_detected` (`GIT_DIFF_FAILED_SENTINEL` マッチ時の `sys.exit(2)` に予約された専用ラベル)
  - work memory body 破損検出 → `wm_body_empty_or_too_short` / `wm_header_missing` / `wm_body_too_small`
  - mktemp 失敗 → `mktemp_failed_*` 系統 (`mktemp_failed_pr_body_tmp`, `mktemp_failed_body_tmp`, `mktemp_failed_tmpfile`, `mktemp_failed_files_tmp`, `mktemp_failed_history_tmp`, `mktemp_failed_diff_stderr_tmp`, 他)

  `git diff` 失敗経路も `WM_UPDATE_FAILED=1; reason=python_sentinel_detected` (Python `sys.exit(2)` + bash `exit 1`) を経由する。bash `exit 1` は bash invocation のみを kill するが、retained `WM_UPDATE_FAILED=1` flag は conversation context に残り、soft-failure 評価ロジックが評価順テーブル行 2 でこの flag を検出して `[fix:pushed-wm-stale]` を emit する (`[fix:error]` **ではない**)。hard fail-fast 設計は PATCH の silent 拒否を保証するが、caller 側へのシグナルは `[fix:pushed-wm-stale]` が正しい (詳細は `commands/pr/fix.md` の評価順テーブルと reason 表を参照)。caller (`/rite:issue:start` review-fix loop) は `[fix:pushed-wm-stale]` を **silent に `[fix:pushed]` 扱いしてはならず**、必ず `AskUserQuestion` で警告を提示してユーザーに「stale work memory のまま継続するか、手動修復のため中断するか」を選択させる義務を負う。詳細な caller セマンティクスは `commands/pr/fix.md` を参照
- **`/rite:lint` に bidirectional backlink format 機械検証を追加** — Wiki ページがコロン記法の canonical な bidirectional backlink 参照を維持しているかを `/rite:lint` が機械的に検証する。Phase 3.x で非ブロッキングの構造 drift チェックとして実行され、不整合は最終レポートに表示される。

### 修正

- **`wiki-query-inject.sh` origin/wiki fallback 対応** — `/rite:wiki:query` が local `wiki` branch 未作成状態（fresh clone / 別 worktree）でも `origin/{wiki_branch}` から Wiki 内容を読めるよう修正。従来は `git show "${wiki_branch}:.rite/wiki/index.md"` が bare branch 名を使用していたため、origin/wiki のみ存在する環境では `fatal: invalid object name 'wiki'` で失敗し、`/rite:pr:cleanup` 後に別 worktree で `/rite:wiki:query` を実行しても経験則が silent に拾えなかった。`cleanup.md` Phase 4.W.1 Step 2 や `wiki-growth-check.sh` と同じ ref 選択パターン (`local > origin` fallback) を適用。ネガティブケース（local / origin ともに不在）は従来通り `WARNING: wiki branch not found` を emit して exit 0 (non-blocking)。あわせて `cleanup.md` Phase 4.W.3 に `wiki-worktree-commit.sh` 経由で報告される `push=failed` (rc=4 経路) を検出し `wiki_ingest_push_failed` sentinel を emit するブロックを追加。loss-safe な cleanup 継続は維持しつつ、origin/wiki との divergence を incident layer で観測可能にする。加えて `plugins/rite/hooks/workflow-incident-emit.sh` の `--type` whitelist に欠落していた `wiki_ingest_push_failed` を追加 — `pr/review.md` / `pr/fix.md` / `issue/close.md` の既存呼び出しはすべて emitter の exit 1 により `hook_abnormal_exit` fallback branch に silent 落ちしており、`issue/start.md` ステップ 8.5 (旧 Phase 5.4.4.1 を統合) で定義された `wiki_ingest_push_failed` sentinel は実機で一度も emit されていなかった
- **`review.md` の Part A 抽出バグ修正** — `_reviewer-base.md` の Part A 抽出が `## Cross-File Impact Check`（`## Reviewer Mindset` と `## Confidence Scoring` の間にあるセクション）を完全にドロップしていた不具合を修正。抽出範囲を「document 先頭 ~ `## Input` heading (exclusive)」に変更し、5 つの必須 cross-file consistency check（削除/リネーム済み export、変更された config key、変更された interface contract、i18n key consistency、keyword list consistency）が **初めて** reviewer agent に届くようになった
- **reviewer agent の tools/model frontmatter drift cleanup** — 全 13 reviewer agent (`api`, `code-quality`, `database`, `dependencies`, `devops`, `error-handling`, `frontend`, `performance`, `prompt-engineer`, `security`, `tech-writer`, `test`, `type-design`) から `tools:` frontmatter を削除、4 reviewer (`code-quality`, `error-handling`, `performance`, `type-design`) から `model: sonnet` を削除。現状は `subagent_type: general-purpose` 経由のため runtime で ignore されているが、named subagent 化した瞬間に副作用 (tech-writer が Bash を失い Doc-Heavy PR Mode 全 blocking 化 / 4 reviewer が opus ユーザーに対して sonnet 固定で品質劣化) を引き起こすリスクがあったため、先行 cleanup で副作用ゼロに保つ。残り 9 reviewer は `model: opus` を明示 pin として意図的に維持 (opus が runtime 上の実効 model だったため、pin を削除すると session default に regress して sonnet になる可能性を避けるため)。あわせて `docs/SPEC.md` / `docs/SPEC.ja.md` の Agent File Format セクションで `tools` を `Yes` (required) から `No (inherit)` に変更し、Current Agents 表の 4 reviewer を `inherit` に更新した
- **Verification-mode post-condition check 追加** — `review.md` に post-condition check (Verification Mode Findings Collection ロジックの子セクション) を追加し、verification mode 時に各 reviewer が `### 修正検証結果` テーブルを出力しているかを検証する。欠落時は reviewer 呼び出し Task tool 経由で per-reviewer retry を 1 回まで実行 (strict verification テンプレート再送)、retry 後も欠落の場合は `verification_post_condition: error` を set、overall assessment を `修正必要` (escalation chain の昇格ラベルと統一。`要修正` は reviewer 個別評価用 label で overall 昇格には使用しない) に昇格し、該当 reviewer の指摘を全件 blocking 扱い。classification vocabulary は `passed` / `warning` / `error` (`doc_heavy_post_condition` と統一)。Retained flags `verification_post_condition` / `verification_post_condition_retry_count` (per-reviewer dict) を retained flags list に登録し、verification mode template に表示する。reviewer が検証出力を silent skip して `finding_count == 0` 誤判定で silent pass する経路を閉塞する
- **`commands/pr/fix.md` reason 表 drift 修正** — work memory 更新パスで実際に emit される 28 件の `WM_UPDATE_FAILED` reason を全て reason 表に登録 (従来は 12 件のみ登録、16 件未登録で drift)。評価順テーブル行 2 の括弧内固定列挙を撤廃し「reason 表のいずれか」に置換、二重 drift を解消。DoD 検証 (手動実行): `comm -3 <(grep -oE 'WM_UPDATE_FAILED=1; reason=[a-z_][a-z_0-9]*' plugins/rite/commands/pr/fix.md | sed 's/.*reason=//' | sort -u) <(awk '/^\*\*`reason` フィールド/{in_table=1;next} in_table && /^\*\*/{in_table=0} in_table && /^\| `[a-z_]/{match($0, /`[a-z_][a-z_0-9]*[^`]*`/); print substr($0, RSTART+1, RLENGTH-2)}' plugins/rite/commands/pr/fix.md | sed 's/\$.*//' | sort -u)` の出力が空 (emit 集合 28 件と reason 表 28 件が完全一致)。awk パターンは `**\`reason\` フィールド` セクションに範囲を絞っており、`fix.md` 内の他テーブルからの false positive を防ぐ (C2 吸収)
- **サブスキル return 後の implicit stop 多層防御** — 累積対策 により、サブスキル return → orchestrator 継続経路が Bash heuristic 起因の implicit stop に対して強固になる。`create-interview`、`wiki/ingest.md` Phase 8 auto-lint、`pr/cleanup` wiki-ingest return、`pr/cleanup` wiki-auto-ingest Phase 5 境界をカバー。`INTERVIEW_DONE=1` plain-text marker と `stop-guard.sh` case-arm `WORKFLOW_HINT` の Step 0 Immediate Bash Action による拡張を含む。
- **`wiki/lint.md` Phase 9.2 `--auto` continuation sentinel** — `--auto` 出力が明示的な continuation sentinel を emit するようになり、警告付き完了と silent-skip の区別が caller 側で可能になった。
- **`pr/cleanup` 完了メッセージの末尾空行** — 「次のステップ」見出し後の不要な末尾空行を削除し、ターミナル表示をクリーンに。
- **`wiki/` と `pr/cleanup` の preprocessor-safe 表記への移行** — スラッシュコマンドのプリプロセッサが bash で eval してしまう (結果として `slash command not found`) `!`+backtick 表現を、文書化された規約に従って `if ! cmd; then` 形式へ移行。

## [0.3.10] - 2026-04-04

### 変更

- review-fix ループ根本修正 — bash エラーハンドリング検出 + 既存 CRITICAL 可視化 + first-pass ルール改善
- sole reviewer guard + Step 6 sub-checks 拡張 — 単一レビュアーの盲点を解消
- レビュアー共同選定拡張 — .md コードブロック検出時に code-quality reviewer を追加
- prompt-engineer-reviewer の検出スコープ拡張 — Content Accuracy + List Consistency + Design Logic Review
- Step 7 に Stale Cross-References 検出ステップカバレッジを追加
- verification mode デフォルト無効化 + context-pressure フェーズ条件分岐
- i18n Sprint キーセクション統合 + en/ja other.yml 重複セクション正規化
- フックスクリプトの jq 呼び出し構文を `echo | jq` に統一

### 修正

- フックスクリプトの jq 抽出堅牢性改善 — CWD フォールバック追加、pre-tool-bash-guard フォールバック追加、context-pressure.sh の silent abort 防止
- レビュー品質改善 — Confidence Calibration 降順修正、E2E auto-create フロー改善、recommendation flow Source C 整合性修正、コメント精度改善

## [0.3.9] - 2026-04-03

### 追加

- レビュアー基盤強化 — `{agent_identity}` 抽出、`_reviewer-base.md` 共通原則、主要 agent 4種（security, code-quality, prompt-engineer, tech-writer）+ confidence_threshold 設定
- レビュアー拡充 — 残り agent 7種再構築 + 新規 reviewer 2種（error-handling, type-design）追加
- `schema_version` 導入 + `rite-config.yml` の自動アップグレード仕組み

### 修正

- deprecated な `commit.style` コード例を全ドキュメント・プロジェクトタイプテンプレートから削除
- ドキュメント内の config 例を `schema_version: 2` 形式に更新
- verification mode re-review でサブエージェント起動を必須化
- 推奨事項の「別 Issue 推奨」アイテムを自動 Issue 化する仕組みを追加
- `flow-state-update.sh` patch モードで `error_count` を 0 にリセットし、stale サーキットブレーカーを防止

## [0.3.8] - 2026-04-01

### 追加

- ファクトチェック Phase — PR レビューで外部仕様の主張を公式ドキュメントで検証し誤情報を防止
- context7 MCP ツールによる検証オプション — ファクトチェックの検証手段として追加（`review.fact_check.use_context7`、デフォルト: オフ）

### 修正

- `.rite-initialized-version` と `.rite-settings-hooks-cleaned` を `.gitignore` に追加

## [0.3.7] - 2026-04-01

### 変更

- レビュアー findings に WHY + EXAMPLE 構造を導入し、修正ガイダンスの精度を向上

## [0.3.6] - 2026-03-27

### 追加

- Sprint Contract — 実装ステップごとの検証基準追加
- Evaluator キャリブレーション — Few-shot 例集と懐疑的トーン追加
- Post-Step Quality Gate — 実装後セルフチェック追加
- コンテキストリセット戦略強化

## [0.3.5] - 2026-03-27

### 追加

- `/rite:investigate` スキル — Grep→Read→クロスチェックの3段階プロセスによる体系的なコード調査
- `investigation-protocol.md` リファレンス — 全ワークフローフェーズで利用可能な簡易コード調査プロトコル
- `rite-config.yml` に `investigate.codex_review.enabled` オプション追加（Codex クロスチェックのオプション化）

### 修正

- `settings.local.json` のレガシー hook を `hooks.json` ネイティブ管理に移行

## [0.3.4] - 2026-03-20

### 変更

- Plugin path resolution をバージョン非依存方式に統一 — `session-start.sh` が `.rite-plugin-root` に解決済みパスを書き出し、コマンドファイルは `cat` で読むだけに

## [0.3.3] - 2026-03-19

### 修正

- マーケットプレイス環境で `/clear` 実行時に SessionStart hook エラーが発生する問題を修正

## [0.3.2] - 2026-03-17

### 修正

- `/rite:init` が `settings.json` の既存 hooks を検出し競合を防止するように修正

### 変更

- `rite-config.yml` から未使用設定を削除し欠落設定を追加

### ドキュメント

- リリーススキルに AskUserQuestion 強制・ブランチ削除手順を追加

## [0.3.1] - 2026-03-17

### 修正

- verification mode 時にフルレビューが実施されない問題を修正
- `{session_id}` プレースホルダーを削除し auto-read に一本化
- `create.md` サブスキル返却後の中断防止ロジック強化
- Issue コメントの作業メモリバックアップ同期を修正
- `.rite-session-id` 不在時の bash リダイレクションエラーを修正
- `session-start.sh` が startup/clear 時に他セッションの active 状態をリセットしない問題を修正
- review-fix ループの段階的緩和ロジックを削除し全指摘必須修正に統一
- e2e フローでレビュアー確認・Ready 確認をスキップ不可に
- flow-state deactivation で patch 方式を使用
- レビューテンプレート出力例の blocking/non-blocking 残存表記を修正
- パス解決不整合を修正し `--if-exists` パターンに統一
- 初期フェーズのサブスキルに Defense-in-Depth flow-state 更新を追加

### 変更

- `loop_count`/`max_iterations`/`loop-limit` パラメータを廃止
- `flow-state-update.sh` から `--loop` パラメータを完全削除
- `hooks/hooks.json` ネイティブ方式を追加し二重実行ガードを設置
- レビューテンプレートに品質3ルールを追加
- `session-start.sh` の trap 廃止とデバッグログ改善

### ドキュメント

- review-fix ループのドキュメント更新

## [0.3.0] - 2026-03-16

### 追加

- Session ownership システムによるマルチセッション競合防止
  - Session ownership ヘルパー関数と flow-state 上書き保護
  - `session-start.sh` に session ownership 対応を追加
  - `session-end.sh` と `stop-guard.sh` に session ownership 対応を追加
  - `wm-sync`、`pre-compact`、`context-pressure` フックに session ownership 対応を追加
  - 全コマンドファイルに `--session {session_id}` パラメータを追加 + `resume.md` の所有権移転

### 修正

- `start.md` のチェックリスト確認に自動チェック処理を追加
- ブランチ存在チェックで exit code ではなく出力文字列で判定するよう修正
- Issue create 完了時の出力順序を改善し次のステップを末尾に移動
- PostToolUse hook で Issue コメント作業メモリを phase 変化時に自動同期
- `review.md` に READ-ONLY 制約を追加し review-fix ループを正常化
- review → fix ループの分岐指示を命令形条件分岐に書き換え
- `session-end.sh` の other session exit パスに診断ログを追加
- フックからデバッグ出力の痕跡を除去

### 変更

- Issue コメント作業メモリ更新ロジックをスクリプト化し確定的実行にする

### ドキュメント

- `gh-cli-commands.md` に `git branch --list` の DO NOT 警告を追加

## [0.2.5] - 2026-03-16

### 追加

- Contextual Commits 統合: コミット body に構造化アクションラインを埋め込み、意思決定を永続化
  - 設定とリファレンスドキュメント（`commit.contextual` 設定）
  - `implement.md` のコミットフローにアクションライン生成を追加
  - `pr/fix.md` のレビュー修正コミットにアクションライン生成を追加
  - `/rite:issue:recall` コマンドを新設（コンテキストコミット履歴の検索）
  - `team-execute.md` の並列コミットにアクションライン生成を追加

### 修正

- `recall.md` のエッジケース対応: base branch フォールバック、grep メタ文字対策、max-count 一貫性
- リリーススキルに GitHub Projects 連携とステータス遷移を追加

## [0.2.4] - 2026-03-14

### 修正

- 作業メモリコメントの実装計画ステップ状態をコミット時に一括更新
- create-decompose.md に Defense-in-Depth パターンを適用
- テスト内の旧状態名 blocked を recovering に統一
- develop ブランチ自動削除時の復旧手順を追加

### 変更

- Defense-in-Depth パターンの順序明確化と冗長性解消
- PostCompact フック導入による auto-compact 復帰の自動化

### 改善

- create サブスキルのプロンプト品質改善

## [0.2.3] - 2026-03-13

### 修正

- create ワークフローのサブスキル返却後の自動継続を強化

## [0.2.2] - 2026-03-12

### 追加

- マーケットプレイス版フックパスのバージョンアップ時自動更新

### 修正

- 親 Issue の Projects Status 自動更新が実行されない問題を修正

## [0.2.1] - 2026-03-12

### 追加

- e2e フローのコンテキストウィンドウオーバーフロー防止機構
- エージェント委譲プロンプトに Skill ツール書式を追加
- エージェント委譲の AGENT_RESULT フォールバック処理を追加

### 修正

- サブスキル遷移で Claude 停止を防ぐプロンプト強化
- 作業メモリの進捗サマリー・変更ファイル更新ロジックを具体化
- create ワークフローのサブスキル遷移指示を強化
- ハードコードされた bash フックパスを `{plugin_root}` に置換しマーケットプレイス互換に
- `resume.md` のカウンター復元の実行タイミング・実行主体を明示
- `context-pressure.sh` の python3 起動最適化と COUNTER_VAL バリデーション追加
- PR コマンドの Issue 作成時に GitHub Projects 登録を確実にする
- 進捗サマリー・変更ファイル更新セクションをチェックリスト更新から独立化
- `flow-state-update.sh` の patch モードで `--active` フラグをサポート
- `flow-state-update.sh` の patch モードで jq フィルター前に `--` セパレータを追加
- `fix.md` work memory 更新の trap に `$pr_body_tmp` を追加
- review/fix ループ中に進捗サマリー・変更ファイルが更新されるよう修正

### 変更

- 進捗サマリー正規表現を堅牢化
- `lint.md` の不正確な参照修正と `start.md` の具体例追加
- `resume.md` カウンター復元スニペットを正式サブセクションに構造化
- `review.md` のセッション情報更新の defense-in-depth 意図を明文化

## [0.2.0] - 2026-03-05

### 追加

- セッション開始時のプラグインバージョンチェック機能

### 変更

- SPEC およびコマンドドキュメント内の Zen/禅 表記を rite に置換

## [0.1.3] - 2026-03-05

### 変更

- 確定的処理をシェルスクリプト（`flow-state-update.sh`、`issue-body-safe-update.sh`）にオフロードし、8ファイル・24箇所の jq + atomic write パターンを1行コールに置換
- `start.md` から完了報告セクションを `completion-report.md` に分離
- `review.md` から評価ルールを `references/assessment-rules.md` に分離
- `cleanup.md` からアーカイブ処理を `references/archive-procedures.md` に分離
- SKILL.md の description を能動的スタイルに最適化し、テーブルをポインタ+概要に圧縮
- 7つの主要コマンドの MUST/CRITICAL 箇所に Why-driven の理由文を追加
- 7つの主要コマンドに Input/Output Contract セクションを追加

## [0.1.2] - 2026-03-04

### 修正

- `work-memory-init` 検証スクリプトの else 成功ブランチ欠落を修正
- 作業メモリコメントが API エラーレスポンスで上書きされる問題を修正
- rite workflow 実行中の不要な hooks 未登録メッセージを修正
- `stop-guard.sh` の trap に EXIT シグナルを追加
- `stop-guard.sh` の compact_state 停止ブロック失敗を修正
- `session-start.sh` の jq エラーハンドリング問題を修正
- `/rite:issue:start` の完了レポートが実行されない問題を修正
- 親 Issue の Projects ステータスが Todo から In Progress に更新されない問題を修正
- `/rite:issue:start` 実行時の Bash コマンドエラーを修正
- find クリーンアップパターンを mktemp サフィックス長非依存に修正
- `ready.md` に出力パターンと Defense-in-Depth を追加
- 作業メモリ更新の安全パターンを全コマンドに統一適用
- stop-guard と post-compact-guard の競合デッドロックを修正
- `/clear → /rite:resume` 案内メッセージの重複表示を修正

### 変更

- `stop-guard.sh` の grep -A20 固定値を awk セクション抽出に改善
- `pre-compact.sh` の echo|jq パイプを here-string に統一
- `stop-guard.sh` のサブシェル最適化
- PID ベース一時ファイル名を mktemp + フォールバックに統一

### 削除

- v0.1.0 変更履歴からリブランド表記を削除

## [0.1.1] - 2026-03-03

### 修正

- 大規模課題の単一 Issue 作成時に Implementation Contract フォーマットが適用されない問題を修正
- `/rite:issue:create` サブスキル復帰後の中断問題を修正
- `/rite:issue:start` 実行中の中断問題を修正
- 作業メモリ更新時の安全パターン追加と破壊防止対策

## [0.1.0] - 2026-03-01

### 追加

- Rite Workflow 初回リリース
- Claude Code 用 Issue ドリブン開発ワークフロー
- マルチレビュアー PR レビューシステム（討論フェーズ付き）
- スプリント計画・チーム実行
- GitHub Projects 連携
- フックベースのセッション管理（stop-guard、pre-compact、セッションライフサイクル）
- 多言語対応（日本語、英語）
- TDD Light モード
- git worktree による並列実装サポート

[0.9.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.8.3...v0.9.0
[0.8.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.12...v0.7.0
[0.6.12]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.11...v0.6.12
[0.6.11]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.10...v0.6.11
[0.6.10]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.9...v0.6.10
[0.6.9]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.8...v0.6.9
[0.6.8]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.7...v0.6.8
[0.6.7]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.6...v0.6.7
[0.6.6]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.5...v0.6.0
[0.5.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.10...v0.4.0
[0.3.10]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.5...v0.3.0
[0.2.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
