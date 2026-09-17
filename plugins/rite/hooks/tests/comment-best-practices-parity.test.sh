#!/usr/bin/env bash
#
# comment-best-practices.md Forward Subset Parity Test
#
# Asserts the Maintenance Invariant declared in
# plugins/rite/skills/rite-workflow/references/comment-best-practices.md §C:
#
#   For every literal entry in §A 原則 2 「禁止句リスト (SoT)」, there exists at
#   least one regex in §C Detection Heuristics row 2 (原則 2) that matches it.
#
# Reverse subset (Heuristics ⊆ SoT) is intentionally best-effort and NOT tested
# here — Heuristics may catch broader patterns than the SoT enumerates.
#
# Scope-expansion invariant: the SoT 適用スコープ was expanded to ドキュメント散文 /
# Wiki ページ, but the 禁止句リスト *entries* themselves are unchanged. The forward
# subset (SoT 禁止句リスト ⊆ §C Heuristics) therefore holds under the expanded scope
# without any probe/regex change here — application scope and the banned-phrase
# enumeration are independent axes. lint Phase 3.5 (generic loop の comment-journal-check.sh) / tech-writer の検出スコープ拡張は
# このリスト整合とは別経路 (comment-journal-check.sh / Detection Checklist) で行う。
#
# Usage:
#   bash plugins/rite/hooks/tests/comment-best-practices-parity.test.sh
#   exit 0: all SoT entries matched by at least one Heuristics regex
#   exit 1: parity broken — at least one SoT entry has no matching Heuristics regex
#
# Note on probes:
#   The SoT table lists token templates like `Fixed in commit {sha}`. We replace
#   `{sha}` / `{N}` / `{issue}` placeholders with concrete probe strings (e.g.
#   `abc1234`, `42`) and assert each probe matches at least one Heuristics regex.
#
# Maintenance Note:
#   The heuristic_regexes and probes arrays below are HARDCODED for portability
#   (no awk/sed parsing of the SoT document at runtime). When you update either:
#   - §A 「禁止句リスト (SoT)」table in comment-best-practices.md, or
#   - §C Detection Heuristics row 2 regex line
#   you MUST manually update the corresponding array in this test. A drift between
#   the SoT document and this test silently weakens the parity guarantee. The
#   `\d` and `\s` are handled asymmetrically because they belong to different extension layers:
#   - `\d` is a PCRE extension. GNU grep -E does NOT support `\d` as a digit class — it matches
#     the literal character `d`. To work under GNU grep -E, `\d` must be translated to `[0-9]`.
#   - `\s` is a GNU grep extension. GNU grep -E supports `\s` as a whitespace class de-facto,
#     equivalent to `[[:space:]]` in POSIX-strict environments. No translation needed.
#   The doc (§C row 2) uses `\d` and `\s` for readability; this test array translates `\d` to
#   `[0-9]` while preserving `\s` as-is. The test target is GNU grep environments; for POSIX-strict
#   portability both `\d` and `\s` would need translation (`\d` → `[0-9]`, `\s` → `[[:space:]]`).

set -o pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SOT_FILE="${REPO_ROOT}/plugins/rite/skills/rite-workflow/references/comment-best-practices.md"

if [ ! -f "$SOT_FILE" ]; then
  echo "ERROR: comment-best-practices.md not found at: $SOT_FILE" >&2
  exit 2
fi

# Heuristics regex subgroups (Detection Heuristics row 2 — 原則 2 no_journal_comment)
# §C Detection Heuristics 表 row 2 の正規表現と semantic に等価
# (`\d` のみ `[0-9]` に翻訳 — PCRE 拡張で GNU grep -E 非対応のため。`\s` は GNU grep -E 拡張として直接動作するため翻訳不要)
heuristic_regexes=(
  'cycle\s*[0-9]+'
  'F-[0-9]+'
  'verified-review'
  'サイクル\s*[0-9]+'
  'Issue\s*#[0-9]+'
  'PR\s*#[0-9]+'
  '(See|Refs|Related\s+to|Closes|Fixes)\s+#[0-9]+'
  '(Fixed|Resolved)\s+in(\s+commit)?\s+\S+'
  'In\s+commit\s+\S+'
  'Pushed\s+as\s+\S+'
  'コミット\s*\S+\s*で対応'
  '#[0-9]+\s*で(別途)?対応'
  '旧実装は'
  '旧コードでは'
  'In\s+the\s+old\s+code'
)

# Concrete probes derived from SoT 表「禁止句」列 (placeholder → literal substitution)
# 各 probe は SoT 表の 1 entry に対応する代表的な発火例
probes=(
  'Fixed in commit abc1234'
  'Fixed in abc1234'
  'Resolved in commit abc1234'
  'See PR #42'
  'See #42'
  'Refs PR #42'
  'Related to #42'
  'Closes #42'
  'Fixes #42'
  'In commit abc1234'
  'Pushed as abc1234'
  'verified-review cycle 5'
  'cycle 5 F-01'
  'F-01 HIGH'
  'In the old code we used X'
  'コミット abc1234 で対応しました'
  'PR #42 で対応'
  '#42 で別途対応'
  'サイクル 5 で導入'
  'cycle 5 F-01 で確立'
  '旧実装は古かった'
  '旧コードでは違うやり方だった'
)

failed_probes=()
matched_count=0

for probe in "${probes[@]}"; do
  matched=0
  for regex in "${heuristic_regexes[@]}"; do
    if printf '%s' "$probe" | grep -cE >/dev/null "$regex"; then
      matched=1
      break
    fi
  done
  if [ "$matched" -eq 1 ]; then
    matched_count=$((matched_count + 1))
  else
    failed_probes+=("$probe")
  fi
done

total=${#probes[@]}

if [ ${#failed_probes[@]} -eq 0 ]; then
  echo "OK: forward subset parity verified — ${matched_count}/${total} SoT probes matched by Heuristics regex"
  exit 0
fi

echo "FAIL: forward subset parity broken — ${#failed_probes[@]} SoT probe(s) not matched by any Heuristics regex:" >&2
for p in "${failed_probes[@]}"; do
  echo "  - ${p}" >&2
done
echo "" >&2
echo "Action: update §C Detection Heuristics row 2 regex to cover the unmatched probes," >&2
echo "        or update this test if the SoT enumeration changed." >&2
exit 1
