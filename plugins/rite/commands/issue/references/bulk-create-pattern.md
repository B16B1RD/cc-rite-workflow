# Bulk Sub-Issue Creation Pattern — 単一 Bash invocation での Pre-amble + Per-Sub-Issue body + linkage 連結

> **Source of Truth**: 本ファイルは `/rite:issue:create` ワークフローにおける **XL 分解パスでの bulk Sub-Issue creation** の **Pre-amble + Per-Sub-Issue body の連結パターン** の SoT である。`create-decompose.md` Phase 0.9.2 の bash literal の正規定義は本 reference に集約する。
>
> **抽出経緯**: `create-decompose.md` Phase 0.9.2 (旧 lines 363-505、約 140 行) には Pre-amble bash block / Per-Sub-Issue body bash block / Critical guard 警告 / Sub-Issue body structure / Placeholder descriptions / Error handling が集約されており、本体ファイルの認知負荷を高めていた。これを Issue #773 (#768 P1-3) PR 8/8 で本 reference に移管し、`create-decompose.md` Phase 0.9.2 本体には **概要 + AC-1 critical 警告 (NFR-2 protected で本体に残す) + 本 reference への参照リンク** のみを残す形にスリム化する。
>
> **NFR-2 (本体保持)**: AC-1 enforcement boundary に関する critical 警告 (`single-Bash-invocation requirement` / `silent-skip risk` の 2 文) は **`create-decompose.md` 本体に残す**。理由: AC-1 enforcement boundary の同 turn 警告は Phase 0.9.4 空配列 fail-fast との因果関係を保つため、本体読込時に LLM が認識できる位置にある必要がある。本 reference は **手順詳細とコードリテラル** を集約し、警告そのものは本体側 SoT を維持する。

## 位置づけ

`create-decompose.md` Phase 0.9 (Bulk Sub-Issue Creation) は以下の 6 step で構成される:

| Step | 役割 | SoT |
|------|------|-----|
| Phase 0.9.1 | Create the Parent Issue | `create-decompose.md` 本体 (作成 bash literal) + 本 reference ([Parent Issue body structure](#parent-issue-body-structure) — Issue #806 で移動) |
| **Phase 0.9.2** | **Bulk Creation of Sub-Issues** (Pre-amble + Per-Sub-Issue body) | **本 reference** |
| Phase 0.9.3 | Add Tasklist to Parent Issue | `create-decompose.md` 本体 |
| Phase 0.9.4 | Sub-Issues API Linkage (Mandatory) | `create-decompose.md` 本体 + [`graphql-helpers.md`](../../../references/graphql-helpers.md#addsubissue-helper) |
| Phase 0.9.5 | Projects Registration | `create-decompose.md` 本体 |
| Phase 0.9.6 | Completion Report | `create-decompose.md` 本体 |

本 reference は **Phase 0.9.2 (Pre-amble + Per-Sub-Issue body の連結 bash literal)** の正規定義を集約する。

## なぜ単一 Bash invocation が要件か (AC-1 enforcement boundary)

Phase 0.9.2 は **2 つの部分** から構成され、両者は **同一の Bash tool invocation** で実行されることが MUST 要件:

1. **Pre-amble** (1 回のみ実行): accumulator arrays (`SUB_ISSUE_NUMBERS` / `SUB_ISSUE_URLS`) を宣言する
2. **Per-Sub-Issue body** (Phase 0.8 分解 list の項目数 N 回繰り返し実行): Sub-Issue を作成し accumulator に append する

**Bash 変数 (配列を含む) は別々の Bash tool 呼び出し境界で消失する**。これは Claude Code の Bash tool 仕様 — 各呼び出しで新規 shell process が起動するため、前の呼び出しで宣言した変数は次の呼び出しでは参照不可。

このため:

- Pre-amble + N 個の Per-Sub-Issue body のすべてを **1 回の Bash tool invocation 内で順次実行** する必要がある。
- 分割すると Phase 0.9.4 (Sub-Issues API linkage) が空配列を参照することになり、**linkage が silent skip され AC-1 が違反される** (linkage 失敗は per-call で non-blocking なため、log を見落とすと silent regression になる)。
- Phase 0.9.4 が AC-1 enforcement boundary であり、空配列ガードで `exit 1` する fail-fast が最終防御層として機能する。

> **これは本コマンドにおける silent-skip リスク最大の箇所**。Bookkeeping (accumulator append) の省略 / script 分割は **いかなる事情でも許容されない**。

## Pre-amble (1 回のみ)

結合スクリプトの先頭に **1 回だけ** 配置する:

```bash
# === Loop pre-amble (このブロックは結合スクリプトの先頭で1回だけ実行) ===
# SUB_ISSUE_NUMBERS / SUB_ISSUE_URLS は Per-Sub-Issue body の全反復で蓄積され、
# 同一 Bash ツール呼び出し内の Phase 0.9.4 から参照される。
SUB_ISSUE_NUMBERS=()
SUB_ISSUE_URLS=()
```

## Per-Sub-Issue body (N 回複製)

Phase 0.8 分解 list の各 Sub-Issue について、以下のブロックを **複製して同一スクリプトに連結** する。各複製ごとに `{sub_issue_title}` / `{sub_issue_body}` / `{estimated_complexity}` placeholder を **その反復の実値で置換** すること:

```bash
# === Per-Sub-Issue body (N 回複製して連結。各複製ごとに placeholder を実値で置換) ===
# Generate body content from Phase 0.8 decomposition and the structure defined below (see "Sub-Issue body structure")
# Note: Empty check is required because {sub_issue_body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{sub_issue_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty for Sub-Issue '{sub_issue_title}'" >&2
else
  result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
    --arg title "{sub_issue_title}" \
    --arg body_file "$tmpfile" \
    --argjson projects_enabled {projects_enabled} \
    --argjson project_number {project_number} \
    --arg owner "{owner}" \
    --arg priority "{priority}" \
    --arg complexity "{estimated_complexity}" \
    --arg iter_mode "none" \
    '{
      issue: { title: $title, body_file: $body_file },
      projects: {
        enabled: $projects_enabled,
        project_number: $project_number,
        owner: $owner,
        status: "Todo",
        priority: $priority,
        complexity: $complexity,
        iteration: { mode: $iter_mode }
      },
      options: { source: "xl_decomposition", non_blocking_projects: true }
    }'
  )")

  if [ -z "$result" ]; then
    echo "ERROR: create-issue-with-projects.sh returned empty result for Sub-Issue '{sub_issue_title}'" >&2
    # Skip accumulation for this Sub-Issue but continue to the next iteration block.
    # NOTE: We intentionally do NOT use `continue` here because each per-Sub-Issue body
    # is concatenated as a flat sequence (not wrapped in a for/while loop), and `continue`
    # outside a loop is a bash syntax error. The else-branch below handles the skip.
  else
    sub_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
    sub_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
    sub_project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
    # project_id/item_id は XL 分解パスでは後続フェーズで使用しないため省略
    printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done

    # === MANDATORY: 配列に蓄積（Phase 0.9.4 が参照） ===
    # 数値であることを検証してから追加（"null" や空文字を弾く）
    if [[ "$sub_issue_number" =~ ^[0-9]+$ ]]; then
      SUB_ISSUE_NUMBERS+=("$sub_issue_number")
      SUB_ISSUE_URLS+=("$sub_issue_url")
    else
      echo "⚠️ Sub-Issue '{sub_issue_title}' の番号が不正のため linkage 配列に追加しません: '$sub_issue_number'" >&2
    fi
  fi
fi
# === Per-Sub-Issue body 終了。次の Sub-Issue があれば、ここに次の複製を連結する ===
```

> **Alternative (advanced)**: 明示的な loop 構造を好む場合、上記 Per-Sub-Issue body を `for sub_entry in ...; do ... done` で wrap し、Phase 0.8 分解 list を bash array entries として展開する形でも実装可能。その場合は else-branch skip ではなく `continue` が syntactically valid となる。**Pre-amble が 1 回だけ実行され、すべての反復が同一 Bash tool invocation で実行される** という contract を満たせばどちらの approach も許容。

## Placeholder descriptions

Per-Sub-Issue body の placeholder は以下の通り:

| Placeholder | 値の source |
|-------------|-------------|
| `{sub_issue_title}` | Phase 0.8 分解 list の各エントリの title |
| `{sub_issue_body}` | 下記「Sub-Issue body structure」を該当反復の値で埋めて生成 |
| `{estimated_complexity}` | Phase 0.8 で見積もった complexity (XS / S / M / L / XL の per-Sub-Issue 値) |
| `{priority}` | 親 Issue から継承 |
| `{owner}` | `github.projects.owner` (`rite-config.yml`) または `gh repo view --json owner --jq '.owner.login'` |
| `{repo}` | `gh repo view --json name --jq '.name'`。Phase 0.9.4 の `link-sub-issue.sh` 呼び出しで必須。これが欠落すると GraphQL `repository(owner:..., name:"{repo}")` lookup が常に "Could not resolve to a Repository" で失敗し、AC-1 が silent 違反される (per-call 失敗が non-blocking なため)。 |
| `{parent_issue_number}` | Phase 0.9.1 で作成した親 Issue 番号 (Sub-Issues 作成対象) |
| `{projects_enabled}` | `rite-config.yml` の `github.projects.enabled` が `true` なら `true`、それ以外 `false` |
| `{project_number}` | `github.projects.project_number` (`rite-config.yml`) |
| `{plugin_root}` | [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version) で解決 |

## Sub-Issue body structure

Per-Sub-Issue body の `{sub_issue_body}` placeholder に展開する markdown:

```markdown
## 概要

{この Sub-Issue で実装する内容}

## 親 Issue

#{parent_issue_number} - {parent_issue_title}

## 設計ドキュメント

詳細な仕様は [docs/designs/{slug}.md](docs/designs/{slug}.md) を参照してください。

## 変更内容

{具体的な変更内容}

## 依存関係

{依存する Sub-Issue があれば記載}

## 複雑度

{complexity}

## チェックリスト

- [ ] 実装完了
- [ ] テスト追加/更新
- [ ] ドキュメント更新（必要な場合）
```

## Parent Issue body structure

Phase 0.9.1 で `create-issue-with-projects.sh` に渡す `{parent_issue_body}` の正規 markdown:

```markdown
## 概要

{概要}

## 背景・目的

{背景・目的}

## 設計ドキュメント

詳細な仕様は [docs/designs/{slug}.md](docs/designs/{slug}.md) を参照してください。

## Sub-Issues

<!-- 自動更新: Sub-Issue 作成後にタスクリストを追加 -->

## 進捗

| フェーズ | 状態 |
|---------|------|
| 基盤構築 | [ ] 未着手 |
| コア実装 | [ ] 未着手 |
| 統合 | [ ] 未着手 |
| 品質保証 | [ ] 未着手 |

## 複雑度

XL（{count} 件の Sub-Issue に分解）
```

**Placeholders for Parent Issue body**:

| Placeholder | 値の source |
|-------------|-------------|
| `{概要}` / `{背景・目的}` | Phase 0.7 仕様書の SPEC-OVERVIEW / SPEC-BACKGROUND |
| `{slug}` | Phase 0.1.3 で生成した tentative_slug (タイトル変更時は再生成) |
| `{count}` | Phase 0.8 分解で確定した Sub-Issue 件数 |

`Sub-Issues` 節は Phase 0.9.3 で Tasklist に置き換わる。`進捗` テーブルは Phase 0.8.3 の実装順序提案フェーズに準拠した 4 段固定。

## Error handling for partial failures

- Sub-Issue creation がループ途中で失敗した場合、エラーを log して残りの Sub-Issue 作成を継続する (per-call non-blocking)。
- ループ完了後、Phase 0.9.6 (Completion Report) で **どの Sub-Issue が成功し、どの Sub-Issue が失敗したか** を報告する。
- 失敗した Sub-Issue は user が手動で `/rite:issue:create` で retry 可能。

各 Sub-Issue 作成成功後の post-processing:

1. `sub_issue_url` / `sub_issue_number` を Phase 0.9.3 (Tasklist update) のために retain する
2. accumulator (`SUB_ISSUE_NUMBERS` / `SUB_ISSUE_URLS`) に append する (Phase 0.9.4 が参照)
3. `create-issue-with-projects.sh` script が Projects 登録 + field 設定を内部で処理する

## Anti-pattern: Pre-amble + Per-Sub-Issue body 分割

❌ **以下の anti-pattern を絶対に行わないこと**:

```
# Bash tool 呼び出し 1 (Pre-amble のみ)
SUB_ISSUE_NUMBERS=()
SUB_ISSUE_URLS=()

# Bash tool 呼び出し 2 (Sub-Issue 1 作成)
... (SUB_ISSUE_NUMBERS は空配列にリセットされている)

# Bash tool 呼び出し 3 (Sub-Issue 2 作成)
... (依然として空配列)
```

Bash variable scope は tool invocation 境界で消失するため、上記分割では `SUB_ISSUE_NUMBERS` は常に空のままで、Phase 0.9.4 が空配列ガードで `exit 1` する。Phase 0.9.4 の fail-fast が無ければ、AC-1 (parent-child linkage) が silent 違反されたまま完了レポートまで到達する。

✅ **正しい pattern**:

```
# Bash tool 呼び出し 1 (Pre-amble + Sub-Issue 1 + Sub-Issue 2 + ... + Sub-Issue N + Phase 0.9.4 を全部連結)
SUB_ISSUE_NUMBERS=()
SUB_ISSUE_URLS=()

# (Sub-Issue 1 の Per-Sub-Issue body)
tmpfile=$(mktemp); trap ...
... SUB_ISSUE_NUMBERS+=("$sub_issue_number") ...

# (Sub-Issue 2 の Per-Sub-Issue body)
tmpfile=$(mktemp); trap ...
... SUB_ISSUE_NUMBERS+=("$sub_issue_number") ...

# ... (Sub-Issue N まで)

# (Phase 0.9.4 linkage を同一スクリプトで実行)
for issue_num in "${SUB_ISSUE_NUMBERS[@]}"; do
  bash {plugin_root}/scripts/link-sub-issue.sh ...
done
```

`create-decompose.md` 本体の AC-1 critical 警告で何度繰り返されているように、この single-Bash-invocation 要件は **本コマンドにおける silent-skip リスク最大の箇所** である。
