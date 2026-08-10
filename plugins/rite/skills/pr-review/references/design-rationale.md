# Review SKILL Design Rationale

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md).
> 本ファイルは `skills/pr-review/SKILL.md` 本体から退避した**設計理由 (Why)** の受け皿。実行手順・分岐表・sentinel 表・
> エラー処理指示・出力テンプレートは SKILL.md 本体または [integrated-report-templates.md](integrated-report-templates.md)
> に残る。本体の該当箇所には `rationale: references/design-rationale.md#<anchor>` 形式のポインタがあり、逆引きできる。
> ここに書いてよいのは「なぜこの実装形なのか」「変更するなら何が壊れるか」の説明のみで、手順そのものを書いてはならない。

## argument-parsing-notes

ステップ 1.0 統合 bash block の設計理由。

- **bash 4+ compat guard**: `mapfile` builtin は bash 4.0 で導入されたため、bash 3.2 (macOS default) では `command not found` で silent 失敗する。guard で fail-fast させる。ステップ 1.2.7 の `mapfile -t changed_file_paths` 利用は doc-heavy 検出の簡素化で撤去済みだが、guard 自体は他の bash 4+ 機能の baseline として維持する。Source: GNU Bash 4.0 NEWS (https://tiswww.case.edu/php/chet/bash/NEWS)
- **config 読取を単一 awk に統合した理由 (C-2)**: `sed | awk | sed | sed | tr | tr` の 6 段 pipeline は pipefail 下で SIGPIPE rc=141 を起こし、fallback branch が config 値を silent に false へ上書きする latent regression を生む。単一 awk はファイルを直接読むため上流コマンドが存在せず、SIGPIPE 経路自体が消える。awk 終了コードは file IO / binary error 以外で 0 を返すため `if ! ...` で捕捉可能。Source: GNU bash manual — Pipelines / POSIX awk exit semantics

## doc-heavy-detection-notes

ステップ 1.2.7 Doc-Heavy PR Detection の設計理由（機械比率計算 bash は目的を過剰に形式化するため撤去し、目的文判断 + ステップ 1.1 の既存 `files` 配列の再利用に簡素化した）。

- **Self-only judgment を明示フラグにする理由**: 「分子から除外、分母には含める」方式では rite plugin self-only PR でも数学的には doc_lines == 0 (= ratio 0) になり「ratio 未満」と区別不能になるため、判定根拠の要約に明示的に記録する。
- **全経路で `[CONTEXT]` を対称 emit する理由**: skip 経路のみ emit する非対称設計だと、後続 phase (ステップ 2.2.1 / 5.1.3 / 5.4) が「`[CONTEXT]` 行が会話履歴に存在しない = 正常」という negative inference に依存し、Claude の context grep が前 session の `[CONTEXT] doc_heavy_pr=true` を誤拾いするリスクを生む。全経路対称 emit なら grep は常に最新行を decisive に拾える。
- **`gh pr view` 再呼び出しを撤去した理由**: 旧実装は `all_files_excluded` 判定用に path 配列を独立取得していたが、目的文判断はステップ 1.1 の `files` 配列（`additions`/`deletions` 付き）のみで完結するため、追加 API 呼び出し・mktemp/trap・bash 配列 hydration が不要になった。

## code-block-scan-notes

ステップ 2.2.1 の fenced code block スキャン bash の設計理由。

- **pipefail を維持する理由**: 現行実装は pipeline を廃止し `diff_out=$(git diff ...)` 独立実行 + here-string 構成に移行したため、pipefail が直接必要な pipeline は存在しない。将来の pipeline 追加時の防御として維持している。
- **`printf | grep -m 1` ではなく here-string `<<<` を使う理由**: pipeline では printf が上流 (writer)、grep が下流 (reader) となり、`grep -m 1` の 1 件マッチ早期終了で上流の printf に SIGPIPE が届く経路が存在する。pipefail 有効時、`$diff_out` が pipe buffer (Linux デフォルト 64KB) を超えるサイズだと printf が rc=141 を返し、case 文の `*)` (IO error 扱い) で `__FAIL_SAFE_ADD__` sentinel が誤発火する (大きな diff の Doc-Heavy PR で silent false positive)。`<<<` は bash が入力を一時ファイル経由で渡すため SIGPIPE を受ける相手がおらず、grep の exit 0/1/2 をそのまま捕捉できる。
- **iteration_id を付与する理由**: 同一 session 内で同じ review が複数回実行されると `[CONTEXT] code_quality_coreviewer_add_reason=` 行が会話履歴に複数残り、後続 phase が「最新値」を決定論的に判別できない。`pr_number-{epoch_seconds}` suffix により「最大の iteration_id を持つ行が最新」と判定できる (M-7 修正。ステップ 7.2 / 7.7 の sentinel 規約と同型)。
- **`[CONTEXT]` 3 状態 emit の理由**: bash block 内で `:` no-op だけだと後続 phase が判定結果を機械的に読み取れない (会話文脈に何も残らない)。

## state-snapshot-notes

ステップ 4.0.A Pre-Review State Snapshot の設計理由。

- **detached HEAD edge case**: orchestrator が `git worktree add --detach` で起動された場合や reviewer ループ中の特殊な checkout で HEAD が detached になると `git branch --show-current` は空文字列を返す。空文字列のままステップ 5.0.A に渡すと verifier が `[ -z "$ORIGINAL_BRANCH" ]` で exit 2 (invalid args) になるため、`DETACHED:<short-hash>` sentinel に置換する。verifier 側で `DETACHED:*` は branch drift check を skip する経路に乗る。
- **md5sum portability**: Linux は `md5sum`、macOS は `shasum` を fallback として使う。両方とも stdout の先頭 token が hash であるため `awk '{print $1}'` で portable に取り出せる。
- **ステップ 5.0.A の placeholder 残留 gate**: `{orig_br}` が `{...}` 形状のまま渡されると verifier が non-empty 文字列として branch 比較し silent false-positive cascade を起こすため、形状検査で早期 reject する (ステップ 6.1.b と同 pattern)。
- **生の `git status --porcelain` ではなく `git-status-filtered.sh` を使う理由**: このスナップショットと ステップ 5.0.A の verify は異なる sandbox 実行コンテキストで走りうるため、bwrap sandbox が overlay する ghost-mount `??` エントリ が両側で食い違い、実変更が無くても hash 不一致 (false-positive drift) が起きる。フィルタを両側に適用するとその ghost-mount 差分が打ち消され、実際の working-tree 変更のみが hash に反映される。
- **フィルタの exit code を明示チェックする理由 (capture-first)**: 生の `git status --porcelain` と異なりフィルタは `mktemp` に依存するため、sandbox の TMPDIR 制限下では plain `git status` が成功してもフィルタは失敗しうる。かつ SKILL.md の bash block は Bash tool の 1 回の呼び出しとして新規シェルで実行され pipefail は既定 off (呼び出し間でシェル状態は引き継がれない) なので、`filter | hash | awk` の `$?` は pipefail に依存させられない。フィルタ自身の出力を先に非パイプで capture してから exit code を判定する。`post-review-state-verify.sh` 側は単一スクリプト全体に `set -uo pipefail` がかかるため pipefail 経由の `$?` チェックで足りるが、SKILL.md block はそれとは独立した実行コンテキストのため同じ前提を流用できない。

## verification-post-condition-notes

ステップ 5.1.1.1 Verification Result Table Presence check の設計理由。

- **設置の根拠**: ステップ 4.5.1 の verification テンプレートは `### 修正検証結果` の出力を義務付けているが、reviewer agent body が system prompt として与えられている現状では、reviewer がステップ 4.5 (full) の出力のみに集中してステップ 4.5.1 (verification) の出力を silent skip する経路が実証されている。テーブル欠落は「前回指摘の修正検証」の silent skip の兆候で、`finding_count == 0` と誤判定されて silent pass する経路が成立するため、契約違反を検出する post-condition で閉塞する。
- **分離の意図 (subagent resolution failure との関係)**: ステップ 5.1.1.1 の retry 機構は output format 異常 (verification table 欠落) のみを対象とし、`subagent resolution failure` とは独立した経路。この分離により、scoped subagent の解決不能という "インフラレベル" の障害と、output format の契約違反という "semantic レベル" の障害が混線することを防ぐ。resolution failure 時の terminal state は retry counter の数値ではなく classification 状態 (`error`) によって実現される (Judgment Matrix 行 3 への flow 分岐)。

## fingerprint-suppression-notes

ステップ 5.1.2.A Accepted Fingerprint Suppression の設計理由。

**Step 2 と Step 3 を統合した理由**: Claude Code Bash tool は呼び出し間で shell 変数を保持しないため、Step 3 (emit) を独立 bash block にすると `$fingerprint` / `$finding_id` / `$original_severity` が undefined になり emit が空値出力になる。match 検出 + 即時 emit を同一 invocation 内で完結させることで cross-call shell 変数破綻を構造的に回避する。重複 emit は per-finding loop の単一実行が暗黙に防止する。

## doc-heavy-post-condition-notes

ステップ 5.1.3 Doc-Heavy PR Mode Post-Condition Check の設計理由。

- **variant b を Step 1 判定式に含める理由**: tech-writer が `finding_count == 0` でも誤って variant b 文言 (`Findings below.`) を出力することがあり、判定を variant a / c のみで行うと「META 行が 1 つもない」と誤判定して false positive で `修正必要` 降格する。
- **inconclusive variant を判定式に含める理由**: `internal-consistency.md` の "Inconclusive 集計 と META 行への反映" は、Verification protocol の各 step で `target_not_found` / `extraction_failed` / `tool_failure` が発生した場合に META 行を `(a + inconclusive)` / `(b + inconclusive)` 形式へ切り替えることを reviewer に要求している。これらを判定式に含めないと、正しく inconclusive を報告した tech-writer を「META 行なし」と誤判定して二重 penalty が起き silent fall-through する。含めることで inconclusive 報告を正しく受け入れ、Step 4.5 で acknowledgement プロセスを発火できる。
- **literal substring match の設計選択**: カテゴリ名の空白/記号の差異 (`Order / Emphasis Consistency` 等の表記揺れ) を厳格に検出し、canonical form (`Order-Emphasis Consistency`) から逸脱した瞬間に発火する。「文書-実装整合性 mode の自己整合性」をステップ 5.1.3 自身が監視するための仕組み。

## step7-triage-redesign-notes

ステップ 7 の名称・推奨決定方式の再設計（自動 Issue 化 → スコープ外指摘のトリアージ）の設計理由。

- **3 つのバイアスの積み重ね**: 旧「自動 Issue 化」には (1) 起票をゴールとする命名、(2) `AskUserQuestion` の選択肢列挙で「別 Issue 作成」が先頭（本 tool の規約上、先頭 = 推奨と解釈されやすい）、(3) 推奨決定の指示不在（エージェント裁量）、の 3 バイアスが積み重なっていた。エージェントには「指摘を先送りすれば fix ループが早く収束する」という構造的な先延ばし動機があり、この 3 バイアスが揃うと保険的な follow-up Issue が増殖する。fix ループ側の別 Issue 化経路は既に「先延ばしの抜け穴」として廃止済み（`skills/iterate/SKILL.md`）であり、ステップ 7 だけが取り残されていた。
- **先延ばし禁止の設計原則**: 仮説的な将来リスクに先手を打つ Issue は大半が無駄に終わる。スコープ内の実指摘は本 PR で解決し（fix ループで強制済み）、スコープ外候補は「起票せず記録して終わり」をデフォルトにする方が、Issue の増殖を防ぎ実際に着手される確率を上げる。
- **推奨機械決定表を裁量の代わりに置く理由**: 「裁量で決めてよい」とすると上記の構造的動機により実質的に「別 Issue 作成」へ誘導される。Likelihood（Observed/Demonstrable vs Hypothetical）と Source（A/B）という機械的に判定可能な軸だけで推奨を決定することで、エージェントの意思が介在する余地を無くす。
- **Decision Log 記録を「追加」の経路とする理由**: fix ループの nit-noted 返信経路・acknowledged suppression（PR コメント / JSON ベースの再指摘抑制）は Decision Log 記録では代替されない。両者は別の目的（前者は次サイクルでの再指摘抑制、後者は仕様変更の記録）を持つため、置き換えではなく追加とした。
- **元 Issue が特定できない PR での「選択肢非表示」**: PR コメント記録という代替スキーマを新設すると、記録先が「Section 9」「作業メモリ」「PR コメント」の 3 種に増え「シンプルさを死守」原則に反する。本リポジトリはブランチ命名規則上ほぼ全 PR が issue 番号を含むため、この縮退経路の実発生頻度は低いと判断し、選択肢非表示（3 択化）で単純に倒した（対象 Issue の Decision Log D-04 参照）。

## phase7-gate-notes

ステップ 7.7 / 8.0.2 gate の設計理由。

- **Defensive layering の全体像**: (a) ステップ 4.5 reviewer template が 3-classification を要求 → (b) ステップ 5.1 collection で classification を extract (default fallback あり) → (c) ステップ 7.1 で candidates を構築 → (d) ステップ 7.2 で sentinel emit → (e) ステップ 7.7 で grep verify → (f) ステップ 8.0.2 で end-to-end gate continuity 参照。各層は個別に失敗しうるが、ステップ 7.7 は result emit 前の last-line-of-defense mechanical gate。ステップ 5/6 が abort-relevant findings を生成しても、ステップ 7.1 candidate extraction (recommendation_items) は独立しており ステップ 7.2 で user confirm が必須。
- **dual placement (7.7 + 8.0.2) の理由**: ステップ 7.7 はステップ 7.1 → 7.2 → 7.7 の sequence で 7.7 が呼ばれた場合に 7.2 sentinel emit を verify する (procedure 内部の integrity check)。ステップ 8.0.2 はステップ 7 entire procedure (7.1-7.7) が skip された場合の最終 fallback で、`candidate_count >= 1` という trigger 条件が満たされている時点で「ステップ 7 が走るはずだった」と判定できる (ステップ 7.7 自体が呼ばれていない silent skip 経路でも catch する)。ステップ 8.0.1 W Phase gate と完全に対称的で、result-emit boundary における defense-in-depth pattern を構成する。

## reviewer-selection-notes

ステップ 2.3 Sole reviewer guard の設計理由。

- **Sole reviewer guard の根拠**: 単一 reviewer は cross-file consistency check が見落とす blind spot を持つ。second perspective (Code Quality を baseline reviewer として追加) でこのリスクを緩和する。`pr-review-toolkit` の always-on `code-reviewer` と同じパターン。

## wiki-raw-source-placement-notes

ステップ 6.5.W Wiki Raw Source 生成の配置理由。

- **Position rationale**: 本 block は review-fix loop 終了後に配置される (caller `/rite:iterate` は `[review:mergeable]` または standalone 実行時のみ ステップ 6.5.W に入る)。loop 途中で書かれた Raw Source は未確定な review state を反映してしまうため、この配置は意図的。


## measured-gate-helper-notes

ステップ 5.3.0.M を helper に委譲した理由。

旧版は本ゲートを LLM の推論ステップとして書いていた。「自分の指摘を non-blocking 化して mergeable を宣言する」判断は reviewer 群の thoroughness 指示と正面衝突するため、裁量に置く限り構造的に実行されにくい —  では 9 サイクルすべてで一度も降格が実行されず、契約上 merge を止めてはならない散文精度指摘でループが 8 時間超継続した。分類を bash へ移し、mergeable 判定 (5.3.1) が LLM の分類を経由しない配置にする。

## non-blocking-findings-array-notes

`non_blocking_findings[]` を独立配列として永続化する理由。

- **なぜ独立配列に出すのか**: `findings[]` にだけ載せない設計にすると、既定 `post_comment: false` では PR コメントも投稿されないため、**永続成果物 (`.rite/review-results/*.json`) に降格の痕跡がゼロ**になり「`overall_assessment: mergeable` + `findings[]: []`」= 指摘ゼロのレビューと区別不能な記録が残る。これは `assessment-rules.md` §5.3.0.M の「破棄経路は存在しない」および「マージ後に人間が拾い直せる状態を保つ」という記録契約を既定構成で偽にする。独立配列にすることで `findings[]` の blocking 集合としての意味を保ちながら記録を永続化する。
- **帰結**: (a) `/rite:fix` の JSON 経路は `findings[]` のみを読むため `non_blocking_count` は JSON 経路では 0 になる（Markdown / 会話経路の N とは一致しない）。一方、`measured_map` 自体は空ではない — findings[] に残る nit-noted 非実測 finding が `measured=false` を持つため。ただし `non_blocking_count` は 0 のまま。(b) 非実測 finding と同一 file:line に GitHub thread がある場合、External review (blocking) に分類される — 安全側。(c) 非実測 finding を `measured: false` 付きで `findings[]` に統合する方向は cross-field invariant 同期が前提であり本 Issue では採らない。

## save-pending-id-path-notes

5.3.0.M step 2 で save-pending marker の id と path を分けて持つ理由。

6.1.a には **id だけ**を渡し (`--pending-id`)、path は helper が内部導出する — caller から full path を受け取る形は、任意文字列が削除対象と機械可読 sentinel の両方へ流れるため guard が要り、その guard が `${TMPDIR}` の文字種と食い違うと非収束になる。path 側は 8.0.4 の `[ -e ]` 検査にのみ使う。詳細: [measured-gate-record.md#save-pending-marker](measured-gate-record.md#save-pending-marker)。

## noclobber-pending-marker-notes

pending / save-pending marker 作成に `set -C` (noclobber) を使う理由。

marker のパスは予測可能で、**ファイルの存在/不在そのものが gate の判定値**であるため、素の `: >` だと (a) 事前に張られた symlink を追随して任意ファイルを 0 バイトへ truncate でき、(b) 他者が作った既存ファイルを掴んでしまう。`set -C` で O_CREAT|O_EXCL 相当にし、拒否時は degraded へ縮退する。詳細: [measured-gate-record.md#pending-marker](measured-gate-record.md#pending-marker) / [#save-pending-marker](measured-gate-record.md#save-pending-marker)。

## review-cycle-id-emit-notes

`REVIEW_CYCLE_ID` と `NONBLOCKING_PENDING_MARKER` を 6.1.a step 0 で emit する理由。

- `REVIEW_CYCLE_ID` は 6.1.d の記録経路と、その実行を保証する gate（6.1.d step 3 / 8.0.3）が「本 cycle で記録経路が走ったか」を stale marker と区別して判定するために使う。**値の生成と記録動作を別ブロックに分ける**ことで、gate 側に本 cycle の比較対象が独立に残る。詳細: [measured-gate-record.md#iteration-id](measured-gate-record.md#iteration-id)。
- `NONBLOCKING_PENDING_MARKER` は 8.0.3 が prose 判定に加えて持つ**機械強制**の入力。sentinel の grep は LLM が会話を読む前提であり、読まずに result pattern へ進む経路を構造的には塞げない。marker は helper 側でしか消えないファイルなので、gate の bash が `[ -e ]` で見るだけで「6.1.d が完走したか」を LLM の認識に依存せず判定できる。詳細: [measured-gate-record.md#pending-marker](measured-gate-record.md#pending-marker)。
