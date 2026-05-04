---
title: "PR シリーズ間で stub 残置 markdown formatting を踏襲する"
domain: "patterns"
created: "2026-05-04T05:30:00+00:00"
updated: "2026-05-04T05:30:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260504T051358Z-pr-802-cycle2.md"
tags: []
confidence: medium
---

# PR シリーズ間で stub 残置 markdown formatting を踏襲する

## 概要

PR シリーズで複数 references を順次抽出する場合、最初の PR で確立された stub 残置 markdown formatting (`> **Moved (Issue #N PR M/T)**:` 形式) を新規 reference 抽出時にも踏襲することで、保守者が `git grep` で stub 一覧を機械検索できる traceability を維持する。新規 reference で独自フォーマットを採用すると、PR 番号 trace 不揃いを cosmetic 指摘で再修正することになる。

## 詳細

PR #802 (Issue #773 PR 8/8) cycle 2 で LOW 1 cosmetic 指摘として検出された pattern:

### 適用ルール

1. **stub 残置 formatting の事前確認**: PR シリーズで複数 references を抽出する場合、最初の PR で確立された stub 残置 markdown formatting を git grep で確認し、新規 reference 抽出時にも literal 一致で踏襲する
2. **「Partial Moved」prefix の使い分け**: critical 警告を本体に残す部分残置経路では、`> **Source of Truth**:` よりも `> **Partial Moved (...)**:` + `critical 警告は本体に維持` の組み合わせがより明示的。完全移管 (Full Moved) と部分残置 (Partial Moved) の semantic 区別が読者に伝わる

### Stub formatting の例

完全移管 (Full Moved):

```markdown
> **Moved (Issue #773 PR 7/8)**: 本セクションは `references/contract-section-mapping.md` に完全移管されました。
```

部分残置 (Partial Moved):

```markdown
> **Partial Moved (Issue #773 PR 8/8)**: 本セクションの bash literal は `references/bulk-create-pattern.md` に移管されました。critical 警告 (single-Bash-invocation requirement / silent-skip risk) は AC-1 enforcement のため本体に維持しています。
```

### 検証方法

- `git grep '> \*\*Moved' plugins/rite/commands/issue/` で stub 一覧を機械検索
- PR レビューで cosmetic 指摘が出る前に、自分の PR に追加した stub formatting が既存 PR と literal 一致するかを目視確認

## 関連ページ

- （関連ページなし）

## ソース

- [PR #802 cycle 2 cosmetic fix](../../raw/fixes/20260504T051358Z-pr-802-cycle2.md)
