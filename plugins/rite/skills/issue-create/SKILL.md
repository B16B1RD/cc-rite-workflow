---
name: issue-create
description: |
  rite workflow の Issue 起票スキル: 新規 Issue を作成し GitHub Projects に登録する
  （重複検出・親 Issue 候補検出・XL 自動分解 = Sub-Issue 作成 + 設計仕様書生成 を含む）。
  ユーザーが明示的に /rite:issue-create で起動する。auto-activate しない。
  起動: /rite:issue-create <title or description>
argument-hint: "<title or description>"
---

# /rite:issue-create

新規 Issue を作成し、GitHub Projects に登録する。重複検出・親 Issue 候補検出・XL 自動分解を含む。

**途中で止まったらユーザーは `/rite:recover` で再開する**。

## Arguments

| Argument | Description |
|----------|-------------|
| `<title or description>` | Issue title or description (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{owner}`, `{repo}` | ステップ 1.1（git-remote.sh 優先 + `gh repo view` fallback。SSH host alias 対応） |
| `{project_number}` | `rite-config.yml` の `github.projects.project_number` |
| `{field_name_status}`, `{field_name_priority}`, `{field_name_complexity}` | `rite-config.yml` の `github.projects.fields.{status,priority,complexity}.name`（任意。未設定は空文字 = helper 内蔵の英日エイリアスで解決） |
| `{language}` | `rite-config.yml` の `language`（`ja` / `en` / `auto`、未設定 `auto`） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute |

---

## ステップ 1: 入力解析と前提取得

### 1.1 リポジトリと Project 設定取得

```bash
# SSH host alias 対応: git-remote.sh 優先 + gh repo view fallback
# (canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}
```

Project 番号は `rite-config.yml` の `github.projects.project_number` を最優先。未設定なら `gh api graphql` でリポジトリの `projectsV2(first:10)` を取得して最も関連するものを選択。Project が見つからない場合は warning + Projects 追加を skip。

### 1.2 言語設定

`rite-config.yml` の `language`（`ja` / `en` / `auto`、未設定 `auto`） に従い AskUserQuestion を表示する。`auto` は CJK 文字を検出して Japanese を選択（default Japanese）。

### 1.3 入力から What / Why / Where 抽出

ユーザー入力から:

- **What**: 何をするか
- **Why**: なぜ必要か
- **Where**: 変更対象（ファイル / モジュール / 機能領域）
- **Scope**: 影響範囲
- **Constraints**: 制約・前提

を抽出する。Short input（10 文字未満）の場合は AskUserQuestion で詳細を要求する。抽出した各項目は Step 4.2 で Implementation Contract の各 Section にマップされる（[`references/contract-section-mapping.md`](./references/contract-section-mapping.md) の Step 3 mapping 参照）。

### 1.3.1 探索サマリの自動検出（軽量化パス）

入力テキストまたは同一セッション会話中に「# 探索サマリ:」見出し（`/rite:unknowns` の出力形式）を検出した場合、上記 1.3 の素朴な What/Why/Where 抽出に代えて [Step 3.1 mapping](./references/contract-section-mapping.md#step-31-探索サマリ-section--contract-section-mapping-riteunknowns-連携時) を適用する軽量化パスに入る（線引き rationale: [`references/unknowns-boundary-rationale.md#線引き`](./references/unknowns-boundary-rationale.md#線引き)）。この検出はステップ 4.0 / 5.0 の仮定表面化手順に軽量化規則として反映される（4.0 / 5.0 参照）。

非サマリ入力ではこの検出は発動せず、1.3 の通常抽出のみを行う（後方互換、AC-5）。

### 1.4 slug 生成

title を lowercase、空白を `-` に置換、30 字以内で slug を生成。日本語タイトルは関連英単語に翻訳して slug 化。

---

## ステップ 2: 重複検出

### 2.1 類似 Issue 検索

```bash
result=$(gh issue list -R {owner_repo} --search "is:open <keywords>" --limit 10 --json number,title,labels)
[ "$(echo "$result" | jq 'length')" -eq 0 ] && \
  result=$(gh issue list -R {owner_repo} --state all --limit 10 --json number,title,labels)
```

keywords は What から 2-3 語抽出（stop word 除去、日本語は as-is）。

### 2.2 候補の評価

title 類似度 / label 一致 / 更新日時 / state（OPEN > CLOSED）で top 5 を選定。

### 2.3 分岐

| 候補数 | Options（AskUserQuestion） |
|--------|---------------------------|
| 0 件 | 次ステップへ |
| 1 件 | (a) #{number} の拡張 → body に `Extends: #{number}` 追記 / (b) 既存 Issue を使用 → 終了 + `/rite:open {number}` 提案 / (c) 関連なし |
| 2+ 件 | (a) #{番号} の拡張 / (b) 別 Issue 番号入力 / (c) 関連なし |

---

## ステップ 3: 規模判定と親 Issue 候補検出

### 3.1 規模ヒューリスティック

以下のいずれかに該当すれば **大型タスク候補**（分解推奨）:

1. 複数の distinct change を含む（"Add auth, logging, and caching" 等）
2. Scope keywords を含む（"全体的に" / "across all" / "multiple files" / "一括" 等）
3. Complexity ≥ L（推定）
4. Umbrella/epic 表現を含む（"プロジェクト" / "epic" / "umbrella" / "phase"）

該当しない場合は **単一 Issue**として扱い、ステップ 4 へ。

### 3.2 分解確認

該当時は AskUserQuestion で「Sub-Issue に分解する（推奨） / 単一 Issue として作成 / 中止」を選択。

- **分解**: ステップ 5 へ（Sub-Issue 分解パス）
- **単一**: ステップ 4 へ（単一 Issue パス）
- **中止**: workflow 終了

---

## ステップ 4: 単一 Issue 作成（Single Issue Path）

### 4.0 仮定表面化（Assumption Surfacing）

Contract 生成（4.2）の前に、モデルが暗黙に補完した仮定を表面化し 3 分類で処理する。**設計原則**: 質問はユーザーの頭の中にしかない情報（ユーザー固有の意思決定）のみに限定し、リポジトリ・Wiki から導出可能な情報はモデルが探索で自己解決する。

**探索サマリ検出時の軽量化**: ステップ 1.3.1 で「# 探索サマリ:」を検出した場合、以下の手順 1-3 に次の軽量化を適用する（rationale: [`references/unknowns-boundary-rationale.md#なぜ探索サマリ検出で-4050-を丸ごとスキップしないか`](./references/unknowns-boundary-rationale.md#なぜ探索サマリ検出で-4050-を丸ごとスキップしないか)）:

- 手順 2（盲点列挙）はスキップする（サマリの「発見した盲点」有無に関わらず、unknowns で実施済み扱い）
- サマリの「確定したこと」に含まれる事項は手順 1（仮定列挙）から除外し、再質問しない
- サマリの「未解決の問い」は手順 1 を経由せず直接、手順 3 の 3 分類 (b)/(c) へ合流させる

非サマリ入力ではこの軽量化は適用されず、手順 1-5 を通常どおり実行する（AC-5、後方互換）。

**質問強度（見込み Complexity 連動）**: ステップ 3.1 で見込まれた規模（未確定なら入力 Scope から XS〜XL を概算。確定値は 4.1 で確認）に連動させる:

| 見込み Complexity | 質問上限 |
|------------------|---------|
| XS / S | 0〜1 問 |
| M 以上 | 最大 3 問 |

**手順**:

1. **仮定列挙**: ステップ 1.3 で抽出した What/Why/Where/Scope/Constraints に対し、Contract 化に必要だが入力に明示されていない仮定（対象ファイルの具体パス・命名規則・既存パターンへの準拠・後方互換方針・エラー時挙動など）を列挙する。
2. **盲点列挙（Blind Spot Pass、見込み Complexity M 以上のみ）**: 見込み XS / S ではこのサブステップ自体をスキップする。M 以上のときのみ、以下 2 つの問いかけで能動的に盲点（unknown unknowns）を洗い出す:
   - この Issue が触れていないが、変更によって壊れうる隣接領域は何か
   - ユーザーが知らない可能性のある既存の制約・慣習・経験則は何か

   発見した項目は専用の処理経路を新設せず、次の手順 3 の 3 分類 (a)/(b)/(c) にそのまま合流させる。0 件の場合は実行痕跡を出力しなくてよい（MAY）。
3. **3 分類**（従来仮定・盲点由来の項目を共通で分類する）:
   - **(a) 導出可能（derive）**: リポジトリ / Wiki から探索で確定できる仮定。質問せず Grep / Read / `git` / wiki-query で自己解決する。
   - **(b) ユーザー固有の意思決定（ask）**: ユーザーの頭の中にしかない意思決定（優先する選択肢・UX 方針・トレードオフの取り方など）。AskUserQuestion で確認する。
   - **(c) 保留可能（defer）**: いま確定しなくても着手でき後続で解消できる仮定。4.2 で Issue body の前提 / Open Questions（Section 1 の `Assumptions / Open Questions` サブセクション。位置は [`template-structure.md`](../../templates/issue/template-structure.md) Section 1 参照）に明文化する。
4. **wiki-query クロスチェック（SHOULD）**: ドラフト Contract のキーワードで Wiki を検索し、蓄積された経験則と矛盾する仮定があれば (b) または (c) として表面化する。Wiki 無効 / 未初期化時は silent skip（`wiki-query-inject.sh` が空出力で返るため、エラー・警告を出さない）:

   ```bash
   # plugin_root は Plugin Path Resolution で解決
   # {contract_keywords} はドラフト Contract の What / 対象ファイルパス / ドメイン用語を
   # カンマ区切りで生成する（他コーラー skills/issue-implement/SKILL.md / skills/fix/SKILL.md /
   # skills/pr-review/SKILL.md / skills/unknowns/SKILL.md と同形式）
   if [ -f "{plugin_root}/hooks/wiki-query-inject.sh" ]; then
     wiki_context=$(bash "{plugin_root}/hooks/wiki-query-inject.sh" --keywords "{contract_keywords}" --format compact 2>/dev/null) || wiki_context=""
     [ -n "$wiki_context" ] && echo "$wiki_context"
   fi
   ```

   非空の `wiki_context` を読み、ドラフト Contract と矛盾する経験則があれば該当仮定を (b) または (c) として表面化する。

5. **質問の発行**: (b) のみを AskUserQuestion で確認し、各問に推奨案を付ける（第 1 選択肢を推奨とする）。

**制約**:

| 条件 | 挙動 |
|------|------|
| 仮定 0 件 | 質問せず 4.1 へ進む（空の AskUserQuestion を出さない） |
| (b) が 4 件以上（従来仮定 + 盲点由来の合計） | 影響の大きい順に 3 問へ絞り、溢れた分は (c) として body に明文化する |
| 見込み XS / S | 質問は最大 1 問に抑制する。盲点列挙（手順 2）はスキップする |
| 探索サマリ検出（ステップ 1.3.1） | 手順 2 スキップ・「確定したこと」を手順 1 から除外・「未解決の問い」を手順 1 経由せず (b)/(c) へ直接合流 |
| Wiki 無効 / 未初期化 | wiki クロスチェックを silent skip する |
| ユーザーが質問で「中止」を選択 | workflow を終了する（既存ポリシー） |
| 全仮定が (a) で解決 | 表面化ステップの出力を 1 行サマリに省略してよい（MAY） |

### 4.1 Issue 情報の最終確認

AskUserQuestion で Issue の以下を確認/補完する:

- title（slug ベース）
- type（feat / fix / docs / refactor / chore — これは **Commit Type**。Issue body 構造で使う Contract Type との対応は [`default.md` Type Definitions](../../templates/issue/default.md#type-definitions) の crosswalk が SoT）
- priority（High / Medium / Low）
- complexity（XS / S / M / L / XL）
- labels（推測されたもの + 追加）

### 4.2 Issue Body 生成（Implementation Contract フォーマット）

Issue body は **Implementation Contract** フォーマット（Section 0-9）で生成する。出力構造は Step 4.1 で確定した **Type** と **Complexity** で決まる。詳細 rubric は SoT reference に委譲し、inline で複製しない（self-contained: 外部サブスキルは invoke しない）。

**Step 1: テンプレート読込（runtime SoT）**

Read tool で以下を読み込む:

- [`../../templates/issue/template-structure.md`](../../templates/issue/template-structure.md) — Section 0-9 の section-by-section markdown template（Type 別 Section 3 / AC count guideline / Minimum test rows を含む）
- [`../../templates/issue/default.md`](../../templates/issue/default.md) — Complexity Gate テーブル（section × XS-XL の M/S/O）と Output Validation Checklist

**Step 2: セクション構成の決定**

[`references/contract-section-mapping.md`](./references/contract-section-mapping.md) の 4-step rubric に従う:

1. **Complexity Gate 適用**: 確定 Complexity の列で `M`(MUST) を必ず含め、`S`(SHOULD) は Step 1.3 で情報が得られた場合のみ含め、`O`(OMIT) は省略
2. **Type Core Section (Section 3) 選択**: Step 4.1 で確定した値は **Commit Type**（feat/fix/...）。[`default.md` Type Definitions](../../templates/issue/default.md#type-definitions) の crosswalk で **Contract Type**（Feature/BugFix/...）へ対応付け、その Contract Type に対応する Section 3 を [Step 2 mapping](./references/contract-section-mapping.md#step-2-type--type-core-section-section-3-mapping) で 1 つ選択する。Section 0 Meta の `**Type**` には Step 4.1 で確定した Commit Type をそのまま記載し、Step 4.4 完了レポートの Type と一致させる（crosswalk は Section 3 選択のためにのみ用い、Meta 値は変換しない）
3. **入力のマッピング**: Step 1.3 で抽出した What/Why/Where/Scope/Constraints を [Step 3 mapping](./references/contract-section-mapping.md#step-3-perspective--target-sections-mapping) と [Section Inclusion Rules](./references/contract-section-mapping.md#section-inclusion-rules) に従って各 Section へ反映（What → Section 1 Goal / Why → Section 1-2 / Where → Section 4.1 Target Files / Scope → Section 2 Scope(In/Out) / Constraints → Section 4.5 / Section 7）。あわせて Step 4.0 で **defer** された仮定があれば Section 1 の `Assumptions / Open Questions` サブセクションへ記載する（仮定が無ければ当該サブセクションは省略）。ステップ 1.3.1 で探索サマリを検出した場合は [Step 3.1 mapping](./references/contract-section-mapping.md#step-31-探索サマリ-section--contract-section-mapping-riteunknowns-連携時) を併用し、「却下した代替案」を Section 9 Decision Log の素材として反映する
4. **MUST だが情報未収集の Section**: 空見出しを残さず `<!-- 情報未収集 -->` プレースホルダーを挿入

**Step 3: AC / Test 数の整合**

`template-structure.md` の AC count guideline と Minimum test rows に従い、確定 Complexity に応じた AC・T-xx 行数を満たす。各 AC は最低 1 つの T-xx に対応させ、Output Validation Checklist で検証する。

生成した body はそのまま Step 4.2.1 の検証を経て Step 4.3 で `create-issue-with-projects.sh` に tmpfile 経由で渡す。

### 4.2.1 本文の断定のファクトチェック

4.2 で生成した body に含まれる**検証可能な断定**を、4.3 の Issue 作成の前に検証する。Complexity は 4.1 で**確定した値**を使う（4.0 の見込み値ではない）。

**Read tool で [`references/body-fact-check.md`](./references/body-fact-check.md) を読み込んでから検査する**（4.2 Step 1 のテンプレート読込と同じ runtime SoT 読込。3 クラスの検出方法・**裏取りコマンド表**・エラー処理は同 reference にのみ存在し、本体には複製しない。読み込まずに下表だけで進めると実行すべきコマンドが判らず、記憶・推測での `VERIFIED` 判定という同 reference が禁じる経路に落ちる）。

| 状況 | アクション |
|------|-----------|
| 検査対象 0 件 | **silent skip** — 出力・質問を一切出さず 4.3 へ（`## E2E Output Minimization` に準拠） |
| すべて `VERIFIED` | 出力を増やさず 4.3 へ |
| `CONTRADICTED` あり | **自動修正せず** AskUserQuestion で 3 択（`訂正案を採用` / `要確認を付記して続行` / `そのまま続行`）。選択を反映して 4.3 へ |
| `UNVERIFIED` あり | 「要確認」（外部仕様の主張は「要検証」）を本文に付記して 4.3 へ。作成をブロックしない |

自己矛盾候補（M 以上）は上表と**直交する軸**のため行にしない。上表のどの行に該当したかに関わらず、reference の「クラス 3」節が定める規則で独立に評価する（相乗り / 新規発行の分岐も同節が単一定義を持つ。ここに写すと consumer 間で転写漏れが起きるため参照に留める）。

### 4.3 Issue 作成 + Projects 登録

`create-issue-with-projects.sh` に委譲（Issue 作成 + Projects 追加 + status / priority / complexity 設定を 1 ステップで実行）。実 interface は JSON 単一引数 + body は tmpfile 経由（canonical SoT: [`issue-create-with-projects.md`](../../references/issue-create-with-projects.md)）:

> **フィールド名のローカライズ配線**: `rite-config.yml` の `github.projects.fields.{status,priority,complexity}.name`（任意）を読み取り、`{field_name_status}` / `{field_name_priority}` / `{field_name_complexity}` に展開する。未設定のキーは空文字とする（helper 側で内蔵の英日エイリアス + 英語正準名にフォールバックするため、日本語フィールド名 Project でもゼロ設定で解決する）。これらは helper 入力 JSON の `projects.field_names` に additive に詰められる。

```bash
# drift-check-ignore: canonical な「JSON を helper へ単一引数で渡す」契約は
#   create-md-invocation-symmetry.test.sh (TC-1/TC-2/TC-4/TC-1e) と SoT が test 強制している。
#   tmpfile / args_json を同一プロセスで参照するため block 分割はできず、
#   long-block heaviness は意図的に許容する。
# body を tmpfile に書く (LLM が {body} 部分を実 markdown に展開してから heredoc に流す)
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat > "$tmpfile" <<'ISSUE_BODY_EOF'
{body}
ISSUE_BODY_EOF

[ -s "$tmpfile" ] || { echo "ERROR: Issue body is empty" >&2; exit 1; }

# {labels_csv} (例: "bug,fix") を JSON array に変換 (空 CSV は空配列)
labels_json=$(printf '%s' "{labels_csv}" | jq -R 'split(",") | map(select(length>0) | gsub("^\\s+|\\s+$"; ""))')

# 各ラベルを冪等に事前作成する (`gh issue create --label X` は X 未存在時に
# `could not add label` で fail するため。skills/cleanup/SKILL.md ステップ 3 と同パターン)。
# 既存ラベル / 権限不足の失敗は無視して続行し、真の失敗は gh issue create 側で
# helper の $result (warnings) として surface される。空 labels_csv はループ 0 回で従来動作。
while IFS= read -r label; do
  [ -z "$label" ] && continue
  gh label create "$label" -R {owner_repo} --description "auto-created by rite issue-create" --color "ededed" 2>/dev/null || true
done < <(printf '%s\n' "$labels_json" | jq -r '.[]')

# args_json を入れ子 $() から分離して構築する (深い入れ子 quoting の malform 源を削減。
# 単一 JSON 引数契約は不変)
args_json=$(jq -n \
  --arg title "{title}" \
  --arg body_file "$tmpfile" \
  --argjson labels "$labels_json" \
  --argjson enabled true \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg status "Todo" \
  --arg priority "{priority}" \
  --arg complexity "{complexity}" \
  --arg field_name_status "{field_name_status}" \
  --arg field_name_priority "{field_name_priority}" \
  --arg field_name_complexity "{field_name_complexity}" \
  --arg iter_mode "none" \
  --arg source "interactive" \
  '{
    issue: { title: $title, body_file: $body_file, labels: $labels },
    projects: {
      enabled: $enabled,
      project_number: $project_number,
      owner: $owner,
      status: $status,
      priority: $priority,
      complexity: $complexity,
      field_names: { status: $field_name_status, priority: $field_name_priority, complexity: $field_name_complexity },
      iteration: { mode: $iter_mode }
    },
    options: { source: $source, non_blocking_projects: true }
  }') || { echo "ERROR: args_json の jq 構築に失敗しました" >&2; exit 1; }

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$args_json") || {
  rc=$?
  echo "ERROR: create-issue-with-projects.sh failed (exit $rc)" >&2
  # helper は失敗時も stdout JSON (warnings に原因を記録) を出力するため、捕捉済み $result を
  # 破棄せず surface する (これが無いと gh の失敗理由がユーザーに一切見えない)
  if [ -n "$result" ]; then
    echo "  helper result:" >&2
    printf '%s\n' "$result" | sed 's/^/    /' >&2
    printf '%s\n' "$result" | jq -r '.warnings[]?' 2>/dev/null | sed 's/^/  ⚠️ /' >&2
  fi
  exit 1
}

[ -z "$result" ] && { echo "ERROR: create-issue-with-projects.sh returned empty result" >&2; exit 1; }

issue_number=$(printf '%s' "$result" | jq -r '.issue_number // empty')
[ -z "$issue_number" ] && { echo "ERROR: result に issue_number が含まれていません: $result" >&2; exit 1; }

project_reg=$(printf '%s' "$result" | jq -r '.project_registration // "unknown"')
if [ "$project_reg" = "failed" ]; then
  echo "WARNING: Issue #$issue_number は作成されましたが Projects 登録に失敗しました" >&2
  # AskUserQuestion で「手動で Projects 登録 / retry / skip して続行」を選択
fi
```

### 4.4 完了レポート

完了レポートの最終 2 行は `<!-- skill return signal: caller must continue next step -->` + `<!-- [create:returned-to-caller:{issue_number}] -->` HTML コメント sentinel とし、user-visible な末端は `✅ ...` 完了メッセージで終わる。sentinel は hook / grep 契約のため必須だが、HTML コメント化することでユーザーに「完了したのか途中なのか」の判別を阻害しない。

```markdown
✅ Issue #{issue_number} を作成しました

| 項目 | 内容 |
|------|------|
| Title | {title} |
| Type | {type} |
| Priority | {priority} |
| Complexity | {complexity} |
| URL | {issue_url} |

### 次のアクション
- `/rite:open {issue_number}` で作業を開始
- または `/rite:pr-create` で Issue なしで PR を作成

<!-- skill return signal: caller must continue next step -->
<!-- [create:returned-to-caller:{issue_number}] -->
```

以上で `/rite:issue-create` は完了（flow-state には触れない）。

---

## ステップ 5: Sub-Issue 分解（Decompose Path）

### 5.0 仮定表面化（Assumption Surfacing）

設計仕様書生成（5.1）の前に、ステップ 4.0 の仮定表面化手順を適用する。分解パスは見込み Complexity が L/XL のため質問上限は最大 3 問。(b) ユーザー固有の意思決定のみを確認し、(c) 保留仮定は 5.1 の仕様書に前提として明文化したうえで、各 Sub-Issue body の Section 1 `Assumptions / Open Questions` へ引き継ぐ。仮定 0 件時の素通り・(b) 4 件以上の (c) 降格・Wiki 無効時の silent skip・中止選択時の終了といった制約は 4.0 と同一。探索サマリ検出時の軽量化（手順 2 スキップ・「確定したこと」除外・「未解決の問い」の直接合流）も 4.0 と同一に適用する。

### 5.1 仕様書生成

大型 Issue から「設計仕様書」を生成する。以下のセクションを含む:

```markdown
## 1. 目的（Goal）
{why}

## 2. スコープ
- In scope: {in_scope}
- Out of scope: {out_of_scope}

## 3. 受入基準
- AC-1: {ac1}
- AC-2: {ac2}

## 4. 設計方針
{design_approach}

## 5. Sub-Issue 構成
1. Sub-1: {sub_1_title}（complexity: {sub_1_complexity}）
2. Sub-2: {sub_2_title}（complexity: {sub_2_complexity}）
...

## 6. 依存関係
- Sub-2 は Sub-1 完了後
- Sub-3 は独立

## 7. リスク・考慮事項
{risks}
```

### 5.1.1 仕様書の断定のファクトチェック

5.1 で生成した設計仕様書に対して ステップ 4.2.1 と同一の検査を適用する。**Read tool で [`references/body-fact-check.md`](./references/body-fact-check.md) を読み込んでから検査する**（4.2.1 と同じ共通参照。裏取りコマンド表は同 reference にのみ存在するため、読込を省くと検査が実行できない）。分解パスは ステップ 4.1 を通らないため確定 Complexity を持たないが、親仕様書は親 Complexity が `XL` 固定（5.5 Step 1 の helper 契約）のため **3 クラスすべて**を検査範囲とする（ステップ 3.1 の分解判定は Complexity 以外の条件でも成立しうるため、見込み値を根拠にしない）。検査対象 0 件時の silent skip・`CONTRADICTED` の 3 択・自己矛盾候補の表面化・`UNVERIFIED` の「要確認」付記はいずれも 4.2.1 と同一。裏取りコマンドが失敗した場合の分類も 4.2.1 と同じく reference のエラー処理表に委ね、条件を本体へ写さない。表面化した項目は 5.2 のユーザー確認より**前**に解消する（5.2 の 3 択に混ぜない）。

検査対象は 5.1 の設計仕様書に閉じる。5.5 で生成する Sub-Issue body は本ステップの対象外とする（本機能の Scope は 4.2 直後と 5.1 後に限定されており、検査を生成地点である 5.5 まで広げるのは別 Issue の範囲）。

### 5.2 ユーザー確認

AskUserQuestion で「この分解で進める / 分解を修正 / 中止」を選択。修正の場合は仕様書を再提示。

### 5.3 + 5.4 + 5.5 Step 1: 親 Issue 作成 + Sub-Issue 一括作成 + fetch（helper 委譲）

> **3 段プロトコル**: 親作成・Sub 一括作成・link・fetch は `scripts/decompose-issues.sh` に委譲する。LLM は (A) workdir を `mktemp` で確保 → (B) **Write tool** で各 body を raw ファイル化＋spec.json 生成（heredoc malform 源を撤廃）→ (C) helper を単一呼び出し、の 3 段で実行する。helper が spec の `workdir` を trap で cleanup し、3 つの `[CONTEXT]` marker と fetch_output を emit するので、Step 5.5 Step 2/3 はそれを literal parse する。

**(A) workdir 確保**

```bash
workdir=$(mktemp -d -t rite-decompose-XXXXXX)
echo "[CONTEXT] DECOMPOSE_WORKDIR=$workdir"
```

**(B) body / spec の生成（Write tool）**

直前の `[CONTEXT] DECOMPOSE_WORKDIR=` から `{DECOMPOSE_WORKDIR}` を読み取り、以下を **Write tool** で書く（heredoc を使わない）:

1. `{DECOMPOSE_WORKDIR}/parent_body.md` ← §5.1 で生成した設計仕様書（`{spec_document}`）の raw 内容
2. 各 Sub-Issue について `{DECOMPOSE_WORKDIR}/sub_{i}_body.md`（i = 1..{sub_count}）← 各 Sub-Issue body の raw 内容（Step 4.2 の Implementation Contract フォーマットで生成する。各 Sub-Issue の確定 Complexity に応じて Complexity Gate を適用）
3. `{DECOMPOSE_WORKDIR}/spec.json` ← 下記スキーマ。`body_file` は上記で書いた絶対パスを指す:

```json
{
  "parent": { "title": "{parent_title}", "body_file": "{DECOMPOSE_WORKDIR}/parent_body.md" },
  "sub_issues": [
    { "title": "{sub_1_title}", "body_file": "{DECOMPOSE_WORKDIR}/sub_1_body.md", "complexity": "{sub_1_complexity}" }
  ],
  "labels_csv": "{labels_csv}",
  "projects": {
    "enabled": true,
    "project_number": {project_number},
    "owner": "{owner}",
    "status": "Todo",
    "priority": "{priority}"
  },
  "repo": "{repo}",
  "workdir": "{DECOMPOSE_WORKDIR}"
}
```

> `sub_issues` 配列は Sub-Issue 件数 `{sub_count}` だけ要素を持たせる（各反復で `{sub_N_title}` / `{sub_N_complexity}` と body ファイルパスを実値置換）。親 labels には helper が `epic` を自動付与する（spec へ付与不要）。親 complexity は helper 内で `XL` 固定。

**(C) helper 呼び出し（単一 bash block）**

```bash
bash {plugin_root}/scripts/decompose-issues.sh --spec "{DECOMPOSE_WORKDIR}/spec.json" || {
  echo "ERROR: Issue 分解失敗 (decompose-issues.sh 非ゼロ終了)" >&2
  exit 1
}
```

> **marker 受け渡し**: helper は stdout に `[CONTEXT] PARENT_ISSUE_NUMBER=N` / `[CONTEXT] SUB_ISSUE_RESULT created=… failed=… link_failures=…` / `[CONTEXT] SUB_ISSUE_NUMBERS=…` を emit し、続けて fetch_output（`original_length=` / `tmpfile_read=` / `tmpfile_write=`）を出力する。Step 5.5 Step 2-3 はこれらを marker として LLM が literal 置換する。Sub-Issue 作成・link の失敗は helper 内で非 blocking にカウントされ、parent 作成失敗のみ helper が `exit 1` を返し上記 caller ガードで停止する。

### 5.5 Step 2: LLM 編集

LLM は以下を実行する:
1. CONTEXT marker (`PARENT_ISSUE_NUMBER`, `SUB_ISSUE_NUMBERS`) を直前の bash 出力から読み取る
2. `tmpfile_read` の内容を Read tool で取得し、Sub-Issues セクション追記版を `tmpfile_write` へ Write tool で書く

### 5.5 Step 3: apply（別 bash block）

> 以下の bash block 内 `{PARENT_ISSUE_NUMBER}`, `{TMPFILE_READ}`, `{TMPFILE_WRITE}`, `{ORIGINAL_LENGTH}` は LLM が直前の CONTEXT marker から literal 置換する。

```bash
# helper 内で safety guard / API 失敗を plain WARNING として stderr に出力するため、
# orchestrator 側は stderr を観測するだけに留め、tmpfile パス未取得のときのみ
# caller 側で WARNING を出して checklist 更新を skip する。
if [ -n "{TMPFILE_READ}" ] && [ -n "{TMPFILE_WRITE}" ]; then
  apply_err=$(bash {plugin_root}/hooks/issue-body-safe-update.sh apply \
    --issue {PARENT_ISSUE_NUMBER} \
    --tmpfile-read "{TMPFILE_READ}" \
    --tmpfile-write "{TMPFILE_WRITE}" \
    --original-length "{ORIGINAL_LENGTH}" \
    --parent 2>&1) || true
  if [ -n "$apply_err" ]; then
    if [ "${#apply_err}" -gt 500 ]; then
      apply_err_short="${apply_err:0:500}...truncated(${#apply_err})"
    else
      apply_err_short="$apply_err"
    fi
    echo "WARNING: 親 Issue body の更新で診断メッセージ: $apply_err_short" >&2
  fi
else
  echo "WARNING: Parent #{PARENT_ISSUE_NUMBER}: fetch did not return tmpfile paths (gh issue view 失敗 or 空 body); 親 Issue body の Sub-Issues セクション更新を skip" >&2
fi
```

### 5.6 完了レポート

Decompose path も完了レポートの最終 2 行は `<!-- skill return signal: caller must continue next step -->` + `<!-- [create:returned-to-caller:{parent_issue_number}] -->` HTML コメント sentinel で終わる。Single Issue path と同じく、sentinel は hook / grep 契約のため必須で、HTML コメント化することで user-visible な末端は `✅ ...` 完了メッセージとなる。`link_failures > 0` 時の警告ブロックは sentinel より前に挿入する。

```markdown
✅ Issue #{parent_issue_number} を分解して {sub_count} 件の Sub-Issue を作成しました

### 親 Issue
- #{parent_issue_number} {parent_title}

### Sub-Issues
- #{sub_1_number} {sub_1_title}（complexity: {sub_1_complexity}）
- #{sub_2_number} {sub_2_title}（complexity: {sub_2_complexity}）
- ...

### 次のアクション
- `/rite:open {first_sub_issue}` で最初の Sub-Issue から作業を開始
- `/rite:issue-list` で全 Sub-Issue 一覧を確認

<!-- skill return signal: caller must continue next step -->
<!-- [create:returned-to-caller:{parent_issue_number}] -->
```

`link_failures > 0` の場合は完了メッセージと sentinel の間に以下を併記し、ユーザーに復旧を促す:

```markdown
### ⚠️ Sub-issues API リンク失敗 ({link_failures} 件)
- 親 #{parent_issue_number} ←→ 子 #{sub_X_number} の link 確立に失敗した Sub-Issue があります（API 失敗 / rate limit / token scope 等）
- 親 Issue body の Tasklist と `## 親 Issue` body meta は fallback として残っています
- 復旧: `bash {plugin_root}/scripts/link-sub-issue.sh {owner} {repo} {parent_issue_number} {sub_X_number}` を該当 Sub-Issue ごとに手動再実行してください
```

以上で `/rite:issue-create` は完了。

> **Note**: 本コマンドは Issue 作成のみで work phase を持たず、flow-state を init / 所有しない。したがって完結時に flow-state を completed/inactive 化する処理は持たない。これは別の active な work フロー（`/rite:open` 等）の途中で本コマンドが sub-task として呼ばれたとき、親セッションの flow-state を誤って上書きしないための設計（standalone 実行でも flow-state には一切触れない）。

---

## エラー時の方針

- 各ステップで止まっても Issue が作成されていなければ、ユーザーは同じ入力で `/rite:issue-create` を再実行できる
- Issue 作成後（`{issue_number}` 確定後）はその Issue を起点に作業を進められる（重複作成を避けるためステップ 2 の重複検出が活きる）
- AskUserQuestion で「中止」が選ばれた場合のみ workflow 終了
- bash command 失敗時は stderr に `WARNING` または `ERROR` プレフィックスを残し、復旧不能なケースのみ workflow を停止する

---

## E2E Output Minimization

ステップ間の出力は最小限に。各ステップは:

- 開始時に 1 行 status（「ステップ N: 〜」）
- bash / AskUserQuestion の結果
- 完了時の最終レポート（ステップ 4.4 / 5.6）

中間説明・サマリ・guidance text は省略する。

## Standalone Usage

`/rite:issue-create` 単独で動作する。Issue 作成後に作業を開始するには `/rite:open {issue_number}` を実行する。

## Error Handling

- owner/repo 解決失敗（git-remote.sh + `gh repo view` fallback とも失敗）→ エラー、認証・remote 設定確認を案内
- Projects 未設定 → warning、Projects 追加を skip
- Issue 作成失敗 → AskUserQuestion で「再試行 / 手動作成 / 中止」
- 親-子リンク失敗 → warning、後で手動リンクを案内
