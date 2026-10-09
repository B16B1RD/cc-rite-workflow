# 主張と出典の照合 — 検証 agent の prompt・判定規則・指摘の形式

PR 自身が書いた「主張 + 出典」の組（「X は #N で解決」「出典は文書 D の節 S」「全件照合した」）を全件、含意まで確かめる。pr-review の「主張と出典の照合」節と issue-implement の commit 前照合が、本ファイルの Prompt 節・判定出力形式を単一 Task の prompt に使う。機械的な部分（抽出・事実の収集・表の全件性）は `scripts/claim-source-check.sh` が持ち、本ファイルは agent の判定と、その結果を指摘に変える形式だけを定める。

Fact-Check Phase（[fact-check.md](fact-check.md)）が検証するのはレビュアーの指摘であり、PR 自身の主張はここで扱う。

## spawn ペイロード

orchestrator は次を連結して `subagent_type: general-purpose` の Task を 1 回 spawn する。子に本ファイルを Read させない。

1. 本ファイルの「Prompt」節と「判定出力形式」節
2. `extract` が書いた行 JSON（`rows`）の全文
3. `facts` が書いた事実 JSON の全文
4. 作業先の絶対パスと、対象 repo（`owner/repo`）

子は読み取り専用で動く（Edit / Write / NotebookEdit 禁止、`gh` は参照系のみ）。結果は completion notification で回収し、未着の出力を推測で補わない。

## Prompt

あなたは、PR が書いた主張が、その主張の挙げる出典で裏づけられるかを確かめる。行 JSON の**全行**を判定する。抜き取りはしない。行を省くと表の検査で拒否される。

行ごとに、次の 3 観点を順に確かめる。

1. **実在** — 出典が存在するか（Issue / PR / コミット / ファイルと行 / 文書の節）。
2. **内容** — 出典の中身が、主張の挙げる要素と対応するか（番号・経路・ファイル・行の内容）。
3. **含意** — 出典が主張そのものを裏づけるか。

出典の種類ごとの確かめ方:

| 出典 | 確かめ方 |
|---|---|
| 「X は #N で解決／#N が入れた」 | 上から順に、最初に当てはまる規則で判定する。(1) `exists: false` の番号は不支持。(2) Issue が閉じておらず主張が「解決」なら不支持。(3) 解決した変更を、Issue の `closer`、`closing_prs[]`、`referencing_prs[]`（既定ブランチ以外へ入った PR は `closing_prs` に載らず、参照元として出る）のマージ済み PR を合わせたものとし、そのどれかに X に当たるファイル・経路が含まれれば支持、どれにも含まれなければ不支持。closer がコミットなら、変更ファイルは `git show --name-only --format= --first-parent <sha>` で取り（マージコミットは `--first-parent` が無いと何も出ない）、作業先に無ければ `gh api repos/<owner>/<repo>/commits/<sha> --jq '.files[].filename'` で取る。どちらでも取れなければ判定不能にする。PR 番号の出典はその PR の `files` で同じく判定する。(4) 解決した変更が 1 件も無ければ自分で参照元を探し、見つかれば (3) で判定し、見つからなければ判定不能にする。X がどのファイルに当たるかは作業先のコードを grep して決める |
| `path:line` | 事実 JSON の行内容が、主張の述べる内容か。行がずれていれば、ずれ先を `git grep` で探し、根拠に書く |
| コミット SHA | 事実 JSON の `files` と `subject` が主張に合うか |
| 文書の節 | 事実 JSON の節本文（`doc: null` なら行の文脈から文書を探して読む）に、主張の要素（番号・経路・用語）があるか。節が実在しても要素が無ければ不支持 |
| 「全件照合した」「確認済み」（PR 本文） | 主張された照合を自分で再現する。対象の件数と実際に確かめられた件数を数え、主張と合うかを判定する。本文の主張を前提として受け入れない |

事実 JSON に `error` がある出典は、自分で同じ取得を 1 回試す。それでも取れなければ判定不能にする。推測で支持にしない。

`files_truncated` / `closing_prs_truncated` / `timeline_truncated` / `lines_truncated` と、節の `truncated` が true の一覧・行・節本文は上限で切れている。そこに無いことを不支持の根拠にせず、自分で全体を取得して確かめる（PR の変更ファイルは `gh api repos/<owner>/<repo>/pulls/<N>/files --paginate --jq '.[].filename'`、Issue の閉じた PR とタイムラインは `gh api graphql` を `after:` カーソルでページ送りする、行と節は作業先のファイルを読む）。取り直しに `gh pr view --json files` は使わない（同じ上限で切れる）。取得できなければ判定不能にする。

例文・fixture・テンプレートの値など、PR が主張として述べていない行は「主張なし」にし、根拠にそう判断した理由（コードブロック内の例、fixture ファイル等）を書く。レビュー対象の PR 自身の本文にある closing keyword の行（`Closes #N` など）は、この PR で閉じるという宣言であり、主張なしにする。

## 判定出力形式

次の形だけを返す。前後の解説は書かない。

```
### 主張と出典の照合
| ID | 判定 | 観点 | 根拠 |
|----|------|------|------|
| CLAIM-1 | 不支持 | 実在・内容・含意 | Verification: repro gh api repos/<owner>/<repo>/pulls/<closing PR>/files --paginate --jq '.[].filename' => 変更ファイルに src/logger.js が無い (src/other.js のみ) |
| CLAIM-2 | 支持 | 実在・内容・含意 | docs/spec.md の該当節に、主張の回数と経路がある |
| CLAIM-3 | 判定不能 | 実在 | Measurement-Blocked: gh api repos/<owner/repo>/commits/<sha> => HTTP 503 |
| CLAIM-4 | 主張なし | - | コードブロック内の書式例で、PR の主張ではない |
```

- 行は行 JSON の ID と 1 対 1（欠落・余剰・重複は拒否される）。
- `判定` は 支持 / 不支持 / 判定不能 / 主張なし。
- `観点` は確かめた観点を `・` で並べる。**支持は 実在・内容・含意 の 3 つすべてを確かめた行だけ**に使える。主張なしは `-`。
- 不支持の根拠は `Verification: repro <実行したコマンド> => <観測>` で始める。判定不能の根拠は `Measurement-Blocked: <実行したコマンド> => <失敗の観測>` を含める。
- セル内の `|` は `¦` で書く。

## 表の検査と報告

orchestrator は agent の出力を作業ツリー外のファイルに保存し、`claim-source-check.sh table --rows <行 JSON> --input <出力>` にかける。拒否されたら、診断を添えて agent を 1 回だけ再 spawn する。再拒否は caller の停止経路に従う。

通過時の `CLAIM_SOURCE_TABLE=ok` の値が確認の範囲になる。報告には次の 1 行を必ず出す。

```
確認範囲: 対象 {total} 件中 {judged} 件を判定（支持 {supported} / 不支持 {unsupported} / 主張なし {no_claim}）、判定不能 {undetermined} 件。観点: 実在 {existence} 件・内容 {content} 件・含意 {implication} 件
```

`judged < total`（判定不能がある）ときは、未判定の行（`CLAIM_SOURCE_ROWS_JSON` のうち判定不能の行）を ID・出所・理由つきで列挙する。

## 指摘の形式（pr-review）

`CLAIM_SOURCE_ROWS_JSON` の各行を、5.3.0.M step 1 の `findings[]` へ 1 件ずつ追加する。

| キー | 値 |
|---|---|
| `reviewer` | `"pr-review"`（orchestrator。agents/ は追加しない） |
| `category` | `"claim_source"` |
| `severity` / `scope` | `"HIGH"` / `"current-pr"` |
| `file` / `line` | 出所が `path:line` ならその path と行。`PR本文:N` なら PR の変更ファイルの先頭を `file` にし、`line: null` |
| `suggestion` | 出典を主張に合うものへ直すか、主張を出典の述べる範囲へ直す。PR 本文の行は fix が `gh pr edit` で本文を直し、同じ commit の再レビューで照合し直す |

`description` はアンカーで始める（Number-reference 指摘と同じ先頭アンカー例外）。行の本文に含まれる `|` は `¦`、`=>` は `⇒` に置き換えて、アンカーの `=>` を 1 つに保つ。

- 不支持: `{verification_anchor}。[{claim_id}] {origin}: 出典が主張を裏づけない。主張: {claim_text}`
- 判定不能: `{blocked_anchor}。[{claim_id}] {origin}: 出典を確かめられず、主張と出典の照合が判定不能。主張: {claim_text}`

`{verification_anchor}` / `{blocked_anchor}` は表の根拠セルの値そのもの。不支持は実測済み（`Verification:`）として blocking に残り、判定不能は実測なしとして `non_blocking_findings[]` の `### 実測阻害` に出る。

## Rationale

<a id="why-full-coverage"></a>
**全件と含意を機械で強制する理由**: 出典の実在・行番号・件数は合っていても、出典が主張を裏づけないことがある（閉じた PR が該当ファイルを変えていない、節に主張の要素が無い）。数行の抜き取りでも報告には「照合した」と書けてしまい、呼び出し側は全件か抜き取りかを区別できない。表の ID 集合を抽出結果と 1 対 1 で突き合わせ、支持に 3 観点すべてを要求することで、抜き取りや実在だけの確認を「照合済み」として通せなくする。

<a id="why-every-cycle"></a>
**毎 cycle・HEAD で全行を照合する理由**: 出典（PR 本文、他の Issue の状態、参照先の行）は cycle の間にも変わる。前 cycle の判定を使い回すと、変わった出典の不一致を見逃す。

<a id="why-not-a-reviewer"></a>
**名前付き reviewer にしない理由**: 抽出・表の検査・指摘への変換は機械的で、判定する agent に必要なのは行と事実だけである。reviewer agent として加えると、選定・merge ゲートの人数計算・結果 schema の reviewer 一覧まで配線が広がる。orchestrator の手順として Number-reference と同じ位置に置き、指摘は `reviewer: "pr-review"` で出す。
