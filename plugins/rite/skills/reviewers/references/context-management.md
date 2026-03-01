# Context Management Reference

Context management strategy for reviewing large PRs.

## Context Management Strategy

When using long conversations or many reviewers, be aware of context window limitations.

| Situation | Mitigation |
|-----------|------------|
| Many reviewers (3+) | Use Progressive Disclosure; only load necessary skill files |
| Large diff | Pass only relevant file diffs to each reviewer (filter to relevant_files, not the entire diff) |
| Long conversation | Claude Code has context window limits. As a guideline, consider manual splitting for 50+ turns or diffs exceeding 2000 lines |
| Task agent context | Each Task has independent context, so parent conversation length does not affect it |

## Specific Guidelines for Large PRs

| Condition | Recommended Action |
|-----------|-------------------|
| Diff exceeds 500 lines | Include only relevant file diffs in each reviewer's prompt |
| 20+ files changed | Split review execution (when reviewer count is high) |
| 4+ reviewers | Execute in 2 batches (e.g., Security+API, then Test+Frontend) |
| Single file with 1000+ line changes | Prioritize dedicated reviewer for that file |

## Split Execution Steps

When 4+ reviewers are needed:

1. **Group reviewers by relevance**
   - Group 1: Security-related (Security + DevOps)
   - Group 2: Code quality (Test + API)
   - Group 3: Documentation (Prompt Engineer + Tech Writer)

2. **Manually run independent `/rite:pr:review` sessions per group**
   - Record first group's review results in unified report
   - Run next group and merge results into existing report

3. **Generate final unified report**
   - Integrate findings from all groups
   - Apply Cross-Validation across all findings
   - Determine overall assessment

## Notes

Claude Code's auto-summarization feature means context management is usually not a concern for normal PRs (under 500 lines).

## Related

- [Cross-Validation](./cross-validation.md) - Result validation & integration
- [Output Format](./output-format.md) - Unified report format
