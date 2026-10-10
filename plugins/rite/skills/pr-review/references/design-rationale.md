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
- **`files` 配列を再利用する理由**: 目的文判断はステップ 1.1 の `files` 配列（`additions`/`deletions` 付き）のみで完結するため、追加 API 呼び出し・mktemp/trap・bash 配列 hydration は不要。

## code-block-scan-notes

ステップ 2.2.1 の fenced code block スキャン bash の設計理由。

- **pipefail を維持する理由**: 現行実装は pipeline を廃止し `diff_out=$(git diff ...)` 独立実行 + here-string 構成に移行したため、pipefail が直接必要な pipeline は存在しない。将来の pipeline 追加時の防御として維持している。
- **`printf | grep -m 1` ではなく here-string `<<<` を使う理由**: pipeline では printf が上流 (writer)、grep が下流 (reader) となり、`grep -m 1` の 1 件マッチ早期終了で上流の printf に SIGPIPE が届く経路が存在する。pipefail 有効時、`$diff_out` が pipe buffer (Linux デフォルト 64KB) を超えるサイズだと printf が rc=141 を返し、case 文の `*)` (IO error 扱い) で `__FAIL_SAFE_ADD__` sentinel が誤発火する (大きな diff の Doc-Heavy PR で silent false positive)。`<<<` は bash 5.0 以前では一時ファイル、5.1 以降では pipe buffer 未満の入力に pipe（大きい入力は一時ファイル）を使う。どちらの経路も上流の書き手プロセスを作らないため、grep の早期終了で書き手が SIGPIPE を受ける経路がなく、grep の exit 0/1/2 をそのまま捕捉できる。
- **iteration_id を付与する理由**: 同一 session 内で同じ review が複数回実行されると `[CONTEXT] code_quality_coreviewer_add_reason=` 行が会話履歴に複数残り、後続 phase が「最新値」を決定論的に判別できない。`pr_number-{epoch_seconds}` suffix により「最大の iteration_id を持つ行が最新」と判定できる (M-7 修正。ステップ 7.2 / 7.7 の sentinel 規約と同型)。
- **`[CONTEXT]` 3 状態 emit の理由**: bash block 内で `:` no-op だけだと後続 phase が判定結果を機械的に読み取れない (会話文脈に何も残らない)。

## state-snapshot-notes

ステップ 4.0.A Pre-Review State Snapshot の設計理由。

- **snapshot を helper に委譲する理由**: 4 値は `post-review-state-verify.sh --snapshot` が 5.0.A の verify と同じ関数で算出する。SKILL.md に算出式を持つと、判別子を変えるたびに snapshot 側と verify 側の両方を揃える必要があり、片側だけ変わると毎回 drift を誤報告する。
- **detached HEAD edge case**: orchestrator が `git worktree add --detach` で起動された場合や reviewer ループ中の特殊な checkout で HEAD が detached になると `git branch --show-current` は空文字列を返す。空文字列のままステップ 5.0.A に渡すと verifier が `[ -z "$ORIGINAL_BRANCH" ]` で exit 2 (invalid args) になるため、helper の `--snapshot` が `DETACHED:<short-hash>` sentinel に置換する。verifier 側で `DETACHED:*` は branch drift check を skip する経路に乗る。
- **md5sum portability**: helper は Linux で `md5sum`、macOS で `shasum` を fallback として使う。両方とも stdout の先頭 token が hash であるため `awk '{print $1}'` で portable に取り出せる。
- **stash / branch list から他セッションを除く理由**: refs/heads と refs/stash は全 worktree で共有されるため、全体の件数や一覧を比べると並列セッションの操作が reviewer の drift に見える。`git for-each-ref` の `worktreepath` で他セッションの worktree（自 worktree 以外で、mutation worktree の名前空間 `rite-review-mutation-*` / `rite-revert-test-*` にないもの。パスは物理パスで比べる）が checkout 中の branch を集め（reviewer 漏出名 `pr-<N>-cycle<X>` / `pr-<N>-test` / `pr-<N>-experiment` / `pr-<N>-mutation` / `pr-<N>-verify` / `pr-<N>-check` / `pr-<N>-sandbox` の branch は、worktree の位置によらず集めない。集合は `pr-cycle-cleanup.sh` の回収対象と同じ）、branch list はそれを除き、stash は件名 `WIP on <branch>:` / `On <branch>:` の branch がそれに当たるものを除く（git は同じ named branch を 2 つの worktree で checkout させないので、件名の branch はそれを checkout した worktree を指す）。自 worktree を基準に絞らないのは、reviewer が自 worktree で別 branch へ切り替えて作った stash や、名前空間の worktree で作った branch を数え続けるため。判別子の外に残るものは helper の docstring が列挙する。
- **ステップ 5.0.A の placeholder 残留 gate**: `{orig_br}` が `{...}` 形状のまま渡されると verifier が non-empty 文字列として branch 比較し silent false-positive cascade を起こすため、形状検査で早期 reject する (ステップ 6.1.b と同 pattern)。
- **tracked 差分で snapshot / verify を揃える理由**: 両側で `git-status-filtered.sh --tracked-only` を使い、sandbox 実行コンテキストごとに変わりうる untracked を hash から除く。環境固有のファイル名やサイズには依存しない。reviewer の新規ファイル作成を黙って見逃さないよう、untracked の件数と名前は WARNING に残す。tracked の staged / unstaged 差分は従来どおり drift 検出対象とする。
- **フィルタの exit code を明示チェックする理由 (capture-first)**: 生の `git status --porcelain` と異なりフィルタは `mktemp` に依存するため、sandbox の TMPDIR 制限下では plain `git status` が成功してもフィルタは失敗しうる。helper はフィルタと `git for-each-ref` の出力を先に非パイプで capture し、失敗したら空入力の hash を出さずに WARNING を出して当該軸を skip する（空入力の hash を正常値として比べると、失敗が「変化なし」に化ける）。

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

ステップ 7（スコープ外指摘のトリアージ）が候補の処分を採否ゲートの出口だけで決める理由。

- **先延ばし動機**: エージェントには「指摘を先送りすれば fix ループが早く収束する」という構造的な先延ばし動機がある。処分をエージェント裁量や選択肢の並び順に任せると、保険的な follow-up Issue が増殖する。fix ループ側で skip → 別 Issue で loop 終了する経路は閉じており（`skills/iterate/SKILL.md`。残存 non-blocking の消化は機械 routing が担う）、ステップ 7 にも同じ動機を残さない。
- **先延ばし禁止の設計原則**: 仮説的な将来リスクに先手を打つ Issue は大半が無駄に終わる。スコープ内の実指摘は本 PR で解決し（fix ループで強制済み）、スコープ外候補は「起票せず記録して終わり」をデフォルトにする方が、Issue の増殖を防ぎ実際に着手される確率を上げる。
- **採否ゲートを裁量と候補ごとの確認の代わりに置く理由**: 候補ごとに人間へ尋ねると、工程の途中に人間の品質判断が常駐する。裁量に任せると上の動機で起票へ寄る。分類役が根因ごとに判定記録（契約・根拠・受入条件）を書き、ゲートが記録の欄だけから出口（file / record / fix / hold）を決めるので、エージェントの意思も重要度も出口に入らない。出口の出ない候補が残れば何も書かずに保留して止める（fail-loud）。対話でも E2E でも処分は同じになる。例外は ADOPT・`origin=pr` だけで、`/rite:iterate` からの review（mergeable と受入条件未検証の停止）では fix、単独実行では hold になる（登録を読む工程が iterate にしか無いため。scope-triage.md 手順 3 の `{fix_loop}`）。
- **Decision Log 記録を「追加」の経路とする理由**: fix ループの nit-noted 返信経路・acknowledged suppression（PR コメント / JSON ベースの再指摘抑制）は Decision Log 記録では代替されない。両者は別の目的（前者は次サイクルでの再指摘抑制、後者は仕様変更の記録）を持つため、置き換えではなく追加とした。
- **元 Issue が特定できない PR**: 記録先を「Section 9」「PR コメント」の 2 種に増やすと「シンプルさを死守」原則に反するため、代替の記録先を作らない。verdict が `file` の記録は先送りトークンの書き先が無いためその場で Issue を作り、`record` の記録は完了レポートに出口と reason を列挙する。ブランチ命名規則（`{type}/issue-{number}-{slug}`）ではほぼ全 PR が issue 番号を含むため、この縮退経路は稀。

## phase7-gate-notes

ステップ 7.7 / 8.0.2 gate の設計理由。

- **Defensive layering の全体像**: (a) ステップ 4.5 reviewer template が 3-classification を要求 → (b) ステップ 5.1 collection で classification を extract (default fallback あり) → (c) ステップ 7.1 で candidates を構築 → (d) ステップ 7.2 で採否ゲートが decided を返した後に証跡付き sentinel emit → (e) ステップ 7.7 で grep verify → (f) ステップ 8.0.2 で end-to-end gate continuity 参照。各層は個別に失敗しうるが、ステップ 7.7 は result emit 前の last-line-of-defense mechanical gate。ステップ 5/6 が abort-relevant findings を生成しても、ステップ 7.1 candidate extraction (recommendation_items) は独立しており ステップ 7.2 で採否ゲートの decided が必須。
- **dual placement (7.7 + 8.0.2) の理由**: ステップ 7.7 はステップ 7.1 → 7.2 → 7.7 の sequence で 7.7 が呼ばれた場合に 7.2 sentinel emit を verify する (procedure 内部の integrity check)。ステップ 8.0.2 はステップ 7 entire procedure (7.1-7.7) が skip された場合の最終 fallback で、`candidate_count >= 1` という trigger 条件が満たされている時点で「ステップ 7 が走るはずだった」と判定できる (ステップ 7.7 自体が呼ばれていない silent skip 経路でも catch する)。ステップ 8.0.1 W Phase gate と完全に対称的で、result-emit boundary における defense-in-depth pattern を構成する。
- **sentinel を decided の後に出し `mode=` / `choice=` / `reason=` を必須にする理由**: 7.7 / 8.0.2 が marker の有無だけを見ると、marker を出した直後に 7.4 へ短絡しても gate は pass する。ゲートの結果（`choice=` の verdict 別の件数と `reason=adoption_decided`）を同じ行に載せ、欠けた行を処分済みと読まない。marker 名は消費側の grep を保つため変えない。

## reviewer-selection-notes

ステップ 2.3 Sole reviewer guard の設計理由。

- **Sole reviewer guard の根拠**: 単一 reviewer は cross-file consistency check が見落とす blind spot を持つ。second perspective (Code Quality を baseline reviewer として追加) でこのリスクを緩和する。`pr-review-toolkit` の always-on `code-reviewer` と同じパターン。

## wiki-raw-source-placement-notes

ステップ 6.5.W Wiki Raw Source 生成の配置理由。

- **Position rationale**: 本 block は review-fix loop 終了後に配置される (caller `/rite:iterate` は `[review:mergeable]` または standalone 実行時のみ ステップ 6.5.W に入る)。loop 途中で書かれた Raw Source は未確定な review state を反映してしまうため、この配置は意図的。


## measured-gate-helper-notes

ステップ 5.3.0.M を helper に委譲した理由。

旧版は本ゲートを LLM の推論ステップとして書いていた。「自分の指摘を non-blocking 化して mergeable を宣言する」判断は reviewer 群の thoroughness 指示と正面衝突するため、裁量に置く限り構造的に実行されにくい — 実測した run では 9 サイクルすべてで一度も降格が実行されず、契約上 merge を止めてはならない散文精度指摘でループが 8 時間超継続した。分類を bash へ移し、mergeable 判定 (5.3.1) が LLM の分類を経由しない配置にする。

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

## spawn-spread-threshold-notes

ステップ 4.6 の spawn spread 閾値を **120 秒**にした理由と、判定を「観測のみ」に留める理由。値源を orchestrator spawn 時刻へ移した理由。

- **値源は 4.3.1 の orchestrator spawn 時刻**: reviewer 自己申告（`### 起動時刻`）はレポート執筆開始時刻に寄る。長時間サブエージェントでは実 spawn との乖離が閾値を超え、並列起動でも直列化と誤判定する（実測で spawn spread が 885s に達した cycle がある）。4.3.1 が Task 発行直前に 1 回 `date -u` し、同一メッセージの reviewer は同じ値を共有する。真の並列なら spread=0。別メッセージの初回 wave は新しい値を取るので、実際の直列化は残る。4.4 retry は初回を保持する（復旧を直列化と誤認しない）。閾値を広げても値源が執筆時刻のままでは測っているものが spawn ではない。
- **閾値 120 秒**: 同一メッセージ並列は spread=0 になるため、閾値は「別メッセージで初回 wave を分けた」ときの壁時計差を測る。wave 間は reviewer 1 人分の所要時間（実測で 10 分超）まで開く。両者は 1 桁以上離れており、閾値の置き所に精度は要らない。**誤検出を出さない側に倒す**方が重要（正常な並列を毎 cycle WARNING で汚すと、本物の直列化が埋もれる）ため、想定レンジ 90〜120 秒の保守側の端を採った。`--threshold` で上書きできるが、既定値の変更は運用データが積まれてから判断する。
- **なぜ強制せず観測だけなのか**: Task の発行は LLM の応答構造そのもので、hook から「1 メッセージにまとめて発行しろ」を強制する経路が存在しない。宣言的 MUST が破れることは既に機構化知見として昇格済みであり、本チェックはその適用として**宣言 → 機械観測**の一段だけを埋める。強制層を将来足すかどうかは、ここで貯まる `reviewer_spawn_spread_seconds` の分布が決める。
- **なぜ non-blocking なのか**: 直列化は壁時計を延ばすだけで、各 reviewer の指摘の質は変わらない。検出を merge ゲートや `overall_assessment` に結びつけると、成果が有効なレビューを効率違反を理由に捨てることになる。
- **判定できないときにフラグを書かない理由**: 契約とキー欠落の意味は [review-result-schema.md](../../../references/review-result-schema.md#reviewer_timings-と直列化フラグ) を SoT とする。

## placeholder-legend

本文の `{variable}` は Bash の `${var}` ではない。Claude がコマンド結果や前フェーズの値を埋める概念マーカー。混同するとシェル展開や未置換 placeholder が残る。

## intro-cycle-identity

cycle 1 を「呼び出し回数・context 残量に無関係のフルレビュー」と宣言する理由。

品質と context 効率のトレードオフ、Verification mode への暗黙フォールバック、レビュアー数の恣意的削減は、いずれも「今回は浅いレビューで足りる」という自己検閲を生む。Identity 契約は初回も再レビューも同じ基準を要求する。cycle 2+ の差分スコープは調査**範囲**だけを狭め、採否**基準**は変えない。

## contract-legacy-phase

Input 契約に `phase: phase5_review` を残す理由。

sub-skill が旧名をまだ書く経路があり、中断した旧セッションからの resume が新名だけだと recover で誤分類される。writer が全て flat `review` へ移るまで dual-accept する。

## e2e-minimization-scope

E2E で削るのはステップ 5–7 の人間向け表示だけ。ステップ 4 の sub-agent 並列実行・PR コメント投稿・recommendation disposition を時間や context を理由に省略すると workflow-identity 違反になる。例外 1–5 は「E2E からしか到達しない記録面」を minimize すると観測契約が空文になるため残す。

## e2e-askuser-split

AskUserQuestion を 2 種に分ける理由。

ステップ 7 のトリアージは未解決指摘・スコープ外指摘の握り潰し防止なので E2E でも処理自体は skip 禁止。処分は採否ゲートの出口だけで決め、候補ごとに質問しないので、E2E と standalone で処分は変わらない（例外は ADOPT・`origin=pr` の fix / hold で、`/rite:iterate` からの呼び出しかどうかで分かれる。scope-triage.md 手順 3 の `{fix_loop}`）。ステップ 3.3 の構成確認は iterate の自律ループと矛盾するため E2E で skip 可。サマリ行と省略 reviewer 表示は両経路で残す（silent capping 禁止）。

## worktree-ensure-preamble

ステップ 1.1.5 が session worktree を保証する理由。

ステップ 1.2 以降は作業ツリーから PR 変更を読む。worktree 不在（resume / context 圧縮 / 別セッション跨ぎ）のまま走るとメインツリー（develop）上で実行され、PR 変更を読めず scratchpad へ退避する degraded 動作になる。`branch_absent` / `failed` を `[review:error]` で止めるのは非対話サブ起動のため（recover の AskUserQuestion と対称にしない）。silent に develop を読んで完了扱いにすると mergeable が偽になる。

## numstat-explicit-flags

`numstat_availability` / `numstat_fallback_reason` を success path でも explicit set する理由。

undefined を残すとステップ 5.4 の placeholder が literal または error になる。空文字列で defined にし、失敗時だけ要約を入れる。stderr WARNING は会話から消えることがあるため、可視性の判断基準は retained flag。

## change-intelligence-reuse

ステップ 1.2.6 が ステップ 1.1 の `files` 配列を再利用する理由。

`path` / `additions` / `deletions` は既に取得済みで、別 API 呼び出しは不要。`git diff --numstat` は programmatic 集計用の補助であり、失敗しても 1.1 の配列で summary は作れる。Doc-Heavy 判定（1.2.7）は 1.1 の配列だけで完結するため、numstat 失敗は Doc-Heavy 精度に影響しない。

## complexity-lane-fallback-loud

`complexity_absent` を含む全 fail-safe を WARNING 付き `full` へ倒す理由。

宣言 Complexity が無い Issue では定常的に出うるが、loud にする根拠は「宣言が必ずある」ことではなく、`full` へ倒れた事実が レーンの効果計測の分母になる観測値だから。正常終了時の marker 欠落 / Issue 番号未特定も同じ consumer 側既定。helper は明示された絶対 `--cwd` へ移動し、入口で保持した `--repo` と origin を照合する。helper 非ゼロは実行場所・repository context の失敗として停止し、full 継続に置き換えない。

## doc-heavy-override-relationship

ステップ 2.2.1 を sole reviewer guard の前に置く理由。

Override は加算のみで既存候補を消さない。fenced block 検出時は tech-writer + code-quality で guard は発火しない。純粋散文では tech-writer 単独になり、後段の sole reviewer guard が code-quality を足す。どちらの経路でも最終的に ≥2 reviewers が保たれる。

スキャン範囲が 2.3 と違う理由: 本相は Doc-Heavy の code-quality 追加判定の先取りで `*.md` 全体を見る。2.3 の Code block detection は Prompt Engineer Activation のみ。本相は tagged fence に限定し、untyped fence は 2.3 に任せる。

## e2e-confirm-skip

ステップ 3.3 が E2E で AskUserQuestion を skip する理由。

iterate は mergeable まで自律的に回す設計で、cycle ごとに構成確認で止まるのは意図と矛盾する。判定は ready Phase 2.1 と同型の flow-state（`phase ∈ {review, fix}` + `active=true`）。helper 失敗時は standalone（確認を出す）へ fail-safe。表示ブロック（起動 reviewer サマリ・省略 reviewer）は両経路で出す。

## named-subagent-and-foreground

named subagent (`rite:{type}-reviewer`) を使う理由と、結果回収を completion notification に置く理由。

Phase B 以降、agent body を system prompt として載せる方が reviewer discipline の強制が強い。bare `{type}-reviewer` は plugin 配布で解決に失敗する。

現行 harness（fork mode 既定 on）は spawn した subagent を background で走らせ、foreground 要求を受け付けない。`run_in_background` は Agent tool に引数が無く、指定しても無効。結果は completion notification として後続 turn に届く。orchestrator は起動確認だけでは 5.1 に進まず、全 reviewer の通知が揃うまで待ち、未着の結果を推測・補完しない。同一メッセージ内の複数 Task は並列発行のまま（4.6 の spawn 時刻は Task 発行時刻）。

inline / 手動 verification は Detection Process・Confidence・Cross-File を迂回する rubber-stamp になるため禁止。

## shared-principles-hybrid

`_reviewer-base.md` を `{shared_reviewer_principles}` として絶対パスと読取義務で渡す理由。

named subagent の system prompt は各 agent ファイル本体だけで、別ファイルの共有原則は自動注入されない。共有原則は約 90KB あり、選定人数分を user prompt へ inline すると親が数百 KB を生成し、prompt の起動上限にも近づく。独立子の経路で採った絶対パス方式を named 経路にも使い、両経路の契約を 1 つにする。

読まずに進む reviewer は無言で共有原則を欠くため、先頭行の読取完了申告を親が照合し、欠ければ再試行する。1 回の Read で読み切れない大きさなので、分割して末尾まで読む義務を明示する。パスを解決・読取できないときに空で起動すると同じ欠落が起動側で起きるため、`[review:error]` で止める。

## recommendation-classification

`分類:` の欠落・規定外を既定値で補わず、producer gate で止める理由。

3 分類のうち `design_confirmation` だけが採否ゲートの候補から外れる。欠落や規定外の値をそこへ寄せると、reviewer が「別 Issue で直す」と書いた推奨が、起票・記録・保留のどの出口も経ずに消える。どの値へ寄せても reviewer の判断を orchestrator が上書きすることになるため、再生成で reviewer 自身に分類させ、再発すれば `[review:error]` で止める。

値は `分類:` の直後の 1 語とし、注記は ` — ` の後ろに置く文法に閉じる。値の後ろに注記を自由に続けてよいとすると、「2 つ目の値」と「注記の中の分類語」を字面で区別する判定が要り、接続語や括弧を足すたびに取りこぼしと誤拒否が入れ替わる。文法を producer の指示と gate で揃えれば、外れた書き方は再生成の診断で直せる。

分類は項目の冒頭（箇条書き記号と装飾の直後）の `分類:` だけから読む。文中や文末の `分類:` はラベルへの言及であり、その項目の分類の宣言ではない。行の中の最初の一致を読むと、「`分類: design_confirmation` を候補から外す点を別 Issue で直すべき」のように言及しただけの推奨が `design_confirmation` として通り、採否ゲートの候補から外れる。チェックボックス（`- [x] 分類: …`）や引用記号（`>`）を挟んだ項目は冒頭とみなさず、欠落として再生成に回す。

`recommendation_items` は全推奨の canonical。`candidate_count` は Source A + Source B（actionable/boundary）の dedup 後の合算に triage の hold の候補を加えた数で、7.7 / 8.0.2 の trigger になる。

## likelihood-evidence-before-demotion

5.1.0.L を 5.3.0 降格の前に置く理由。

現実的指摘の producer がアンカーを省略するのは retry 可能な契約違反。明示 Hypothetical 例外は正当な仮説指摘。順序を逆にすると省略が機械降格に吸収され、契約違反が消える。

## fingerprint-asymmetric-output

accepted fingerprint を JSON から消し Markdown に残す理由。

`/rite:fix` は JSON を読む。accepted finding を JSON に残すと次 cycle の fix loop に再入場する（decision-replay）。Markdown 側は audit log。適用は 5.3.0.M step 1 の JSON 生成時だけで、6.1.a は再生成しない。

## json-single-authoring-site

JSON 本文の書き手を 5.3.0.M step 1 に一本化する理由。

6.1.a / 6.1.b でも生成すると、ゲート適用後のローカル JSON が `mergeable` なのに PR コメントの Raw JSON は `fix-needed` という乖離が出る。`/rite:fix` Priority 3 は PR コメント側を読むため、次 cycle の分類が狂う。

`verdict` を step 1 で書かない理由: 移送後の blocking 件数が未確定で、書けば必ず推測値になる。書き手は `review-measured-gate.sh` のみ。

`findings[].verification` を書かない理由: helper がアンカーから算出する唯一の書き手。先に書くと既存値を尊重し、本ゲートが閉じた裁量が復活する。

## class-demotion-policy

5.3.0.C を 5.3.0.M の後・5.3.1 の前に置く理由。

実測付き blocking を class A（実行時挙動が変わる）/ class B（検出網・可読性・文書整合）に分け、A=0 の cycle で exclusion なし B を non-blocking にして churn 尾部を自然終了させる。exclusion 付き B（既存記述の削除/弱体化、合意済み AC の実測済み未充足、または指摘が主張する AC 未充足）は blocking 維持。判定表の `unmet` 行は AC ごとに 1 finding しか指せないため、同じ AC を指す他の指摘と acceptance が未充足と判定しなかった AC への指摘は map の `ac_claim` で拾い、acceptance との食い違いは降格ではなく警告で可視化する。gated finding の `verification.measured` が boolean でない入力は classification map で修復できないため、分類と書き換えの前に `measured_undetermined` で停止する。成功した実測ゲート出力の gated finding は boolean を持つ。不確実なら class B（攻め側既定。散文への実行観測の指摘を除く）。ファイルパスで機械分類しない。

classification map のパスに commit SHA を入れる理由: `${TMPDIR}` はセッション内不変で、含めないと前 cycle の map が同一パスに残り、step 1 を飛ばして step 2 だけ実行すると stale map を無音適用する。

## metrics-no-json-embed

default 経路（`post_comment_mode=false`）で metrics を JSON に埋め込まない理由。

review-result-schema.md に `metrics` top-level field が無い。schema 拡張は別 PR。それまでは `[CONTEXT] REVIEW_METRICS=` stderr emit が唯一の default 経路。opt-in 経路は PR コメント本文の末尾（Raw JSON 直前）に集約する。

## wiki-skip-emit-and-write-failed

Wiki ingest の skip / write 失敗を silent にしない理由。

設定 skip（disabled / auto_ingest_off）は正当な skip だが、caller の 8.0.1 W Phase gate は `WIKI_INGEST_*` 接頭辞しか見ない。status line と sentinel を出さないと「未実行」と「正当 skip」が区別できない。

heredoc write 失敗で trigger を起動していないのに `trigger_exit=1` を reason にすると誤帰属になる。root cause は `WIKI_CONTENT_WRITE_FAILED` だが gate はそれを見ないため、`WIKI_INGEST_FAILED; reason=content_write_failed` を別に出す。

## step7-terminal-results

ステップ 7 を `[review:mergeable]` と受入条件未検証の停止で走らせ、`[review:fix-needed:N]` では skip する理由。

`[review:fix-needed:N]` では fix loop が続き、最終 mergeable レビューで 7 を走らせれば重複 Issue 化を避けられる。

受入条件未検証の停止は、PR 内推奨の登録が無ければループの終端であり、iterate は再試行せずに止まるため再レビューは起きない。登録があれば iterate がそれを fix へ渡して再レビューするが、その再レビューが受入条件未検証の停止で終われば、同じく終端になる。終端では最終 mergeable レビューの前提が当てはまらないので、skip すると候補（Source B を含み、`total_findings == 0` でも 1 件以上になりうる）は 7.2 の処分を一度も受けずに消える。mergeable と同じく実行する。

## defense-in-depth-handoff

ステップ 8.0 で result emit 前に flow-state を更新する理由。

フォークコンテキストが caller に戻ったあと LLM が turn を終えても、state の `next_action` / `--handoff` が残るため `/rite:recover` と Stop hook で復帰できる。継続は `/rite:fix`、終了は `FINALIZE:review:mergeable`。機構は stop-loop-continuation-contract.md。

`error_count` を phase 遷移で 0 に戻す理由: 現在 production reader の無い reserved slot で、stale count を持ち越さない。`--preserve-error-count` のときだけ保持。

## w-phase-gate-sole

8.0.1 が W Phase skip の sole defense である理由。

`flow-state.sh` の phase enum は名前だけを見、W Phase sentinel の有無は見ない。wiki enabled なのに `WIKI_INGEST_*` が一つも無いのは 6.5.W 未実行。

## p64-defense-in-depth

ステップ 6.4 が 6.2 のあと Issue comment を冗長更新する理由。

local work memory が SoT、Issue comment は backup。どちらかが silent fail しても recover 用に少なくとも一方が正しい状態を持つ。

## aggregate-label-ban

ステップ 8.1 の result / E2E 行に「推奨 N 件」を書かない理由。

件数だけの aggregate は 7.7 が塞いだ「全て scope 外」ラベル回避と同型で、disposition を飛ばしたように見える。分類は 5.4 の推奨事項テーブル、完了報告の disposition は iterate の責務。

## mergeable-zero-findings-no-override

`total_findings == 0` で `[review:fix-needed:0]` に補正しない理由。

iterate は sentinel だけで routing する。fix は対象 0 件で完了し、次 cycle も同じ状態のまま `max_review_cycles` まで空転する。降格分の可視化は 5.4 の実測なし指摘 section と 6.1.d の関連 Issue 記録コメント。

## 6.1d-always-eval

6.1.d を `{post_comment_mode}` に依存させない理由。

既定 `post_comment: false` でも非実測指摘を破棄しない記録契約（D-01）。共有可能な永続チャネルは関連 Issue（cycle 中の update-in-place コメント + マージ時 follow-up Issue）であり、PR コメントではない。6.1.b / 6.1.c の完了で 6.1 を終わらせると、この第 3 経路が消える。ケース 2（永続化失敗 hard fail）だけは復旧優先で 6.1.d に進まない。

## 6.1c-machine-gate

6.1.c のケース分岐を helper に置く理由。

Claude が自然言語で `LOCAL_SAVE_FAILED` を読む設計は見落としで silent fallthrough し、silent data loss 防止が骨抜きになる。`post_comment=false` ∧ 保存失敗は `exit 2` の hard fail。WARNING + exit 0 では CI 検出性が足りない。

## verification-inline-ban

verification mode でも Task 経由必須の理由。

incremental diff が小さい / context 圧が高いときに inline すると、reviewer の Detection Process・Confidence・Cross-File が消える。verification は 4.5.1 + 4.5 を 1 prompt に載せる。

## decision-log-per-candidate

Decision Log append を候補ごとに単一 Bash invocation にする理由。

複数候補を 1 呼び出しでループすると `trap` が候補間で上書きされ tmpfile がリークする。

記録先を元 Issue 本文の Section 9 に一本化する理由: Section 9 が無いときに作業メモリへ逃がすと、作業メモリも無い Issue（Complexity S 以下で Section 9 を省いた Issue や cleanup の follow-up Issue）で記録先が尽き、人間の手動追記が定常経路になる。Section 9 を新設すれば記録は作業メモリの有無に依存せず、PR 作成時の Implementation Notes も同じ Section 9 から判断を読める。Issue 作成時に S 以下で Section 9 を省く規則は生成時のテンプレート規則であり、後から実際の判断を記録するための新設とは衝突しない。

採番を Section 9 の内側に限る理由: Section 9 は判断の記録がない本文にも新設されるため、本文の散文に D-NN を含む Issue（レビュー指摘の文面をそのまま転記する follow-up Issue 等）にも Section 9 ができる。本文全体を数えると散文の番号に 1 を足した値へ飛び、新設時の D-01 と連番にならない。境界は追記位置を決める awk と同じにし、数える範囲と書き込む範囲を一致させる。

## deferred-defect-token

先送りトークンを、採否ゲートの verdict が `file` の判定記録の Decision Log 行にだけ付ける理由。

Decision Log は「対応しない理由」の記録であって追跡ではない。起票すべき欠陥の行だけが残ると、誰も Issue を起こさないまま放置される。cleanup の follow-up 起票はレビュー結果 JSON の `non_blocking_findings[]` を読むため、推奨事項由来の欠陥はトークンが無いとそこに届かない。

記録先を JSON ではなく Decision Log 行そのものにするのは、7.4 が JSON 保存（6.1.a）の後に走り、保存済み JSON は停滞判定の受領記録と照合されるため書き換えられないから。同じ理由で、verdict が `fix` の候補（PR 内推奨）も JSON ではなく state の登録（`review-pr-recommendations.sh record`）に書く。Issue 本文は別環境の cleanup からも読めるが、JSON はそうとは限らない。

トークンは HTML コメントにして表示を汚さず、PR 番号を含めて別 PR の cleanup が拾わないようにする。付けるのは verdict が `file` の記録だけで、トークン付きの行は cleanup 6.0 の follow-up が採否ゲート（`--kind followup`）で判定し直し、出口が `file` のものだけを起票する。`record` の記録（`LINK` / `RESOLVED` / `REJECT`）には付けない。`LINK` は追跡先の既存 Issue があり、付けると二重起票になる。`RESOLVED` / `REJECT` は起票する欠陥ではない。起票の自動可否は cleanup 6.0.C の確認ゲート（batch `--merge` は確認しない、単独実行は確認する）にそのまま従う。

## 5.3-execution-order-why

5.3.0 → 5.3.0.M → 5.3.0.C → 5.3.1 の順を守る理由。

5.3.1 の Red blocking は全降格**後**の `全指摘事項` に対して働く。前段を飛ばすと Hypothetical / 非実測 / class B が blocking のまま残り、契約上止めてはならない指摘でループが続く。

## assignee-handoff-comment

既存 Issue を引き受け先にして新規作成を見送る経路に申し送りコメントを必須化した理由。

「引き受け先が実在する」判定だけで triage を閉じると、#N 側に何も残らず、後から「フォローアップ Issue 化はありませんか」と問われて初めてコメントが投稿される。Decision Log は元 Issue の記録であり引き受け先への通知ではない。CLOSED Issue は着手対象にできないため投稿せず、判定記録の `tracker` を直して 7.2 のゲートからやり直す。新しい質問を足さずゲートへ戻すのは、差し戻し先が既にあり inventory を増やさないため。`HANDOFF_COMMENT_REJECTED=1` のあとに 7.4.3 へ進むと申し送りコメントの必須化が空文になる。

## triage-write-mark

7.4.3 / 7.4.4 が書き込み済みを印で照合する理由と、印の key の作り方。

7.4.5 の台帳記録などで止まった処分は、7.2 から同じ候補で 7.4 をやり直す。Decision Log は最大 D-NN に 1 を足して追記するだけで、申し送りは投稿済みかを覚えていないので、照合しないと成功済みの書き込みが新しい番号・新しいコメントとして重なる。hold の解除を書き込みごとに分けて状態を持たせるより、書いた先に印を残して読み直す方が、途中のどこで止まっても同じ規則で済む。

key に `C-n` を使わないのは、run ごとに振り直すから。key を候補から毎回作り直さず、一度付けた key を判定記録ファイルの `write_keys` に出口と候補全文ごとに残して次の run で使うのは、再実行の再レビューが同じ根因を言い換えて出し直すと、分類役がその候補を前の run の候補と同じ記録に束ね、記録の候補集合が変わるから。材料を hold の候補に限っても、hold は 7.2 とゲートが run ごとにその run の全候補で書き直すので、束ねた言い換えが次の run では hold の候補になり key がずれる。残す先は hold ではなく、`issued` を run をまたいで持ち越すのと同じ判定記録ファイルにする（ゲートの保留は hold を作り直す）。前の run で key を持つ候補の無い記録は、出口と記録の全候補から作る。記録の単位は前の run と変えない。別々の key を持った候補を 1 つの記録に束ねると、どちらの印で照合するかを決められない。1 つの key の候補を複数の記録に分けると、同じ印を 2 件目が書き込み済みと読み、その記録を黙って書かない。どちらも書かずに止め、候補ごとの前の key を示して、手順 2 が前の単位に直させる（分けた 2 件目に新しい key を振ると、前の run が 1 行で記録した根因をもう 1 行書く）。`write_keys` は cleanup まで残るので、処分を終えた後の cycle で同じ候補の単位を変えても止まる（黙って key を振り直さない）。出口も key に入れるのは、判定が変わった再実行（例: `tracker` を直して REJECT が LINK になる）を別の記録として書くため。印に PR 番号を入れるのは、同じ本文に別 PR の処分の印があっても一致させないため。

照合できないとき（本文やコメントを読めない、key が 16 桁の hex でない）は書かない。未置換の key の印は全判定記録で同じになり、2 件目以降を書き込み済みと誤って飛ばす。

## acceptance-reviewer

受入条件確認を専任 reviewer にし、mandatory・cap 枠外で毎 cycle 起動する理由。

他の reviewer は「diff が導入した問題」を revert test で探すため、fix が機能を削り過ぎて AC を満たさなくなった状態や、最初から満たしていない AC を検出する責任を誰も持たない。欠落指向・全 HEAD 対象・差分スコープ非適用は専門 reviewer と別モードなので、既存 reviewer への責務追加ではなく専任にする。cap 枠内に数えると軽量レーンや `max_reviewers` で専門 reviewer の枠が 1 つ減り、品質を人数上限で縛ることになるため、cap 適用後に追加する。

判定表の AC-ID 集合と未充足 finding の残存を helper（`scripts/acceptance-criteria-check.sh`）で機械検査するのは、reviewer が AC を読み飛ばした出力や、降格ゲートで未充足 finding が消えた JSON を「全充足」と区別できないため。未充足行は降格されても未検証へ格下げしない — 不合格を観測した事実と finding の採否は別で、格下げは人間確認で通せる経路を再生産する。Accepted Fingerprint Suppression / Fact-Checking / Debate は免除せず、そこで finding が消えたら最終整合検査が error で止める（例外経路を増やさず fail-loud に倒す）。Deduplication だけ免除するのは、同じ file の別指摘へ統合されると `[AC-N]` 接頭辞の紐付けが壊れ、正常な未充足まで error になるため。

blocking 0 で未検証だけが残る cycle を `[review:mergeable]` にしないのは、agent が観測できなかった AC を黙って合格扱いにするため。新 sentinel を足さず `[review:error]` + `REVIEW_STOP=ac_unverified` にするのは sentinel 語彙と caller の分岐表を増やさないため。ステップ 8.0 は 8.1 より先に flow-state を書くので、同じ条件の行で handoff を付けない — 付けると FINALIZE の mergeable 完了経路へ Stop hook が差し戻す。iterate が自動再試行しないのは、同じ HEAD では再実行しても観測できないため。

## excluded-selection-reason

除外行にも `selection_reason` を非空で残すのは、保存後の最終ゲートが選定済みか否かに依らず非空を要求し、保存後は receipt を書き換えられず停止するため。`exclusion_reason` の複写は検査を通るが根拠の情報量がゼロになるので、分岐ごとに「候補になった経緯」を書かせる。生成時に外れた記録は Write 直後の `--record-file` 検査で保存前に止める。

## ci-base-conflict

PR が base と競合している間、GitHub は `pull_request` の workflow を起動しない。必須 check は欠落のまま終わらず、待機は上限まで続いても完了しない。上限判定より先に競合を見るのは、最後の取得で競合が見えた場合を期限超過と区別するためである。競合は CI の状態によらず見る。CI が古いコミットで成功済みでも、競合した PR の統合結果は検証されていないため、mergeable と確定させない。

競合で待てない cycle は、待っても閉じられない。5.3.0.CI は `review-finish` より前にあり、cycle はまだ証跡（manifest / content / result、保存済み receipt）を持たないので、`review-abandon` で閉じられる。放棄すると cycle が無くなり、commit ガードは base を取り込む merge commit を止めない。取り込んだ HEAD は次の cycle が、最後に保存したレビュー以降の差分としてレビューする。
