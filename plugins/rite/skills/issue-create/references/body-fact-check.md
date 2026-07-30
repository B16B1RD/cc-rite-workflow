# Body Fact-Check — 生成した Issue 本文の断定を検証する

> **SoT scope**: Issue 本文に書かれた**検証可能な断定**を、Issue 作成 / 編集を適用する前にファクトチェックする手順の SoT。consumer は `skills/issue-create/SKILL.md` ステップ 4.2.1（Single Issue path、body 生成直後）と ステップ 5.1.1（Decompose path、設計仕様書生成後）、`skills/issue-edit/SKILL.md` Phase 3.1.1（変更された本文部分）の 3 箇所。判定語彙の**ラベル**（`VERIFIED` / `CONTRADICTED` / `UNVERIFIED`）は [`skills/pr-review/references/fact-check.md`](../../pr-review/references/fact-check.md) と揃えるが、**判定根拠は異なる** — 同 SoT は外部仕様の WebSearch 検証を根拠とし、本 reference は**コマンド出力との突合**を根拠とする。各値の意味は下記「3 値の処理」を正とする（後置修飾を持たない bare `UNVERIFIED` は本 reference のローカル語彙であり、SoT 側の `UNVERIFIED:ソース未確認` / `UNVERIFIED:リソース超過` とは別値）。

構造検査（AC 件数・T-xx 対応等）は [`templates/issue/default.md`](../../../templates/issue/default.md) の Output Validation Checklist の責務であり、本 reference は**記述内容の真偽**のみを見る（責務を混ぜない）。

## 発火条件

検査対象は下表の 3 クラスに限定する。それ以外の主張（文体・構成）へ広げない。外部仕様の主張は**能動的に検出・検証しない**が、3 クラスの検査過程で目に入った場合は下記「3 値の処理」に従い「要検証」を付記し `/rite:pr-review` の Fact-Checking Phase に委ねる（本ステップでは検証自体を行わない）。

| 確定 Complexity | 検査範囲 |
|------------------|---------|
| XS / S | 番号参照クラスのみ |
| M 以上 | 3 クラスすべて |

- issue-create ステップ 4.2.1 の Complexity は ステップ 4.1 で**確定済み**の値を使う（ステップ 4.0 の見込み値ではない）
- issue-create ステップ 5.1.1（分解パス）は ステップ 4.1 を通らないため確定 Complexity を持たない。親仕様書は親 Complexity が `XL` 固定（`SKILL.md` 5.5 Step 1 の helper 契約）のため **3 クラスすべて**を対象とする
- issue-edit Phase 3.1.1 は Phase 1.3 で取得した Projects の Complexity フィールド値を使う。Projects 未登録で値が得られない場合は**番号参照クラスのみ**に倒す
- **検査対象の主張が 0 件のときは silent skip する** — 「検証対象なし」等の行も出力しない（`skills/issue-create/SKILL.md` の `## E2E Output Minimization` に準拠）

検出は**過検出よりも取りこぼし側に倒してよい**。本ステップは安全網であり、最終防衛線は `/rite:pr-review` の reviewer 側の裏取り（[`reviewer-prompt-generator.md`](../../pr-review/references/reviewer-prompt-generator.md) の仕様取り扱い指示）が担う。

## クラス 1: 番号参照クラス（実測必須）

**検出**: git history / Issue / PR / commit を指す断定。`#N` / `PR #N` / 7 桁以上の commit SHA を伴い、かつ「#N で X された」「#N 以降 Y で運用」のように**その参照先の内容を主張**しているもの。単なるリンク（`Extends: #N`、`refs #N`）は対象外。

**裏取り**: 記憶・推測で `VERIFIED` としてはならない。実際に以下を実行し、出力と本文の断定を突合する:

| 断定の種類 | 裏取りコマンド |
|-----------|---------------|
| Issue の存在 / title / state | `gh issue view {N} -R {owner_repo} --json number,title,state,url`（**返った `url` のパスセグメントが `/issues/` であることを先に確認する** — 本コマンドは PR 番号でも成功するため。下記「PR 番号 / Issue 番号の混同」参照） |
| PR の存在 / title / state | `gh pr view {N} -R {owner_repo} --json number,title,state`（**本文が `PR #N` と型を明示している場合にのみ本行から始める**。bare `#N` は 1 行目で型を判定してからこちらに来る — 下記[型解決の規則](#type-resolution)参照） |
| commit の存在 / subject | `git log --oneline -1 {sha}` |
| 「#N で A → B に変更された」（変更方向） | SHA が本文に直書きされていればそれを `{sha}` に使う。`#N` 形式なら、まず上表 1 行目の `gh issue view {N} -R {owner_repo} --json url` で**種別を判定してから** 2 分岐する（`#N` は PR とは限らない — 本リポジトリの commit 規約では Issue を `refs #N` で引くため Issue 番号 citation が主経路）: `url` が `/pull/` なら `gh pr view {N} -R {owner_repo} --json mergeCommit` の `mergeCommit.oid` を `{sha}` に代入（`null` = 未マージなら `UNVERIFIED`）。`/issues/` なら `git log -E --grep "refs #{N}[^0-9]" --grep "refs #{N}$" --format=%H` で実装 commit を解決して代入（2 つの `--grep` は OR 結合で「N の直後が非数字 or 行末」の語境界を成す。**境界を省いた素の `--grep "refs #{N}"` を使ってはならない** — 語境界を持たない部分一致のため、短い番号が長い番号の prefix として「ちょうど 1 件」マッチし下記 guard を素通りする。0 件 / 複数件で特定できなければ `UNVERIFIED`）。**この解決段階のコマンド失敗を `CONTRADICTED` に流してはならない**（種別は 1 行目の出力で確定済み。解決失敗は `UNVERIFIED` に倒す）。`{sha}` が得られたら `git show {sha}^:{path}`（変更前）と `git show {sha}:{path}`（変更後）を**両方**取得する |

**変更方向の断定は片側だけ見てはならない**。変更後だけを見ると「元から B だった」と区別できず、方向の逆転を検出できない。

**`git log --grep` の一致は候補であって解決結果ではない**。commit message は自分の実装対象を `refs #N` で引くだけでなく、**他所の作業を地の文で引用する**ときにも同じ文字列を書く。候補が 1 件でも、それが引用側の commit なら誤った `{sha}` を掴んだまま変更前後の突合へ進み、偽 `VERIFIED` / 偽 `CONTRADICTED` が無言で成立する。したがって候補ごとに `git log -1 --format='%s%n%b' {sha}` の**全文**を読み、**その commit 自身が #N の実装であるか**を判断して絞り込む。実装であれば残し、#N を他所の作業として言及しているだけ（別 PR の主旨を引き合いに出す、無関係であることを述べる 等）なら候補から外す。絞り込み後に 1 件でなければ `UNVERIFIED`。

**一致した「位置」で分岐してはならない** — subject 行 / squash された箇条書き行 / trailer 行 / 地の文 のいずれであるかは判別材料にならない。実装 commit も自分の Issue を地の文で引くため、位置で切ると正当な解決を落とす（実測で確認済み）。同じ理由で、一致位置を狭める正規表現（行頭アンカー・括弧付き行末など）を裏取りコマンドに足してはならない — 散文引用と実装 commit は正規表現では区別できず、衝突を減らすぶんだけ正当な解決も失う。判別は上記の全文読解でのみ行う。

**候補が 0 件 / 複数件のときは候補 SHA の一覧を stderr の `WARNING` に載せる**（下記「3 値の処理」の WARNING 規則が定める 1 本に、`{理由}` として候補一覧を含める。WARNING を別に増やさない）。載せないと「解決が曖昧だった」と「ネットワークが落ちていた」が本文の同じ「要確認」注記に潰れ、後から切り分けられない。

**PR 番号 / Issue 番号の混同**: squash merge した commit の subject 末尾 `(#N)` は **PR 番号**であり Issue 番号ではない（Issue 番号は commit body の `refs #M` 側にある）。`gh issue view {N}` は **PR 番号を渡してもエラーにせず PR を返す**（対照的に `gh pr view {N}` は Issue 番号を `Could not resolve to a PullRequest` で正しく弾く。壊れているのは Issue 側だけ）。したがって `#N` を Issue として引用する断定は、**上表 `gh issue view` の出力に含まれる `url` のパスセグメントで種別を先に判定する** — `/issues/` なら Issue、`/pull/` なら PR。判定には必ず同じ 1 回の出力を使うこと（`-R {owner_repo}` を落とした二度目の呼び出しは SSH host alias 環境で別リポジトリを引く）。

<a id="type-resolution"></a>

**型解決の規則（両方向の SoT。エラー処理表はこの規則を参照するだけで条件を持たない）**:

| 本文の書き方 | 型の決め方 | 型が食い違ったときの判定 |
|-------------|-----------|------------------------|
| 型を明示しない bare `#N` | 上表 1 行目の `gh issue view {N} --json url` を先に実行し、返った `url` の判定結果を**その主張の型として採用する** | **`CONTRADICTED` にしない**（本文は型を主張していないので、食い違い自体が存在しない） |
| `Issue #N` と明示 | 同上で判定 | `url` が `/pull/` なら `CONTRADICTED` |
| `PR #N` と明示 | 同上で判定 | `url` が `/issues/` なら `CONTRADICTED` |

bare `#N` を一律 `CONTRADICTED` に倒すと、上記「過検出よりも取りこぼし側に倒してよい」の逆方向になる — 直前の段落が「Issue 番号 citation が主経路」と述べているぶん読み手は bare `#N` を Issue 引用と解釈しやすく、この経路は実際に踏まれる。

**型判定は必ず `gh issue view` 側で行う**。`gh pr view` は Issue 番号を非ゼロ終了で弾くため `url` を返さず、失敗した時点で型を決める材料が無い。bare `#N` を PR と当たりを付けて `gh pr view` から始めると、実在する Issue 番号が「PR ではない」という stderr だけを根拠に誤って `CONTRADICTED` へ落ちる。

**title 照合を判別手段にしてはならない**。squash merge 運用では PR title が Issue title から派生するため両者はほぼ一致し、誤った対象のまま `VERIFIED` に倒れる。`state` も単独では使えない（open な PR は Issue と同じ `OPEN` を返す）。

> 罠を手元で再現するには、squash merge された commit に対して `git log -1 --format='%s%n%b' {sha}` を実行し、subject 末尾の `(#N)`（PR）と body の `refs #M`（Issue）が別の番号を指すことを確認する。そのうえで両方の番号へ `gh issue view` を掛けると、PR 番号側でも成功して返ることが観測できる。本文に具体番号を書かないのは Simplification Charter の「禁止パターン」節（`Issue #[0-9]+` / `PR #[0-9]+` の本文引用は原則 0 件、必要でも 1 ファイル 1 件まで）に従うため。

## クラス 2: 現状断定クラス（wording lint、実測しない）

**検出**: 観測範囲の限定がない現在形の断定。「現在 X で運用されている」「実体は Y」「一般に Z である」等。

**処理**: 実測は要求しない（他リポジトリ・他環境の実在は一般に知り得ないため、機械化できるのは文言規則まで）。観測範囲の限定を付けるよう促す:

- 「本リポジトリでは」「本 PR 時点では」「`{file}` の `{関数名}` では」等の限定句を**候補として挙げる**（本文へ自動適用しない）
- 限定を付けられない断定は、そもそも根拠が無い可能性を疑う

本クラスは `CONTRADICTED` 判定を出さない。検出した項目は `UNVERIFIED` として下記「3 値の処理」へ合流させ、挙げた限定句候補は同表の指定どおり「要確認」の付記に併記する（本クラス独自の処理経路・出力先を持たない）。

## クラス 3: 自己矛盾クラス（自動修正しない）

**検出**: 同一 body 内の以下の組み合わせで両立しない記述を探す。

- Non-goal / Out of Scope ↔ In Scope / AC
- MUST NOT ↔ MUST / SHOULD / AC / エッジケースの択一
- AC ↔ Test Specification の対応
- Decision Log ↔ 本文の記述

**処理**: 矛盾候補を列挙し、**自動修正せず**下記の確認へ載せる。

## 3 値の処理

| 判定 | 意味 | 処理 |
|------|------|------|
| `VERIFIED` | コマンド出力と一致 | そのまま続行（出力を増やさない） |
| `CONTRADICTED` | コマンド出力と矛盾 / 参照先の番号が存在しない | **自動修正せず** AskUserQuestion で矛盾内容と訂正案を提示する（下記） |
| `UNVERIFIED` | 検証不能（コマンド失敗 / 対象外の主張） | 番号参照は本文に「要確認」を付記して続行（non-blocking）。現状断定はクラス 2 の限定句候補を付記に併記する（例: `要確認（限定句候補: 本リポジトリでは）`）。外部仕様の主張は「要検証」を付記し `/rite:pr-review` の Fact-Checking Phase に委ねる |

**`CONTRADICTED` の AskUserQuestion は 3 択とする**:

| 選択肢 | 挙動 |
|--------|------|
| 訂正案を採用 | 提示した訂正で本文を書き換えて続行 |
| 要確認を付記して続行 | 本文はそのまま維持し、該当箇所に「要確認」を付記して続行 |
| そのまま続行 | 本文を一切変更せず続行（ユーザーの判断を最終とする） |

> **なぜ 3 択か**: 「ユーザー承認なしに本文を書き換えない」と「訂正を拒否しても『要確認』は付記する」は、付記自体が書き換えであるため 2 択では両立しない。付記もユーザー承認下に置くことで両方を満たす。

**`VERIFIED` 以外の判定はすべて stderr に `WARNING` を 1 行出す**（本節が唯一の定義。エラー処理表の個々の行やクラス別の節には書かない）。書式:

```
WARNING: fact-check {判定} ({参照識別子}): {理由} — {処理}
```

| 欄 | 内容 |
|----|------|
| `{判定}` | `CONTRADICTED` / `UNVERIFIED` |
| `{参照識別子}` | 本文が引いた形をそのまま使う（`#N` / `Issue #N` / `PR #N` / commit SHA）。番号を持たない現状断定クラスは対象箇所を短く示す |
| `{理由}` | 判定の根拠。`UNVERIFIED` では**理由を必ず具体化する**（`候補 0 件` / `候補 複数件: {SHA 一覧}` / `未マージ (mergeCommit: null)` / `コマンド失敗: {stderr 要約}` / `実測しないクラス` 等） |
| `{処理}` | `CONTRADICTED` は選択された処理（`要確認を付記して続行` / `そのまま続行`）。`UNVERIFIED` は付記したマーカー（`要確認` / `要検証`）または `付記なし` |

**`訂正案を採用` で解消した `CONTRADICTED` だけが WARNING を出さない**（矛盾が消えているため）。

これを 1 本の規則にするのは、**判定の強さと観測可能性を逆相関させない**ため。`CONTRADICTED` の `そのまま続行` は本文に何も残さないので、WARNING が無いと痕跡がセッション transcript だけになる。`UNVERIFIED` 側も同様で、非ゼロ終了しない経路（候補 0 件 / 複数件 / 未マージ）はコマンドが成功しているぶん痕跡が「要確認」注記だけになり、ネットワーク断由来のものと同一視される。理由欄の具体化がその 2 者を分ける。

自己矛盾クラスの矛盾候補も確認に載せる（`修正して続行` / `そのまま続行`）。**本クラスは他 2 クラスの判定（`VERIFIED` / `CONTRADICTED` / `UNVERIFIED`）と直交する軸**であり、consumer の分岐表のどの行に該当した場合でも独立に評価する（3 クラスすべてで検出 0 件のときのみ評価しない）。`CONTRADICTED` と同時に検出したときは同一の AskUserQuestion に相乗りし、`CONTRADICTED` が 0 件のときは本項目だけで新規に発行する。

surface する項目は **1 項目 = 1 question** とし、1 回の AskUserQuestion 呼び出しには**最大 4 件**まで載せる（同ツールの質問数上限）。**1 question に 2 つの決定を載せてはならない** — 回答は 1 つなので、自身の 3 択と他項目の可否を同じ問いで決めることはできない。

**枠に載せる順序**（同じ検出結果なら毎回同じ項目が枠に載るよう固定する）:

1. `CONTRADICTED`（本文の断定が誤っている確度が最も高い）
2. 自己矛盾クラスの矛盾候補
3. 同順位内では本文の出現順

**5 件目以降が出た場合**は、`AskUserQuestion` を **2 回目以降として追加で呼び出し**、同じく 1 項目 = 1 question・最大 4 件で載せる（上限は 1 呼び出しあたりの制約であって総予算ではない）。項目が尽きるまで繰り返す。**無承認で本文へ付記してはならない** — 「なぜ 3 択か」が置いた「付記もユーザー承認下に置く」不変条件は、項目数が増えても例外を作らない（上限を理由に例外を作ると、`CONTRADICTED` が最も多い body ほど無承認の書き換えが起きる）。

呼び出し回数が増えるのを避けたい場合でも、**項目を落として本文だけ書き換える縮退は禁止**する。載せきれない事情があるなら、その項目は本文を変更せず `UNVERIFIED` 相当として WARNING に理由付きで記録する（上記 WARNING 規則の `{処理}` 欄を `付記なし` にする）。

**各 consumer は本検査専用の AskUserQuestion を発行すること** — 既存の確認へ畳み込むと、その確認自身が枠を消費して上限が consumer ごとに割れ、溢れの扱いも分岐する。専用に発行すれば本節の規定がそのまま全 consumer に適用される。

## エラー処理

| 条件 | 挙動 |
|------|------|
| 参照先の番号が存在しない（`gh issue view` の stderr が `Could not resolve to an issue or pull request` を含む非ゼロ終了 — Issue / PR 共通番号空間での不存在を断定できる。`Could not resolve` の**部分一致で判定してはならない** — 同語はリポジトリ解決失敗にも現れる） | `CONTRADICTED`（タイポの可能性を訂正案として提示する） |
| **本文が明示的に `PR #N` と型を書いて**引用した番号が PR ではない（`gh pr view` の stderr が `Could not resolve to a PullRequest` を含む非ゼロ終了 — **不存在を含意しない**。実在する Issue 番号でも同じ stderr になる）。**型を明示しない bare `#N` は本行の対象外**（[型解決の規則](#type-resolution)に従い `gh issue view` 側で型を決める） | `CONTRADICTED`。ただし訂正案はタイポと決めつけず、`gh issue view {N} -R {owner_repo} --json url` を追加実行して切り分ける: (a) `url` が `/issues/` なら「N は Issue 番号であり PR ではない」、(b) `Could not resolve to an issue or pull request` なら番号不存在としてタイポの可能性、(c) **それ以外の失敗（`Could not resolve to a Repository` / 一過性障害 / rate limit / 認証切れ）なら「切り分け不能」**をそれぞれ訂正案として提示する。**(c) でも `CONTRADICTED` 判定は維持する**（判定は `gh pr view` の結果で確定済みで、この追加実行は訂正案を作るためだけのもの）。下 2 行の `UNVERIFIED` は本行の追加実行には適用しない |
| `git` 裏取りコマンド（`git log` / `git show`）の**非ゼロ終了すべて**（stderr の文言 — `unknown revision` / `bad object` / `invalid object name` / path 系文言 等 — **で分岐しない**。網羅で判定する）。**ローカル git は「存在しない」と「fetch されていない」を区別できない** — 浅い clone / 未 fetch ブランチ / fork 上の commit では**実在する SHA も同一の stderr** になる（本行を `CONTRADICTED` の根拠にしてはならない） | `UNVERIFIED` として「要確認」を付記し続行（タイポと断定しない。WARNING は上記の単一規則が担う）。サーバ権威で不存在を断定したい場合のみ `gh api repos/{owner_repo}/commits/{sha}` を追加実行し、**stderr が `No commit found for SHA`（HTTP 422）のときに限り** `CONTRADICTED` へ昇格してよい（HTTP 404 は SHA ではなく `{owner_repo}` 側の不在なので昇格しない） |
| **上記以外**の非ゼロ終了（オフライン / `gh` 認証切れ / リポジトリ解決失敗・権限不足（stderr が `Could not resolve to a Repository` — 番号ではなく `{owner_repo}` 側の問題）等） | `UNVERIFIED` として「要確認」を付記し続行（WARNING は上記の単一規則が担う）。Issue 作成 / 編集を**ブロックしない** |
| **本文が明示的に `Issue #N` と型を書いて**引用した番号が PR として解決した（上表コマンドの `url` が `/pull/` を含む）。**型を明示しない bare `#N` は本行の対象外**（[型解決の規則](#type-resolution)参照） | `CONTRADICTED`（PR 番号を Issue と誤認している。対応する Issue 番号は commit body の `refs #M` 側を確認して訂正案に載せる） |
| 検査対象 0 件 | silent skip（追加の出力・質問を出さない） |
| issue-edit で本文以外（title / Projects フィールド）のみの変更 | 検査を実行しない |

## 制約

- 番号参照クラスは**必ずコマンドを実行**して突合する（記憶・推測での `VERIFIED` 判定を禁止する）
- 本検査のための helper スクリプト / hook を新設しない（既存コマンド + 散文手順で完結させる）
- issue-create（4.2.1 / 5.1.1）と issue-edit（Phase 3.1.1）は本 reference を共通参照し、検査ロジックを複製しない
