# Sub-Issue Link Handler Reference

`plugins/rite/scripts/link-sub-issue.sh` から返される `link_status` を処理するための正典スニペット。

## 目的

GitHub Sub-issues API で親 Issue と子 Issue を紐付けた結果 (`link_status`) をハンドルするロジック。`/rite:issue-create` が flat 化される前は `create-decompose.md` と `parent-routing.md` の 2 ヶ所に inline 重複していた。flat 化後は `skills/issue-create/SKILL.md` ステップ 5.4 に inline 統合され、さらに `scripts/decompose-issues.sh` (Sub-Issue 一括作成 loop) へ抽出され、現在はこの helper script のみが使用する。

呼び出し元は周辺ロジック（単発実行 vs ループ実行、失敗カウンタ集計の有無）に応じて、以下の 2 variant のうち該当するものを inline で展開する。

## 前提

呼び出し元は以下の bash 変数を設定済みであること:

| 変数 | 生成元 | 内容 |
|------|--------|------|
| `link_result` | `bash {plugin_root}/scripts/link-sub-issue.sh "{owner}" "{repo}" "{parent_issue_number}" "$sub_number"` | `link-sub-issue.sh` の JSON 出力 |
| `link_status` | `printf '%s' "$link_result" \| jq -r '.status'` | `ok` / `already-linked` / `failed` / 予期しない文字列 |
| `link_msg` | `printf '%s' "$link_result" \| jq -r '.message'` | 成功時の人間可読メッセージ |
| `sub_number` | 呼び出し元 | 処理中の子 Issue 番号（loop 変数または単発値） |

## Variant A: basic (カウンタなし)

単発の子 Issue を紐付け、失敗集計を行わないケース。`parent-routing.md` sub-skill (`/rite:open` 内部) の child creation path で使われていた (現在は flat 化で sub-skill 自体が削除)。現状は主に Variant B (counting) の方が `scripts/decompose-issues.sh` の Sub-Issue 一括作成 loop で使われる。

```bash
case "$link_status" in
 ok|already-linked)
 echo "✅ $link_msg"
 ;;
 failed)
 printf '%s' "$link_result" | jq -r '.warnings[]' \
 | while read -r w; do echo "⚠️ $w" >&2; done
 echo "⚠️ Sub-issues API linkage failed for #$sub_number; body meta fallback in place" >&2
 ;;
 *)
 # 未知 status を silent 通過させない
 echo "⚠️ Unexpected link status '$link_status' for #$sub_number (msg: $link_msg)" >&2
 ;;
esac
```

## Variant B: counting (失敗カウンタあり)

複数の子 Issue を loop で紐付け、全件失敗 / 部分失敗を別レイヤで検出するケース。`scripts/decompose-issues.sh` の Sub-Issue 一括作成 loop (create.md ステップ 5.4 から抽出、元は `create-decompose.md` Phase 3.3) で使用する。呼び出し元は loop の前に `link_failures=0` で初期化しておくこと。

```bash
case "$link_status" in
 ok|already-linked)
 echo "✅ $link_msg"
 ;;
 failed)
 printf '%s' "$link_result" | jq -r '.warnings[]' \
 | while read -r w; do echo "⚠️ $w" >&2; done
 echo "⚠️ Sub-issues API linkage failed for #$sub_number; body meta fallback in place" >&2
 link_failures=$((link_failures + 1))
 ;;
 *)
 # 未知 status を silent 通過させない
 echo "⚠️ Unexpected link status '$link_status' for #$sub_number (msg: $link_msg)" >&2
 link_failures=$((link_failures + 1))
 ;;
esac
```

2つの variant の差分は `failed` / `*` ブランチにおける `link_failures=$((link_failures + 1))` の有無のみで、それ以外のメッセージ・stderr 出力・未知 status 扱いは完全に一致する。

## 設計上の不変条件

呼び出し元が variant を選ぶ際も、以下の制約は必ず保持すること。Variant を増やす場合もここを書き換えないこと。

- **unknown status silent 通過禁止 (MUST NOT)**: `*` ブランチで stderr 警告を必ず出すこと。`case` の `*)` を省略したり、無視したり、ログレベルを落としたりしてはならない。Sub-issues API が将来新しい status 値を追加した場合の早期検出に依存している制約である。
- **Non-blocking**: 本ハンドラーは `exit 1` / `return 1` を行わない。Sub-issues API linkage の失敗は警告出力のみで後続処理を継続し、`Parent Issue: #N` body meta と Tasklist を fallback として残す。全件失敗時の ERROR 級警告は **Variant B 呼び出し元** の集計ロジック (`link_failures` aggregate) 側で扱う責務で、本ハンドラーの責務ではない。Variant A は単発処理用 (retired)。
- **Stdout vs stderr**: 成功メッセージは stdout (`echo "✅ ..."`)、警告は stderr (`... >&2`) に出力する。パイプで後段処理を行う呼び出し元が警告を通常出力と混同しないためのルール。

## Caller Responsibility

呼び出し元 (command ファイル側) は以下の責務を負う。新規 caller を追加する際もこれらを必ず守ること。

### 1. Inline 展開規約

本 reference は **canonical 定義** であり、caller (shell script / command ファイル) 側は **対応する variant の case ブロックを inline で完全記述** する。「`# expand here` のような placeholder コメントを残して LLM 実行時に展開させる」アプローチは **採用しない**（Variant B の現 caller は shell script `decompose-issues.sh` で、case ブロックは LLM 展開を介さず実体として配置されるため本制約は構造的に満たされる）。理由:

- bash インタプリタは `#` コメントを no-op として消費するため、placeholder のまま実行されると `link_status` が一切評価されず、`failed` / 未知 status が silent 通過する「unknown status silent 通過禁止」MUST NOT 違反になる
- LLM 動作の冗長性に依存する設計は、コンテキスト圧迫 / placeholder 見落とし / hallucination のいずれでも silent regression を起こす
- 本リポジトリの他 reference (`references/gh-cli-patterns.md`, `references/graphql-helpers.md`) も「caller 側で inline 完全記述 + reference link を補助情報として付随」形式を採る

### 2. Drift 防止

inline 展開のため、本 reference を修正する際は以下 **すべての caller** を同時に更新する責務がある:

- `scripts/decompose-issues.sh` — Sub-Issue 一括作成 loop (Variant B 利用、create.md ステップ 5.4 から抽出した単一 caller)

各 caller (script / command ファイル) 内には「⚠️ DRIFT 警告」コメントが配置されており、修正時に同期すべきファイル一覧を明示している。新規 caller を追加する際は本セクションと当該コメント両方を更新すること。

### 3. Variant 選択ロジック

| 状況 | 採用 variant | 理由 |
|------|------------|------|
| 単発処理 / 全件失敗集計なし | Variant A (basic) | カウンタ初期化と aggregate check が不要 |
| ループ処理 / 全件失敗を別レイヤで検出 | Variant B (counting) | `link_failures` 集計を呼び出し元の ERROR レイヤと連携 |

## Related Documents

- [`references/graphql-helpers.md#addsubissue-helper`](./graphql-helpers.md#addsubissue-helper) — 実際に Sub-issues API を呼び出す GraphQL mutation の helper
- [`scripts/link-sub-issue.sh`](../scripts/link-sub-issue.sh) — 本ハンドラーがパースする JSON を出力するスクリプト本体
- [`scripts/decompose-issues.sh`](../scripts/decompose-issues.sh) — Variant B の利用箇所 (create.md ステップ 5.4 から抽出した Sub-Issue 一括作成 loop)
- 旧 caller (retired): `parent-routing.md` child creation path (Variant A) / `create-decompose.md` Phase 3.3 (Variant B) / `skills/issue-create/SKILL.md` ステップ 5.4 inline (Variant B、`scripts/decompose-issues.sh` へ抽出)
