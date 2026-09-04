---
type: "patterns"
title: "位置依存の表パースには検査行数ガードを対にする（silent false-pass 遮断）"
domain: "patterns"
description: "`awk -F'|' '{ slug = $2; agent = $4 }'` のような位置依存の列パースは、表形式変更（Agent 列より前へのカラム挿入等）でトークンが期待列からずれる。"
created: "2026-07-03T18:30:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260703T164934Z-pr-1743.md"
  - type: "fixes"
    resource: "raw/fixes/20260703T165654Z-pr-1743.md"
tags: ["bash", "awk", "lint", "fail-fast", "drift-check"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-03T18:30:00+00:00" }
---

# 位置依存の表パースには検査行数ガードを対にする（silent false-pass 遮断）

## 概要

`awk -F'|' '{ slug = $2; agent = $4 }'` のような位置依存の列パースは、表形式変更（Agent 列より前へのカラム挿入等）でトークンが期待列からずれる。regex フィルタで「該当しない行は skip」する防御的実装ほど、形式変更時に**全行が silent に skip され検査が no-op 化して rc=0 の false pass** になる。集合抽出の下限ガード（`>= N 件抽出できなければ invocation error`）と対称に、行内整合チェックにも「フィルタ通過行数を数えて < N なら rc=2 で fail fast」する**検査行数ガード**を対にする。

## 詳細

起点事例（reviewer-registry-drift-check.sh）の I3 slug 整合チェックで実測・対策したパターン。

### 失敗モード

1. `extract_section_rows | awk -F'|'` で Type Identifiers 表の各行から `$2`（slug）と `$4`（Agent セル）を取り出す
2. `if (agent !~ re) next` でヘッダ・separator 行を skip する防御を入れる
3. 将来、表に列が挿入されると Agent トークンが `$4` から `$5` へずれ、**全データ行が regex フィルタに落ちて skip される**
4. 検査対象 0 行 = 不整合 0 件 → rc=0 で「同期している」と誤報告（sandbox で実証: 4 カラム化 + slug/Agent swap drift → rc=0）

### canonical ガード

```bash
i3_out=$(... | awk -F'|' -v re="^${AGENT_RE}$" '
  {
    ...
    if (agent !~ re) next   # ヘッダ / separator は skip
    checked++
    ...
  }
  END { printf "I3_CHECKED=%d\n", checked }
')
i3_checked=$(printf '%s\n' "$i3_out" | sed -n 's/^I3_CHECKED=//p')
if [ "${i3_checked:-0}" -lt 10 ]; then
  echo "ERROR: I3 slug check evaluated only ${i3_checked:-0} rows (expected >= 10)" >&2
  echo "  Likely cause: table format changed (Agent cell no longer in column 4)" >&2
  exit 2   # drift (rc=1) ではなく invocation error (rc=2) として fail fast
fi
```

- ガードの閾値は集合抽出ガードと同じ運用実態値（レジストリ規模の下限）に揃える
- 発火時は「大量 drift 報告」ではなく **invocation error (rc=2)** に分類する（exit code 語彙の保持）
- 回帰テストは「列挿入 → rc=2」を明示 TC で pin する（TC-10。TC が無いとガード削除 mutation が生き残る）

### 適用範囲

- lint / drift-check 系の表・列挙パーサ全般（`-F'|'` の markdown 表、`cut -f`、`awk '{print $N}'` の固定列）
- 「skip する防御」を持つパーサほど本ガードが必須（防御が silent no-op の温床になるため）

## 関連ページ

- [Exit code semantic preservation: caller は case で語彙を保持する](./exit-code-semantic-preservation.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)

## ソース

- [位置依存 awk 列パースの silent no-op 化を MEDIUM 検出](../../raw/reviews/20260703T164934Z-pr-1743.md)
- [検査行数ガード + TC-10 回帰 pin を適用](../../raw/fixes/20260703T165654Z-pr-1743.md)
