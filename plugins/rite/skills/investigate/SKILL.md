---
name: investigate
description: |
  Investigate code structures (/investigate) using a 3-phase process: Grep to locate,
  Read to verify, and Codex (optional) to cross-check. Prevents false reports from
  guessing. Covers all code structures: function calls, hashes, conditionals,
  method chains, class definitions, and configuration values.
  Activates on "調査", "investigate", "コード調査", "grep で調べて", "呼び出し箇所",
  "使われ方", "一覧", "全件", "どこで使われている".
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
    enabled: true    # Set false to skip Codex cross-check in Phase 6
```

When `codex_review.enabled` is `false` or Codex MCP is unavailable, Claude performs self-verification as an alternative (Phase 6b: 代替検証).

## Command

Full investigation procedure: [commands/investigate.md](../../commands/investigate.md)

Lightweight protocol for use in other phases: [references/investigation-protocol.md](../../references/investigation-protocol.md)
