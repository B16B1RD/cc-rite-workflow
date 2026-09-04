---
title: "Silent guard contract — pre-condition guard は pass() を呼ばずに silent return する"
domain: "patterns"
description: "`assert_file_exists_or_fail` のような **pre-condition guard 系 helper** は、成功時に `pass()` を呼ばずに silent return (rc=0) する契約を持つべきである。"
promote: rite-plugin
created: "2026-05-19T11:50:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260519T023807Z-pr-1052.md"
tags: ["bash", "test-helpers", "precondition-guard", "assertion-semantics", "pass-counter"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-19T11:50:00+09:00" }
---

# Silent guard contract — pre-condition guard は pass() を呼ばずに silent return する

## 概要

`assert_file_exists_or_fail` のような **pre-condition guard 系 helper** は、成功時に `pass()` を呼ばずに silent return (rc=0) する契約を持つべきである。失敗時のみ `fail()` で 1 件記録 + diagnostic を出す。これにより guard が保護する後続 assertion (`assert_grep` 等) の PASS カウントを不要に膨張させず、test summary の数値整合性を保てる。`pass()` を呼んでしまうと「helper 1 件 = pass +1、assert 2 件 = pass +2」となり、本来の assertion 件数を反映しない不正な PASS が累積する。

## 詳細

### Pre-condition guard と assertion のセマンティクス差

| 種別 | 成功時の挙動 | 失敗時の挙動 | カウンタ影響 |
|------|------------|------------|-------------|
| **Assertion** (`assert_grep` 等) | `pass()` を呼んで PASS+1 | `fail()` を呼んで FAIL+1 | 1 helper 呼び出し = 1 件カウント |
| **Pre-condition guard** (`assert_file_exists_or_fail` 等) | **silent return (rc=0)**、カウンタ不変 | `fail()` を呼んで FAIL+1、rc=1 | 成功時はカウンタ影響なし |

guard は「後続 assertion を意味あるものにする前提条件」を確認する補助手段であり、それ自体は test の主張ではない。したがって成功時に PASS を加算するとカウンタが本来の assertion 件数と乖離する。

### canonical 実装 pattern

```bash
# Pre-condition guard for assertion pairs on the same file
# Returns 0 if file exists (caller proceeds — silent), non-zero if absent
# (caller skips subsequent assertions via `continue`)
assert_file_exists_or_fail() {
  local label="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    fail "$label (file not found: $file)"
    return 1
  fi
  return 0  # ← silent: pass() を呼ばない
}

# Caller pattern:
for r in api code-quality database ...; do
  f="$REVIEWERS_DIR/$r.md"
  assert_file_exists_or_fail "$r.md" "$f" || continue
  assert_grep "$r.md: 5-column header" "$f" 'pattern1'
  assert_not_grep "$r.md: 4-column drift" "$f" 'pattern2'
done
```

### Silent contract を test で構造的に pin する

guard が将来 positive assertion に退行する変更 (例: 誰かが「成功時も pass で記録した方が watchable」と判断して `pass()` を追加してしまう) を構造的に検出するには、helper の self-test で **`PASS=0 FAIL=0 RC=0`** を明示的にチェックする:

| TC | 状況 | 期待カウンタ |
|----|------|------------|
| TC-13.1 | file 存在時 | `PASS=0 FAIL=0 RC=0` (silent guard contract) |
| TC-13.2 | file 不在時 | `FAIL=1 RC=1` + `file not found` diagnostic |

TC-13.1 で `PASS=0` を pin することで、`pass()` が誤って追加された瞬間に test が `PASS=1` を観測して fail に変わり、silent contract への退行が確実に検出される。これは [[mutation-testing-test-fidelity]] の「実装を mutate すると確実に FAIL する identification power」を test 設計時に組み込む応用例。

### caller migration 時の history-preserving comment

inline guard を helper 呼び出しに置換する際、過去 Issue の経緯コメントを保持しつつ helper 化したことを表記する:

```bash
# missing-file inflation guard → helper 化
assert_file_exists_or_fail "$r.md" "$f" || continue
```

これにより helper 名だけでは見えない caller-side の migration 経路 (なぜ inline ではなく helper 経由か) が後続改修者に伝わる。

### excluded-with-rationale checkmark pattern

受入条件 checklist の「他テストへの横展開」項目を `[x]` でマークしつつ「該当しない理由」を本文 / PR description で明示する形態（運用例）:

> - [x] 他テスト (T-2/T-3/T-4 / sentinel-visibility-rule.test.sh 等) で同様 inflation が起きうるパターンがあれば、それも新ヘルパーに統一 — 調査の結果、T-2/T-3/T-4 は単一固定ファイル (`_reviewer-base.md` / `severity-levels.md`) への assertion で loop iteration を持たないため inflation 構造に該当しない。

これは「Issue 本文の `現状 T-2/T-3/T-4 は構造的に inflation を起こさない` 記述と整合し、本 PR では追加対応なし」と PR description で再宣言する形で構造的に閉塞する。reviewer は checkbox の `[x]` だけでなく該当しない rationale を読むことで、scope の正しさを評価できる。

## 関連ページ

- [loop 内の独立 assert は missing file で fail message が assertion 数倍に膨張する](../anti-patterns/loop-independent-assert-missing-file-inflation.md)

## ソース

- [0 findings、Silent guard contract / Excluded-with-rationale の経験則記録](../../raw/reviews/20260519T023807Z-pr-1052.md)
