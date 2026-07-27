# 非実測指摘の記録経路と実行保証 gate — 設計理由

`skills/pr-review/SKILL.md` ステップ 6.1.d（非実測指摘の PR コメント記録）と ステップ 8.0.3（その外部 gate）の rationale。SKILL.md 本体には実行時に必要な分岐表・sentinel 表・エラー処理のみを残し、設計理由は本ファイルへ退避する（skills 行数原則）。

関連: Issue #2024（実測必須ゲート、D-01）。

<a id="single-invocation"></a>
## なぜ helper を単一 invocation にしたか
記録経路を「step 0: 既存コメント検索 → step 1: 本文 Write → step 2: 投稿」の 3 bash に分け、実行保証 gate（6.1.d step 3 と 8.0.3）の pass 条件を **step 0 が emit する lookup marker の存在**に置く構成は成立しない。

それは「動作の完了」ではなく「動作の直前」を検証しており、**step 0 だけ実行して step 1-2 を skip しても両 gate が green で通過する**。既定設定 `pr_review.post_comment: false` では記録コメントが非実測指摘の唯一の共有可能な durable チャネルであるため、この穴は D-01（マージ後に人間が拾い直せる状態を保つ）の無音喪失に直結する。同構成で emit されうる `NONBLOCKING_RECORDED` / `NONBLOCKING_CLEAR_SKIPPED` のような marker も、gate が見ていなければ consumer ゼロで意味を持たない。

本実装は lookup・skip 判定・投稿を `hooks/review-nonblocking-record.sh` の **1 プロセス**に閉じ、terminal sentinel を EXIT trap から emit する。これにより:

- 「lookup だけ実行された」という中間状態が構造的に存在しない
- sentinel の存在 = 記録経路が終端まで走った、が定義上成立する
- `outcome` の初期値を `aborted` に置くことで、判定分岐へ到達する前の異常終了が success（`created` / `updated` / `skipped`）を騙れない
- caller が `existing_comment_id` を Bash 呼び出し間で受け渡す必要が消え、placeholder 経路が 1 本減る（`existing_id_placeholder_residue` reason は本実装に存在しない）
- skip 判定（0 件 ∧ 既存なし → 投稿しない）を LLM ではなく helper が持つため、AC-4 の非退行も機械的に保証される

**terminal sentinel は 1 種のみ**とし、成功／skip／失敗の区別は `outcome=` フィールドに畳む。marker を増やすと「どれかが consumer ゼロ」の状態を再生産するため。

<a id="placeholder-gate-mapping"></a>
## placeholder residue gate の対応表
Issue #2034 の受入基準は `{pr_number}` / `{non_blocking_count}` / `{existing_comment_id}` / `{review_tmp_dir}` の 4 点に gate を求めていた。単一 invocation 化で substitution point 自体が変わったため、実装した gate 集合との対応を以下に明示する（要求の黙殺を防ぐため）。

| 要求された placeholder | 実装した gate | 差分の理由 |
|---|---|---|
| `{pr_number}` | `--pr` の numeric gate（`pr_number_placeholder_residue`） | 変更なし |
| `{non_blocking_count}` | `--count` の numeric gate（`non_blocking_count_placeholder_residue`） | 変更なし。0 件時も `--count 0` を明示要求し、空文字と区別する |
| `{existing_comment_id}` | **なし（substitution point が消滅）** | helper が内部で lookup するため caller が渡さない。渡せない値に gate は置けない |
| `{review_tmp_dir}` | `--content-file` のブレース残留 gate（`content_file_placeholder_residue`） | 本文パスに `{review_tmp_dir}` が残ると `[ -s ]` が偽になり `body_file_empty`（Write 失敗）に潰れる。skill 定義のバグと本文生成の失敗は復旧手順が異なるため専用 reason を持つ |
| （新規）`{owner_repo}` | `--owner-repo` の `owner/repo` 形状 gate（`owner_repo_placeholder_residue`） | helper 化で API パスが引数になったため新設 |
| （新規）`{review_cycle_id}` | `--iteration-id` のブレース残留 gate（`iteration_id_placeholder_residue`） | 鮮度判定の参照値が未置換だと gate の cycle 一致判定が恒久的に成立しなくなる |

**caller 契約違反 7 種**（placeholder residue 5 種 + `content_file_missing` + `unknown_option`）は **exit 1（loud）**、本文不備 / gh / IO 失敗は **exit 0（非ブロッキング、AC-3）** と扱いを分ける。前者は skill 定義のバグであり、記録の失敗ではないため。`content_file` の**不在**は step 1 の Write 呼び出し漏れ＝契約違反であって IO 失敗ではないので、非空検査に潰さず独立の gate にする（潰すと記録ゼロのまま gate が pass する）。

なお placeholder gate は terminal sentinel の trap 設置より**前**に置く。ここで落ちた場合は記録経路が一度も走っていないため、`outcome=failed` を名乗らせず非ゼロ rc で caller に返す（gate 側は sentinel 不在として ERROR を出し、6.1.d へ戻す）。

<a id="iteration-id"></a>
## iteration_id を LLM が渡す理由
`/rite:iterate` は同一 conversation で cycle ごとに `/rite:pr-review` を invoke するため、sentinel の**存在だけ**を見る gate は前 cycle の marker に false-positive match して silent pass する。

 cycle 識別子を 6.1.d の bash 内で `$(date +%s)` から生成する構成は成立しない。**marker を emit する当のブロックの中で値が生まれる**ため、LLM 側に「本 cycle の値」を独立に保持した比較対象が残らないからである。gate は「最大 iteration_id の行」を採るしかなく、cycle 2 で 6.1.d を丸ごと skip した場合に「最大＝cycle 1 の値」が採用されて stale 判定が成立しない。

本実装は ステップ 6.1.a step 0（既に存在する `REVIEW_TMP_DIR` emit 用の bash）で `REVIEW_CYCLE_ID={pr}-{epoch}` を **1 度だけ**生成し、LLM がその値を (1) helper の `--iteration-id`、(2) gate の比較対象、の 2 箇所へリテラル置換する。値の生成と記録動作が別ブロックに分かれるため、gate は「terminal sentinel の `iteration_id=` が本 cycle の `REVIEW_CYCLE_ID` と**一致するか**」を等値で判定できる。ステップ 7.2 → 7.7 / 8.0.2 の `PHASE_7_ASKUSER_INVOKED` と同型。

<a id="gate-order"></a>
## 8.0 の gate 評価順序を規定した理由
gate を足すとき、先行 gate の pass 行が「proceed to ステップ 8.1」のままだと**新設 gate が到達不能**になる。個々の gate が終端（8.1）を直接名指しする書き方は、gate を 1 本足すたびに既存の全 pass 行を書き換える必要があり、書き換え漏れが即座に到達不能を生む。

そこで 8.0 冒頭に **gate 評価順序の規定**を 1 箇所だけ置き、各 gate の pass 行は「次の gate へ進む」とだけ書く（実リテラルは `the next gate in the 8.0 evaluation order`）。終端（8.1 へ抜ける条件）は順序規定側が持つ。8.0.4 を将来追加する場合も、順序規定に 1 行足すだけで既存 gate の pass 行は不変。

この不変条件は静的 pin で 2 層に固定する（`hooks/tests/review-helpers-gate-behavior.test.sh` TC-5e）。単層では塞げないため両方要る:

1. **構造 denylist（言語非依存）**: 区間内の **表の行**（行頭 `|`）が終端 `ステップ 8.1` を名指ししないこと。判定材料が「表の行であること」と節番号リテラルだけなので、行の文面が和文でも英文でも効く。散文中の cross-reference は表の行ではないため対象外。
2. **表記 allowlist（英文のみ）**: 英文 pass 行（`Gate passes` を含む行）がすべて規約文言 `the next gate in the 8.0 evaluation order` を含むこと。「次の gate を正しく指す」正の契約を固定する。**行の抽出自体が英語リテラル依存**であり、和文で書かれた pass 行は分子・分母の双方から落ちてこの層をすり抜ける — その穴は層 1 が塞ぐ。

加えて順序規定が 1 箇所だけ存在すること。

<a id="dual-gate"></a>
## 二層 gate（6.1.d step 3 ⇄ 8.0.3）が捕捉する failure mode の違い

- **6.1.d step 3（サブステップ内部の integrity check）**: 6.1.d に入ったが helper を呼ばずに 6.2 へ抜けた、を捕捉する。
- **8.0.3（result-emit boundary の外側）**: 6.1.d サブステップを**丸ごと** skip した、を捕捉する。内部 check は gate 自身も一緒に skip されるため、この failure mode には届かない。

ステップ 7.7（procedure 内部）⇄ ステップ 8.0.2（全体 skip）と同じ dual placement。**両者は同一の述語**（terminal sentinel の存在 ∧ `iteration_id` が本 cycle と一致）を異なる位置で評価する。片側だけ弱い述語にすると、その位置で「動作前 marker を見る」欠陥が再発する。述語には比較対象の**選択規則**（複数ある `REVIEW_CYCLE_ID` のうち epoch 最大を採る）まで含める — 選択規則が片側にしか無ければ「同一の述語」は成立しない。

<a id="startswith"></a>
## lookup と本文検査の設計理由（PATCH 先の同定）

`hooks/review-nonblocking-record.sh` は本節を rationale の実体として参照する（helper 側は契約の宣言のみを持つ）。

**lookup は「自分が投稿した」∧「1 行目 marker への前方一致（`startswith`）」の連言**で行う。

- **author 条件が必須な理由**: 前方一致だけでは、marker で始まるコメントを第三者が 1 件投稿するだけで `last` がそれを掴み、PATCH 先が奪われる。書込権限があれば他人のコメントを丸ごと上書き破壊し、権限不足なら 403 で `patch_failed` に落ちて以後の cycle も同じ id を掴み続け、記録が恒久的に失われる。
- **`contains` を使わない理由**: 本文全体を対象にすると、marker 文字列を引用しただけの別コメント（6.1.b が投稿するレビュー結果コメントの finding 本文、人間の Quote reply）が `last` で選ばれる。
- **前方一致でマッチ能力が損なわれない理由**: write 側（ステップ 6.1.d step 1）が「variant A / B のどちらも 1 行目に marker 見出しを置く」を契約として守るため。引用返信は先頭に `> ` が付くため構造的に除外される。

**投稿前に本文を 2 段で検査する**（非空 → 1 行目が marker で始まる）。どちらの契約違反も、1 行目 marker を失ったコメントを PATCH で作り出し、以降の lookup を恒久的に miss させる（update-in-place の永久破綻）。空 body だけを塞ぐと、本文生成が失敗した非空ケース（例: エラーメッセージだけが書き込まれた本文）が素通りする。診断の分離のため両者は別 reason（`body_file_empty` / `body_marker_missing`）にする。

**lookup が自分の投稿を見つけられないときは単一コメント不変条件を意図的に諦める**: gh 失敗による degraded に加え、別アカウント / 別トークン identity で過去に投稿した記録が残っている場合（author 条件により自分の投稿として拾えない。この場合 `degraded=0` のまま）も同様に、`count > 0` なら新規作成へ縮退する。既存の記録コメントが実在していれば 2 通目が作られ、古い方は孤児として残る。skip して記録を落とすより、重複してでも記録を残す方を選んだ（WARNING と `degraded=1` で可視化されるため silent ではない）。ユーザー向け文書が「update-in-place の 1 件」と書くのはこの縮退を除いた通常時の挙動。

<a id="static-pin"></a>
## 静的 pin に mutation 実測を要求する理由
静的 pin は、追加時点から一度も失敗しえない tautology になりやすい（典型は「旧形状を検索する pin を、旧形状を消した同じ commit で追加する」形）。加えて次の失敗形がある:

- pin のコメントが謳う保証と実装が乖離する（「3 箇所を個別に確認する」と書いて 1 箇所しか見ていない等）
- 下限判定（`-ge N`）は、散文 1 行の追加で live な参照の削除を見逃す
- 対象文字列の**存在**しか見ないため、`# ` を足したコメントアウトや `if false && ...` の死に分岐化を検出できない
- **出現回数**を pin すると双方向に誤る — live な述語を差し替えつつ同区間に散文を 1 行足せば数が相殺されて素通りし（false negative）、逆に gate を変えない散文追加だけで落ちる（false positive）
- **現行の表記**（英語 1 語句・特定のインデント幅）に係留すると、house style に沿った自然な言い換えで素通りする。denylist ではなく allowlist（「pass 行は必ず規約文言を含む」）にすれば表記変更に耐える
- **区間スコープの pin** は終端 anchor の不一致が無音で区間を EOF まで拡張し、隣の節の同名行を拾って通ってしまう

したがって pin は以下を守る:

1. 数ではなく **live な述語そのもの**を要求する（`**Check**: ...` のような load-bearing な行の存在）
2. 対象が**生きた実行経路**にあることを行頭 anchor + 到達性検査で確認する
3. denylist ではなく allowlist で書く（現行表記への係留を避ける）
4. 区間スコープを使うときは**終端 anchor の存在自体を先に assert する**
5. pin のコメントは実際に検査している対象だけを述べる
6. 追加時にその場で mutation（述語置換 / コメントアウト / 表記言い換え / 散文追加 / 区間境界変更）を当て、落ちること（かつ無害な変更では落ちないこと）を実測する

mutation の実測結果は PR 本文の mutation matrix に記録する。pin の実装は `hooks/tests/review-helpers-gate-behavior.test.sh` の TC-5。
