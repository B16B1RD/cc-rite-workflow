# Wiki Index

このファイルは Wiki 全ページのカタログです。Ingest サイクルごとに自動更新されます。

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Fix の完成判定は shell script 単体動作ではなく実ワークフロー発火実績で行う](pages/heuristics/fix-verification-requires-natural-workflow-firing.md) | heuristics | 修正が動いていると主張する前に、shell script 単体のテストデータではなく、自然な workflow 経路を通った commit 履歴上の発火実績を確認する。 | 2026-04-17T00:15:00+00:00 | high |
| [Asymmetric Fix Transcription (対称位置への伝播漏れ)](pages/anti-patterns/asymmetric-fix-transcription.md) | anti-patterns | fix を 1 箇所に適用したとき同パターンを持つ対称位置に伝播させ忘れる failure mode。PR #548 で 6 cycle の review-fix ループ (21→17→2→7→3→0) の dominant pattern として実測。PR #550 で symmetric error handling、PR #553 で Phase 内 mktemp pattern 統一へ一般化。 | 2026-04-17T00:49:00+00:00 | high |
| [`if ! cmd; then rc=$?` は常に 0 を捕捉する](pages/anti-patterns/bash-if-bang-rc-capture.md) | anti-patterns | bash の `!` 演算子は rc を binary 反転するため `if ! cmd; then rc=$?` の `$?` は常に 0 を捕捉する。`set +e; cmd; rc=$?; set -e; case` による明示 3 値分離が canonical。 | 2026-04-16T19:37:16Z | high |
| [stderr ノイズ削減: truncate ではなく selective surface で解く](pages/heuristics/stderr-selective-surface-over-truncate.md) | heuristics | success path の stderr ノイズを `2>/dev/null` や全 truncate で消すと legitimate warning も silent drop する。git の `-q` で informational 抑制 + grep filter で warning/hint/error 行のみ selective surface する責務分離が正解。PR #550 で multi-step 処理の per-step tempfile 分離に拡張。 | 2026-04-17T00:00:00+00:00 | high |
| [trap 登録 → mktemp の順序で tempfile lifecycle を守る](pages/patterns/trap-register-before-mktemp.md) | patterns | `mktemp → trap` 順では signal が届く窓で orphan が残る。「空文字変数宣言 → signal-specific trap → mktemp」の canonical 順序 + POSIX exit code (130/143/129) 明示渡しで signal 経路も堅牢化する。 | 2026-04-16T19:37:16Z | high |
| [Exit code semantic preservation: caller は case で語彙を保持する](pages/patterns/exit-code-semantic-preservation.md) | patterns | script header で定義した exit code 語彙 (例: `2=legitimate skip`) は caller が `case` で明示 routing しなければ一律 failure に潰れ false-positive incident を生む。双方向契約と `[CONTEXT]` sentinel の組み合わせで語彙を保持する。 | 2026-04-16T19:37:16Z | high |
| [mktemp 失敗は silent 握り潰さず WARNING を可視化する](pages/patterns/mktemp-failure-surface-warning.md) | patterns | `mktemp ... \|\| echo ""` は disk full / inode 枯渇を silent 握り潰す。`if ! var=$(mktemp ...); then WARNING; var=""; fi` 形式で stderr に可視化し `[CONTEXT]` sentinel で機械可読にする。PR #550 で silent fallback 全般 (rev-parse/rm 非対称) に一般化。 | 2026-04-17T00:00:00+00:00 | high |
| [jq -n create mode: 既存値を読み取ってから再構築する](pages/patterns/jq-create-mode-preserve-existing.md) | patterns | `.rite-flow-state` を `jq -n` で毎回全フィールド再構築すると永続化すべきフィールド (parent_issue_number / loop_count 等) を silent リセットする CRITICAL 欠陥。既存値を先読みして `--argjson` で渡す canonical pattern を適用する。 | 2026-04-16T19:37:16Z | high |
| [兄弟 shell script の重複 helper は shared lib 抽出で解く](pages/heuristics/shell-script-shared-lib-extraction.md) | heuristics | `parse_wiki_scalar()` のような helper が 3 scripts に complete-match duplicate している場合、個別対称修正では drift が止まらない。shared lib 抽出が Asymmetric Fix Transcription の根本解決策。scope 基準で本 PR 対応か別 Issue 分離かを判断する。 | 2026-04-16T19:37:16Z | medium |
| [Phase 番号は構造的対称性を保つ（孤立 sub-phase を生まない）](pages/heuristics/phase-number-structural-symmetry.md) | heuristics | `### 8.0.1` を書くなら親 `### 8.0` を必ず存在させる。cross-file の Phase 参照は grep で追跡し、enforcement note は実装 hook 名を明示して doc-impl drift を防ぐ。 | 2026-04-16T19:37:16Z | medium |
| [separate_branch 戦略は git worktree で dev ブランチ不動を実現する](pages/patterns/worktree-based-separate-branch-write.md) | patterns | wiki 別ブランチへの書き込みを `stash + checkout + stash pop` で行う Block A/B パターンは構造的に脆弱。`.rite/wiki-worktree/` worktree へ Write/Edit、`wiki-worktree-commit.sh` で単一プロセス commit/push することで dev ブランチ不動を実現する (Issue #547)。 | 2026-04-16T19:37:16Z | high |
| [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](pages/heuristics/observed-likelihood-gate-with-evidence-anchors.md) | heuristics | findings に Likelihood-Evidence anchor (tool/path/line) が無い場合は自動降格。複数 reviewer が anchor 付きで独立検出した場合は severity boost（triple cross-validation）。憶測ベース findings の false-positive を severity から分離する gate。 | 2026-04-16T19:37:16Z | medium |
| [_SCRIPT_DIR canonicalize: cd 前に BASH_SOURCE を絶対 path 化する](pages/patterns/script-dir-canonicalize-before-cd.md) | patterns | `cd "$repo_root"` 後の `$(dirname "$0")` は相対 path invocation で壊れ、sibling lib の source が `./scripts/lib/...` として解釈される。`_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` を cd 前に実行して絶対 path 化するのが canonical convention。 | 2026-04-17T00:00:00+00:00 | high |
| [Bash lib helper の contract は実装と同じ rigour で保証する](pages/patterns/bash-lib-helper-contract-rigour.md) | patterns | docstring で「caller owns shell options / outer trap preserved」と宣言するなら、実装側で `set -e` 強制 / `trap -` 消去をしてはいけない。`$-` + `trap -p`/`eval` で errexit と outer trap を保存復元する。signal override / nested function leak 等 subtle な挙動も Contract 節に明示化する。 | 2026-04-17T00:00:00+00:00 | high |
| [AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する](pages/patterns/drift-check-anchor-prose-code-sync.md) | patterns | AC anchor / reasons table / Eval-order enumeration / bash 実装の emit 順は 3 重契約であり、`distributed-fix-drift-check.sh` Pattern-2/5 で機械検証する。PR #553 で 7 reasons + 2 fallbacks = 9 経路の drift 検出が実証され、カテゴリ非対称 (5 artifacts ↔ 4 mktemp blocks) の合流ケースも category 単位表記で対応。 | 2026-04-17T00:49:00+00:00 | high |

## 統計

- 総ページ数: 14
- ドメイン別: patterns=7, heuristics=5, anti-patterns=2
- 最終更新: 2026-04-17T00:49:00+00:00
