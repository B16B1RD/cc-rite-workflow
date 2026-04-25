---
title: "bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す"
domain: "patterns"
created: "2026-04-25T11:40:00+00:00"
updated: "2026-04-25T11:40:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260425T081422Z-pr-659-cycle2.md"
tags: ["bash", "case-statement", "silent-fall-through", "defensive-programming", "fail-loud"]
confidence: high
---

# bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す

## 概要

bash の case 文で routing する文字列変数 (例: `status_update_result`) の初期値が allowed values 列挙 (例: `success` / `not_registered` / `update_failed` / `projects_disabled`) 外の sentinel 値 (例: `skipped`) だと、case 文に対応 arm がない場合に silent fall-through する経路を生む。初期値は allowed values 内のいずれかに safe-side semantics を持つ値で設定するか、`*:initial)` のような fail-loud sentinel arm を case 文に追加することで silent fall-through を防ぐのが canonical。

## 詳細

### 発生条件

以下のすべてを満たす経路で発生する:

1. **case 文で routing する文字列変数** が存在する (`case "$var" in arm1) ... arm2) ... esac`)
2. **その変数の初期値が case 文の任意の arm にも match しない sentinel 値**で初期化されている (例: `var="initial"` で case 文に `initial)` arm が無い)
3. **`*)` catch-all arm が存在しない、または catch-all 内で no-op になっている**
4. **早期 exit / continue / 条件分岐 skip 経路** が変数を上書きせずに case 文に到達する経路を持つ

### PR #659 cycle 2 での実測事例

`commands/issue/close.md` Phase 4.6.3 で:

```bash
# 旧実装 (silent fall-through risk)
status_update_result="skipped"   # 初期値 (allowed values 外の sentinel)
# allowed values コメント: success / not_registered / update_failed / projects_disabled

if [ "$projects_enabled" = "true" ]; then
  # ... script delegate 呼び出し ...
  case "$status_result" in
    updated)              status_update_result="success" ;;
    skipped_not_in_project) status_update_result="not_registered" ;;
    failed|*)             status_update_result="update_failed" ;;
  esac
else
  status_update_result="projects_disabled"
fi

# 後続の Step 3 inconsistency summary
case "${issue_close_result}:${status_update_result}" in
  "success:success"|"success:projects_disabled"|"success:not_registered") ... ;;
  "success:update_failed") ... ;;
  "failed:success") ... ;;
  "failed:projects_disabled") ... ;;
  "failed:not_registered") ... ;;
  "failed:"*) ... ;;
  # ⚠️ "*:skipped" 行が無いため、status_update_result="skipped" のまま到達すると silent fall-through
esac
```

将来「early-exit 経路で `status_update_result` を上書きせずに inconsistency summary に到達する」変更が加わると、初期値 `"skipped"` のまま case 文に到達して silent fall-through する。reviewer (cycle 2 HIGH F-02) が指摘し、cycle 2 fix で初期値を `"projects_disabled"` (allowed values 内の safe-side default = success:projects_disabled が「整合性 OK」判定) に変更した。

### Canonical 対策

#### 対策 1: 初期値を allowed values 内に設定する (recommended)

allowed values 列挙のうち「safe-side semantics を持つ値」を初期値に採用する:

```bash
# Recommended: 初期値を allowed values の中から safe-side default で選ぶ
status_update_result="projects_disabled"   # success:projects_disabled = 整合性 OK 判定
```

選択基準: case 文の inconsistency summary で「初期値 × 他変数の組み合わせ」が legitimate な状態 (整合性 OK / non-error path) として handle される値を選ぶ。

#### 対策 2: fail-loud sentinel arm を case 文に追加する

allowed values 列挙の事情 (semantics の都合で sentinel 値が必要) で初期値を allowed values 外にせざるを得ない場合、case 文に `*:initial)` のような fail-loud arm を追加して silent fall-through を防ぐ:

```bash
status_update_result="initial"   # sentinel value (allowed values 外)

case "${issue_close_result}:${status_update_result}" in
  "success:success") ... ;;
  # ... 他の legitimate combinations ...
  *:initial)
    echo "[BUG] status_update_result が初期値 'initial' のまま到達しました — case 文の上流で必ず上書きされるべき経路" >&2
    exit 1
    ;;
esac
```

`*:initial)` arm が hit したら exit 1 で fail-loud するため、silent fall-through 経路が pipeline test / staging environment で確実に detect される。

### Detection Heuristic

bash code review 時に以下を grep で機械検証する:

```bash
# 1. allowed values コメントを抽出
grep -E '^\s*#.*allowed values?:' file.sh

# 2. 変数の初期値を確認
grep -E '^\s*<varname>=' file.sh

# 3. case 文の arm を列挙
sed -n '/case "$<varname>" in/,/esac/p' file.sh | grep -E '^\s*[a-zA-Z_]'

# 4. 初期値が allowed values または case arm のいずれかに含まれるかを目視確認
```

### 関連 anti-pattern

silent fall-through 系の bash defensive programming gap は、本 pattern と以下の sibling pattern が共通の root cause を持つ:

- `failed|*)` wildcard collapse (将来の `.result` 値追加時の silent miscategorization 防止) — `*)` catch-all で fail-loud に倒す
- bash case 文の `*)` 欠落 (`failed)` のみで catch-all なし) — defensive shape の `failed|*)` 統合

これらは「bash case 文の defensive shape」という共通カテゴリで、PR ごとに発見・修正されるたびに sibling site で同種の drift が surface する累積対策の対象。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)
- [LLM substitute placeholder は bash residue gate で fail-fast 化する](./placeholder-residue-gate-bash-fail-fast.md)

## ソース

- [PR #659 cycle 2 review (initial value silent fall-through risk、HIGH 1 件)](raw/reviews/20260425T081422Z-pr-659-cycle2.md)
