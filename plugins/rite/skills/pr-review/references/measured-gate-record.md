# 非実測指摘の記録経路と実行保証 gate — 設計理由

`skills/pr-review/SKILL.md` ステップ 6.1.a / 6.1.d（レビュー結果の保存・記録経路）と、その外部 gate（ステップ 8.0.3 / 8.0.4）の rationale。SKILL.md 本体には実行時に必要な分岐表・sentinel 表・エラー処理のみを残し、設計理由は本ファイルへ退避する（skills 行数原則）。

関連: 実測必須ゲート（非実測指摘を破棄せず記録する契約）。

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
| `{review_tmp_dir}` | `--content-file` のブレース残留 gate（`content_file_placeholder_residue`） | 未置換パスは存在しないパスなので、専用 gate が無ければ後段の存在検査 `content_file_missing` に潰れる。どちらも caller 契約違反だが、前者は skill テンプレート側の substitution 漏れ、後者は step 1 の Write 呼び出し漏れで復旧手順が異なるため独立の reason を持つ |
| （新規）`{owner_repo}` | `--owner-repo` の `owner/repo` 形状 gate（`owner_repo_placeholder_residue`） | helper 化で API パスが引数になったため新設 |
| （新規）`{review_cycle_id}` | `--iteration-id` のブレース残留 gate（`iteration_id_placeholder_residue`） | 鮮度判定の参照値が未置換だと gate の cycle 一致判定が恒久的に成立しなくなる |

**caller 契約違反 7 種**（placeholder residue 5 種 + `content_file_missing` + `unknown_option`）は **exit 1（loud）**、本文不備 / gh / IO 失敗は **exit 0（非ブロッキング、AC-3）** と扱いを分ける。caller 契約違反 7 種を exit 1 にするのは、skill 定義のバグであり記録の失敗ではないため。**exit code と pending marker の保持は別軸**である点に注意 — 本文不備 4 種は `exit 0` でありながら marker を残し emit を差し戻す（下記「消す / 残すの境界は『原因』で引く」を参照）。`content_file` の**不在**は step 1 の Write 呼び出し漏れ＝契約違反であって IO 失敗ではないので、非空検査に潰さず独立の gate にする（潰すと記録ゼロのまま gate が pass する）。

なお placeholder gate は terminal sentinel の trap 設置より**前**に置く。ここで落ちた場合は記録経路が一度も走っていないため、`outcome=failed` を名乗らせず非ゼロ rc で caller に返す（gate 側は sentinel 不在として ERROR を出し、6.1.d へ戻す）。

<a id="iteration-id"></a>
## iteration_id を LLM が渡す理由
`/rite:iterate` は同一 conversation で cycle ごとに `/rite:pr-review` を invoke するため、sentinel の**存在だけ**を見る gate は前 cycle の marker に false-positive match して silent pass する。

 cycle 識別子を 6.1.d の bash 内で `$(date +%s)` から生成する構成は成立しない。**marker を emit する当のブロックの中で値が生まれる**ため、LLM 側に「本 cycle の値」を独立に保持した比較対象が残らないからである。gate は「最大 iteration_id の行」を採るしかなく、cycle 2 で 6.1.d を丸ごと skip した場合に「最大＝cycle 1 の値」が採用されて stale 判定が成立しない。

本実装は ステップ 6.1.a step 0（既に存在する `REVIEW_TMP_DIR` emit 用の bash）で `REVIEW_CYCLE_ID={pr}-{epoch}` を **1 度だけ**生成し、LLM がその値を (1) helper の `--iteration-id`、(2) gate の比較対象、の 2 箇所へリテラル置換する。値の生成と記録動作が別ブロックに分かれるため、gate は「terminal sentinel の `iteration_id=` が本 cycle の `REVIEW_CYCLE_ID` と**一致するか**」を等値で判定できる。ステップ 7.2 → 7.7 / 8.0.2 の `PHASE_7_ASKUSER_INVOKED` と同型。

<a id="gate-order"></a>
## 8.0 の gate 評価順序を規定した理由
gate を足すとき、先行 gate の pass 行が「proceed to ステップ 8.1」のままだと**新設 gate が到達不能**になる。個々の gate が終端（8.1）を直接名指しする書き方は、gate を 1 本足すたびに既存の全 pass 行を書き換える必要があり、書き換え漏れが即座に到達不能を生む。

そこで 8.0 冒頭に **gate 評価順序の規定**を 1 箇所だけ置き、各 gate の pass 行は「次の gate へ進む」とだけ書く（実リテラルは `the next gate in the 8.0 evaluation order`）。終端（8.1 へ抜ける条件）は順序規定側が持つ。8.0.5 以降を追加する場合、**既存 gate の pass 行は不変**。ただし静的 pin 側は連動更新が要る — TC-5d の期待リテラル（順序規定の全文を `grep -cF` する。ファイル全体を数える assertion と 8.0 区間に限定する assertion の **2 本**があり、両方を書き換える）と TC-5e の `_g_spec` list（gate ごとのデータ行数 / pass 行数 / ERROR 行数）の 2 pin。後者を忘れると新 gate だけ per-gate 検査が走らず、部分削除・意味反転の穴がその gate に対して再び開く。

この不変条件は静的 pin で 3 層に固定する（`hooks/tests/review-helpers-gate-behavior.test.sh` TC-5e）。単層では塞げないため 3 つとも要る:

1. **構造 denylist（言語非依存）**: 区間内の **表の行**（行頭 `|`）が終端 `8.1`（`ステップ` 接頭辞の有無を問わない bare 表記も含む）を名指ししないこと。判定材料が「表の行であること」と節番号リテラルだけなので、行の文面が和文でも英文でも効く。散文中の cross-reference は表の行ではないため対象外。
2. **表記 allowlist（全称、言語非依存）**: 区間内の**全データ行**（`^|` かつヘッダー/セパレータ行を除く）が、規約文言 `the next gate in the 8.0 evaluation order` / `**ERROR**` / `legitimately skipped` のいずれかを含むこと。件数一致ではなく全称で判定するため、和文で書かれた pass 行が規約文言を欠いたまま紛れ込んでもこの層で確実に検出される（層 1 だけに頼らない）。層 1・層 2 が通す余地を残すのは、**規約文言 3 種のいずれかを含みつつ、リテラル `8.1` を使わずに終端への直行を追認する言い回し**（層 1 は表記 `8.1` に、層 2 は規約文言の有無に係留しており、いずれもこの軸を見ていない）。逆に規約文言を 1 つも持たない行は層 2 が確実に検出する。
3. **gate ごとの実在性と hand-off（厳密等値）**: 各 gate 区間のデータ行数と、`Gate passes` ∧ 規約文言を共起させる pass 行数と、`**ERROR**` 行数を、gate ごとに厳密な等値で固定する（`_g_spec` の `見出し:データ行数:pass 行数:ERROR 行数`）。**層 1・層 2 はいずれも行の削除に無反応**であり、AC-6 の中核 failure mode（pass 行の削除で後続 gate が到達不能になる）を捕捉するのは本層のみ。加えて ERROR 行数の等値は、層 2 の allowlist トークン `legitimately skipped` が escape hatch となって層 1・層 2 が素通りさせる **ERROR 行の極性反転**を捕捉する唯一の層でもある。実測: 8.0.2 の pass 行 1 本を削除すると本層の 3 assertion のうち 2 本（データ行数・pass 行数）が落ち、層 1・層 2 は緑のまま通る。

加えて順序規定が 1 箇所だけ存在すること。

<a id="dual-gate"></a>
## 二層 gate（6.1.d step 3 ⇄ 8.0.3）が捕捉する failure mode の違い

- **6.1.d step 3（サブステップ内部の integrity check）**: 6.1.d に入ったが helper を呼ばずに 6.2 へ抜けた、を捕捉する。
- **8.0.3（result-emit boundary の外側）**: 6.1.d サブステップを**丸ごと** skip した、を捕捉する。内部 check は gate 自身も一緒に skip されるため、この failure mode には届かない。

ステップ 7.7（procedure 内部）⇄ ステップ 8.0.2（全体 skip）と同じ dual placement。**両者は同一の述語**（terminal sentinel の存在 ∧ `iteration_id` が本 cycle と一致）を異なる位置で評価する。片側だけ弱い述語にすると、その位置で「動作前 marker を見る」欠陥が再発する。述語には比較対象の**選択規則**（複数ある `REVIEW_CYCLE_ID` のうち epoch 最大を採る）まで含める — 選択規則が片側にしか無ければ「同一の述語」は成立しない。

<a id="pending-marker"></a>
## 8.0.3 に機械強制（pending marker）を併置した理由

sentinel の grep は **LLM が会話を読む**ことを前提にしている。読まずに result pattern を emit する経路は prose では構造的に塞げず、実際に本 PR 自身の review cycle で `non_blocking_findings` を持つ 14 cycle のうち記録が PR に届いたのは 1 cycle だけだった（残りは gate が ERROR を出したのか、そもそも評価されなかったのかを事後に区別できない）。「gate を守る対象の外に置く」だけでは、gate の**発火**が保証されても gate の**評価**は保証されない。

そこで ステップ 6.1.a step 0 が `${TMPDIR:-/tmp}/rite-nbr-pending-<review_cycle_id>` を作り、6.1.d の helper が EXIT trap で消す。8.0.3 の bash が `[ -e ]` で見るだけで「6.1.d が完走したか」が LLM の認識に依存せず決まる。設計上の要点は 3 つ:

1. **消す / 残すの境界は「原因」で引く（exit code ではない）** — 差し戻せば収束するもの（caller 契約違反）は残し、差し戻しても同 cycle 内で収束しないもの（gh / network / rate-limit / IO）は消す。
   - **残す**: 引数 gate 群（placeholder residue 5 種 / `content_file_missing`、trap 設置**前**の `exit 1`）と本文検査 4 段（`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`、trap 設置**後**の `retain_pending_marker=1`）。いずれも caller (LLM) が本文 / `--count` を作り直せば 1 iteration で収束する。
   - **消す**: `patch_failed` / `create_failed` / lookup degraded / `body_check_unavailable`（本文述語の評価自体が失敗した環境起因。発生位置は本文検査と同じだが、本文を作り直しても解消しないため「残す」側ではない）、signal 中断（`signal_aborted`）、および正常終了（`created` / `updated` / `skipped`）。8.0.3 へ伝えるのは「完走した」ことだけで、成否は terminal sentinel の `outcome=` が担う。これにより非ブロッキング契約（AC-3）を gate 側へ持ち込まない。

   境界を **exit code**（trap 設置の前後）で引いてはならない。本文検査 4 段は trap 設置**後**に検出されるため、exit code で線を引くと「caller 起因で決定論的に再現する」と定義した契約違反が gh outage と同じ扱いになり、機械強制から外れる。marker 保持は `overall_assessment` を変えず「result pattern を emit してよいか」だけを止めるため、引数 gate 群が既に行っている挙動と構造的に同一である。この分離は AC-3 の改訂で仕様側に明文化されており、AC-3 が保証するのは判定値の不変であって emit 可否ではない — 本 marker 保持は AC-3 の carve-out に該当する経路そのものであり、例外的な逸脱ではない。carve-out の canonical 定義は [common-error-handling.md#non-blocking-contract-canonical-定義](../../../references/common-error-handling.md#non-blocking-contract-canonical-定義) の「判定値と emit 可否の分離」行。
2. **gate 側で marker を削除しない** — 削除すると 6.1.d を実行せず再評価だけで gate を通せてしまい、機械強制の意味が消える。静的 pin はこの不在（`rm -f "$pending_marker"` が 8.0.3 区間に 0 本）も固定する。
3. **削除文は helper の EXIT trap 内にあること自体が不変条件** — 関数外（末尾 `exit 0` の直前）へ移すと、early `exit 0` で抜ける経路（AC-4 の正常系である「0 件 ∧ 既存なし」の skip）で marker が残り、8.0.3 が毎 cycle `exit 1` を返して `[review:mergeable]` を永久に emit できないデッドロックになる。静的 pin は「件数 1 本」ではなく **`_rite_p61d_cleanup` 区間内に 1 本 / 区間外に 0 本** の配置で固定する（件数 pin は移動を検出できない）。

marker を作れない環境（read-only な `${TMPDIR}` 等）では `NONBLOCKING_GATE=degraded` に倒し、prose 判定のみで続行する。機械強制が使えないことを sentinel で可視化したうえで、従来の防御は維持する（degraded を無音にしない）。

**選択規則も述語の一部**: 8.0.3 の Pre-Check が置換する `{pending_marker}` は、`**Check**` の `REVIEW_CYCLE_ID` と**同じ選択規則**（会話に複数ある場合は末尾 `-{epoch}` が最大のもの＝本 cycle のもの）で採る。ただし本 cycle の marker が作れず空文字で emit された場合は、epoch で順序付けできないため空文字を優先する（過去 cycle の実パスは helper が削除済で、採ると `pending_marker_absent` の誤 pass になる。後述の「限界」＝ステップ 6 全体が skip されたケースとは別の経路）。二層は「6.1.d が本 cycle で完走したか」という同一の問いを異なる位置で評価するものなので、片側にだけ選択規則を置くと層ごとに別 cycle の値を見ることになる。

**限界**: 本機構が保証するのは「6.1.d が完走した」ことまで。ステップ 6 を丸ごと skip した cycle では本 cycle の marker がそもそも作られず、会話に残る前 cycle の**実パス**（前 cycle の helper が削除済）を採ると `pending_marker_absent` として **pass** する（`degraded` にはならない — `degraded` に倒れるのは置換値が空文字か `{...}` 形状のときだけ）。この限界は ステップ 8.0.4 が塞ぐ（下記 [#save-pending-marker](#save-pending-marker)）。

<a id="save-pending-marker"></a>
## save-pending marker（8.0.4）の設計理由 — anchor 配置 / id 受け渡し / marker の意味 / 差し戻し先

本 gate が塞ぐのは「ステップ 6 全体の skip」で、上記「限界」がそのまま顕在化した形になる。この状態では中間サイクルの永続 JSON が残らず、6.1.d の記録コメントも PATCH されないまま、どの gate も発火しない。

**なぜ 6.1.a が落ちやすいか**: 6.1.a は JSON 本文の生成を 5.3.0.M step 1 に譲っており、現在は「bash を 1 行打つだけ」の低顕著性ステップである。E2E 出力最小化下の中間 cycle では、この種のステップが最も落ちやすい。

**anchor 配置が設計の核心**: 実行保証の marker は、守る対象（ステップ 6）の**外側**で、かつ**毎 cycle 再生成される**位置に張らなければならない。候補は 2 つあったが等価ではない。

- **5.3.0.M step 1**（不採用）— この block の出力は `REVIEW_TMP_DIR=${TMPDIR:-/tmp}` だけで、値はセッション不変。stale な値を再利用しても Write 先は正しく解決するため、block を skip しても下流に何の齟齬も出ない。6.1.a step 0 が skip された理由（唯一の出力の消費者が、それ自身 skip 可能なステップだけ）と構造的に同一で、anchor 自身が同じ失敗をする。
- **5.3.0.M step 2**（採用）— `review-measured-gate.sh` の `blocking={n}` は毎 cycle 変わり、`total_findings` を経て `[review:fix-needed:{n}]` に直結する。stale 値を使えば result pattern が目に見えて壊れるため、この block だけは構造的に skip できない。

**なぜ helper は path ではなく id を受け取るのか**: caller から full path を受け取る形にすると、caller 由来の任意文字列が「削除対象」と「機械可読 sentinel の `marker=` フィールド」の両方へ同時に流れる。この形では traversal（`<dir>/rite-p61a-pending-x/../victim`）・sentinel 偽造（改行で 2 行目に完全な形の `[CONTEXT]` 行を綴る）・制御文字の 3 方向を個別に塞ぐ guard が要り、しかもその guard の受理値域が**生成側の値域**（`${TMPDIR}` の文字種）と食い違った瞬間に「保存は成功しているのに marker が消えず 8.0.4 が恒久的に落ちる」非収束を生む。id だけを受け取り path を helper 内で組み立てれば、この失敗クラスは構造的に存在しない（sibling の 6.1.d helper が `--iteration-id` で同じ形を採っているのと同型）。8.0.4 が使うのは path 側だけで、両者は同じ block から対で emit される。

**marker の意味は「実行された」であって「成功した」ではない**: `review-result-save.sh` は保存失敗（`LOCAL_SAVE_FAILED`）でも EXIT trap で marker を削除する。成功時のみ削除する設計にすると、D-04 非ブロッキング契約（保存失敗は WARNING のみ）が 8.0.4 経由で blocking gate に化ける。保存失敗の可視化は既存の `LOCAL_SAVE_FAILED` と ステップ 6.1.c ケース 2（`post_comment=false` との組み合わせで `exit 2`）が既に担っており、二重化する必要がない。helper が起動した cycle で marker が残るのは (i) trap 設置**前**の `exit 1`（`--content-file` 未指定 / unknown option）と `--pending-id` の形状違反で path を導出できなかった場合、(ii) `rm` 自体が失敗した場合の 2 群。(i) は 8.0.3 の引数 gate 群と同じ「caller 契約違反は差し戻せば収束する」境界だが、(ii) は環境起因で再実行では収束せず手動削除を要する。`--pr` 欠落 / 非数値は trap 設置**後**の `exit 0` かつ marker path が `--pending-id` から独立に導出されるため marker は削除される。

**差し戻し先が 6.1.a step 0 であること自体が不変条件**: 8.0.4 の ACTION が step 2（保存 helper）だけを名指しすると、step 0 が emit する `REVIEW_CYCLE_ID` と `NONBLOCKING_PENDING_MARKER` が前 cycle の値のまま残り、8.0.3 が再び自己整合で誤 pass する。step 0 → step 2 の順で差し戻すことで、8.0.4 の発火が 8.0.3 の anchor 再生成を連鎖的に引き起こし、ステップ 6 全体の実行が回復する。この推移的性質があるため、`REVIEW_CYCLE_ID` の生成位置そのものを 5.3.0.M へ移す（6.1.d に同じ per-cycle anchor を直接与える）改修は本 Issue では不要と判断した。

<a id="durable-id"></a>
## PATCH 先の同定を本文照合から durable な comment id へ移した理由

`hooks/review-nonblocking-record.sh` の lookup 述語は、PR #2038 の cycle 1〜5 で 4 度強化された（author 条件 → sentinel の位置非依存 `contains` → 本文全体の `endswith` → 最終非空行の等値）。そのたびに新しい抜け道が見つかり、最後まで消えなかったのが **「記録コメントの raw markdown を copy-paste して作られた、同一 author の人間コメント」** である。機械専用 sentinel は rendered view に現れない HTML コメントだが、Edit view / `gh api` / `gh pr view --comments` から raw ごと複製できるため、「人間が書き写す経路が存在しない」とは言えない。この場合 `-X PATCH` が人間の本文を丸ごと上書きする。

**本文の文字列で「自分が投稿したもの」を同定する限り、この残余は原理的に消えない。** 述語をさらに厳しくする方向（5 回目の強化）は採らず、同定手段そのものを本文の外へ移した。

**なぜ PR body か**（Issue #2041 Open Question の (a)）:

- **記録コメント本文には置けない** — 本文に置いた id は raw の copy-paste で marker ごと複製され、本文照合と同じ誤認経路が再生する。同定子は「複製経路から構造的に隔離された場所」にある必要がある。
- **`.rite/` 配下には置けない** — gitignore かつ machine-local のため、別マシン / CI から回した cycle では読めず、毎回 fallback に縮退する。
- **PR label も採らない** — repo 全体に label が増える副作用があり、id ごとに新しい label を作る設計は repo を汚す。
- PR body は PR に紐づく永続領域で、rite 内で書き換える経路は `pr-create` の作成時だけ（`gh pr edit --body` を持つ skill は他に無い）。人間が消せば fallback へ倒れるだけで、現状より悪くならない。

**2 段解決の順序と帰結**:

| 段 | 条件 | 帰結 |
|---|---|---|
| 1 | PR body の id が指すコメントが実在し author が自分 | それを canonical とする（本文を一切読まない） |
| 1 | id が指すコメントが **404** | 削除済みとみなし**新規作成**へ倒す（fallback へ倒さない） |
| 1 | id が非数値 / PR body 読取失敗 / 404 以外の取得失敗 / author 不一致 | **fallback** へ倒す |
| 2 | 上記で確定しなかった場合 | 現行 3 条件（author ∧ 1 行目 marker 前方一致 ∧ 最終非空行 sentinel）で探す |

**404 と一時障害を分けるのは帰結が逆だから**。削除済みなら新規作成が正しい（かつて canonical だった記録が消えた以上、本文照合で別のコメントを掴むより新しい 1 件を作る方が意図に近い）。一方 network / rate-limit の一時障害で新規作成へ倒すと、**実在する canonical の隣に重複を作る**。判別は `gh` が 404 時に stderr へ出す `HTTP 404` / `Not Found` で行う。

**`degraded=1` の意味を「PATCH 先を特定できなかった」に狭めた**。本文照合の lookup が失敗しても durable id で PATCH 先が確定していれば update-in-place は成立するため、そこを degraded に含めると「既存コメントを特定できない」という事実と異なる案内が出るうえ、本 Issue が消そうとしている「degraded 縮退 → 重複記録コメント」を自分で再導入することになる。自 login の取得失敗だけは id 経路の author 検証も不能にするため従来どおり `degraded=1`。

**本文照合の走査は id 解決の成否に依らず常に実行する**。id で PATCH 先が確定した cycle でも、孤児 / 重複（`NONBLOCKING_LEGACY_ORPHAN` / `NONBLOCKING_DUPLICATE_RECORD`）の観測を落とすと PR 上の残骸が silent になる。id 経路が節約するのは「本文で同定すること」であって「PR の状態を見ること」ではない。

**永続化のタイミングと失敗時の扱い**: 新規作成した cycle は `gh pr comment` が返す URL（`...#issuecomment-{id}`）から id を取り、PR body へ書く。fallback で canonical を見つけた cycle も書く（durable id を持たない既存 PR の migration 経路）。id 経路で解決できた cycle は PR body に同じ値が既にあるため書き直さない。永続化に失敗しても記録は成功扱いのままで、**pending marker も残さない** — 環境 / IO 起因であり caller が本文を作り直しても解消しないため、`body_check_unavailable` と同じ削除バケットに属する（retain 側へ落とすと 8.0.3 が毎 cycle 差し戻し、result pattern を永久に emit できなくなる）。

**id 不在では marker を出さない**。永続化前（初回 cycle / 既存 PR）は fallback が正しい経路であり、毎 cycle WARNING を出すと本当の異常（`id_author_mismatch` 等）が埋もれる。fallback で同定できた時点で id が書かれるため、この状態は 1 cycle で解消する。

<a id="startswith"></a>
## lookup と本文検査の設計理由（PATCH 先の同定、fallback 側）

`hooks/review-nonblocking-record.sh` は本節を rationale の実体として参照する（helper 側は契約の宣言のみを持つ）。

**fallback の lookup は「自分が投稿した」∧「1 行目 marker への前方一致（`startswith`）」∧「**最終非空行が**機械専用 sentinel `<!-- rite:nbr:v1 -->` **と等しい**」の連言**で行う（第一候補は durable な comment id。[#durable-id](#durable-id) 参照）。write 側の本文検査も同じ「最終非空行の等値」で、read/write は同一述語（CR を落とし、空白のみの行を除いた最終行）。**この述語は id が使えない環境（PR body から読めない / 別 identity の過去投稿 / 永続化前）で唯一の同定手段として残るため、弱めてはならない。**

- **author 条件が必須な理由**: 前方一致だけでは、marker で始まるコメントを第三者が 1 件投稿するだけで `last` がそれを掴み、PATCH 先が奪われる。書込権限があれば他人のコメントを丸ごと上書き破壊し、権限不足なら 403 で `patch_failed` に落ちて以後の cycle も同じ id を掴み続け、記録が恒久的に失われる。
- **`contains($MARKER)` を使わない理由**: 人間可視の marker 文字列を本文全体で探すと、marker を引用しただけの別コメント（6.1.b が投稿するレビュー結果コメントの finding 本文、人間の Quote reply）が `last` で選ばれる。
- **機械専用 sentinel が必須な理由**: author + `startswith` の 2 条件でも、**同一 author が書いた、引用接頭辞を持たない、marker 前方一致の人間コメント**は除外できない。例えば運用者が記録を追跡するために「## 📜 rite 非実測指摘の記録 の対応状況」という見出しでコメントを書くと、次 cycle の 6.1.d がその本文を記録コメントで丸ごと上書きする。「引用返信は先頭に `> ` が付くため構造的に除外される」は GitHub の **Quote reply 経路しか覆っていない**。
- **sentinel は位置まで固定する（最終非空行の等値）**: `<!-- rite:nbr:v1 -->` は HTML コメントなので rendered view には現れないが、**raw markdown の copy-paste では同伴する**（Edit view / `gh api` / `gh pr view --comments` 経由）。したがって「人間が書き写す経路が存在しない」とは言えず、位置非依存の `contains` では、人間が記録の raw を一部貼り込んだメモを拾ってしまい上記の破壊が残る。**最終非空行が sentinel と等しいこと**を条件にすれば、本文中に引用として現れた sentinel も、末尾に `> ` 付きで引用された sentinel も構造的に除外される（本文全体への `endswith` は行頭の `> ` を吸収するため不十分）。write 側の本文検査も**完全に同じ述語**（CR を落とし、空白のみの行を除いた最終行の等値）にして read == write を保つ — 片側だけ緩いと人間のコメントを掴んで破壊し、片側だけ厳しいと次 cycle の lookup が自分の投稿を miss して増殖する。
- **述語変更は migration 問題を伴う**: 条件を 1 つ足した瞬間、その条件を持たない既存レコードは検出されなくなる。lookup で「author ∧ marker 前方一致は満たすが最終非空行 sentinel に落ちた件数」を数え、0 件でなければ WARNING + `[CONTEXT] NONBLOCKING_LEGACY_ORPHAN=1` を emit する。あわせて sentinel を持つ自分の記録コメントが 2 件以上（過去の degraded 縮退が生んだ重複）なら `[CONTEXT] NONBLOCKING_DUPLICATE_RECORD=1` を emit する — 原因も復旧手順も違うため合算せず別 marker にする。これを silent にすると、sentinel 導入前に投稿された記録コメントが孤児として残ったことを観測する手段が無くなる（本 helper が他の全 degraded 経路で WARNING を出す規律から外れる）。
- **前方一致でマッチ能力が損なわれない理由**: write 側（ステップ 6.1.d step 1）が「variant A / B のどちらも 1 行目に marker 見出しを置き、末尾に sentinel を置く」を契約として守るため。

**投稿前に本文を 4 段で検査する**（非空 → 1 行目が marker で始まる → **最終非空行が**機械専用 sentinel → `📎 non_blocking_count:` 行が `--count` と一致する）。最初の 3 段の契約違反はいずれも lookup の 3 条件を満たさないコメントを投稿し、以降の lookup を恒久的に miss させる（update-in-place の永久破綻 = 記録コメントが cycle ごとに増殖）。空 body だけを塞ぐと、本文生成が失敗した非空ケース（例: エラーメッセージだけが書き込まれた本文）が素通りする。診断の分離のため 4 段は別 reason（`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`）にする。

**4 段目（count/body 整合検査）が必要な理由**: ステップ 6.1.d step 1（本文 variant 選択）と step 2（`--count` 置換）は独立した 2 箇所の LLM 置換であり、片方だけずれると事実と異なる記録が投稿される — `--count 0` + variant A 本文（N 件を列挙）で 0 件のはずが記録が無音で消える、または `--count N>0` + variant B「0 件」本文 で虚偽の記録が残る。本文に機械可読な `📎 non_blocking_count: {n}` 行を持たせ、helper が投稿前に `--count` と照合することで、どちらのずれも非ブロッキングな `outcome=failed` に倒し observable にする。

**lookup が自分の投稿を見つけられないときは単一コメント不変条件を意図的に諦める**: gh 失敗による degraded に加え、別アカウント / 別トークン identity で過去に投稿した記録が残っている場合（author 条件により自分の投稿として拾えない。この場合 `degraded=0` のまま）も同様に、`count > 0` なら新規作成へ縮退する。既存の記録コメントが実在していれば 2 通目が作られ、古い方は孤児として残る。skip して記録を落とすより、重複してでも記録を残す方を選んだ。

可視性は 2 経路で非対称であり、これは受容している:

- **gh 失敗による degraded**: WARNING + `degraded=1` が出るため観測できる。
- **identity 変更による取りこぼし**: lookup 自体は rc=0 で成功し author 条件が空を返すだけなので、`degraded=0` のまま WARNING も出ない。**出力は正当な初回投稿と完全に同一**で、孤児コメント 1 件が残ることを観測する手段が無い。identity の変更を helper が知る術が無いため（「自分の過去投稿」の定義自体が identity に依存する）、観測不能な縮退として受け入れる。

ユーザー向け文書が「update-in-place の 1 件」と書くのはこれら縮退を除いた通常時の挙動。

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
3. denylist ではなく allowlist で書く（現行表記への係留を避ける）。**例外**: *判定の向き*を担う少数のセル（Routing 表の pass 行 / ERROR 行）は、substring 系 pin を 4 世代重ねてもなお極性反転・空 domain・否定形言い換えを通した実績があるため、canonical セル文字列の**完全一致**で固定する。この層に限り表記変更を意図的に loud fail させ、期待値更新という形で人手のレビューを強制する（実装: `review-helpers-gate-behavior.test.sh` TC-5b の `_routing_canonical`）
4. 区間スコープを使うときは**終端 anchor の存在自体を先に assert する**
5. pin のコメントは実際に検査している対象だけを述べる
6. 追加時にその場で mutation（述語置換 / コメントアウト / 表記言い換え / 散文追加 / 区間境界変更）を当て、落ちること（かつ無害な変更では落ちないこと）を実測する

mutation の実測結果は、**その pin を追加・変更した PR の本文**に matrix として残す（後から「何を変異させて落ちることを確かめたか」を追える形にするため。既存 PR の matrix を後追いで更新する運用は取らない — 変更した本人がその場で書く）。pin の実装は `hooks/tests/review-helpers-gate-behavior.test.sh` の TC-5。
