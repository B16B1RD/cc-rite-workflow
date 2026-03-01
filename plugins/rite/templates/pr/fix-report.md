# Review Fix Report

## Summary

This PR addresses review feedback from #{pr_number}.

**Review Date**: {review_date}
**Fix Date**: {fix_date}

---

## Issues Addressed

### 🔴 CRITICAL Issues

| Issue | Status | Description | Resolution |
|-------|--------|-------------|------------|
| {issue_id} | ✅ Fixed | {issue_description} | {resolution_description} |

### 🟡 MUST Fix Issues

| Issue | Status | Description | Resolution |
|-------|--------|-------------|------------|
| {issue_id} | ✅ Fixed | {issue_description} | {resolution_description} |

### 🟢 SHOULD Improve Issues

| Issue | Status | Description | Resolution |
|-------|--------|-------------|------------|
| {issue_id} | ✅ Fixed / ⏭️ Deferred | {issue_description} | {resolution_description} |

---

## Deferred Issues

<!-- Issues intentionally not addressed in this fix -->

| Issue | Reason for Deferral | Tracking |
|-------|---------------------|----------|
| {issue_id} | {deferral_reason} | #{follow_up_issue_number} |

---

## Changes Made

### Files Modified

- `{file_path}`: {change_description}
- `{file_path}`: {change_description}

### Verification

- [ ] All CRITICAL issues resolved
- [ ] All MUST issues resolved
- [ ] Tests pass
- [ ] No new issues introduced

---

## Testing

**Test commands run**:
```bash
{test_commands}
```

**Test results**:
{test_results}

---

## Screenshots/Evidence (if applicable)

<!-- Add before/after screenshots or evidence of fixes -->

---

## Ready for Re-review

This PR is now ready for re-review. All critical and must-fix issues have been addressed.

**Next Step**: `/rite:pr:review` to verify fixes

---

**Related PR**: #{pr_number}
**Review Comment**: {review_comment_url}

🤖 Generated with [rite workflow](https://github.com/{owner}/cc-rite-workflow)
