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

AskUserQuestion を 2 種に分ける理由（#1861）。

ステップ 7 のトリアージは未解決指摘・スコープ外指摘の握り潰し防止なので E2E でも処理自体は skip 禁止。Decision Log への可逆記録は question_resolution の推奨自律処理。ステップ 3.3 の構成確認は iterate の自律ループと矛盾するため E2E で skip 可。サマリ行と省略 reviewer 表示は両経路で残す（silent capping 禁止）。

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

宣言 Complexity が無い Issue では定常的に出うるが、loud にする根拠は「宣言が必ずある」ことではなく、`full` へ倒れた事実が AC-5 の効果計測の分母になる観測値だから。helper 非ゼロ / marker 欠落 / Issue 番号未特定も同じ consumer 側既定。

## doc-heavy-override-relationship

ステップ 2.2.1 を sole reviewer guard の前に置く理由。

Override は加算のみで既存候補を消さない。fenced block 検出時は tech-writer + code-quality で guard は発火しない。純粋散文では tech-writer 単独になり、後段の sole reviewer guard が code-quality を足す。どちらの経路でも最終的に ≥2 reviewers が保たれる。

スキャン範囲が 2.3 と違う理由: 本相は Doc-Heavy の code-quality 追加判定の先取りで `*.md` 全体を見る。2.3 の Code block detection は Prompt Engineer Activation のみ。本相は tagged fence に限定し、untyped fence は 2.3 に任せる。

## e2e-confirm-skip

ステップ 3.3 が E2E で AskUserQuestion を skip する理由。

iterate は mergeable まで自律的に回す設計で、cycle ごとに構成確認で止まるのは意図と矛盾する。判定は ready Phase 2.1 と同型の flow-state（`phase ∈ {review, fix}` + `active=true`）。helper 失敗時は standalone（確認を出す）へ fail-safe。表示ブロック（起動 reviewer サマリ・省略 reviewer）は両経路で出す。

## named-subagent-and-foreground

named subagent (`rite:{type}-reviewer`) と `run_in_background: false` 必須の理由。

Phase B 以降、agent body を system prompt として載せる方が reviewer discipline の強制が強い。bare `{type}-reviewer` は plugin 配布で解決に失敗する。

harness は省略時 default で background 起動する。background は起動確認だけ返して caller が turn を終え、結果回収と `error_count` が壊れる。同一メッセージ内の foreground Task は既に並列で、Claude は全結果を待ってから次へ進む。

inline / 手動 verification は Detection Process・Confidence・Cross-File を迂回する rubber-stamp になるため禁止。

## shared-principles-hybrid

`_reviewer-base.md` を user prompt の `{shared_reviewer_principles}` として渡す理由。

named subagent の system prompt は各 agent ファイル本体だけで、別ファイルの共有原則は自動注入されない。READ-ONLY / Mindset / Cross-File / Confidence を全 reviewer に届けるため、`## Input` 直前までの連続範囲を抽出する。個別見出しだけ拾うと間の節が落ちる。

## recommendation-classification

`分類:` 欠落時に `design_confirmation` を default する理由。

最も保守的（対応不要・観察のみ）で、欠落を actionable 扱いして Issue 化する先延ばしを防ぐ。欠落は `[CONTEXT] RECOMMENDATION_CLASSIFICATION_MISSING` で観測する。

`recommendation_items` は全推奨の canonical。`candidate_count` は Source A + Source B（actionable/boundary、user 採否後）の合算で、7.7 / 8.0.2 の trigger になる。

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

実測付き blocking を class A（実行時挙動が変わる）/ class B（検出網・可読性・文書整合）に分け、A=0 の cycle で B を全件 non-blocking にして churn 尾部を自然終了させる。実測未判定は分類対象外で class A 固定 — 判定不能を降格に丸めない 3 値モデル。不確実なら class B（攻め側既定）。ファイルパスで機械分類しない。

classification map のパスに commit SHA を入れる理由: `${TMPDIR}` はセッション内不変で、含めないと前 cycle の map が同一パスに残り、step 1 を飛ばして step 2 だけ実行すると stale map を無音適用する。

## metrics-no-json-embed

default 経路（`post_comment_mode=false`）で metrics を JSON に埋め込まない理由。

review-result-schema.md に `metrics` top-level field が無い。schema 拡張は別 PR。それまでは `[CONTEXT] REVIEW_METRICS=` stderr emit が唯一の default 経路。opt-in 経路は PR コメント本文の末尾（Raw JSON 直前）に集約する。

## wiki-skip-emit-and-write-failed

Wiki ingest の skip / write 失敗を silent にしない理由。

設定 skip（disabled / auto_ingest_off）は正当な skip だが、caller の 8.0.1 W Phase gate は `WIKI_INGEST_*` 接頭辞しか見ない。status line と sentinel を出さないと「未実行」と「正当 skip」が区別できない。

heredoc write 失敗で trigger を起動していないのに `trigger_exit=1` を reason にすると誤帰属になる。root cause は `WIKI_CONTENT_WRITE_FAILED` だが gate はそれを見ないため、`WIKI_INGEST_FAILED; reason=content_write_failed` を別に出す。

## step7-mergeable-only

ステップ 7 を `[review:mergeable]` のときだけ走らせる理由。

`[review:fix-needed:N]` では fix loop が続き、最終 mergeable レビューで 7 を走らせれば重複 Issue 化を避けられる。

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

iterate は sentinel だけで routing する。fix は対象 0 件で完了し、次 cycle も同じ状態のまま `max_review_cycles` まで空転する。降格分の可視化は 5.4 の実測なし指摘 section と 6.1.d の記録コメント。

## 6.1d-always-eval

6.1.d を `{post_comment_mode}` に依存させない理由。

既定 `post_comment: false` でも非実測指摘を破棄しない記録契約。6.1.b / 6.1.c の完了で 6.1 を終わらせると、この第 3 経路が消える。ケース 2（永続化失敗 hard fail）だけは復旧優先で 6.1.d に進まない。

## 6.1c-machine-gate

6.1.c のケース分岐を helper に置く理由。

Claude が自然言語で `LOCAL_SAVE_FAILED` を読む設計は見落としで silent fallthrough し、silent data loss 防止が骨抜きになる。`post_comment=false` ∧ 保存失敗は `exit 2` の hard fail。WARNING + exit 0 では CI 検出性が足りない。

## verification-inline-ban

verification mode でも Task 経由必須の理由。

incremental diff が小さい / context 圧が高いときに inline すると、reviewer の Detection Process・Confidence・Cross-File が消える。verification は 4.5.1 + 4.5 を 1 prompt に載せる。

## decision-log-per-candidate

Decision Log append を候補ごとに単一 Bash invocation にする理由。

複数候補を 1 呼び出しでループすると `trap` が候補間で上書きされ tmpfile がリークする。

## 5.3-execution-order-why

5.3.0 → 5.3.0.M → 5.3.0.C → 5.3.1 の順を守る理由。

5.3.1 の Red blocking は全降格**後**の `全指摘事項` に対して働く。前段を飛ばすと Hypothetical / 非実測 / class B が blocking のまま残り、契約上止めてはならない指摘でループが続く。
