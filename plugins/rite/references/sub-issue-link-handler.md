# Sub-Issue Link Handler Reference

`plugins/rite/scripts/link-sub-issue.sh` から返される `link_status` を処理するための正典スニペット。`/rite:issue:create-decompose` と `/rite:issue:parent-routing` が共通で使用する。

## 目的

GitHub Sub-issues API で親 Issue と子 Issue を紐付けた結果 (`link_status`) をハンドルするロジックは、従来 `create-decompose.md` と `parent-routing.md` の2ヶ所に同一 inline 重複していた。片方を修正したときにもう片方の同期を忘れる drift リスクがあったため、ハンドラー本体を本ファイルに一元化する。

呼び出し元は周辺ロジック（単発実行 vs ループ実行、失敗カウンタ集計の有無）に応じて、以下の2 variant のうち該当するものを inline で展開する。

## 前提

呼び出し元は以下の bash 変数を設定済みであること:

| 変数 | 生成元 | 内容 |
|------|--------|------|
| `link_result` | `bash {plugin_root}/scripts/link-sub-issue.sh "{owner}" "{repo}" "{parent_issue_number}" "$sub_number"` | `link-sub-issue.sh` の JSON 出力 |
| `link_status` | `printf '%s' "$link_result" \| jq -r '.status'` | `ok` / `already-linked` / `failed` / 予期しない文字列 |
| `link_msg`    | `printf '%s' "$link_result" \| jq -r '.message'` | 成功時の人間可読メッセージ |
| `sub_number`  | 呼び出し元 | 処理中の子 Issue 番号（loop 変数または単発値） |

## Variant A: basic (カウンタなし)

単発の子 Issue を紐付け、失敗集計を行わないケース。`/rite:issue:parent-routing` の child creation path（1件ずつ loop で呼び出されるが、全件失敗の集計は行わない）で使用する。

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
    # 未知 status を silent 通過させない (Issue #514 MUST NOT)
    echo "⚠️ Unexpected link status '$link_status' for #$sub_number (msg: $link_msg)" >&2
    ;;
esac
```

## Variant B: counting (失敗カウンタあり)

複数の子 Issue を loop で紐付け、全件失敗 / 部分失敗を別レイヤで検出するケース。`/rite:issue:create-decompose` Phase 3.3 (Sub-Issues API Linkage) で使用する。呼び出し元は loop の前に `link_failures=0` で初期化しておくこと。

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
    # 未知 status を silent 通過させない (Issue #514 MUST NOT)
    echo "⚠️ Unexpected link status '$link_status' for #$sub_number (msg: $link_msg)" >&2
    link_failures=$((link_failures + 1))
    ;;
esac
```

2つの variant の差分は `failed` / `*` ブランチにおける `link_failures=$((link_failures + 1))` の有無のみで、それ以外のメッセージ・stderr 出力・未知 status 扱いは完全に一致する。

## 設計上の不変条件

呼び出し元が variant を選ぶ際も、以下の制約は必ず保持すること。Variant を増やす場合もここを書き換えないこと。

- **Issue #514 MUST NOT — unknown status silent 通過禁止**: `*` ブランチで stderr 警告を必ず出すこと。`case` の `*)` を省略したり、無視したり、ログレベルを落としたりしてはならない。Sub-issues API が将来新しい status 値を追加した場合の早期検出に依存している制約である。
- **Non-blocking**: 本ハンドラーは `exit 1` / `return 1` を行わない。AC-4 / AC-5 に従い、Sub-issues API linkage の失敗は警告出力のみで後続処理を継続する（`Parent Issue: #N` body meta と Tasklist が fallback として残る）。全件失敗時の ERROR 級警告は **Variant B 呼び出し元** の集計ロジック (`link_failures` aggregate) 側で扱う責務で、本ハンドラーの責務ではない。**Variant A 呼び出し元** は全件失敗集計を行わない（個別 failure の stderr 警告のみに依存する）。例: `parent-routing.md` の child creation path は単一 child を 1 件ずつ処理するため本 variant を採用する。
- **Stdout vs stderr**: 成功メッセージは stdout (`echo "✅ ..."`)、警告は stderr (`... >&2`) に出力する。パイプで後段処理を行う呼び出し元が警告を通常出力と混同しないためのルール。

## Caller Responsibility

呼び出し元 (command ファイル側) は以下の責務を負う。新規 caller を追加する際もこれらを必ず守ること。

### 1. Inline 展開規約

本 reference は **canonical 定義** であり、command ファイル側は **対応する variant の case ブロックを inline で完全記述** する。「`# expand here` のような placeholder コメントを残して LLM 実行時に展開させる」アプローチは **採用しない**。理由:

- bash インタプリタは `#` コメントを no-op として消費するため、placeholder のまま実行されると `link_status` が一切評価されず、`failed` / 未知 status が silent 通過する Issue #514 MUST NOT 違反になる
- LLM 動作の冗長性に依存する設計は、コンテキスト圧迫 / placeholder 見落とし / hallucination のいずれでも silent regression を起こす
- 本リポジトリの他 reference (`references/gh-cli-patterns.md`, `references/graphql-helpers.md`) も「caller 側で inline 完全記述 + reference link を補助情報として付随」形式を採る

### 2. Drift 防止

inline 展開のため、本 reference を修正する際は以下 **すべての caller** を同時に更新する責務がある:

- `commands/issue/create-decompose.md` Phase 3.3 (Sub-Issues API Linkage) (Variant B 利用)
- `commands/issue/parent-routing.md` child creation path (Variant A 利用)

各 command ファイル内には「⚠️ DRIFT 警告」コメントが配置されており、修正時に同期すべきファイル一覧を明示している。新規 caller を追加する際は本セクションと当該コメント両方を更新すること。

### 3. Variant 選択ロジック

| 状況 | 採用 variant | 理由 |
|------|------------|------|
| 単発処理 / 全件失敗集計なし | Variant A (basic) | カウンタ初期化と aggregate check が不要 |
| ループ処理 / 全件失敗を別レイヤで検出 | Variant B (counting) | `link_failures` 集計を呼び出し元の ERROR レイヤと連携 |

## Related Documents

- [`references/graphql-helpers.md#addsubissue-helper`](./graphql-helpers.md#addsubissue-helper) — 実際に Sub-issues API を呼び出す GraphQL mutation の helper
- [`scripts/link-sub-issue.sh`](../scripts/link-sub-issue.sh) — 本ハンドラーがパースする JSON を出力するスクリプト本体
- [`commands/issue/create-decompose.md`](../commands/issue/create-decompose.md) Phase 3.3 (Sub-Issues API Linkage) — Variant B の利用箇所
- [`commands/issue/parent-routing.md`](../commands/issue/parent-routing.md) child creation path — Variant A の利用箇所
