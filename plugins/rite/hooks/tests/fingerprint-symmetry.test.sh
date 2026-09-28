#!/bin/bash
# fix 側の accept（skills/fix/references/accept-finding.md の永続化 block）が記録した fingerprint を、
# pr-review 側の scripts/pr-review-step.sh fingerprint-check が同じ finding JSON から再計算して
# 一致させることを固定する。description にバッククォート・$・二重引用符を含めても一致し、
# どちらの側もシェル展開を起こさない。finding JSON の読み取り失敗は両側とも理由付きで報告する。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACCEPT="$PLUGIN_ROOT/skills/fix/references/accept-finding.md"
STEP="$PLUGIN_ROOT/scripts/pr-review-step.sh"

assert_file_exists_or_fail "accept-finding.md exists" "$ACCEPT" || exit 1
assert_file_exists_or_fail "pr-review-step.sh exists" "$STEP" || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rite-fp-symmetry-XXXXXX") || { fail "mktemp -d failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# 永続化 block（字下げ fence を含む ```bash の中で「accept fingerprint 永続化」を含むもの）を取り出す
awk '
  /^[[:space:]]*```bash$/ { inb = 1; block = ""; next }
  inb && /^[[:space:]]*```$/ { if (index(block, "accept fingerprint 永続化")) { printf "%s", block; exit } inb = 0; next }
  inb { block = block $0 "\n" }
' "$ACCEPT" > "$WORK/accept-block.sh"
if [ -s "$WORK/accept-block.sh" ]; then
  pass "the accept persistence block is extracted"
else
  fail "the accept persistence block is extracted"
fi

# state root は非 git の作業ディレクトリ（state-path-resolve.sh は cwd を返す）
run_accept() {  # $1=finding JSON path
  # placeholder だけを置換し、${pr_number} のような変数展開には触れない
  sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" -e 's|\([^$]\){pr_number}|\191|g' -e "s|{finding_file}|$1|g" \
    "$WORK/accept-block.sh" > "$WORK/accept-run.sh"
  (cd "$WORK" && bash "$WORK/accept-run.sh") 2>&1
}
run_check() {  # $1=finding JSON path
  (cd "$WORK" && bash "$STEP" fingerprint-check --pr 91 --finding-id F-01 --severity HIGH --finding-file "$1") 2>&1
}

jq -n '{file: "./src/a.sh", line: 12,
        category: "code_quality",
        description: "`touch '"$WORK"'/expanded` と $HOME を含む  \"引用\" 付きの説明"}' > "$WORK/finding.json"

accept_out=$(run_accept "$WORK/finding.json")
case "$accept_out" in
  *"ACCEPT_FINGERPRINT_PERSISTED=1"*"file=./src/a.sh; line=12"*) pass "accept persists the fingerprint from the finding JSON" ;;
  *) fail "accept persists the fingerprint from the finding JSON (got: $accept_out)" ;;
esac
assert "accept records one fingerprint" "1" "$(grep -c . "$WORK/.rite/state/accepted-fingerprints-91.txt" 2>/dev/null)"

check_out=$(run_check "$WORK/finding.json")
case "$check_out" in
  *"FINDING_SUPPRESSED_BY_ACCEPT=1; finding_id=F-01"*) pass "fingerprint-check matches the fingerprint accept recorded" ;;
  *) fail "fingerprint-check matches the fingerprint accept recorded (got: $check_out)" ;;
esac
if [ -e "$WORK/expanded" ]; then
  fail "a backtick in the description is not executed"
else
  pass "a backtick in the description is not executed"
fi

# 読み取り失敗: 空値から計算せず、両側とも理由付きの marker を出して rc=0 で終える
printf '{"file": "a", "category": "c", "description": "x" "y"}\n' > "$WORK/broken.json"
check_out=$(run_check "$WORK/broken.json"); check_rc=$?
assert "fingerprint-check on an invalid JSON exits 0" "0" "$check_rc"
case "$check_out" in
  *"FINGERPRINT_COMPUTE_FAILED=1; reason=finding_file_invalid; finding_id=F-01"*) pass "fingerprint-check reports finding_file_invalid" ;;
  *) fail "fingerprint-check reports finding_file_invalid (got: $check_out)" ;;
esac
check_out=$(run_check "$WORK/absent.json")
case "$check_out" in
  *"FINGERPRINT_COMPUTE_FAILED=1; reason=finding_file_unreadable; finding_id=F-01"*) pass "fingerprint-check reports finding_file_unreadable" ;;
  *) fail "fingerprint-check reports finding_file_unreadable (got: $check_out)" ;;
esac
jq -n '{file: "a", category: "", description: "x"}' > "$WORK/empty-category.json"
accept_out=$(run_accept "$WORK/empty-category.json")
case "$accept_out" in
  *"ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=finding_file_invalid"*) pass "accept reports finding_file_invalid for an empty category" ;;
  *) fail "accept reports finding_file_invalid for an empty category (got: $accept_out)" ;;
esac
assert "accept does not record a fingerprint from an invalid JSON" "1" "$(grep -c . "$WORK/.rite/state/accepted-fingerprints-91.txt" 2>/dev/null)"

if ! print_summary "$(basename "$0")" \
  "fix の accept（skills/fix/references/accept-finding.md）と pr-review の fingerprint-check（scripts/pr-review-step.sh）は同じ finding JSON を同じ jq で読む。"; then
  exit 1
fi
