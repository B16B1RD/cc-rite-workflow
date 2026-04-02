# Common Principles Reference

A collection of common principles to reduce excessive AskUserQuestion usage and improve workflow efficiency.

## Purpose

Claude Code usage reports have shown numerous AskUserQuestion calls.
Reducing unnecessary questions in automated workflows improves workflow efficiency.

## Principle List

| Principle ID | Principle Name | When to Apply |
|-------------|---------------|---------------|
| `question_self_check` | Self-Check Before Asking | All phases |
| `default_value_usage` | Use Default Values | Configuration lookup |
| `context_inference` | Infer from Context | All phases |

---

## Principle Details

### question_self_check (Self-Check Before Asking)

**Summary**: Self-check whether the question is truly necessary before asking.

**Failure Patterns**:
- Asking obvious questions (Yes/No with immediate answer, uniquely determined)
- Asking questions already answered in the user's request
- Asking about things obviously derivable from project context
- Asking either/or questions where "both" is clearly the answer

**Rules**:

Check the following before asking any question:

1. Is the answer already contained in the user's request?
2. Can it be obviously derived from the project's nature?
3. Is it uniquely determined by general best practices?
4. Do multiple options truly exist with real trade-offs?

**Prohibited Question Patterns**:
- Yes/No questions that are obvious and immediately answerable
- Questions already answered in the user's request text
- Questions obvious if the project's nature is understood
- Either/or questions where "both" is clearly the answer
- Scope confirmation questions where "apply to all" is clearly the answer

**Allowed Question Patterns**:
- When multiple options exist with genuine trade-offs for each
- When user intent is genuinely ambiguous and misunderstanding would require redoing >30 minutes of work or rewriting >50 lines of code
- Important confirmations related to security or destructive changes

**Prohibited Examples**:
```text
❌ 「この対処方法として、どのアプローチを想定していますか？」
   → プロジェクトの性質を理解すれば自明

❌ 「skill 定義への原則追加と、チェック機構の追加、どちらを優先しますか？」
   → 「両方やるべき」または依頼内容から自明

❌ 「原則を追加する skill の範囲はどこまでですか？」
   → 「全体に適用すべき」が明らか
```

**Allowed Examples**:
```text
✅ 「認証方式として JWT と Session のどちらを使用しますか？
     - JWT: ステートレス、スケーラブル、トークン管理が必要
     - Session: シンプル、サーバー側状態管理、セッションストア必要」
   → 明確なトレードオフがある

✅ 「このリファクタリングは破壊的変更を含みます。
     既存の API 利用者への影響を許容しますか？」
   → セキュリティ/破壊的変更に関わる重要な確認
```

---

### default_value_usage (Use Default Values)

**Summary**: When clear defaults exist, apply them without confirmation.

**Failure Patterns**:
- Asking for confirmation when default values are already set
- Not checking config files before asking
- Asking every time when common conventions exist

**Rules**:

1. Prioritize defaults configured in `rite-config.yml`
2. Check config files before considering a question
3. Apply defaults without confirmation when they are clear

**Default Value Lookup**:

Defaults are determined in 2 tiers:
1. **Project config** (`rite-config.yml`): Takes priority
2. **Template defaults**: Fallback when project config is missing

| Item | Project Config | Fallback Value |
|------|---------------|----------------|
| Base branch | `rite-config.yml` `branch.base` | `main` |
| Priority | `rite-config.yml` `github.projects.fields.priority` | `Medium` |
| Complexity | `rite-config.yml` `github.projects.fields.complexity` | `M` |
| Decomposition threshold | `rite-config.yml` `issue.auto_decompose_threshold` | `M` |
| Language setting | `rite-config.yml` `language` | `auto` |

**Note**: Fallback values are only used when `rite-config.yml` does not exist or when a specific item is not configured.

**Prohibited Examples**:
```text
❌ 「どのブランチから作成しますか？」
   → rite-config.yml の branch.base を参照

❌ 「Priority はどれにしますか？」
   → デフォルト Medium を適用
```

**Allowed Examples**:
```text
✅ 「rite-config.yml に branch.base が設定されていません。
     どのブランチをベースにしますか？」
   → 設定がない場合のみ確認

✅ 「この Issue は Priority High と明記されています。
     通常より優先度を上げて設定しますか？」
   → Issue 本文に明示的な指定がある場合の確認
```

---

### context_inference (Infer from Context)

**Summary**: Do not ask about things that can be inferred from context.

**Failure Patterns**:
- Asking when the answer is in conversation history
- Asking about information obvious from the branch name
- Asking about things readable from the Issue body
- Asking about things obvious from the previous operation

**Rules**:

1. Check conversation history before considering a question
2. Extract Issue number and type from branch name
3. Understand requirements/specs from Issue body
4. Infer next action from the previous operation result

**Information Sources**:

| Information | Source | Example |
|-------------|--------|---------|
| Issue number | Branch name `{type}/issue-{number}-*` | `feat/issue-123-add-login` → `123` |
| Change type | Branch name prefix | `fix/` → Bug fix |
| Requirements | Issue body `## 概要` section | Extract requirement details |
| Change targets | Issue body `## 変更内容` section | Extract target files |
| Complexity | Issue body `## 複雑度` section | Extract `M`, `L`, etc. |
| Parent-child relationship | Issue body Tasklist | Detect `- [ ] #XX` pattern |

**Prohibited Examples**:
```text
❌ 「どの Issue に対する作業ですか？」
   → ブランチ名から抽出可能

❌ 「この変更はバグ修正ですか、新機能ですか？」
   → ブランチ名 prefix から判断可能

❌ 「変更対象のファイルはどれですか？」
   → Issue 本文に記載されている場合は抽出
```

**Allowed Examples**:
```text
✅ 「ブランチ名に Issue 番号が含まれていません。
     どの Issue に関連する作業ですか？」
   → パターンにマッチしない場合のみ確認

✅ 「Issue 本文に変更対象が明記されていません。
     どのファイルを変更しますか？」
   → Issue 本文から抽出できない場合のみ確認
```

---

## Checklist

Check the following before asking any question:

- [ ] **question_self_check**: Is this question truly necessary? Is it not obvious?
- [ ] **default_value_usage**: Is there a default value in `rite-config.yml`?
- [ ] **context_inference**: Can it be inferred from conversation history, branch name, or Issue body?

---

## Related

- [SKILL.md](../SKILL.md) - Common principles summary (references this file)
- [coding-principles.md](./coding-principles.md) - AI coding principles (`question_self_check` holds a reference to this file)
- Related Issues: #401 (fix asking obvious questions), #404 (create common principles file)

**Reference Relationships**:
- Detailed definition of `question_self_check` principle: **This file** (`common-principles.md`)
- `question_self_check` section in `coding-principles.md`: Reference only to this file
