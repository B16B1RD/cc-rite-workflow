# Migration Guide: Named Subagent Switch for `/rite:pr:review`

**Target version**: rite workflow plugin ≥ 0.x.y (Phase B merge)
**Affected command**: `/rite:pr:review`
**Change classification**: **Breaking Change** (user-facing behavior, reviewer invocation mechanism)
**Issue**: [#358](https://github.com/B16B1RD/cc-rite-workflow/issues/358) (parent: [#355](https://github.com/B16B1RD/cc-rite-workflow/issues/355))

---

## 1. What changed

Prior to this change, `/rite:pr:review` invoked all reviewer agents via `subagent_type: general-purpose`. The reviewer identity (agent body from `plugins/rite/agents/*-reviewer.md`) was extracted and injected into the **user prompt** as a placeholder (`{agent_identity}`). Since `general-purpose` ignores the target agent file's YAML frontmatter (`model`, `tools`), the reviewer identity had no enforcement at the runtime level — it was just text the LLM might or might not follow.

After this change, reviewers are invoked via the scoped named form:

```
subagent_type: "rite:{reviewer_type}-reviewer"
```

Examples:

| Before | After |
|--------|-------|
| `subagent_type: general-purpose` (identity via `{agent_identity}` in user prompt) | `subagent_type: rite:security-reviewer` |
| `subagent_type: general-purpose` | `subagent_type: rite:code-quality-reviewer` |
| `subagent_type: general-purpose` | `subagent_type: rite:tech-writer-reviewer` |

Under named subagent invocation, the **agent file body** (`plugins/rite/agents/{reviewer_type}-reviewer.md`) becomes the sub-agent's **system prompt** automatically. The YAML frontmatter (`model`, `tools`) is honored by the runtime. Reviewer discipline now has the same enforcement level as any other named sub-agent in Claude Code.

### Hybrid approach for shared principles

`plugins/rite/agents/_reviewer-base.md` contains **shared reviewer principles** (Reviewer Mindset, Cross-File Impact Check, Confidence Scoring) that apply to every reviewer. These are **not** automatically injected into named subagents, because `_reviewer-base.md` is a reference file — not a named sub-agent.

To preserve the Cross-File Impact Check (added as a Phase A / [#357](https://github.com/B16B1RD/cc-rite-workflow/pull/357) bug fix), Phase B adopts a **hybrid approach**:

- Agent-specific identity (Core Principles, Detection Process, Detailed Checklist, Output Format) is delivered via the named subagent's **system prompt**
- Shared principles (from `_reviewer-base.md`) are extracted as `{shared_reviewer_principles}` and injected into the **user prompt** — preserving the Phase A bug fix without duplicating 40 lines of content across 13 agent files

This keeps `_reviewer-base.md` as the single source of truth for shared reviewer discipline.

---

## 2. Who is affected

- **Users running `/rite:pr:review` on opus**: Reviewer quality should improve due to stronger system-prompt-level identity enforcement. No action required.
- **Users running `/rite:pr:review` on sonnet**: 9 of 13 reviewer agents (`api`, `database`, `dependencies`, `devops`, `frontend`, `prompt-engineer`, `security`, `tech-writer`, `test`) have `model: opus` pinned in their frontmatter. Previously this pin was ignored because `general-purpose` doesn't honor agent frontmatter. After Phase B these reviewers will **force-upgrade to opus**, which may increase cost. See [opus Recommendation](#3-opus-recommendation) for why this is intentional.
- **Users on older Claude Code installations**: See [Claude Code version requirement](#4-claude-code-version-requirement).
- **Plugin consumers (not developing rite)**: This change is applied automatically when the plugin updates. No manual configuration needed.

---

## 3. opus Recommendation

This Phase B improvement is **most effective on opus**. In sonnet environments, the Detection Process and Cross-File Impact Check rigor that named subagent invocation unlocks may not translate to proportional review quality gains, because sonnet's weaker instruction-following dilutes the system prompt's authority.

If you currently run `/rite:pr:review` on sonnet and do not want the cost increase from forced opus upgrade, you can opt out by editing `plugins/rite/agents/*-reviewer.md` and removing the `model: opus` lines in the YAML frontmatter. This reverts each reviewer to session default (typically sonnet). Be aware this partially undermines the Phase B quality gains.

---

## 4. Claude Code version requirement

Named scoped subagent invocation (`rite:xxx-reviewer`) requires a Claude Code version that supports:

- Plugin-scoped sub-agent names with the `{plugin_name}:{agent_name}` format
- Automatic sub-agent body loading as system prompt for Task tool calls with `subagent_type` set to a scoped name

If your Claude Code installation does not support this format, `/rite:pr:review` will fail at the retry classification step with `subagent resolution failure`. See [Rollback Scenario 1](#rollback-scenario-1-all-reviewer-subagent-resolution-fails).

To check your Claude Code version:

```bash
claude --version
```

If the version is too old, upgrade Claude Code first, then re-run `/rite:pr:review`.

---

## 5. Rollback scenarios

### Rollback Scenario 1: All reviewer subagent resolution fails

**Symptom**: Every `/rite:pr:review` invocation fails with `subagent resolution failure` for every reviewer. Task tool returns `Agent type 'rite:xxx-reviewer' not found. Available agents: ...`.

**Cause**: Plugin not installed correctly, version mismatch, or agent file moved.

**Workaround (manual)**: Revert the Phase B commit on your local branch while keeping the Phase A fixes:

```bash
git revert <phase-b-commit-sha>
```

This restores `subagent_type: general-purpose` with `{agent_identity}` extraction. The Phase A Part A bug fix (Cross-File Impact Check) and tools/model frontmatter cleanup remain intact.

**Long-term fix**: Upgrade Claude Code to the version that supports plugin-scoped subagent names.

### Rollback Scenario 2: tech-writer-reviewer fails due to Bash permission

**Symptom**: `/rite:pr:review` works for most reviewers but `tech-writer-reviewer` fails in Doc-Heavy PR Mode because it cannot execute `gh api` or `Bash` commands.

**Cause**: `plugins/rite/agents/tech-writer-reviewer.md` frontmatter does not inherit `tools` correctly. This should not happen because Phase A (#357) removed the `tools:` key from all 13 reviewer frontmatters, making them inherit session defaults.

**Workaround (hotfix)**: Add an explicit `tools:` field to the tech-writer-reviewer frontmatter:

```yaml
---
name: tech-writer-reviewer
description: Reviews documentation for clarity, accuracy, and completeness
model: opus
tools: [Read, Grep, Glob, Bash, WebFetch]
---
```

The other 12 reviewers continue using Phase B named subagent invocation unchanged.

### Rollback Scenario 3: Verification mode output format broken

**Symptom**: `/rite:pr:review` in verification mode (re-review after fix) produces unexpected output format. The `### 修正検証結果` table is missing or malformed.

**Cause**: Under Phase B, verification mode uses the same user prompt mechanism as full review (案 C). The Phase 4.5.1 verification template in the user prompt should still drive the verification output format. If the system prompt (agent body) contains a conflicting `## Output Format` section, the reviewer may default to full-review format.

**Workaround**: Force `subagent_type: general-purpose` for verification mode only by adding a conditional branch in `plugins/rite/commands/pr/review.md` Phase 4.3.1:

```
if (review_mode == "verification") {
  subagent_type = "general-purpose"
} else {
  subagent_type = "rite:{reviewer_type}-reviewer"
}
```

This falls back to Phase A behavior for verification while keeping Phase B for full review. Apply as a temporary hotfix until the verification output format issue is investigated.

---

## 6. How to verify Phase B is active

After updating the plugin, run `/rite:pr:review` on any PR. Check the conversation log for:

1. Task tool invocations use `subagent_type: "rite:xxx-reviewer"` (not `general-purpose`)
2. No error messages like `Agent type 'rite:xxx-reviewer' not found`
3. Review results include per-reviewer sections (`#### Security Reviewer`, `#### Code Quality Reviewer`, etc.) in the PR comment
4. The integrated review comment (`📜 rite レビュー結果`) appears normally

If all four conditions hold, Phase B is active and working.

---

## 7. Related documentation

- [`plugins/rite/commands/pr/review.md`](../../plugins/rite/commands/pr/review.md) — updated command definition
- [`plugins/rite/agents/_reviewer-base.md`](../../plugins/rite/agents/_reviewer-base.md) — shared principles (source of truth)
- [`plugins/rite/agents/*-reviewer.md`](../../plugins/rite/agents/) — per-reviewer identity and detection process
- [`docs/investigations/review-quality-gap-baseline.md`](../investigations/review-quality-gap-baseline.md) — Phase 0 empirical test of scoped subagent name resolution (Section 2)
- [`docs/designs/review-quality-gap-closure.md`](../designs/review-quality-gap-closure.md) — full design document for Phases 0-D

---

## 8. Questions and support

File an issue at [https://github.com/B16B1RD/cc-rite-workflow/issues](https://github.com/B16B1RD/cc-rite-workflow/issues) with:

- Claude Code version (`claude --version`)
- Exact `subagent resolution failure` error message (if applicable)
- Which of the 13 reviewers failed
- Whether the same PR worked before Phase B (confirming regression)
