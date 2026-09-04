---
title: "bash control-flow integrity: continue/break/return は enclosing 構文を bash literal 内に明示する"
domain: "anti-patterns"
description: "bash literal block (`.md` ファイル内に埋め込まれた bash skeleton) 内で `continue` / `break` / `return` を使用する場合、enclosing 構文 (`for` / `while` / `until` loop または function 定義) を**同じ bash literal 内**に明示的に含める必要がある。"
promote: rite-plugin
created: "2026-05-26T13:30:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260526T121902Z-pr-1149-cycle6.md"
  - type: "fixes"
    resource: "raw/fixes/20260526T125406Z-pr-1149-cycle6.md"
  - type: "reviews"
    resource: "raw/reviews/20260526T105538Z-pr-1149-cycle2.md"
tags: ["bash", "control-flow", "inline-rewrite", "silent-regression", "cumulative-defense"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-26T13:30:00+00:00" }
---

# bash control-flow integrity: continue/break/return は enclosing 構文を bash literal 内に明示する

## 概要

bash literal block (`.md` ファイル内に埋め込まれた bash skeleton) 内で `continue` / `break` / `return` を使用する場合、enclosing 構文 (`for` / `while` / `until` loop または function 定義) を**同じ bash literal 内**に明示的に含める必要がある。enclosing loop を prose comment「タスクごとに以下を反復実行」のような外部委譲で表現すると、bash 仕様違反 (continue/break outside loop = stderr error + 次行 fall-through、rc=0) を許容する silent regression 経路となる。起点事例の cycle 2 fix で導入された 3 `continue` site が cycle 3-5 reviewer (合計 4 cycle) で見落とされ、cycle 6 で実機 verify (rc=0、3 error path で silent regression) により初検出された。

## 詳細

### Failure mechanism

bash の `continue` / `break` は POSIX 仕様で enclosing loop の存在を要求する。loop なしで実行されると以下が起きる:

1. stderr に `continue: only meaningful in a 'for', 'while', or 'until' loop` (または同等エラー) を emit
2. exit code は **0** で続行 (fatal ではない)
3. 次行に fall-through (意図した「該当 iteration の skip + 次 iteration へ進む」は発生しない)

`.md` ファイル内の bash literal は LLM が「loop 化責務を委ねる」prose comment と組み合わせて記述しがちだが、LLM が bash literal をそのまま `bash` ツールで実行する場合 prose comment は無視され、`continue` が flat に実行されて silent regression となる。

### Detection

- **commit 前 syntax check**: `bash -n <file>` で syntax error にはならない (bash 仕様上は valid syntax)。`bashlint` / `shellcheck` 等の静的解析が必要。`shellcheck` は `SC2104` で warning を emit するが、`.md` 内 bash block を抽出して shellcheck にかける CI gate が無いと検出されない。
- **review 時**: `grep -n '^\s*\(continue\|break\|return\)' <file.md>` で `.md` 内の control flow statement を列挙し、各 hit について **同じ bash code fence (`\`\`\`bash` ... `\`\`\``) 内に enclosing 構文があるか** を verify する。prose comment による「タスクごとに反復」記述だけでは不十分。
- **mutation test**: `continue` を `printf 'should-not-reach\n'` に置換し test fixture を re-run。test が PASS なら該当 code path が dead であり、`continue` が機能していない silent regression として識別される。

### Canonical fix

bash literal 内で iteration が必要だが LLM 側で繰り返し実行する設計の場合、以下のいずれかを採用する:

1. **fail-fast 化**: `continue` を `exit 1` に置換し、各 iteration を独立 invocation で実行する設計に restructure。peer file `commands/issue/create.md` の if/else + fail-fast pattern が canonical（cycle 6 で対称化）。
2. **enclosing 構文の明示**: bash literal 内に `for task in "${tasks[@]}"; do ... done` のような explicit loop を含め、`continue` が legal な context を保証する。
3. **`{REPEAT_FOR_EACH_X}` macro**: LLM への指示として明示的に「以下を各 task について繰り返す」macro 記法を使い、bash literal は単一 iteration の skeleton として記述する。

### Cumulative-defense PR での発火条件

本 anti-pattern は **inline rewrite** (peer file convention を見ずに skeleton を再構築) の文脈で頻発する。起点事例の cycle 2 fix がまさにこの経路:

- cycle 1 fix で「Issue body template + bash skeleton 再 inline」を実施
- pre-PR cleanup.md Phase 1.7.2 の original 安全機構 (`exit 1` fail-fast / mktemp 0-byte ガード / `result=$(...)` rc capture) を**すべて失った状態**で新規 skeleton を組み立て
- `continue` 3 site を新規導入 (cycle 1-2 では未指摘)
- cycle 3-5 reviewer は documentation drift / asymmetric / placeholder-source-deletion に注意 frame が固定化、bash control-flow integrity を独立 axis として scan していなかった
- cycle 6 で reviewer attention frame を拡張し初検出 → 実機 verify で silent regression を実証

### Review axis 化

`dogfooding cycle` (rite で rite を開発) では reviewer 注意 frame の bias により本 class を体系的に見落とす経路がある。review prompt に以下の **5 独立 axis** を明示することで cycle 6-7 で 2 cycle 収束を実現した:

1. documentation drift (literal Phase 番号 / wording 等の表記揺れ)
2. functional regression (caller chain / API 契約等の機能変更)
3. **bash control-flow integrity** (loop / control statement の構造完全性)
4. cross-file symmetry (peer file との convention 対称性)
5. self-referential consistency (fix 自身が新たな drift を生まないか)

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md)

## ソース

- [bash control-flow regression 初検出](../../raw/reviews/20260526T121902Z-pr-1149-cycle6.md)
- [continue → exit 1 fail-fast 置換](../../raw/fixes/20260526T125406Z-pr-1149-cycle6.md)
- [inline rewrite で continue 3 site 新規導入](../../raw/reviews/20260526T105538Z-pr-1149-cycle2.md)
