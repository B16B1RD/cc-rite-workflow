# Interview Perspectives Template

This template defines the 6 interview perspectives used by Phase 0.5 (Deep-Dive Interview) in `create-interview.md`.

## Perspective Scope Table

| Perspective | Included in Scope |
|-------------|-------------------|
| 1. Technical Implementation | S, M, L, XL |
| 2. User Experience / Interface | M, L, XL, Documentation |
| 3. Edge Cases and Boundary Conditions | S, M, L, XL |
| 4. Consistency with Existing Features | M, L, XL, Documentation |
| 5. Non-Functional Requirements | L, XL (or user-initiated) |
| 6. Tradeoff Decisions | L, XL, Documentation (or user-initiated) |

For perspectives within scope, the "confirmation conditions" for each perspective are used for question priority, but **do not skip based on AI judgment alone; confirm with the user**. Only skip when the user explicitly states "that perspective is not needed".

### 1. Technical Implementation Details

**Includes ambiguity detection**: This perspective also covers detection and resolution of ambiguous expressions in user input (e.g., "Improve ~", "Fix ~" without specific details, "Some", "A few" with unspecified quantities, "Such as", "Like" with unclear scope). When ambiguity is detected, ask clarifying questions before proceeding to implementation options.

**Confirmation condition**: When there are multiple implementation options and the choice significantly affects implementation

```
質問: {機能} の実装アプローチはどちらを想定していますか？

オプション:
- {アプローチA}: {メリット/特徴}
- {アプローチB}: {メリット/特徴}
- 要件を説明するので提案してほしい
- まだ決めていない
```

Examples:
- Data persistence: local storage vs server-side
- State management: Context vs Redux vs Zustand
- API design: REST vs GraphQL
- Authentication method: JWT vs session vs OAuth

### 2. User Experience / Interface

**Confirmation condition**: When the change involves UI/UX and there are multiple options for display methods or operation flows

```
質問: {機能} のユーザー体験について、重視するポイントは？

オプション:
- シンプルさ優先（最小限の操作で完了）
- 柔軟性優先（カスタマイズ可能）
- 既存UIとの一貫性優先
- 特定の参考UIがある
```

Specific items to confirm:
- How to communicate errors to users
- How to display loading states
- Need for undo functionality
- Accessibility requirements

### 3. Edge Cases and Boundary Conditions

**Confirmation condition**: When there are abnormal cases or boundary values in input data or state, and their handling affects implementation

```
質問: 以下のケースへの対応は必要ですか？

オプション:
- {エッジケース1}: 対応必要
- {エッジケース2}: 対応必要
- すべて対応不要（正常系のみ）
- 判断を任せる
```

Examples:
- Handling of empty data / null / undefined
- Processing large volumes of data (1000+ items)
- Behavior when network is disconnected
- Concurrent editing / race conditions
- Behavior when permissions are lacking

### 4. Consistency with Existing Features

**Confirmation condition**: When the change may affect existing features and consistency verification is needed

```
質問: この変更に関連して、既存の {関連機能} への影響は考慮しますか？

オプション:
- 影響を考慮し、必要なら修正する
- 今回のスコープ外（別 Issue で対応）
- 影響はないと想定
- 調査してから判断したい
```

### 5. Non-Functional Requirements

**Confirmation condition**: When the feature involves important non-functional requirements such as performance, security, and scalability

```
質問: この機能で特に重視する非機能要件は？

オプション:
- パフォーマンス（応答速度、処理効率）
- セキュリティ（認証、認可、データ保護）
- スケーラビリティ（将来の拡張性）
- 特に制約なし
```

**Note**: This question allows multiple selections. Use the `multiSelect: true` option of the `AskUserQuestion` tool.

### 6. Tradeoff Decisions

**Confirmation condition**: When there are conflicting requirements and the implementation approach changes depending on which is prioritized

```
質問: {トレードオフA} と {トレードオフB} が相反する場合、どちらを優先しますか？

オプション:
- {A} を優先: {理由/影響}
- {B} を優先: {理由/影響}
- バランスを取る（具体的に相談）
- ケースバイケースで判断
```

Examples:
- Implementation speed vs code quality
- Feature completeness vs release timing
- Generality vs optimization for specific use cases
