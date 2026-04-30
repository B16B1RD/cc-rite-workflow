# Phase Mapping Reference

Mapping information for phase details. Used in work memory session information.

## Phase Detail Mapping

| Phase | Phase Detail |
|-------|-------------|
| `phase0` | Epic/Sub-Issues 判定 |
| `phase1` | 品質検証 |
| `phase2` | ブランチ作成・準備 |
| `phase3` | 実装計画生成 |
| `phase4` | 作業開始準備 |
| `phase5_implementation` | 実装作業中 |
| `phase5_lint` | 品質チェック中 |
| `phase5_post_lint` | チェックリスト確認中 |
| `phase5_pr` | PR 作成中 |
| `phase5_review` | レビュー中 |
| `phase5_post_review` | レビュー後処理 |
| `phase5_fix` | レビュー修正中 |
| `phase5_post_fix` | レビュー修正後処理 |
| `completed` | 完了 |

## Phase 5 Sub-phase Transitions

Phase 5 transitions in the following order (with review-fix loop):

```text
phase5_implementation → phase5_lint → phase5_post_lint → phase5_pr → phase5_review
                                                                           ↓
                                                                     phase5_post_review
                                                                           ↓
                                                                     [Issues found?]
                                                                      Yes ↓ No → completed
                                                                     phase5_fix
                                                                           ↓
                                                                     phase5_post_fix
                                                                           ↓
                                                                     phase5_review (re-review)
```

- `phase5_review`, `phase5_post_review`, `phase5_fix`, and `phase5_post_fix` loop until all issues are resolved
- `phase5_post_review` updates flow state after review completion (defense-in-depth, #719)
- `phase5_post_fix` updates flow state after fix completion (defense-in-depth)
- Transitions to `completed` when all issues are resolved

## Usage Example

Work memory session information section:

```markdown
### セッション情報
- **開始**: 2026-01-29T12:00:00+09:00
- **ブランチ**: feat/issue-123-feature-name
- **最終更新**: 2026-01-29T14:30:00+09:00
- **コマンド**: rite:issue:start
- **フェーズ**: phase5_implementation
- **フェーズ詳細**: 実装作業中
```

## Related

- [Session Detection](./session-detection.md) - Auto-detection at session start
- [Work Memory Format](./work-memory-format.md) - Work memory format
