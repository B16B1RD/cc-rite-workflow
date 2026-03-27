---
name: investigate
description: |
  コード調査（/investigate）を実行するスキル。grep でコード構造の場所を特定し、
  Read で実際の内容を検証し、Codex（オプション）でクロスチェックする3段階プロセスで、
  推測による誤報告を防ぐ。関数呼び出し、ハッシュ、条件式、メソッドチェーン等の
  コード構造全般を対象とする。
  「調査」「investigate」「コード調査」「grep で調べて」「呼び出し箇所」「使われ方」
  「一覧」「全件」「どこで使われている」で発動する。
---

# Investigate Skill

ソースコードを正確に調査し、検証済みの結果を報告するスキル。

## Auto-Activation Keywords

- 調査, investigate, コード調査
- grep で調べて, 呼び出し箇所, 使われ方
- 一覧, 全件, どこで使われている
- 引数, パラメータ, 設定値
- コード構造, パターン検索

## Context

When activated, this skill provides:

1. **Structured Investigation Process**
   - Phase 1: Scope clarification
   - Phase 2: Search (Grep)
   - Phase 3: Verification (Read)
   - Phase 4: Dynamic pattern tracking
   - Phase 5: Result aggregation
   - Phase 6: Cross-check (Codex or alternative)
   - Phase 7: Final report

2. **Code Structure Coverage**
   - Function calls and arguments
   - Hash/dictionary structures
   - Conditional expressions and branches
   - Method chains
   - Class/module definitions
   - Configuration values

3. **Verification Guarantees**
   - Every grep hit is verified by Read
   - Completeness check (grep hit count = Read verification count)
   - Cross-check via Codex MCP or Claude self-verification
   - No guessing — unverified values reported as "unverified"

## Configuration

Reads `investigate` section from `rite-config.yml`:

```yaml
investigate:
  codex_review:
    enabled: true    # false で Phase 6 の Codex クロスチェックをスキップ
```

When `codex_review.enabled` is `false` or Codex MCP is unavailable, Claude performs self-verification as an alternative (Phase 6b).
