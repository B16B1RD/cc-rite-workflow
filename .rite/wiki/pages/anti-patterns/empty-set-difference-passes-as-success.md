---
type: "anti-patterns"
title: "集合演算で検証するときは入力集合が空である可能性を成功と区別する"
domain: "anti-patterns"
description: "「A に含まれて B に含まれない要素が無いこと」を差集合の空で検証する形は、**A 自体が空でも成立する**。"
created: "2026-07-30T01:20:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260729T142410Z-pr-2051.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T144345Z-pr-2051.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-30T01:20:00+09:00" }
---

# 集合演算で検証するときは入力集合が空である可能性を成功と区別する

## 概要

「A に含まれて B に含まれない要素が無いこと」を差集合の空で検証する形は、**A 自体が空でも成立する**。抽出側が壊れて 0 件になったケースが、網羅されているケースと同じ「合格」として返る。差集合を見る前に、入力集合が期待どおり非空であることを検査する必要がある。

## 詳細

### 実測された経路

起点事例で新設した `fix-reason-coverage-check.sh` は、「skill 本文が emit する `WM_UPDATE_FAILED` の reason 値が、すべて reason 表に文書化されているか」を次の形で検証していた。

```bash
# emitted: skill 本文から reason 値を正規表現で抽出
emitted=$(grep -oE 'WM_UPDATE_FAILED=1; reason=([a-z_]+)' "$TARGET" | sed 's/.*reason=//' | sort -u)
# documented: reason 表から値を抽出
documented=$(grep -oE '^\| `([a-z_]+)`' "$TARGET" | tr -d '|` ' | sort -u)

# 差集合が空なら合格
if [ -z "$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented"))" ]; then
  exit 0   # ← emitted が空でもここに来る
fi
```

`emitted` の抽出は **prose markdown への正規表現マッチ**である。skill 本文の記法が変わる（`reason=` の前後にバッククォートが入る、marker のフォーマットが変わる、該当ブロックが別ファイルへ移る）と抽出は 0 件になり、`comm -23` は空を返し、スクリプトは rc=0 で「合格」を報告する。**検証が無言で no-op 化する**。

同 PR ではこの構造が、塞ごうとしていた defect（awk が壊れて空値を返し opt-out default に吸収される）と同型であることが指摘された。

### 対処: 入力集合の非空を独立に検査する

```bash
emitted=$(grep -oE '...' "$TARGET" | sed '...' | sort -u)

# 差集合を見る前に、抽出自体が成立したかを検査する
if [ -z "$emitted" ]; then
  echo "ERROR: $TARGET から WM_UPDATE_FAILED emit を 1 件も抽出できませんでした" >&2
  echo "  原因候補: skill 本文の記法変更 / 該当ブロックの移動 / 正規表現の drift" >&2
  exit 2
fi

# ここから差集合の検証
```

`exit 2`（`exit 1` = 差分あり、とは別の値）に分けることで、呼び出し元が「網羅性の欠落」と「検証機構の故障」を区別できる。

### 一般形

この落とし穴は差集合に限らない。**「無いことを確認する」検証は、探す対象が存在する前提が崩れると自動的に成立する**。

| 検証の形 | 入力が空のときの挙動 | 追加すべき検査 |
|---|---|---|
| `comm -23 A B` が空 | A が空でも合格 | A の非空 |
| `grep -v pattern` が空 | 入力が空でも合格 | 入力の非空 |
| `diff expected actual` が空 | 両方空でも合格 | expected の非空 |
| 「全 N 件が条件を満たす」ループ | N=0 でも合格 | N > 0 |
| `find ... -exec check` の全件 pass | find が 0 件でも合格 | find の件数 |

### テストで固定する

この非空ガード自体も空振りしうるため、**抽出を意図的に 0 件にする fixture** でガードが発火することを確認する。

```bash
# emit 行を 1 つも含まない fixture を渡し、rc=2 になることを assert
printf '# no emit lines here\n' > "$SANDBOX/empty-target.md"
assert "抽出 0 件は rc=2 で fail-loud" "2" "$(run --target "$SANDBOX/empty-target.md")"
```

## 関連ページ

- [検出器が「走査できなかった」を「問題なし」に畳むと、ガードが黙って無検査になる](./checker-conflates-unscannable-with-clean.md)
- [全域で成功する resolver への委譲が既存 fail-fast ガードを silent success 化する](./total-resolver-delegation-defeats-fail-fast-gate.md)
- [「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる](../heuristics/exhaustiveness-claims-require-mechanical-inventory.md)

## ソース

- [レビュー結果](../../raw/reviews/20260729T142410Z-pr-2051.md)
- [fix 結果](../../raw/fixes/20260729T144345Z-pr-2051.md)
