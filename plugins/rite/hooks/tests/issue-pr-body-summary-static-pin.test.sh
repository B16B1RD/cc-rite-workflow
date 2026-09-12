#!/bin/bash
# Pin human summaries and execute the documented version / append / PR-create code.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
structure="$PLUGIN_ROOT/templates/issue/template-structure.md"
pr_template="$PLUGIN_ROOT/templates/pr/generic.md"
pr_create="$PLUGIN_ROOT/skills/pr-create/SKILL.md"

require_literal() {
  grep -Fq -- "$2" "$1" && return 0
  printf 'MISSING RULE: %s: %s\n' "$1" "$2" >&2
  return 1
}
pin() {
  if require_literal "$1" "$2"; then pass "$2"; else fail "$2"; fi
}
for file in "$structure" "$pr_template"; do
  for literal in '## 要約' '**何が起きているか**:' '**何をするか**:' '**見てほしい点**:' '**用語**:' '<details>' '<summary>'; do
    pin "$file" "$literal"
  done
  if awk '/^<summary>/ { getline; if ($0 != "") exit 1; found=1 } END { if (!found) exit 1 }' "$file"; then
    pass "summary is followed by blank line: ${file##*/}"
  else fail "missing blank line after summary: ${file##*/}"; fi
done
for literal in '内部用語が無ければ' '省略する' '| SVG（添付） |' '| Mermaid（本文内 fence） |' '| 図なし |' '<!-- 図なし:' '2.99.0 未満は SVG 行を選ばず' '解析不能時は WARNING を stderr' '配色はテーマ中立' 'Section 1〜9 の見出し文字列・チェックボックス行パターン' 'タイトルは内部機構名を避け'; do
  pin "$structure" "$literal"
done
if awk '/\| SVG（添付） \|/ { svg=NR } /\| Mermaid（本文内 fence） \|/ { mer=NR } END { exit !(svg && mer && svg < mer) }' "$structure"; then
  pass 'SVG row appears before Mermaid row'
else fail 'SVG row appears before Mermaid row'; fi
if awk '/<!-- 図なし:/ { c=NR } /^<details>/ { d=NR } END { exit !(c && d && c < d) }' "$structure"; then
  pass '図なし comment appears before details'
else fail '図なし comment appears before details'; fi
for literal in 'F-[0-9]+' 'cycle [0-9]+' '[0-9a-fA-F]{7,}' 'PR #[0-9]+' '#[0-9]+' 'Closes #N'; do
  pin "$structure" "$literal"
  pin "$PLUGIN_ROOT/templates/issue/default.md" "$literal"
done
for heading in '1. Goal' '2. Scope' '3. User Scenarios' '4. Implementation Details' '5. Acceptance Criteria' '6. Test Specification' '7. Important Conventions' '8. Definition of Done' '9. Decision Log'; do
  pin "$structure" "## $heading"
done
pin "$pr_template" '内部用語が無ければ用語ブロックを省略'
pin "$pr_template" '</details>'
pin "$PLUGIN_ROOT/templates/issue/default.md" '| 上段要約 | M | M | M | M | M |'
pin "$PLUGIN_ROOT/skills/issue-create/SKILL.md" '「上段要約」「図の選択規則」「契約層の折りたたみ」を適用'
pin "$PLUGIN_ROOT/skills/issue-create/SKILL.md" '分解経路の親も共通選択表に従う'
pin "$PLUGIN_ROOT/skills/issue-create/SKILL.md" 'parent.attachments'
pin "$pr_create" 'の「上段要約」「図の選択規則」'
pin "$pr_create" '上段に再掲する'
pin "$pr_create" 'diagram.svg` を書かず'
pin "$pr_create" '再掲・図なし・Mermaid は必ず'
pin "$pr_create" 'Mermaid fence'
pin "$pr_create" 'ノードの追加・削除'
pin "$pr_create" 'ラベルの文言変更だけでは描き直さない'
pin "$pr_create" 'Issue の図から変わった点'
pin "$pr_create" '親 Issue の図の {部分} を担当'
pin "$pr_create" '<!-- 図なし: {理由} -->'
pin "$pr_create" '関連 Issue に図が無く、選択表の図種に該当する'
pin "$pr_create" '新規生成または描き直し'
pin "$pr_create" '関連 Issue 不在は「図が無く」'
if grep -Fq -- 'Issue なしで PR を作る場合は図なし行へ' "$pr_create"; then fail 'deleted preface resurfaced'; else pass 'deleted preface absent'; fi
pin "$PLUGIN_ROOT/skills/issue-create/SKILL.md" 'diagram.svg`（SVG 時のみ）'
pin "$pr_template" '関連 Issue の図'
pin "$structure" '`svg_allowed=true` なら第一候補'
pin "$structure" '`svg_allowed=false` のときのみ'
pin "$structure" 'Mermaid に落とさない'
pin "$PLUGIN_ROOT/skills/issue-create/SKILL.md" 'svg_allowed=true` なら SVG を第一候補'
pin "$PLUGIN_ROOT/skills/issue-implement/SKILL.md" '`## Acceptance Criteria` / `## 5. Acceptance Criteria`'
if awk '/^Closes / { closes=NR } /^<details>/ { details=NR } /^## 変更/ { changes=NR } /^<\/details>/ { end=NR } END { exit !(closes && closes<details && details<changes && changes<end) }' "$pr_template"; then
  pass 'PR closes outside details; changes inside'
else fail 'PR section ordering'; fi

# Prove the same pin detector fails on an actual deleted rule.
sed '/^\*\*見てほしい点\*\*:/d' "$structure" > "$work/mutant.md"
if assert_mutant_changed 'deleted summary rule' "$structure" "$work/mutant.md"; then
  rc=0
  require_literal "$work/mutant.md" '**見てほしい点**:' 2> "$work/mutation.err" || rc=$?
  assert 'deleted literal returns 1' 1 "$rc"
  assert_grep 'deleted literal reports MISSING RULE' "$work/mutation.err" '^MISSING RULE:'
fi

# Execute the actual one-line version gate; gh is a local function, never the CLI.
version_code=$(grep '^svg_allowed=' "$structure")
for pair in '2.98.0 false' '2.99.0 true' '2.100.0 true' 'invalid false'; do
  read -r version expected <<< "$pair"
  actual=$(VERSION="$version" bash -c 'gh() { printf "gh version %s\n" "$VERSION"; }; eval "$1"; printf "%s" "$svg_allowed"' _ "$version_code" 2> "$work/version.err")
  assert "SVG allowed for $version" "$expected" "$actual"
  if [ "$version" = invalid ]; then
    assert_grep 'invalid version warning' "$work/version.err" 'WARNING:'
  else assert "valid $version is quiet" '' "$(cat "$work/version.err")"; fi
done

# Extract the real Decision Log awk program, including its historical boundaries.
awk '/NEW_LINE="\$new_line" awk '\''/ { active=1; next } active && /^  '\''/ { exit } active { print }' \
  "$PLUGIN_ROOT/skills/pr-review/references/scope-triage.md" > "$work/append.awk"
# The extraction anchors on one call site; pin that it is unique and is the Section 9 append, not the creation awk.
assert 'Decision Log append awk call site is unique' 1 "$(grep -cF 'NEW_LINE="$new_line" awk '"'" "$PLUGIN_ROOT/skills/pr-review/references/scope-triage.md")"
assert_grep 'extracted awk is the Section 9 append' "$work/append.awk" 'END \{ if \(in_section\)'
for boundary in '</details>' '## Following section' '---' ''; do
  printf '## 9. Decision Log\n- D-01: existing\n' > "$work/log.md"
  [ -z "$boundary" ] || printf '%s\n' "$boundary" >> "$work/log.md"
  NEW_LINE='- D-02: appended' awk -f "$work/append.awk" "$work/log.md" > "$work/appended.md"
  printf '## 9. Decision Log\n- D-01: existing\n- D-02: appended\n' > "$work/expected.md"
  [ -z "$boundary" ] || printf '%s\n' "$boundary" >> "$work/expected.md"
  if cmp -s "$work/expected.md" "$work/appended.md"; then pass "append before boundary: ${boundary:-EOF}"; else fail "append boundary: ${boundary:-EOF}"; fi
done

# Execute the real Decision Log Append block; gh / date / awk failures are local mocks, never the CLI.
triage="$PLUGIN_ROOT/skills/pr-review/references/scope-triage.md"
awk '/^#### 7\.4\.3 / { sec=1 } sec && /^```bash$/ { active=1; next } active && /^```$/ { exit } active { print }' "$triage" > "$work/dl-block.sh"
assert_grep 'Decision Log block extracted' "$work/dl-block.sh" 'section=created'
dl_code=$(cat "$work/dl-block.sh")
dl_code=${dl_code//\{decision\}/decided}
dl_code=${dl_code//\{reason\}/why}
dl_code=${dl_code//\{impact\}/what}
dl_code=${dl_code//\{source_issue_number\}/7}
dl_code=${dl_code//\{owner_repo\}/example\/repo}
printf '%s\n' "$dl_code" > "$work/dl.sh"
assert_not_grep 'Decision Log block has no placeholder residue' "$work/dl.sh" '(^|[^$])\{[a-z_]+\}'
mkdir "$work/dl-bin" "$work/awk-fail"
cat > "$work/dl-bin/gh" <<'MOCK'
#!/bin/bash
jq -cn --args '$ARGS.positional' -- "$@" >> "$MOCK_LOG"
if [ "$1 $2" = 'issue view' ]; then cat "$MOCK_BODY"; fi
if [ "$1 $2" = 'issue edit' ]; then
  while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$MOCK_EDITED"; shift; done
fi
MOCK
printf '#!/bin/bash\necho 2026-01-02\n' > "$work/dl-bin/date"
# Only the AWK_FAIL_AT-th awk call fails, so each exit-status capture in the block is pinned on its own.
cat > "$work/awk-fail/awk" <<'MOCK'
#!/bin/bash
echo call >> "$AWK_LOG"
if [ "$(wc -l < "$AWK_LOG" | tr -d ' ')" -ne "$AWK_FAIL_AT" ]; then exec "$REAL_AWK" "$@"; fi
if [ "$AWK_FAIL_MODE" = partial ]; then IFS= read -r first; printf '%s\n' "$first"; exit 2; fi
cat > /dev/null
exit 0
MOCK
chmod +x "$work/dl-bin/gh" "$work/dl-bin/date" "$work/awk-fail/awk"
REAL_AWK=$(command -v awk)
export REAL_AWK
dl_line='- 2026-01-02 D-01: decided / Reason: why / Impact: what'
run_decision_log() {
  local name="$1" body="$2" extra_path="${3:-}" rc=0
  : > "$work/$name.argv"; : > "$work/$name.awklog"
  AWK_LOG="$work/$name.awklog" MOCK_LOG="$work/$name.argv" MOCK_BODY="$body" MOCK_EDITED="$work/$name.edited" \
    PATH="${extra_path:+$extra_path:}$work/dl-bin:$PATH" bash "$work/dl.sh" > "$work/$name.out" 2> "$work/$name.err" || rc=$?
  assert "Decision Log $name exit status" 0 "$rc"
}
edit_count() { jq -s '[.[] | select(.[0:2] == ["issue", "edit"] and index("--body-file") != null)] | length' "$work/$1.argv"; }
heading_count() { grep -c '^## 9\. Decision Log' "$work/$1.edited" || true; }

# Section 9 is created inside the contract details, before </details> and not before the footer rule.
cat > "$work/contract-body.md" <<'BODY'
**Type**: fix

## 要約

free text
---

<details>
<summary>Implementation Contract（契約）</summary>

## 8. Definition of Done

- [ ] done

</details>

---

🤖 Generated with rite
BODY
details_at=$(grep -n '^</details>$' "$work/contract-body.md" | cut -d: -f1)
{ head -n $((details_at - 1)) "$work/contract-body.md"; printf '## 9. Decision Log\n\n%s\n\n' "$dl_line"; tail -n +"$details_at" "$work/contract-body.md"; } > "$work/contract-expected.md"
run_decision_log contract "$work/contract-body.md"
assert_grep 'created marker names D-01 and section=created' "$work/contract.out" 'DECISION_LOG_APPENDED=1; issue=7; entry=D-01; section=created'
assert 'created section edits once' 1 "$(edit_count contract)"
if cmp -s "$work/contract-expected.md" "$work/contract.edited"; then pass 'created section keeps every other line'; else fail 'created section changed other lines'; fi
assert 'created section heading appears once' 1 "$(heading_count contract)"
if awk -v l="$dl_line" '/^<details>/ { o=NR } $0 == l { d=NR } /^<\/details>/ { c=NR } END { exit !(o && o < d && d < c) }' "$work/contract.edited"; then
  pass 'created D-01 sits inside details'
else fail 'created D-01 outside details'; fi
assert 'pr-create reads one decision from created section' 1 \
  "$(awk '/^## 9\. Decision Log/ { s=1; next } s && (/^## / || /^<\/details>/) { exit } s && /D-[0-9]+:/ { n++ } END { print n+0 }' "$work/contract.edited")"

# CRLF bodies keep their bytes; only the inserted lines are added.
sed 's/$/\r/' "$work/contract-body.md" > "$work/crlf-body.md"
{ head -n $((details_at - 1)) "$work/crlf-body.md"; printf '## 9. Decision Log\n\n%s\n\n' "$dl_line"; tail -n +"$details_at" "$work/crlf-body.md"; } > "$work/crlf-expected.md"
run_decision_log crlf "$work/crlf-body.md"
if cmp -s "$work/crlf-expected.md" "$work/crlf.edited"; then pass 'CRLF body gets section before </details>'; else fail 'CRLF body insertion'; fi

# No details: a footer rule followed only by the signature is the boundary.
printf '<!-- rite:marker -->\n**Type**: fix\n\n## 概要\n\ntext\n\n---\n\n🤖 Generated with rite\n' > "$work/footer-body.md"
printf '<!-- rite:marker -->\n**Type**: fix\n\n## 概要\n\ntext\n\n## 9. Decision Log\n\n%s\n\n---\n\n🤖 Generated with rite\n' "$dl_line" > "$work/footer-expected.md"
run_decision_log footer "$work/footer-body.md"
if cmp -s "$work/footer-expected.md" "$work/footer.edited"; then pass 'marker body gets section before footer rule'; else fail 'marker body footer insertion'; fi
assert 'footer body heading appears once' 1 "$(heading_count footer)"

# Free-text rule / </details> lines are not boundaries; the section goes to the end.
printf '<!-- rite:follow-up -->\n## 残存非実測指摘\n\n- 説明: before\n---\n</details>\n- 提案: after\n' > "$work/freetext-body.md"
{ cat "$work/freetext-body.md"; printf '\n## 9. Decision Log\n\n%s\n' "$dl_line"; } > "$work/freetext-expected.md"
run_decision_log freetext "$work/freetext-body.md"
if cmp -s "$work/freetext-expected.md" "$work/freetext.edited"; then pass 'free-text rule body gets section at end'; else fail 'free-text rule body insertion'; fi
assert 'free-text body heading appears once' 1 "$(heading_count freetext)"

# The created section is the Section 9 of the next append.
run_decision_log existing "$work/contract.edited"
assert_grep 'existing section appends D-02' "$work/existing.out" 'DECISION_LOG_APPENDED=1; issue=7; entry=D-02$'
assert_not_grep 'existing section is not reported as created' "$work/existing.out" 'section=created'
assert 'existing section heading stays single' 1 "$(heading_count existing)"
if awk '/ D-01: / { a=NR } / D-02: / { b=NR } /^<\/details>/ { c=NR } END { exit !(a && a < b && b < c) }' "$work/existing.edited"; then
  pass 'D-02 follows D-01 inside details'
else fail 'D-02 position'; fi

# Numbering counts only Section 9; D-NN in prose before or after the section is not a decision.
cat > "$work/prose-body.md" <<'BODY'
**Type**: fix

## 残存非実測指摘

- 説明: 2 件目が D-04 に飛ぶ

<details>
<summary>Implementation Contract（契約）</summary>

## 8. Definition of Done

- [ ] done

</details>

- 提案: D-09 を参照
BODY
run_decision_log prose-created "$work/prose-body.md"
assert_grep 'prose body creates D-01' "$work/prose-created.out" 'entry=D-01; section=created'
run_decision_log prose-appended "$work/prose-created.edited"
assert_grep 'prose body appends D-02' "$work/prose-appended.out" 'entry=D-02$'
assert_grep 'prose body records D-02' "$work/prose-appended.edited" ' D-02: decided'
assert_not_grep 'prose body skips no number' "$work/prose-appended.edited" ' D-(05|10): '
printf '## 要約\n\n- 説明: D-07 を参照\n\n## 9. Decision Log\n\n- 2026-01-01 D-03: earlier / CARD-12 は別物\n\n---\n\n- 提案: D-08 を参照\n' > "$work/max-body.md"
run_decision_log max "$work/max-body.md"
assert_grep 'Section 9 maximum D-03 appends D-04' "$work/max.out" 'entry=D-04$'
# A digit directly before D-NN in a record is not part of the number.
printf '## 9. Decision Log\n\n- 2026-01-01 D-01: a\n- 2026-01-01 D-02: b\n- 2026-01-01 D-03: c\n- 2026-01-01 D-04: see 9D-02\n' > "$work/digit-body.md"
run_decision_log digit "$work/digit-body.md"
assert_grep 'digit before D-NN still appends D-05' "$work/digit.out" 'entry=D-05$'

# A failing numbering scan or append awk on an existing Section 9 never writes back.
for fail in partial:1 partial:2; do
  at=${fail##*:}
  name="existing-awk-$at"
  AWK_FAIL_MODE=partial AWK_FAIL_AT=$at run_decision_log "$name" "$work/contract.edited" "$work/awk-fail"
  if [ "$(wc -l < "$work/$name.awklog" | tr -d ' ')" -ge "$at" ]; then pass "$name mock reached the failing call"; else fail "$name mock did not reach the failing call"; fi
  assert "$name does not edit" 0 "$(edit_count "$name")"
  assert_not_grep "$name reports no append" "$work/$name.out" 'DECISION_LOG_APPENDED'
  assert_grep "$name reports gh_edit_failure" "$work/$name.err" 'DECISION_LOG_APPEND_FAILED=1; reason=gh_edit_failure'
done
assert_grep 'failed scan leaves the pending number open' "$work/existing-awk-1.err" 'D-NN: decided'
assert_grep 'failed append prints the pending D-02' "$work/existing-awk-2.err" 'D-02: decided'

# A failing or empty body build never writes back, whichever awk call fails.
for fail in partial:1 partial:2 empty:2; do
  mode=${fail%%:*}
  at=${fail##*:}
  name="awk-$mode-$at"
  AWK_FAIL_MODE=$mode AWK_FAIL_AT=$at run_decision_log "$name" "$work/footer-body.md" "$work/awk-fail"
  if [ "$(wc -l < "$work/$name.awklog" | tr -d ' ')" -ge "$at" ]; then pass "$name mock reached the failing call"; else fail "$name mock did not reach the failing call"; fi
  assert "$name does not edit" 0 "$(edit_count "$name")"
  assert_not_grep "$name reports no append" "$work/$name.out" 'DECISION_LOG_APPENDED'
  assert_grep "$name reports gh_edit_failure" "$work/$name.err" 'DECISION_LOG_APPEND_FAILED=1; reason=gh_edit_failure'
  assert_grep "$name prints the pending line" "$work/$name.err" 'D-01: decided'
done

# The work-memory fallback is gone from the Decision Log contract.
for gone in 'issue-comment-wm-sync' 'wm_sync_failure' 'fallback=work_memory' '決定事項・メモ'; do
  if grep -qF -- "$gone" "$triage"; then fail "scope-triage still mentions $gone"; else pass "scope-triage has no $gone"; fi
done
awk '/^#### 7\.4\.3 / { s=1; print; next } s && /^#### / { exit } s { print }' "$triage" > "$work/dl-section.md"
assert_not_grep 'Decision Log section has no work memory route' "$work/dl-section.md" '作業メモリ'
assert 'Decision Log failure table has three reasons' 3 "$(grep -cE '^\| `[a-z_]+_failure` \|' "$work/dl-section.md" || true)"

# Consumer headings/checklist syntax remains observable through a details wrapper.
cat > "$work/contract.md" <<'BODY'
## 5. Acceptance Criteria
- [ ] AC-1: first
- [x] AC-2: second
## 6. Test Specification
- [ ] T-01: verify
BODY
{ printf '<details>\n<summary>Contract</summary>\n\n'; cat "$work/contract.md"; printf '\n</details>\n'; } > "$work/wrapped.md"
for file in contract wrapped; do
  grep '^- \[ \]' "$work/$file.md" > "$work/$file.checks"
  awk '/^## (5\. )?Acceptance Criteria$/ { active=1; next } active && /^## / { exit } active { print }' "$work/$file.md" > "$work/$file.ac"
done
assert 'unchecked checklist count' 2 "$(wc -l < "$work/wrapped.checks" | tr -d ' ')"
assert 'AC row count' 2 "$(wc -l < "$work/wrapped.ac" | tr -d ' ')"
for extracted in checks ac; do
  if cmp -s "$work/contract.$extracted" "$work/wrapped.$extracted"; then pass "wrapped $extracted matches original"; else fail "wrapped $extracted changed"; fi
done

# Execute the actual Phase 3.4(C) block with a mock; URL + failed upload is not success.
pr_code=$(awk '/^pr_workdir="\{PR_CREATE_WORKDIR\}"/ { active=1 } active && /^```/ { exit } active { print }' "$pr_create")
mkdir "$work/bin"
cat > "$work/bin/gh" <<'MOCK'
#!/bin/bash
jq -cn --args '$ARGS.positional' -- "$@" >> "$MOCK_LOG"
echo 'https://github.com/example/repo/pull/42'
if [ "$MOCK_MODE" = failure ]; then echo 'upload failed: permission denied' >&2; exit 1; fi
MOCK
chmod +x "$work/bin/gh"
for mode in empty spaces failure; do
  case_dir="$work/$mode"
  mkdir "$case_dir"
  printf 'Plain title\n' > "$case_dir/pr_title.txt"
  printf 'PR body\n' > "$case_dir/pr_body.md"
  attachment="$case_dir/diagram with spaces.svg"
  printf '<svg/>\n' > "$attachment"
  if [ "$mode" = empty ]; then printf '[]\n' > "$case_dir/attachments.json"; else jq -n --arg a "$attachment" '[$a]' > "$case_dir/attachments.json"; fi
  block=${pr_code//\{PR_CREATE_WORKDIR\}/$case_dir}
  block=${block//\{owner_repo\}/example\/repo}
  block=${block//\{base_branch\}/develop}
  block=${block//\{branch_name\}/feature}
  printf '%s\n' "$block" > "$work/create.sh"
  rc=0
  MOCK_MODE="$mode" MOCK_LOG="$work/$mode.argv" PATH="$work/bin:$PATH" bash "$work/create.sh" > "$work/$mode.out" 2> "$work/$mode.err" || rc=$?
  expected_rc=0; [ "$mode" != failure ] || expected_rc=1
  assert "PR $mode exit status" "$expected_rc" "$rc"
  if jq -se 'length == 1 and .[0][0:2] == ["pr", "create"]' "$work/$mode.argv" >/dev/null; then pass "PR $mode creates exactly once"; else fail "PR $mode create count"; fi
  if [ "$mode" = empty ]; then expected_args='[]'; else expected_args=$(jq -cn --arg a "$attachment" '[$a]'); fi
  actual_args=$(jq -c '[range(length) as $i | select(.[$i] == "--attach") | .[$i+1]]' "$work/$mode.argv")
  assert "PR $mode attachment argv" "$expected_args" "$actual_args"
  if [ "$mode" = failure ]; then
    assert 'failed upload preserves PR URL' 'https://github.com/example/repo/pull/42' "$(cat "$work/$mode.out")"
    assert 'failed upload preserves stderr' 'upload failed: permission denied' "$(cat "$work/$mode.err")"
  fi
done
print_summary "$(basename "$0")" || exit 1
