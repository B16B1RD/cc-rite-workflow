#!/bin/bash
# T-1: reviewer SoT 群すべてが 5 列形式の Output Format を持つ
#
# Verification:
#   - agents/_reviewer-base.md (Japanese 列名: 重要度|スコープ|ファイル:行|内容|推奨対応)
#   - 10 reviewer agent (acceptance/application/code-quality/dependencies/devops/error-handling/
#     prompt-engineer/security/tech-writer/test) すべての example 表
#     (Japanese 列名)
#   - skills/reviewers/{SKILL.md, references/output-format.md, references/finding-examples.md}
#     (English 列名: Severity|Scope|File:Line|Issue|Recommendation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
AGENTS_DIR="$REPO_ROOT/plugins/rite/agents"

# 1. _reviewer-base.md に 5 列ヘッダーが存在する
base_file="$AGENTS_DIR/_reviewer-base.md"
assert_grep "_reviewer-base.md: 5-column header (重要度|スコープ|ファイル:行|内容|推奨対応)" \
  "$base_file" \
  '\| 重要度 \| スコープ \| ファイル:行 \| 内容 \| 推奨対応 \|'

# 2. _reviewer-base.md の旧 4 列ヘッダーがどこかに残存していないこと
assert_not_grep "_reviewer-base.md: 4-column header drift (must not exist)" \
  "$base_file" \
  '\| 重要度 \| ファイル:行 \| 内容 \| 推奨対応 \|'

# 3. 10 reviewer agent の example 表が 5 列か
reviewers=(
  acceptance-reviewer
  application-reviewer
  code-quality-reviewer
  dependencies-reviewer
  devops-reviewer
  error-handling-reviewer
  prompt-engineer-reviewer
  security-reviewer
  tech-writer-reviewer
  test-reviewer
)

for r in "${reviewers[@]}"; do
  f="$AGENTS_DIR/$r.md"
  # File-existence guard: assert_grep / assert_not_grep は
  # それぞれ独立にファイル不在チェックを行うため、不在時には 1 reviewer = 2 fail message
  # に膨張する。assert_file_exists_or_fail で 1 件 fail + caller の `|| continue` で
  # 後続 assertion を skip し、原本の「1 reviewer = 1 fail」挙動を維持する
  # (_test-helpers.sh 側に共通化済)。
  assert_file_exists_or_fail "$r.md" "$f" || continue
  assert_grep "$r.md: 5-column header present" \
    "$f" \
    '\| 重要度 \| スコープ \| ファイル:行 \| 内容 \| 推奨対応 \|'
  assert_not_grep "$r.md: 4-column header drift (must not exist)" \
    "$f" \
    '\| 重要度 \| ファイル:行 \| 内容 \| 推奨対応 \|'
done

# 4. skills/reviewers/* の SoT ファイル群 (英語列名) が 5 列形式 を持つ
#    agent 側 (日本語列名) と同じ symmetric pair (5-column present /
#    4-column drift NOT present) を skills 側 (英語列名) にも適用する。
#    Asymmetric Fix Transcription (対称位置への伝播漏れ) を防ぐため、
#    skills/reviewers/* を 4 列 → 5 列に同期した変更が将来 regression で 4 列に
#    戻された場合に静かに通過しないよう保護する。
SKILLS_DIR="$REPO_ROOT/plugins/rite/skills/reviewers"
skills_files=(
  "SKILL.md"
  "references/output-format.md"
  "references/finding-examples.md"
)

for sf in "${skills_files[@]}"; do
  f="$SKILLS_DIR/$sf"
  assert_file_exists_or_fail "skills/reviewers/$sf" "$f" || continue
  assert_grep "skills/reviewers/$sf: 5-column header present (English)" \
    "$f" \
    '\| Severity \| Scope \| File:Line \| Issue \| Recommendation \|'
  assert_not_grep "skills/reviewers/$sf: 4-column header drift (must not exist, English)" \
    "$f" \
    '\| Severity \| File:Line \| Issue \| Recommendation \|'
done

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
