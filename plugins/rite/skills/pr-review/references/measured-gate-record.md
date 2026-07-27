# 非実測指摘の記録経路と実行保証 gate — 設計理由

`skills/pr-review/SKILL.md` ステップ 6.1.d（非実測指摘の PR コメント記録）と ステップ 8.0.3（その外部 gate）の rationale。SKILL.md 本体には実行時に必要な分岐表・sentinel 表・エラー処理のみを残し、設計理由は本ファイルへ退避する（skills 行数原則）。

出典: Issue #2024（実測必須ゲート、D-01）／ Issue #2034（Sub-C）／ close 済み PR #2030 の cycle 3 レビュー指摘。

<a id="single-invocation"></a>
## なぜ helper を単一 invocation にしたか（F-02）

PR #2030 は 6.1.d を「step 0: 既存コメント検索（markdown 埋め込み bash）→ step 1: 本文 Write → step 2: 投稿（別 bash）」の 3 ステップに分け、実行保証 gate（6.1.d step 3 と 8.0.3）の pass 条件を **step 0 が emit する `NONBLOCKING_LOOKUP=done` marker の存在**に置いていた。

これは「動作の完了」ではなく「動作の直前」を検証しており、**step 0 だけ実行して step 1-2 を skip しても両 gate が green で通過する**。既定設定 `pr_review.post_comment: false` では記録コメントが非実測指摘の唯一の共有可能な durable チャネルであるため、この穴は D-01（マージ後に人間が拾い直せる状態を保つ）の無音喪失に直結する。同 PR が emit していた `NONBLOCKING_RECORDED` / `NONBLOCKING_CLEAR_SKIPPED` は consumer がゼロで、gate はそれらを見ていなかった。

本実装は lookup・skip 判定・投稿を `hooks/review-nonblocking-record.sh` の **1 プロセス**に閉じ、terminal sentinel を EXIT trap から emit する。これにより:

- 「lookup だけ実行された」という中間状態が構造的に存在しない
- sentinel の存在 = 記録経路が終端まで走った、が定義上成立する
- `outcome` の初期値を `aborted` に置くことで、判定分岐へ到達する前の異常終了が success（`created` / `updated` / `skipped`）を騙れない
- caller が `existing_comment_id` を Bash 呼び出し間で受け渡す必要が消え、placeholder 経路が 1 本減る（`existing_id_placeholder_residue` reason は本実装に存在しない）
- skip 判定（0 件 ∧ 既存なし → 投稿しない）を LLM ではなく helper が持つため、AC-4 の非退行も機械的に保証される

**terminal sentinel は 1 種のみ**とし、成功／skip／失敗の区別は `outcome=` フィールドに畳む。marker を増やして「どれかが consumer ゼロ」という #2030 の失敗形を再生産しないため。

<a id="placeholder-gate-mapping"></a>
## placeholder residue gate の対応表（Issue #2034 MUST list との差分）

Issue #2034 の MUST は `{pr_number}` / `{non_blocking_count}` / `{existing_comment_id}` / `{review_tmp_dir}` の 4 点に gate を求めている。単一 invocation 化で substitution point 自体が変わったため、実装した gate 集合との対応を以下に明示する（MUST の黙殺を防ぐため）。

| MUST の placeholder | 実装した gate | 差分の理由 |
|---|---|---|
| `{pr_number}` | `--pr` の numeric gate（`pr_number_placeholder_residue`） | 変更なし |
| `{non_blocking_count}` | `--count` の numeric gate（`non_blocking_count_placeholder_residue`） | 変更なし。0 件時も `--count 0` を明示要求し、空文字と区別する |
| `{existing_comment_id}` | **なし（substitution point が消滅）** | helper が内部で lookup するため caller が渡さない。渡せない値に gate は置けない |
| `{review_tmp_dir}` | `--content-file` のブレース残留 gate（`content_file_placeholder_residue`） | 本文パスに `{review_tmp_dir}` が残ると `[ -s ]` が偽になり `body_file_empty`（Write 失敗）に潰れる。skill 定義のバグと本文生成の失敗は復旧手順が異なるため専用 reason を持つ |
| （新規）`{owner_repo}` | `--owner-repo` の `owner/repo` 形状 gate（`owner_repo_placeholder_residue`） | helper 化で API パスが引数になったため新設 |
| （新規）`{review_cycle_id}` | `--iteration-id` のブレース残留 gate（`iteration_id_placeholder_residue`） | 鮮度判定の参照値が未置換だと gate の cycle 一致判定が恒久的に成立しなくなる |

placeholder residue 系は **exit 1（loud）**、gh / IO 失敗は **exit 0（非ブロッキング、AC-3）** と扱いを分ける。前者は skill 定義のバグであり、記録の失敗ではないため。

なお placeholder gate は terminal sentinel の trap 設置より**前**に置く。ここで落ちた場合は記録経路が一度も走っていないため、`outcome=failed` を名乗らせず非ゼロ rc で caller に返す（gate 側は sentinel 不在として ERROR を出し、6.1.d へ戻す）。

<a id="iteration-id"></a>
## iteration_id を LLM が渡す理由（F-05）

`/rite:iterate` は同一 conversation で cycle ごとに `/rite:pr-review` を invoke するため、sentinel の**存在だけ**を見る gate は前 cycle の marker に false-positive match して silent pass する（AC-7）。

PR #2030 は cycle 識別子を 6.1.d step 0 の bash 内で `$(date +%s)` から生成していたが、これは **marker を emit する当のブロックの中で値が生まれる**ため、LLM 側に「本 cycle の値」を独立に保持した比較対象が残らない。gate は「最大 iteration_id の行」を採るしかなく、cycle 2 で 6.1.d を丸ごと skip した場合に「最大＝cycle 1 の値」が採用されて stale 判定が成立しない。

本実装は ステップ 6.1.a step 0（既に存在する `REVIEW_TMP_DIR` emit 用の bash）で `REVIEW_CYCLE_ID={pr}-{epoch}` を **1 度だけ**生成し、LLM がその値を (1) helper の `--iteration-id`、(2) gate の比較対象、の 2 箇所へリテラル置換する。値の生成と記録動作が別ブロックに分かれるため、gate は「terminal sentinel の `iteration_id=` が本 cycle の `REVIEW_CYCLE_ID` と**一致するか**」を等値で判定できる。ステップ 7.2 → 7.7 / 8.0.2 の `PHASE_7_ASKUSER_INVOKED` と同型。

<a id="gate-order"></a>
## 8.0 の gate 評価順序を規定した理由（F-04 / AC-6）

PR #2030 は 8.0.3 を追加した一方、先行する 8.0.2 の pass 行が「proceed to ステップ 8.1」のままだったため、**新設した 8.0.3 が到達不能**だった。個々の gate が終端（8.1）を直接名指しする書き方は、gate を 1 本足すたびに既存の全 pass 行を書き換える必要があり、書き換え漏れが即座に到達不能を生む。

そこで 8.0 冒頭に **gate 評価順序の規定**を 1 箇所だけ置き、各 gate の pass 行は「次の gate へ進む」とだけ書く。終端（8.1 へ抜ける条件）は順序規定側が持つ。8.0.4 を将来追加する場合も、順序規定に 1 行足すだけで既存 gate の pass 行は不変。

この不変条件は静的 pin で機械的に固定する（`hooks/tests/review-helpers-gate-behavior.test.sh` TC-5）: 8.0.1〜8.1 の区間に「proceed to ステップ 8.1」が出現しないこと、かつ順序規定が 1 箇所存在すること。

<a id="dual-gate"></a>
## 二層 gate（6.1.d step 3 ⇄ 8.0.3）が捕捉する failure mode の違い

- **6.1.d step 3（サブステップ内部の integrity check）**: 6.1.d に入ったが helper を呼ばずに 6.2 へ抜けた、を捕捉する。
- **8.0.3（result-emit boundary の外側）**: 6.1.d サブステップを**丸ごと** skip した、を捕捉する。内部 check は gate 自身も一緒に skip されるため、この failure mode には届かない。

ステップ 7.7（procedure 内部）⇄ ステップ 8.0.2（全体 skip）と同じ dual placement。**両者は同一の述語**（terminal sentinel の存在 ∧ `iteration_id` が本 cycle と一致）を異なる位置で評価する。片側だけ弱い述語にすると、その位置で F-02 の穴が再発する。

<a id="startswith"></a>
## marker 検索を前方一致にする理由

既存コメントの特定は **1 行目 marker への `startswith`（前方一致）**で行う。`contains` で本文全体を対象にすると、marker 文字列を引用しただけの別コメント（6.1.b が投稿するレビュー結果コメントの finding 本文、人間の Quote reply）が `last` で選ばれ、PATCH がそのコメントを丸ごと上書き破壊する。

write 側（ステップ 6.1.d step 1）が「variant A / B のどちらも 1 行目に marker 見出しを置く」を契約として守るため、前方一致でマッチ能力は損なわれない（引用返信は先頭に `> ` が付くため構造的に除外される）。

本文ファイルの非空検査を投稿前に置くのも同根で、空 body の PATCH は 1 行目 marker を消し、以降の lookup を恒久的に miss させる（update-in-place の永久破綻）。

<a id="static-pin"></a>
## 静的 pin に mutation 実測を要求する理由（F-03 / F-09 / F-10 / F-11）

PR #2030 が追加した静的 pin には、追加時点から一度も失敗しえない tautology が含まれていた（旧形状を検索する pin を、旧形状を消した同じ commit で追加していた — git 履歴で確定）。さらに:

- pin のコメントが謳う保証（「documented set 3 箇所を個別に確認する」）と実装（emit 1 箇所のみ検査）が乖離していた（F-09）
- `-ge 4` の下限判定は、散文 1 行の追加で live emit の削除を見逃す（F-10）
- 対象文字列の**存在**しか見ないため、`if false && ...` のような死に分岐化を検出できない（F-11）

したがって本 PR で追加する pin は以下を守る:

1. 件数判定は**等値**（`-ge` の下限判定を使わない）
2. 対象が**生きた実行経路**にあることを到達性 pin で確認する（隣接行が実際の呼び出し／分岐であること）
3. pin のコメントは実際に検査している対象だけを述べる
4. 追加時にその場で mutation（述語置換 / 死に分岐化 / 変数リネーム / 散文追加）を当て、落ちることを実測する

mutation の実測結果は PR 本文の mutation matrix に記録する。
