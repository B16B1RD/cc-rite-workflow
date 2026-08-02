# Reviewer 指示テンプレート（Generator フェーズ）

`/rite:pr-review` ステップ 4.5 で各 reviewer agent に渡す通常レビュー指示のテンプレート。SKILL.md 側の「Placeholder embedding method」表に従い `{placeholder}` を埋めて使用する。

````
PR #{number}: {title} のレビューを {reviewer_type} として実行してください。

## 変更概要
{change_intelligence_summary}

## レビュー対象ファイル
{relevant_files}

## 差分
{diff_content}

## 関連 Issue の仕様
{issue_spec}

**重要**: 上記の仕様は Issue で合意された要件です。実装が仕様と異なる場合は、以下のルールに従ってください:
1. **仕様どおりに実装されていない場合** → 「仕様不整合」として CRITICAL で指摘
2. **仕様自体に問題がある（矛盾、曖昧さ、技術的に不可能）と判断した場合** → 指摘として挙げず、「仕様への疑問」セクションに記載し、ユーザー確認を促す
3. **仕様に記載がない実装判断** → 通常のレビュー基準で評価

**仕様中の番号参照は裏取りしてから判定に使う**: 仕様が commit / Issue / PR 番号を引いて内容を主張している場合（「#N で X された」「#N 以降 Y で運用」等）、その断定を評価基準に使う**前に** `git log --oneline -1 {sha}` / `git show {sha}^:{path}` と `git show {sha}:{path}`（変更方向は両側必須）/ `gh issue view {N} -R <owner>/<repo> --json number,title,state,url` / `gh pr view {N} -R <owner>/<repo>` で裏取りする。**`gh` には `-R <owner>/<repo>` を必ず明示すること** — 省略すると SSH host alias 環境で別リポジトリを引く（owner/repo の解決手順は [`references/gh-cli-patterns.md` の Owner/Repo Resolution](../../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) に従う）。裏取りで仕様側の誤りが判明したら、実装を「仕様不整合」として指摘するのではなく上記ルール 2 の「仕様への疑問」に回す（誤った仕様を ground truth として扱うと仕様の誤りが CRITICAL 指摘として増幅される）。squash merge commit の subject 末尾 `(#N)` は **PR 番号**であり Issue 番号ではない。`gh issue view` は PR 番号を渡しても成功して PR を返すため、Issue として引く番号は返った `url` のパスセグメントが `/issues/` であることを先に確認する（`/pull/` なら PR。title 照合は PR title が Issue title から派生するため判別に使えず、`state` も open な PR が Issue と同じ `OPEN` を返すため単独では使えない）。裏取りできない場合（`gh` 認証切れ等）は仕様の当該断定を評価基準に使わず、「仕様への疑問」に未検証として記載する。
<!-- 番号種別判定（url パスセグメント / title・state が使えない理由）の同旨記述: skills/issue-create/references/body-fact-check.md のクラス 1。reviewer prompt は subagent に注入されるため本文は自己完結させるが、gh の挙動が変わったときは両方を更新すること -->

## 共通レビュー原則
<!-- `_reviewer-base.md` から抽出される全 reviewer 共通の原則。READ-ONLY Enforcement / Mindset / Cross-File Impact Check / Confidence Scoring が含まれる。reviewer 固有の identity (Role / Core Principles / Detection Process / Detailed Checklist (Expertise Areas, Review Checklist, Severity Definitions, Finding Quality Guidelines) / Output Format) は named subagent の system prompt (agents/{reviewer_type}-reviewer.md) として自動注入されるためここには含めない -->
{shared_reviewer_principles}

## Doc-Heavy PR Mode (Conditional — 適用時のみ非空)
<!-- reviewer_type == tech-writer かつ doc_heavy_pr == true のときのみ内容が入る。それ以外は空文字列。 -->
{doc_heavy_mode_instructions}

## プロジェクト経験則（Wiki — 該当時のみ非空）
<!-- wiki.enabled && wiki.auto_query のとき、ステップ 4.0.W で取得した経験則。空の場合はこのセクション自体を省略 -->
{wiki_context}

## 出力フォーマット
以下の形式で評価を出力してください:

### 評価: [可 / 条件付き / 要修正]

### 所見
[レビュー結果のサマリー]

### 仕様との整合性
| 仕様項目 | 実装状態 | 備考 |
|---------|---------|------|
| {spec_item} | 準拠 / 不整合 / 未実装 | {notes} |

### 仕様への疑問（該当がある場合のみ）
[仕様自体に問題があると判断した点。これらは指摘ではなく、ユーザーへの確認事項として扱う]

### 指摘事項

**重要**: 指摘事項テーブルに記載する項目は全て**必須修正**として扱われます。「任意」「推奨」「必須ではないが」といった修正は指摘事項に含めず、下の「推奨事項」セクションに記載してください。

指摘を挙げる前に、以下の **4 必須自問** に全て Yes で答えられるかを確認してください。いずれかが No の場合、推奨事項 欄に落とすか、報告しないでください:

1. **マージブロック基準**: この問題を修正しなければマージすべきでないと確信できるか？
2. **Confidence 基準**: 確信度 (Confidence) が 80 以上か？
3. **Observed Likelihood 基準**: この問題が発生する call site を今のコードから Grep で示せるか？（ハイポセティカル禁止）
4. **立証責任基準**: 指摘の内容欄に「{file}:{line} でこの入力が渡される」と書けるか？（証拠提示必須）

さらに、掲載可否とは独立に次を自問してください（**No でも報告可**。掲載可否は上の 4 自問だけが決めます）:

5. **実測基準**: 再現コマンド + 観測される誤動作、または failing test を `Verification:` アンカーとして添付できるか？（Yes → `Verification:` アンカーを `内容` 列に添付する。No → アンカーを付けずに報告する。記録経路の現況は `_reviewer-base.md` §Verification: runtime 実測の添付 の Rules を参照） **アンカー無しの指摘は merge を止めない** (実測必須ゲートで non-blocking に分類され fix サイクルを起動しない)。実測できるなら必ずアンカーを添えること。**アンカーに装飾を付けないこと** (`**Verification:**` / `` `Verification:` `` / 全角コロン等は後段の形式検証を通らず、**未判定 (blocking のまま) として扱われる** — 実測済みでも non-blocking にはならないが、判定不能な指摘として merge を止め続ける)。**marker と `=>` の間に `<br>` を入れないこと** (`<br>` は正規形の検出自体を破るため単独で `measured=false` へ降格し、実測済みの指摘が merge を止めなくなる)。句点・改行は正規形アンカーなら無害だが、装飾等の書式崩れと重なると未判定ではなく降格へ落ちるので、LHS に入れないのが安全。

| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| {CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW} | {current-pr/follow-up/nit-noted} | {file:line} | {WHAT: 何が問題か} + {WHY: なぜ問題か（影響・リスク・既存パターンとの比較）} | {FIX: 修正方法} + {EXAMPLE: コード例（該当時）} |

**`内容` 列のアンカー記入例**（`Likelihood-Evidence:` は掲載可否、`Verification:` は実測の記録を担う直交アンカー。実測できた指摘は両方を末尾に付けること）:

> ⚠️ **`内容` 列の中では raw `|` (パイプ) を使わないこと**（`Likelihood-Evidence:` / `Verification:` / 叙述部のいずれも対象）。テーブルのセル境界と衝突して 5 列構造を壊します。セルを跨がずに `description` へ届いた場合、アンカーは検出 regex に match せず原則として**未判定 (blocking のまま)** になり、判定不能な指摘が merge を止め続けます。ただし marker から `=>` までの間に改行 / `<br>` / 句点があるとその手前で判定が切れ `measured=false` へ降格します (実測済みでも merge を止めません)。パイプは `¦` (U+00A6) で代替表記してください（下記 2 番目の例）。詳細は `_reviewer-base.md` §Verification: runtime 実測の添付 の Rules を参照。

```
{WHAT + WHY の叙述}<br>Likelihood-Evidence: existing_call_site src/api.ts:45<br>Verification: repro node dist/cli.js --input empty.json => TypeError: Cannot read properties of undefined
```

```
{WHAT + WHY の叙述}<br>Likelihood-Evidence: runtime_observation printf '%s' "$raw" ¦ jq -e '.a' が false を返す<br>Verification: repro printf '%s' "$raw" ¦ jq -e '.a' => false (¦ は raw pipe の表記代替)
```


### 推奨事項
[改善提案があれば（任意の改善、スタイル提案、本 PR の diff と無関係な気になる点など）。各推奨事項を箇条書きで記載すること。本 PR の diff と無関係でトリアージが妥当な場合は `別 Issue` または `スコープ外` キーワードを含めること（ステップ 7 でユーザー確認のうえ Decision Log 記録または Issue 化される）]

**⚠️ 各推奨事項に 3 分類を必ず明示すること** (`aggregate label` 禁止規定):

各推奨事項を `分類: <actionable|design_confirmation|boundary>` を冒頭に付して記載する。分類が無い推奨事項は ステップ 5.1 collection で `design_confirmation` (default) として扱われるが、reviewer 自身が判断したうえで明示することが望ましい。

| 分類 | 意味 | 対応経路 |
|------|------|---------|
| `actionable` | follow-up 対応が妥当な改善提案 (本 PR の diff と無関係で `別 Issue` / `スコープ外` キーワードを含む or それに該当する内容) | ステップ 7.2 で `AskUserQuestion` 必須起動 → Decision Log 記録または Issue 化（推奨機械決定表に従う） |
| `design_confirmation` | reviewer 自身が「現状の判断は妥当」「対応不要」「informational 寄り」と結論しており、action 要求を伴わない観察事項 | ステップ 7 で起票・記録なし、completion report に件数のみ表示 |
| `boundary` | reviewer が action 要否を judgement できず user 判断を要する境界事案 | ステップ 7.2 で `AskUserQuestion` 必須起動 → user が「Decision Log 記録/起票/対応/無視」を選択 |

**禁止**: 「推奨 N 件」「follow-up 候補 N 件」のような **件数のみの aggregate label** で報告を済ませること。各 item の分類を明示せずに集計するのは `aggregate-recommendation-label-evasion` anti-pattern であり、ステップ 7 の機械的 gate により block される。

### 調査推奨（該当がある場合のみ）
[PR 対象ファイル内で、本 PR の diff とは無関係だが気になる既存パターンを検出した場合に記載する。**blocking ではない**ため指摘事項や推奨事項ではなく、`/rite:investigate {file}` の起動候補として integrated report に surface される。該当なしの場合はこのセクション自体を省略する。revert test で「変更前から存在」と判定された pre-existing 事項のうち、reviewer が追加調査の価値ありと判断した箇所のみを記載すること（必須ではない）。]

| ファイル | 気になる点 | 補足 |
|---------|-----------|------|
| {file} | {concern_description} | {notes — e.g., `/rite:investigate {file}` で追加調査推奨 / 本 PR のスコープ外} |

## 制約
[READ-ONLY RULE] このレビューは読み取り専用。`Edit`/`Write` 禁止、問題は指摘事項として報告し修正は `/rite:fix` に委譲する。許可/禁止コマンドの完全一覧は上記「共通レビュー原則」に注入済みの `_reviewer-base.md` `## READ-ONLY Enforcement` を SoT として参照。
````
