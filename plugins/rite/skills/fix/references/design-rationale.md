# Fix SKILL Design Rationale

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md).
> 本ファイルは `skills/fix/SKILL.md` 本体から退避した**設計理由 (Why)** の受け皿。実行手順・分岐表・sentinel 表・
> エラー処理指示は SKILL.md 本体に残る。本体の該当箇所には `rationale: references/design-rationale.md#<anchor>`
> 形式のポインタがあり、逆引きできる。ここに書いてよいのは「なぜこの実装形なのか」「変更するなら何が壊れるか」
> の説明のみで、手順そのものを書いてはならない (二重管理防止)。

## inline-annotation-convention

SKILL.md 内の `verified-review` 注釈は `/verified-review` コマンドによるレビュー指摘の対応追跡に使用される。命名規則:

- `H-N` / `M-N` / `L-N` / `S-N` / `I-N` / `C-N` — 重要度プレフィックス (High/Medium/Low/Suggestion/Important/Critical) + サイクル内通番
- 括弧内 `(M10)` 等 — サイクル横断の統合追跡 ID

これらの注釈は git history でも追跡可能だが、コード内で変更理由の文脈を保持するため残している。

## argument-detection-rules

ステップ 1.0 Detection rules (順序ベース判定) の設計理由。

**RFC 3986 順序対応**: 順序 2 の regex は `?query` を `#fragment` の前後どちらでも許容する。RFC 3986 §3 ABNF (`URI = scheme ":" hier-part [ "?" query ] [ "#" fragment ]`) では `?query` が `#fragment` より先に来るのが正規順序だが、GitHub UI で生成されるコメント URL は両方の順序で出現しうる:

- `https://github.com/owner/repo/pull/123?notification_referrer_id=NT_abc#issuecomment-456` (RFC 準拠 / 通知メール / Copy link / Slack 連携経由) — group 2 で query を吸収
- `https://github.com/owner/repo/pull/123#issuecomment-456?notification_referrer_id=NT_abc` (旧 GitHub UI / 一部の bot) — group 4 で query を吸収
- `https://github.com/owner/repo/pull/123#issuecomment-456` (基本形) — group 2/4 ともに空

**bash 互換性と順序保証**: 順序 2/3 の regex は negative lookahead `(?!issuecomment-)` を使わない。bash の `[[ =~ ]]` (POSIX ERE) や `grep -E` は lookaround 系の構文をサポートしないため。順序 2 (issuecomment URL) を順序 3 (一般 PR URL) より先に試すことで、issuecomment URL は順序 2 でマッチして target_comment_id が抽出され、lookaround が不要になる。Source: [IEEE Std 1003.1 Chapter 9 — Regular Expressions](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html)

**順序 3 の受理範囲**: GitHub の "Files changed" タブから URL をコピーすると `pull/123/files` や `pull/123?tab=files` が返るため、`(/[^#?]*)?(\?[^#]*)?(#.*)?$` 形式で trailing path / query / fragment をすべて optional で受理する (`/files`, `/commits`, `/checks`, `?tab=files`, `?notification_referrer_id=...`, `#diff-{sha256}` 等)。pr_number のみ抽出する。

## review-file-flag-parsing

ステップ 1.0.1 の `--review-file` flag 抽出 bash の設計理由。

- **sed regex に `[[:space:]]` を使う理由**: tab 区切りのトークンも処理するため。
- **`printf '%s'` を使う理由**: `echo` は `-n`/`-e`/`-E` で始まるトークンを option として誤解釈するため。
- **sentinel が `null` ではなく `__RITE_UNSET__` である理由**: `null` を sentinel に使うと `--review-file null` を渡したユーザーが「`null` という名前のファイル」を意図した場合と衝突する。`__RITE_UNSET__` は legitimate な file path として現実に存在しないため衝突しない。
- **Pattern 1/2 の値 capture が `[^[:space:]]*` (0 文字以上) である理由**: `--review-file=` (値なし) や `/rite:fix 123 --review-file` (末尾フラグ単独) も match させ、空値を `review_file_path_empty_value` の明示エラーとして検出するため。1 文字以上 (`+`) にすると末尾空指定が regex non-match で silent fallthrough する。
- **境界マッチャー `([[:space:]]|$)` の理由**: `--review-file=foo` が `--review-files` や `--review-file-bogus` の prefix として誤検出される経路を塞ぐ。Pattern 2 の sed 側に境界がないのは、detection 側で境界 guard が効いた後にのみ実行されるため (else branch は detection regex が match した時のみ到達する)。

## bash-compat-guard

`mapfile` builtin は bash 4.0 で導入されたため、bash 3.2 (macOS default) では `mapfile -t < <(...)` が silent 失敗し、下流経路へ silent routing する regression を起こす。guard は prose 参照ではなく inline 実行可能コードとしてエントリ引数 parse bash block 冒頭 (fix: ステップ 1.0.1 Step 0 / review: ステップ 1.0 Step 0) に配置する (C-3 対応)。Source: GNU Bash 4.0 NEWS (https://tiswww.case.edu/php/chet/bash/NEWS)

## review-source-resolution

ステップ 1.2.0 caller guard の `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_source_resolve_failed` /
`reason=findings_maps_build_failed` emit は、retained-flag 規約 ([common-error-handling.md](../../../references/common-error-handling.md) 系統A: `exit 1` の前に
`*_FAILED=1` emit を要求) を満たすための caller-side generic guard。helper 側が具体 reason を stderr emit 済みでも、
caller の `exit 1` 直前に emit が必要になる。

## pr-comment-raw-json-extraction

ステップ 1.2.0 Priority 3 (PR comment 経路) の設計理由。

- **tempfile 経由 hand-off にした理由**: 大きい multi-line PR コメント本文を Claude が HEREDOC literal に埋め込む方式は escape 漏れ・truncate リスクがあるため廃止した。Broad Retrieval が specific path に書き出し、Priority 3 block が直接読み出す。ステップ 5.1 までの間に異常終了すると orphan 化するため trap で cleanup を保証する。
- **cat の exit code を独立 capture する理由**: exit code を check しないと、permission 変更 / NFS timeout / TOCTOU truncate で silent に空文字列になり、後段の awk parser が no-match → `raw_json=""` → legacy fallthrough に silent 合流する。
- **tempfile 不在時に [INFO] を emit する理由**: (a) Broad Retrieval が `📜 rite レビュー結果` コメントを発見せず tempfile を作成しなかった legitimate な経路 (新規 PR / review 未実行 / 削除済み) と、(b) Claude が Priority 3 進入時に Broad Retrieval bash block を skip した前提条件違反経路、の 2 ケースを区別して trace するため。機械的 enforcement は複雑で scope 外のため、observability を確保する対症療法として [INFO] を emit する。
- **awk が「`---` separator 後の最後の `### 📄 Raw JSON`」を採用する理由**: findings の description / suggestion 列内に `### 📄 Raw JSON` リテラル文字列が含まれる場合 (fix.md / pr-review.md 自身を扱う PR が該当)、最初のマッチで `in_section` を立てると本来の Raw JSON section より早く誤検出される。ステップ 6.1.b の Raw JSON section は必ず `---` separator の後にあるため、1-pass で末尾の section start を tracking し END 内で逆方向スキャンする。実装は POSIX awk のみで動作し、tac (GNU coreutils 専用) や 2-pass 読み込みを必要としない。
- **here-string `<<<` を使う理由**: `printf | awk` 形式は awk の `exit` による stdin 早期終了で printf が SIGPIPE を受ける経路がある (bash-defensive-patterns.md Pattern 5)。
- **awk exit code を明示検査する理由**: awk OOM / binary 異常の空出力が「Raw JSON section なし (legacy format)」と区別不能になり、legacy parser が新形式コメントを garble する silent regression を防ぐ。
- **3 つの失敗ケースを else の no-op に融合させない理由**: `raw_json=""` だけが legitimate な legacy fallthrough であり、「jq empty 失敗」「必須 fields 欠落」は壊れた新形式 JSON として WARNING + reason emit してから legacy parser に流すべき。

## schema-normalization-mirror

ステップ 1.2.0 Priority 3 の schema 1.1.0 後方互換 normalization の動作契約。Priority 0/2 (file-based) は
`scripts/review-findings-maps.sh` へ委譲済みで、本 block はその string-based 鏡像。

- (a) schema_version == "1.0"|"1.0.0" の場合、findings[] に欠落している scope を severity から default mapping (CRITICAL/HIGH/MEDIUM → current-pr、LOW-MEDIUM/LOW → nit-noted) で補完。1 件以上補完したら `[CONTEXT] REVIEW_SOURCE_SCOPE_DEFAULTED=1` を emit。
- (b) invariant #5: pre_existing == false ∧ scope == "nit-noted" の finding を検出。1 件以上あれば WARNING + `[CONTEXT] REVIEW_SOURCE_AUTO_CORRECTED=1` を emit し、scope を current-pr に自動書き換え。
- (c) (a) または (b) または (e) で mutation が発生した場合のみ raw_json を mutated 版に差し替える。
- (d) 後方互換: invariant #5 は pre_existing フィールドが存在する 1.1.0 JSON のみで発火する (1.0/1.0.0 では default mapping は scope を補完するのみで pre_existing は補完しない)。
- (e) auto_demote_low (default true) で severity == "LOW" ∧ scope == "current-pr" の finding scope を "nit-noted" に降格。`auto_demote_low: false` で opt-out 可。

**commit_sha stale detection で mismatch 時に WARNING のみで continue する理由**: PR コメントは最新の push 後に投稿される可能性が高く、legacy Markdown parser への fallthrough はむしろ情報損失になるため。

## fast-path-block-design

ステップ 1.2 Target Comment Fast Path の Block A/B/C 分割設計の理由。

- **「パス先行宣言 → trap 先行設定 → mktemp → gh api」の順序**: orphan race window を排除する。ステップ 4.5.1 / 4.5.2 / Fast Path で同型パターンに統一している。
- **confidence_override tempfile の無条件 truncate を統合 trap setup より前に置く理由**: このファイルは fix ループ全体で参照される orphan-by-design なファイル (前セッションの残留を許容する設計) であり、truncate 自体が失敗しても fix loop 全体の破綻ではないため trap 保護は不要。対照的に Block A の raw_json / intermediate は session 内限定の artifact であり trap 保護が必須。SIGINT/SIGTERM/SIGHUP で前セッションの override file が orphan として残った場合でも、無条件 truncate が次回起動時の混入を決定論的に防ぐ (H-1 継承)。
- **gh api の stderr を独立ファイルに退避する理由**: `2>&1` を付けると、成功時に gh が stderr に警告 (deprecation warning 等) を出した場合に `$target_comment` が invalid JSON となり直後の jq が失敗する。独立分離することで 404 / 403 / 5xx の詳細メッセージを失敗時に添付できる。
- **Block B の .issue_url post-condition の背景**: GitHub REST API `/repos/{owner}/{repo}/issues/comments/{id}` は PR/Issue を区別しない単一エンドポイント (PR は内部的に Issue でもある) で、コメント ID space を共有する。ユーザーが `pull/123#issuecomment-456` を渡したつもりが 456 が別 PR/Issue のコメントだった場合、gh api は exit 0 で別の comment body を返す (silent failure)。`.issue_url` が `/pull/{pr_number}` または `/issues/{pr_number}` で終わることを検証して防ぐ。
- **Block B の非 0 exit で upstream を invalidate する理由**: syntax error / subshell OOM / SIGPIPE / 将来の `set -e` 導入等の shell-level 非期待終了で validation を skip した状態の intermediate が残留すると、Block C が raw_json を検査せず pass する silent misclassification が成立するため。
- **Block C の raw_json 存在 check**: Block B validation 失敗経路で invalidate される対象のため、Block C 進入時に存在していれば Block A/B 正常完了の defense-in-depth な確認になる (Block B EXIT trap 非 0 exit 経路との二重防御)。
- **Fast Path 一時ファイルの多段 cleanup (ステップ 1.4 cancel / 1.5 / Cancel-Rerun 経路) が重複している理由**: Block C の trap が常に削除するが、Block A/B 成功後に orchestrator が異常終了して Block C 未到達の経路でも orphan を残さないための defense-in-depth。`rm -f` は idempotent なので二重削除でも副作用なし。

**Fast Path の一時ファイル構成 (Block A outputs)**: Block A は 4 ファイルを書き出し、後続 Block B/C が一時ファイル経由で読み出す:

- `raw_json`: gh api レスポンス全体 (Block B が `.issue_url` を再抽出、Block C は不使用)
- `intermediate_body`: `jq .body` の抽出結果 (Block C が final `body_file` にコピー)
- `intermediate_author`: `jq .user.login` の抽出結果 (Block C が final `author_file` にコピー)
- `intermediate_skip`: `target_author_mention_skip` の計算結果 (Block C が final `skip_file` にコピー)

**用語「intermediate」**: body/author/skip の 3 ファイルを指す。`raw_json` は別カテゴリ (intermediate 3 + raw_json = 合計 4 ファイル)。

**2-state commit pattern (`blockA_committed` / `handoff_committed`)**: Block A/C は同型の 2-state commit フラグで trap cleanup 対象を切り替える (trap + cleanup パターンの canonical 説明は [bash-trap-patterns.md#signal-specific-trap-template](../../../references/bash-trap-patterns.md#signal-specific-trap-template))。

- **Block A (`blockA_committed`)**: `0` (初期値) = 書き出し前/中の exit で raw_json + intermediate 3 ファイルを全削除 (orphan 防止)。`1` (全書き出し成功後) = raw_json と intermediate を保護し、err files のみ削除。
- **Block B**: 新規 output を持たないため commit flag を持たない。validation 失敗時は upstream (raw_json + intermediate 3 ファイル) を `_rite_fix_blockB_invalidate_upstream` で明示的に rm する。
- **Block C (`handoff_committed`)**: `0` (初期値) = 書き出し前/中の exit で handoff 3 ファイルも削除 (orphan 防止)。`1` (全書き出し + post-condition pass 後) = handoff 3 ファイルを保護。raw_json + intermediate 3 ファイル (合計 4) は成功/失敗問わず常に削除する (後続 phase では使わない)。

## interpretation-priority

ステップ 1.2 best-effort parse の応答解釈 (Step A/B/C) の設計理由。

**優先順位の変更理由**: 従来「キャンセルを最優先に置くことで安全側に倒す」という設計だったが、これはユーザーが明示的に「キャンセルせず〜」と述べた場合にも機械的にキャンセル側に倒してしまい、ユーザー意図の逆転を silent に引き起こす問題があった。打ち消し集合による前処理を経た上で、option 2 (手動入力) と option 3 (別 URL) を入れ替えることで、否定形応答の正しい解釈と曖昧応答の再質問を両立させる。

**「無応答」を判定基準から外した理由**: Claude Code の対話モデルでは「無応答」状態は通常発生しない (応答を待つ間ブロックされる)。タイムアウト等で無応答が発生した場合は AskUserQuestion 自体のエラーとして扱われ、解釈ループには到達しない。

## confidence-gate-notes

- **`touch` ではなく `: > {path}` で truncate する理由**: `touch` は POSIX 仕様上既存ファイルを truncate しない ([POSIX touch(1p)](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/touch.html) — 既存ファイルには `utimensat()` のみで content は変更されない) ため、前セッションの stale データに追記してしまう silent regression の原因になる。
- **`wc -l` の stderr を独立退避する理由**: `2>/dev/null` だと read permission 拒否 / inode 破損 / ファイル内容破壊などの IO エラーで silent に空文字列 → count=0 に落ちて、policy override の監査トレースが完成報告から silent drop する。
- **exit 時に confidence_override / pr-comment tempfile を明示的に rm する理由 (defense-in-depth)**: ステップ 1.2 進入時の無条件 truncate (`: >`) に削除を委ねると、何らかの経路で truncate 呼び出しが skip された場合に前セッションの stale データが混入する silent regression が起きる。ステップ 5.1 (E2E) / ステップ 5.2 (Standalone) の終了経路で specific path による明示 rm を行い、次回実行時の混入を決定論的に防ぐ。

## simplification-first-rationale

ステップ 2 冒頭に本原則を置く理由: 多サイクル PR の実測分析（2026-07、複数の長期レビュー run の永続レビュー結果 JSON 9 cycle 分）で、cycle 2 以降の blocking 指摘の約 8 割が「前 cycle の fix が導入した機構への指摘」だった。指摘への修正が規約・分岐・ガードの**追加**で行われると、次 cycle がその追加物を同じ厳密さでレビューして新たな構造欠陥を検出し、ループが収束しない。実例となった docs 変更は +64/-16 の docs 変更に fix 6 cycle・実時間 10 時間超を要し、序盤 cycle が積み上げた分岐機構を「削除して行全体再生成へ単純化する」fix が入った時点で初めて収束へ向かった。

新しいモデル世代（Opus 4.5 以降）には頼まれていない抽象・柔軟性を足す overengineering 傾向が公式に文書化されており（[Claude prompting best practices §Overeagerness](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-4-best-practices)）、追加型 fix はこの傾向と毎 cycle の全力 re-review の相互作用で発散する。

Escalation trigger が「前 cycle fix への指摘」を名指しする理由: 同分析で cycle 3 以降の指摘はほぼ全てこの型であり、パッチ重ね掛けスパイラルの最も確度の高い観測シグナルであるため。Root Cause Gate（ステップ 3.2.1）とは直交する — あちらは commit body に根本原因の**記名**を求め、本原則は修正の**形**（追加 vs 削除・単純化）を問う。

## impact-scan-rationale

ステップ 2.2.A Pre-Fix Impact Scan が必須である理由: 「指摘箇所だけ直す」では既存 caller / test / 他 file の同名
symbol を壊す silent regression が頻発する。指摘ゼロを目指してループする以上、デグレが入ると次 cycle で reviewer
が新規 finding を出し、fix ループが収束せず (サーキットブレーカー上限まで) reviewer の context を浪費する。
修正前の影響範囲確認で予防できる。Doc-Heavy PR 以外でも同様。

## nit-noted-reply-notes

- **nit-noted 経路が commit も PR reply も発生させない理由**: nit-noted は「修正不要の informational 指摘」のため code 変更 (Edit/Write) も commit も PR コメントも発生しない。`acknowledged_nit_count = {nit_noted_count}` で分類件数だけ積む。自律ループでは宛先の人間が不在で、認知返信は独り言になる。

## human-origin-reply-gate

login 比較は単一トークン運用で無効。rite 由来は本文 marker で判定する。判定不能は人間扱いに倒す（人間指摘の見過ごしは誤返信より高くつく）。

## retained-flag-emission

bash の `exit 1` は Bash tool の exit code に変換されるだけで Claude のフロー制御にはならない。ステップ 5.1 が
会話コンテキストで `*_FAILED=1` retained flag を検出しない限り、silent に `[fix:pushed]` / `[fix:replied-only]`
と判定される。このため mktemp 失敗を含むすべての失敗経路で `exit 1` の直前に retained flag を emit する
(成功経路の投稿失敗 emit と対称)。

## work-memory-update-rationale

ステップ 4.5.1 / 4.5.2 の設計理由。

- **PR body を single-quoted HEREDOC で書き出す理由**: double-quoted printf 形式は PR body 内の `"` でクォート閉じが起きるとシェル parser が後続テキストをコマンドラインとして解釈する構文エラーになり、さらに `$(...)` 形式の command substitution が literal 展開時に実行される command injection リスクを生む。PR body は外部入力 (PR 投稿者) であるため expansion の完全抑制が必須。
- **grep / git branch を pipeline 化せず独立 if-else で実行する理由**: bash pipefail は rightmost non-zero を返すため、`grep -oE '...' | head -1 | grep -oE '[0-9]+'` の 2 段 pipeline では先頭 grep の rc=2 (IO エラー) を末尾 grep の rc=1 (no match) が隠蔽し、IO error 分岐が到達不能になる (実証: `(exit 2)|(exit 0)|(exit 1)` → rc=1)。独立実行して終了コードを直接 case 分岐し、数字抽出は sed -n に移譲する (sed の失敗は無害な空文字結果)。Source: bash man page / [Baeldung — Exit Status of Piped Processes](https://www.baeldung.com/linux/exit-status-piped-processes)
- **grep IO エラーで exit 1 しない (soft failure) 理由**: `exit 1` は Claude のフロー制御にならず ([retained-flag-emission](#retained-flag-emission) 参照)、コメント宣言と実動作が矛盾する。retained flag のみ emit して継続することで、(1) retained flag の伝達経路が一貫する (ステップ 4.5 の失敗は全て `[fix:pushed-wm-stale]` 経路)、(2) コミット済み fix の損失を防ぐ、(3) caller は AskUserQuestion で続行/中断を判断できる (H-2 対応)。
- **wm_emit_done gate の理由**: retained flag の重複 emit はステップ 5.1 の reason 解釈を非決定的にし debug UX を悪化させる (M-4)。また IO error 経路で issue_number を空にするだけだと直後の branch fallback が誤起動して「IO error 経路なのに issue_number が設定される」semantics 破壊を起こす (M-5)。
- **issue_number 抽出失敗で retained flag を emit する理由**: 単に WARNING を出すだけだと E2E flow / hook 経由実行で人間の目に見えず、review-fix loop が更新失敗を認識しないまま `[fix:pushed]` を silent 出力し、次 iteration が stale work memory のまま続行する (HIGH-2 対応)。
- **4.5.2 の base_branch 解決を簡素化した理由**: grep exit 1/2 区別・sed IO エラー個別 reason は撤去済み。委譲後は git diff の失敗が単一の visible gate になるため、base_branch を誤解決しても silent fallback ではなく git diff 失敗として表面化する。
- **helper stderr を退避する理由**: `2>/dev/null` で破棄すると `WM_UPDATE_FAILED` 時に operator が root-cause (auth/rate/network/safety-check 詳細 + backup path) を追えない。pr-review.md ステップ 6.2 と同じ stderr-capture 規約。
- **変更ゼロ時の挙動**: helper の update-progress は空 changed-files-file を受けると `### 変更ファイル` セクション本文を空文字に置換するが、4.5.2 は fix commit 後に走るため git diff は全コミットを含み、変更ゼロは実運用で発生しない。

## wiki-ingest-notes

ステップ 4.6.W.2 で mktemp 失敗時に `/dev/null` fallback + WARNING とする理由: `|| commit_err="/dev/null"` を
silent に行うと `[ -s "$commit_err" ]` guard が no-op 化し、/tmp が壊れた host で exit code だけ見えて診断が
消える。WARNING で退避不能を明示する。review / fix / close の 3 skill で対称に保つ (single-source principle)。

## output-pattern-notes

ステップ 5 の設計理由。

- **用語定義 (soft failure / silent regression / stale / hard fail-fast) の詳細**:
  - **soft failure**: 致命的だが exit 1 で fix loop を kill せず、retained flag を emit してから caller に判断を委ねる失敗。ステップ 4.5 の grep IO エラー / git diff 失敗 / helper status 失敗 / Issue create 失敗等が該当し、ステップ 5.1 評価順テーブルで `[fix:error]` または `[fix:pushed-wm-stale]` に昇格する。
  - **silent regression**: soft failure を caller が silent に handle した結果 (例: `[fix:pushed]` と誤判定して次の iteration に進む)。retained flag 機構とステップ 5.1 評価順により caller に必ず通知される。
  - **stale**: work memory comment が最新の fix 内容を反映していない状態。`[fix:pushed-wm-stale]` 出力時の semantics で、caller は AskUserQuestion で続行/中断を選択する。
  - **hard fail-fast**: 即座に exit 1 で fix loop を kill する失敗 (引数 parse 失敗 / mktemp 失敗等)。`exit 1` だけでは Claude のフロー制御にならないため retained flag も併用する。
- **local-wm-update hook の stderr 退避 + lock/non-lock 分岐の理由**: `2>/dev/null || true` は lock contention だけでなく permission denied / script 不在 / bash syntax error / 内部致命的エラーもすべて silent suppress する。lock 判定の exact phrase pattern (`file is locked|lock contention|resource busy`) は、`lock|contention|busy` の緩い pattern が permission denied / device busy 等まで silent suppress する欠陥を避けるため (canonical: common-error-handling.md#hook-lock-contention-classification-canonical)。mktemp 失敗時も silent skip に戻さず、`2>&1` + `head -5` の簡易 fallback で可視化する。
- **WM_UPDATE_FAILED 網羅性 DoD 検証スクリプトの設計上の要点** (スクリプト本体は `hooks/scripts/fix-reason-coverage-check.sh`、呼び出しは SKILL.md ステップ 5.1):
  - `grep` 側は `WM_UPDATE_FAILED=1; reason=` で prefix を絞り、`CONFIDENCE_OVERRIDE_READ_FAILED` / `REPLY_POST_FAILED` / `ISSUE_CREATE_FAILED` の別 context flag を前方一致で自動除外する。
  - `awk` 側は `| reason | 発生 Phase | 発生条件 |` の table header 行を起点に `in_table=1` を開始し、非 `|` 行で戻すことで reason 表のみを対象とする。他テーブルや周辺段落を起点/終点トリガーにしないため、blockquote が `**` 強調に格上げされても in_table 範囲を壊さない。
  - `sed 's/\$.*//'` は表側 reason に shell 変数展開 suffix が含まれる場合に備えた defensive 正規化 (現状該当なし、将来の drift 誤検出防止のため残置)。
- **error_count のリセット挙動**: `flow-state.sh set` は phase transition ごとに error_count を 0 にリセットし、`--preserve-error-count` 指定時のみ既存値を保持する。error_count は現在 production reader のない reserved/legacy schema slot で、リセットにより将来の再導入時に stale count を持ち越さない。

## contract-legacy-phase

`phase: phase5_fix` を Input 契約に残すのは、sub-skill が旧名をまだ書く経路があり、中断した旧セッションからの resume が新名だけだと recover で誤分類されるため。writer が全て flat `fix` へ移るまで dual-accept する。

## e2e-output-minimization-scope

E2E で削るのは完了報告の表示だけ。fix 本体・commit/push・work memory を時間や context を理由に省略すると workflow-identity 違反になる。

## fullwidth-normalization

順序 1 の全角数字救済は日本語 IME の誤投入を吸収するためのもの。正規化は silent にすると別 PR を触ったことに気付けないので INFO を出す。ASCII のみは no-op なので INFO を出さない。

## worktree-ensure-preamble

fix はステップ 2 以降で作業ツリーを Edit/Write する。session worktree が無いとメインツリー (develop) 上で走り、`git branch --show-current` が develop を返して issue 抽出が空になり、最悪 develop へ修正を書く。`branch_absent` / `failed` を `[fix:error]` で止めるのは非対話サブ起動のため (recover の AskUserQuestion と対称にしない)。

## hybrid-source-priority

会話 > ローカルファイル > PR コメントのハイブリッドは、同一セッションの即時連携とセッション横断再開を両立するため。`--review-file` 明示時に P1–P3 へ silent fallthrough しないのは、ユーザーがそのファイルを使う意図を捨てないため。

## priority2-helper-delegation

Priority 2 成功時に Fast Path / Broad Retrieval を skip するのは、file-based source では PR コメント経路が不要だから。map 構築と schema 1.1.0 normalization は `review-findings-maps.sh` に委譲済み (旧 inline の verbatim emit)。helper の reason SoT は docstring。

## confidence-override-h1

H-1: ステップ 1.2 進入時に confidence_override tempfile を無条件 truncate するのは、前セッションが SIGINT 等で orphan を残しても次回起動へ混入させないため。機械的な値取得をファイル経由にするのは、会話履歴 grep が context 圧縮で欠けるため。`[CONTEXT]` 行の併用は人間が tail で見える補助であり、機械取得の SoT ではない。

## external-tool-title-case

`/verified-review` は rite plugin 配下に無く、ユーザーレベルの独立コマンド。同コマンドと `pr-review-toolkit:review-pr` は Title Case (`Critical` / `Important`) を使うため別名マッピングが必須。絵文字エイリアスは未検証の将来互換で、実ツールが出力したら Note に追記する。

## measured-map-construction

`measured_map` は正規化前の原ファイルから、`scope_map` は helper 正規化後 tempfile から来る。登録条件に原 scope を使うと auto-demote の二重計上と auto-correct の未登録 (ゲート bypass) が両方向に起きる。現行世代では `false` を持つ finding の scope は nit-noted のままなので破綻シナリオは限定的だが、規則は fail-safe として固定する。

JSON 経路の `non_blocking_count` が 0 になるのは、write 側が gated な非実測 finding を `non_blocking_findings[]` へ移送する契約のため。N 件が入るのは Markdown / 会話経路のみ。全経路一致は未成立。

`(.verification.measured // false)` で畳むと、verification を持たない旧 JSON と形式崩れアンカー (helper が `verification` を書かない = 未判定) の全 finding が non-blocking になり、ループが指摘を解消せず空転する。

## human-thread-provenance

`measured_map` は file:line キーなので、非実測 finding と同座標の人間 thread が巻き込まれ、fix も reply もされずに「対応済み」へ入る。出自確認できない thread は External review (安全側)。振り替えは `non_blocking_count` 減算を伴うため、無痕跡だと finalize 等式が永久不成立になり `max_review_cycles` まで空転する。

## accept-cycle-markers

「本 cycle 内で accept 決定が発生」は `ACCEPT_FINGERPRINT_PERSISTED` と `ACCEPT_FINGERPRINT_PERSIST_FAILED` の両方をトリガーにする。reply は永続化の成否に関わらず完了しており、失敗時は次回 review で suppression が効かない。ここで re-review しないと `[fix:replied-only]` で正常終了し、suppression 未確認のまま loop が終わる。`{accept_count}` (累計) を使うと過去 cycle の 1 件で恒久継続になり無限 re-review する。

条件の SoT はステップ 5.1 Output Pattern テーブル row 4/5。4.6 Note と Handoff 節は参照のみ (bit-exact 手動同期に頼らない)。旧 Phase 4.3 の「別Issue作成」残骸を条件に複製していた事故への再発防止。

## wiki-ingest-placement

4.6.W / 4.6.W.2 をループ退出後に置くのは、途中で書いた raw が未決着の fix 状態を永久化するため。trigger は raw を dev 作業ツリーへ書き、commit helper が wiki ブランチへ移す。ページ統合は `/rite:wiki-ingest` の責務。

## reviewer-display-single-source

`{reviewer_display}` 展開ルールはステップ 2.1 の表が単一源。ステップ 3.2 trailer は同表を参照するだけで literal を複製しない (drift 防止)。
