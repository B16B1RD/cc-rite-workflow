---
title: "兄弟 shell script の重複 helper は shared lib 抽出で解く"
domain: "heuristics"
promote: rite-plugin
created: "2026-04-16T19:37:16Z"
updated: "2026-07-20T10:36:25+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260720T013625Z-pr-1921.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T092207Z-pr-544.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T180658Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T091926Z-pr-544.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T180001Z-pr-548.md"
tags: ["dry", "shared-lib", "refactor", "duplication"]
confidence: medium
---

# 兄弟 shell script の重複 helper は shared lib 抽出で解く

## 概要

`parse_wiki_scalar()` や worktree fast path のような同型 helper 関数を、兄弟 shell script (`wiki-ingest-commit.sh` / `wiki-worktree-commit.sh` / `wiki-worktree-setup.sh`) に個別コピーで実装すると drift リスクが増大する。個別 fix の繰り返しでは根本解決にならず、共通 helper として抽出して source する方針が必要。

## 詳細

### 複数ファイル対称修正の限界

起点事例では `parse_wiki_scalar` が 3 shell scripts に complete-match duplicate。cycle 4 review で発見されたが、scope を 1 PR で全面 refactor するには substantial すぎるため別 Issue として分離した。

この「fix 採用タイミングを scope で分ける」判断は以下の基準で行う:

| 状況 | 対応 |
|------|------|
| 同 commit / 類似 pattern の小規模 duplication（3-5 行、2-3 ファイル） | 本 PR で inline 対称修正 + 対称性を契約として doc 化 |
| 別 lib 抽出が必要な大規模 duplication（関数単位、3+ ファイル、テスト必要） | 別 Issue で refactor 分離 |

### DRY refactoring の canonical path

先行 DRY fix 事例で実施された pattern:

```bash
# Before: 3 箇所で同じ git ls-tree を呼ぶ
check_a() { git ls-tree -r "$ref" ...; }
check_b() { git ls-tree -r "$ref" ...; }
check_c() { git ls-tree -r "$ref" ...; }

# After: scope 内で 1 回 fetch、helper は結果を受け取る
check_page_stall() {
  local ls_tree_result
  ls_tree_result=$(git ls-tree -r "$ref" ...)
  _count_lines "$ls_tree_result"
  _count_pending_from_list "$ls_tree_result"
}
_count_lines() { wc -l <<<"$1"; }
_count_pending_from_list() { grep 'ingested: false' <<<"$1" | wc -l; }
```

helper を pre-fetched 結果を引数として受ける形に変えると、複数呼び出しを 1 fetch に集約できる。

### Asymmetric Fix Transcription との関係

shared lib 抽出前の状態では `parse_wiki_scalar` のような helper が drift しやすい。reviewer は cycle ごとに「3 ファイルで同 pattern が一致しているか」を手動検証する負担がかかる。shared lib 抽出すれば:

- 1 箇所の修正で自動的に全 caller に反映
- 非対称が発生する余地がない
- reviewer の認知負荷低減

本パターンは [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の根本解決策として位置付けられる。

### Cross-script duplication の検出

```bash
# 同じ関数定義が複数ファイルに存在するか
grep -rn 'parse_wiki_scalar()' plugins/rite/hooks/scripts/
```

一致する定義が 2+ ファイルにあれば shared lib 候補。`source` で取り込む共通ファイル（例: `plugins/rite/hooks/scripts/_lib.sh`）に集約する。

### Owner/repo 解決 helper の重複

SSH host alias 対応 PR の review で、 owner/repo 解決パターン (`git-remote.sh resolve-owner-repo` 優先 → `gh repo view` fallback → 両失敗で degrade + WARNING) を実装する `get_owner_repo()` 型 helper が、リポジトリ内 6 ファイルに重複実装されていることが指摘された。本 PR では sibling hook (`issue-comment-wm-sync.sh`) の既存実装を忠実に踏襲する対称修正を選択し、共通化は別 Issue 候補として scope 外化した — 本ページの「同 commit / 類似 pattern の小規模 duplication は本 PR で inline 対称修正」基準に一致する判断。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1921 review results (cycle 2) — get_owner_repo 型 helper が 6 ファイルに重複、共通化は別 Issue 候補として scope 外化](../../raw/reviews/20260720T013625Z-pr-1921.md)
- [PR #544 fix (git ls-tree duplication の DRY 解消)](../../raw/fixes/20260416T092207Z-pr-544.md)
- [PR #548 cycle 4 fix (shared lib 抽出は Issue #549 で分離)](../../raw/fixes/20260416T180658Z-pr-548.md)
- [PR #544 review (DRY violation 検出)](../../raw/reviews/20260416T091926Z-pr-544.md)
- [PR #548 cycle 4 review (cross-script duplication 検出)](../../raw/reviews/20260416T180001Z-pr-548.md)
