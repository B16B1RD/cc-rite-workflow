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

複数の子 Issue を loop で紐付け、全件失敗 / 部分失敗を別レイヤで検出するケース。`/rite:issue:create-decompose` Phase 0.9.4 で使用する。呼び出し元は loop の前に `link_failures=0` で初期化しておくこと。

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
- **Non-blocking**: 本ハンドラーは `exit 1` / `return 1` を行わない。AC-4 / AC-5 に従い、Sub-issues API linkage の失敗は警告出力のみで後続処理を継続する（`Parent Issue: #N` body meta と Tasklist が fallback として残る）。全件失敗時の ERROR 級警告は呼び出し元の集計ロジック (`link_failures` aggregate) 側で扱う責務で、本ハンドラーの責務ではない。
- **Stdout vs stderr**: 成功メッセージは stdout (`echo "✅ ..."`)、警告は stderr (`... >&2`) に出力する。パイプで後段処理を行う呼び出し元が警告を通常出力と混同しないためのルール。

## Related Documents

- [`references/graphql-helpers.md#addsubissue-helper`](./graphql-helpers.md#addsubissue-helper) — 実際に Sub-issues API を呼び出す GraphQL mutation の helper
- [`scripts/link-sub-issue.sh`](../scripts/link-sub-issue.sh) — 本ハンドラーがパースする JSON を出力するスクリプト本体
- [`commands/issue/create-decompose.md`](../commands/issue/create-decompose.md) Phase 0.9.4 — Variant B の利用箇所
- [`commands/issue/parent-routing.md`](../commands/issue/parent-routing.md) child creation path — Variant A の利用箇所
