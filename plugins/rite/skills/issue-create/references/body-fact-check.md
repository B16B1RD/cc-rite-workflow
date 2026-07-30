# Body Fact-Check — 生成した Issue 本文の断定を検証する

> **SoT scope**: Issue 本文に書かれた**検証可能な断定**を、Issue 作成 / 編集を適用する前にファクトチェックする手順の SoT。consumer は `skills/issue-create/SKILL.md` ステップ 4.2.1（Single Issue path、body 生成直後）と ステップ 5.1.1（Decompose path、設計仕様書生成後）、`skills/issue-edit/SKILL.md` Phase 3.1.1（変更された本文部分）の 3 箇所。判定語彙（`VERIFIED` / `CONTRADICTED` / `UNVERIFIED`）は [`skills/pr-review/references/fact-check.md`](../../pr-review/references/fact-check.md) が SoT であり、本 reference では再定義せず転用する。

構造検査（AC 件数・T-xx 対応等）は [`templates/issue/default.md`](../../../templates/issue/default.md) の Output Validation Checklist の責務であり、本 reference は**記述内容の真偽**のみを見る（責務を混ぜない）。

## 発火条件

検査対象は下表の 3 クラスに限定する。それ以外の主張（文体・構成・外部仕様）へ広げない。

| 確定 Complexity | 検査範囲 |
|------------------|---------|
| XS / S | 番号参照クラスのみ |
| M 以上 | 3 クラスすべて |

- issue-create ステップ 4.2.1 / 5.1.1 の Complexity は ステップ 4.1 で**確定済み**の値を使う（ステップ 4.0 の見込み値ではない）
- issue-edit Phase 3.1.1 は Phase 1.3 で取得した Projects の Complexity フィールド値を使う。Projects 未登録で値が得られない場合は**番号参照クラスのみ**に倒す
- **検査対象の主張が 0 件のときは silent skip する** — 「検証対象なし」等の行も出力しない（`skills/issue-create/SKILL.md` の `## E2E Output Minimization` に準拠）

検出は**過検出よりも取りこぼし側に倒してよい**。本ステップは安全網であり、最終防衛線は `/rite:pr-review` の reviewer 側の裏取り（[`reviewer-prompt-generator.md`](../../pr-review/references/reviewer-prompt-generator.md) の仕様取り扱い指示）が担う。

## クラス 1: 番号参照クラス（実測必須）

**検出**: git history / Issue / PR / commit を指す断定。`#N` / `PR #N` / 7 桁以上の commit SHA を伴い、かつ「#N で X された」「#N 以降 Y で運用」のように**その参照先の内容を主張**しているもの。単なるリンク（`Extends: #N`、`refs #N`）は対象外。

**裏取り**: 記憶・推測で `VERIFIED` としてはならない。実際に以下を実行し、出力と本文の断定を突合する:

| 断定の種類 | 裏取りコマンド |
|-----------|---------------|
| Issue の存在 / title / state | `gh issue view {N} -R {owner_repo} --json number,title,state` |
| PR の存在 / title / state | `gh pr view {N} -R {owner_repo} --json number,title,state` |
| commit の存在 / subject | `git log --oneline -1 {sha}` |
| 「#N で A → B に変更された」（変更方向） | `git show {sha}^:{path}`（変更前）と `git show {sha}:{path}`（変更後）を**両方**取得する |

**変更方向の断定は片側だけ見てはならない**。変更後だけを見ると「元から B だった」と区別できず、方向の逆転を検出できない。

**PR 番号 / Issue 番号の混同**: squash merge した commit の subject 末尾 `(#N)` は **PR 番号**であり Issue 番号ではない（Issue 番号は commit body の `refs #M` 側にある）。`#N` を Issue として引用する断定は `gh issue view {N}` の title が文脈と一致するかまで確認する。本リポジトリの実例: commit `9fd680e4` の subject は `(#1539)`（PR 番号）で、対応する Issue は `#1519`。番号だけを見て Issue と断定すると別物を指す。

## クラス 2: 現状断定クラス（wording lint、実測しない）

**検出**: 観測範囲の限定がない現在形の断定。「現在 X で運用されている」「実体は Y」「一般に Z である」等。

**処理**: 実測は要求しない（他リポジトリ・他環境の実在は一般に知り得ないため、機械化できるのは文言規則まで）。観測範囲の限定を付けるよう促す:

- 「本リポジトリでは」「本 PR 時点では」「`{file}:{line}` では」等の限定句を追加する
- 限定を付けられない断定は、そもそも根拠が無い可能性を疑う

本クラスは `CONTRADICTED` 判定を出さない（wording の指摘に留める）。

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
| `UNVERIFIED` | 検証不能（コマンド失敗 / 対象外の主張） | 番号参照・現状断定は本文に「要確認」を付記して続行（non-blocking）。外部仕様の主張は「要検証」を付記し `/rite:pr-review` の Fact-Checking Phase に委ねる |

**`CONTRADICTED` の AskUserQuestion は 3 択とする**:

| 選択肢 | 挙動 |
|--------|------|
| 訂正案を採用 | 提示した訂正で本文を書き換えて続行 |
| 要確認を付記して続行 | 本文はそのまま維持し、該当箇所に「要確認」を付記して続行 |
| そのまま続行 | 本文を一切変更せず続行（ユーザーの判断を最終とする） |

> **なぜ 3 択か**: 「ユーザー承認なしに本文を書き換えない」と「訂正を拒否しても『要確認』は付記する」は、付記自体が書き換えであるため 2 択では両立しない。付記もユーザー承認下に置くことで両方を満たす。

自己矛盾クラスの矛盾候補も同じ確認に載せる（`修正して続行` / `そのまま続行`）。surface する項目は 1 項目 = 1 question として最大 4 件までとし、溢れた分は本文に「要確認」として列挙する（AskUserQuestion の質問数上限に合わせる）。

## エラー処理

| 条件 | 挙動 |
|------|------|
| 裏取りコマンドが失敗（オフライン / `gh` 認証切れ / 浅い clone に commit が無い） | `UNVERIFIED` として「要確認」を付記し続行。stderr に `WARNING` を出す。Issue 作成 / 編集を**ブロックしない** |
| 参照先の Issue / PR が存在しない番号 | `CONTRADICTED`（タイポの可能性を訂正案として提示する） |
| 検査対象 0 件 | silent skip（追加の出力・質問を出さない） |
| issue-edit で本文以外（title / Projects フィールド）のみの変更 | 検査を実行しない |

## 制約

- 番号参照クラスは**必ずコマンドを実行**して突合する（記憶・推測での `VERIFIED` 判定を禁止する）
- 本検査のための helper スクリプト / hook を新設しない（既存コマンド + 散文手順で完結させる）
- issue-create（4.2.1 / 5.1.1）と issue-edit（Phase 3.1.1）は本 reference を共通参照し、検査ロジックを複製しない
