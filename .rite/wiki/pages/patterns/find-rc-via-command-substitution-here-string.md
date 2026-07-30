---
title: "rc 観測が必要な find は process substitution でなく command substitution + here-string で呼ぶ"
domain: "patterns"
created: "2026-06-09T04:36:49+00:00"
updated: "2026-06-09T04:36:49+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260609T040553Z-pr-1315.md"
  - type: "fixes"
    ref: "raw/fixes/20260609T041117Z-pr-1315.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T042259Z-pr-1315.md"
tags: ["bash", "process-substitution", "command-substitution", "here-string", "rc-propagation", "find", "cleanup-gc", "sibling-symmetry"]
confidence: high
---

# rc 観測が必要な find は process substitution でなく command substitution + here-string で呼ぶ

## 概要

cleanup/GC スクリプトで `find` の結果をループ処理する際、`while read; do ...; done < <(find ... 2>/dev/null)` の **process substitution** を使うと、`find` 自身の wholesale 失敗 (`$TMPDIR` 不在 / 権限なし / IO エラー) の exit code がシェルに伝播せず、空ループ → 無言 no-op になる。`2>/dev/null` を併用すると stderr も消え完全にサイレント化する。同一スクリプト内の sibling ブロックが `if out=$(cmd); then ...; else rc=$?; WARNING; errors++; fi` で rc を捕捉している場合、新規ブロックだけが process substitution で rc 捕捉を欠くと「失敗を errors カウンタに加算する」確立済み方針への非対称違反になる。`out=$(find ...)` の **command substitution + here-string `<<<`** に揃えると find の rc が観測可能になり sibling 対称性を保てる。

## 詳細

### 失敗パターン（cycle 1, MEDIUM）

`pr-cycle-cleanup.sh` に orphan workdir reaping (Step 3) を追加した際、新規ブロックが process substitution で書かれていた:

```bash
# 非対称: find の wholesale 失敗が silent no-op になる
while IFS= read -r d; do
  rm -rf "$d"; workdirs=$((workdirs + 1))
done < <(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'rite-pr-create-*' -mmin +1440 2>/dev/null)
```

- process substitution `< <(...)` は `find` を独立 subshell で起動するため、find の exit code はシェルに伝播しない
- `2>/dev/null` で stderr も握り潰されるため、`$TMPDIR` 不在 / 権限なし / IO エラーによる wholesale 失敗が空ループ → `workdirs=0` の無言 no-op として表面化しない
- 同スクリプトの sibling ブロック (worktree 走査 / branch 走査) は `if out=$(cmd); then ...; else rc=$?; WARNING; errors++; fi` で rc を捕捉しており、新規ブロックだけが rc 観測を欠く **非対称違反**

error-handling / code-quality reviewer が独立に MEDIUM 検出。

### canonical fix

```bash
# 対称: command substitution で find の rc を観測し sibling と揃える
if found=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'rite-pr-create-*' -mmin +1440 2>"$err"); then
  while IFS= read -r d; do
    [ -z "$d" ] && continue          # 空 stdout 時の here-string 単一空行を skip
    rm -rf "$d"; workdirs=$((workdirs + 1))
  done <<< "$found"
else
  rc=$?; echo "WARNING: find failed (rc=$rc)" >&2; errors=$((errors + 1))
fi
```

- **command substitution `out=$(find ...)`** は find の exit code を直接 `$?` / `if` 条件で観測できる
- **here-string `<<< "$found"`** でループに渡す。空 stdout のときは here-string が単一の空行を生むため、ループ先頭の `[ -z "$d" ] && continue` ガードで skip する (branch 走査ループと同じイディオム)
- sibling ブロックと同じ `rc 捕捉 → WARNING → errors++` の 4 要素を揃える

### failure path のテスト

`$TMPDIR` を不在パスに向けて wholesale 失敗を誘発できる。script の `mktemp` が `/tmp` 直書きなら `TMPDIR` override の影響を受けないため、テストの隔離と failure 注入を両立できる。

### sibling 4 ブロック対称性の verify（cycle 2）

cycle 2 のフルレビューは 0 findings / mergeable。fix が新規 regression を持ち込んでいないことを 6 reviewer 全員が確認した。fix-introduced finding を防ぐには、修正が既存 sibling パターンと **対称か** — すなわち `rc 捕捉` / `WARNING` / `errors++` の各要素が sibling ブロックと一致するか — を verify するのが有効。(test reviewer は per-item 失敗分岐の coverage gap を follow-up として別 Issue に切り出し。)

### process substitution が常に悪いわけではない (重要な区別)

本ページは [`mapfile -t < <(...)` で pipefail safe な iteration を書く](./mapfile-process-substitution-pipefail-safe.md) と **矛盾しない**。両者は同じ `< <(...)` 構文を扱うが、判断軸が異なる:

| コマンドの非ゼロ exit の性質 | canonical |
|------|----------|
| 期待される良性の非ゼロ (grep no-match = 0 件正常) を **吸収** したい | process substitution + `mapfile` (rc を伝播させないのが目的) |
| wholesale 失敗 (find の IO エラー等) を **観測** して errors++ / WARNING したい | command substitution + here-string (rc 観測が目的) |

つまり「非ゼロ exit を吸収すべきか観測すべきか」が分岐点。sibling ブロックが rc を捕捉して errors カウンタに加算している文脈では後者を選ぶ。

## 関連ページ

- [`mapfile -t < <(...)` で pipefail safe な iteration を書く](./mapfile-process-substitution-pipefail-safe.md)
- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #1315 review results](../../raw/reviews/20260609T040553Z-pr-1315.md)
- [PR #1315 fix results](../../raw/fixes/20260609T041117Z-pr-1315.md)
- [PR #1315 review results (cycle 2)](../../raw/reviews/20260609T042259Z-pr-1315.md)
