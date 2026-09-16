#!/bin/bash
# End-to-end regression for the Status role chain across board shapes.
#
# helper (scripts/projects-status-update.sh) -> gate (hooks/scripts/projects-status-gate.sh)
# -> drift check (hooks/scripts/projects-board-drift-check.sh) must agree on one
# rite-config.yml no matter how the board spells its columns. Each shape runs the same
# scenario against a stateful gh shim whose board is a JSON file: item-edit mutates it,
# and the next reader sees the new column, so a stage that judged on a column name
# instead of a role would break the chain on the first non-English board.
#
# Shapes (fixture repos under $TEST_ROOT, each with its own rite-config.yml):
#   legacy    no role keys; the English standard names are assumed
#   english   the same five columns written out with roles
#   todo      `To-Do` / `In progress` spelling
#   japanese  `ステータス` field with Japanese columns
#   nocancel  no column for abandoned Issues (cancelled row omitted)
#
# Per shape (T-01 .. T-03, T-05):
#   - gate before any write reports `missing` (the todo column has not reached in_progress)
#   - helper in_progress -> in_review -> done each return `updated`; the gate reports `ok`
#     with the reached role after each write
#   - a CLOSED COMPLETED Issue left on the in_review column is 1 drift finding (proves the
#     scan reads this board), and 0 findings once the done write lands
#   - the item-edit option ids are exactly [in_progress, in_review, done] in that order,
#     and no other write subcommand (item-add / field-create / issue edit / mutation ...)
#     appears in the gh log: the board's option set is never touched
# nocancel additionally (T-04): a CLOSED NOT_PLANNED Issue -> helper `cancelled` returns
#   `skipped_role_unmapped` with no item-edit, and the drift check lists it as informational
#   with 0 findings.
#
# Static pins on the documentation this chain is specified by:
#   T-06  no Target document defines the Status set by English display names (grammar
#         arms with a positive-control fixture, then a 0-hit sweep)
#   T-07  README.md / README.ja.md carry the same Status Transitions fence and both point
#         at rite-config.yml `fields.status.options`
#   T-08  docs/CONFIGURATION.md shows the four board shapes and the three config states
# T-06 sweeps only the documents that define the Status contract (the Target set below).
# Skill files that print a legacy board's column names in user-facing messages
# (issue-close / issue-cancel / cleanup) are display-name examples, not definitions,
# and stay outside the sweep.
#
# Usage: bash plugins/rite/hooks/tests/projects-status-boards.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
HELPER="$PLUGIN_ROOT/scripts/projects-status-update.sh"
GATE="$PLUGIN_ROOT/hooks/scripts/projects-status-gate.sh"
DRIFT="$PLUGIN_ROOT/hooks/scripts/projects-board-drift-check.sh"

for dep in jq git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: $dep is required" >&2; exit 1; }
done
for f in "$HELPER" "$GATE" "$DRIFT"; do
  [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rite-status-boards-XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Stateful gh shim. The board lives in $BOARD_STATE:
#   {"field": "<Status field name>", "options": [{"id","name"}...],
#    "issues": {"42": {"state","stateReason","status"}}}
# item-edit resolves the option id back to a column name and writes it into the issue,
# so the helper's own write is what the gate and the drift check read next.
# ---------------------------------------------------------------------------
write_gh_shim() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'GH_SHIM'
#!/bin/bash
set -euo pipefail
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "api graphql")
    if printf '%s\n' "$*" | grep -q 'states: CLOSED'; then
      jq -c '. as $s | {data:{repository:{issues:{nodes:[
        $s.issues | to_entries[] | select(.value.state == "CLOSED") |
        {number: (.key | tonumber), title: ("issue " + .key), stateReason: .value.stateReason,
         projectItems: {nodes: [{project: {number: 1},
           fieldValues: {nodes: (if .value.status == "" then [] else [{field: {name: $s.field}, name: .value.status}] end)}}]}}
      ]}}}}' "$BOARD_STATE"
    else
      n=""
      for a in "$@"; do case "$a" in number=*) n="${a#number=}" ;; esac; done
      jq -c --arg n "$n" '. as $s | $s.issues[$n] as $i |
        if $i == null then {data:{repository:{issue:null}}} else
        {data:{repository:{issue:{url: ("https://github.com/o/r/issues/" + $n), state: $i.state, stateReason: $i.stateReason,
          projectItems: {nodes: [{id: ("ITEM_" + $n), project: {id: "PROJ_1", number: 1},
            fieldValues: {nodes: (if $i.status == "" then [] else [{field: {name: $s.field}, name: $i.status}] end)}}]}}}}} end' "$BOARD_STATE"
    fi ;;
  "project field-list")
    jq -c '{fields: [{id: "FIELD_STATUS", name: .field, options: .options}]}' "$BOARD_STATE" ;;
  "project item-edit")
    item=""; opt=""; prev=""
    for a in "$@"; do
      case "$prev" in --id) item="$a" ;; --single-select-option-id) opt="$a" ;; esac
      prev="$a"
    done
    tmp="$BOARD_STATE.tmp"
    jq -e --arg item "$item" --arg opt "$opt" '. as $s |
      ([$s.options[] | select(.id == $opt) | .name][0]) as $name |
      if $name == null then error("unknown option id " + $opt) else
      .issues[($item | ltrimstr("ITEM_"))].status = $name end' "$BOARD_STATE" > "$tmp"
    mv "$tmp" "$BOARD_STATE" ;;
  "repo view")
    printf '{"owner":{"login":"o"},"name":"r"}\n' ;;
  *) exit 0 ;;
esac
GH_SHIM
  chmod +x "$dir/bin/gh"
}

# $1=dir $2=config yaml body $3=field name $4=options JSON
make_board() {
  local dir="$1" config="$2" field="$3" options="$4"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && git remote add origin "git@github.com:o/r.git" ) >/dev/null 2>&1
  printf '%s\n' "$config" > "$dir/rite-config.yml"
  write_gh_shim "$dir"
  jq -n --arg field "$field" --argjson options "$options" \
    '{field: $field, options: $options, issues: {"42": {state: "OPEN", stateReason: null, status: ($options[0].name)}}}' \
    > "$dir/board.json"
  : > "$dir/gh.log"
}

# Every stage runs from the fixture repo with the shim first on PATH, so the resolver
# reads the fixture's rite-config.yml (git toplevel) and never this repository's.
run_in() {
  local dir="$1"; shift
  ( cd "$dir" && PATH="$dir/bin:$PATH" BOARD_STATE="$dir/board.json" GH_LOG="$dir/gh.log" "$@" )
}

helper_result() {
  local dir="$1" issue="$2" role="$3" out
  out=$(run_in "$dir" bash "$HELPER" "$(jq -n --argjson issue "$issue" --arg role "$role" \
    '{issue_number: $issue, owner: "o", repo: "r", project_number: 1, status_role: $role, auto_add: false, non_blocking: true}')" 2>/dev/null)
  printf '%s' "$out" | jq -r '.result // "no-json"'
}

gate_marker() {
  local dir="$1" issue="$2" expect="$3"
  run_in "$dir" bash "$GATE" --issue "$issue" --expect "$expect" --quiet 2>/dev/null
}

# Runs the drift check; stdout lands in DRIFT_OUT and the exit code in DRIFT_RC. Both are
# set in the calling shell (not via a $(...) capture, which would drop the exit code).
DRIFT_RC=0; DRIFT_OUT=""
drift_run() {
  local dir="$1"
  DRIFT_RC=0
  run_in "$dir" bash "$DRIFT" --dry-run --quiet > "$dir/drift.out" 2>/dev/null || DRIFT_RC=$?
  DRIFT_OUT=$(cat "$dir/drift.out")
}

set_issue() {
  local dir="$1" issue="$2" state="$3" reason="$4" status="$5" tmp="$1/board.json.tmp"
  jq --arg n "$issue" --arg state "$state" --arg reason "$reason" --arg status "$status" \
    '.issues[$n] = {state: $state, stateReason: (if $reason == "" then null else $reason end), status: $status}' \
    "$dir/board.json" > "$tmp" && mv "$tmp" "$dir/board.json"
}

board_status() { jq -r --arg n "$2" '.issues[$n].status' "$1/board.json"; }
option_id() { jq -r --arg name "$2" '.options[] | select(.name == $name) | .id' "$1/board.json"; }

# Write-class gh subcommands. item-edit on the Status field is the one write the chain is
# allowed to make; everything else here would change the board's shape or the Issue.
WRITE_RE='^gh (project (item-add|item-create|item-delete|field-create|field-delete|edit|create)|issue (edit|close|create|reopen)|api graphql .*mutation)'

# $1=shape $2=dir $3..$6 = display names of in_progress / in_review / done / todo
run_chain() {
  local shape="$1" dir="$2" ip="$3" ir="$4" dn="$5" td="$6"
  local marker res out ids expected_ids writes lines_before lines_after

  echo ""
  echo "[$shape] helper -> gate -> drift check"

  assert "$shape: issue starts on the todo column" "$td" "$(board_status "$dir" 42)"

  marker=$(gate_marker "$dir" 42 in_progress)
  case "$marker" in
    *"PROJECTS_STATUS_INVARIANT=missing;"*"role=todo;"*) pass "$shape: gate reports missing before any write (role=todo)" ;;
    *) fail "$shape: gate before write expected missing/role=todo, got: $marker" ;;
  esac

  res=$(helper_result "$dir" 42 in_progress)
  assert "$shape: helper in_progress -> updated" "updated" "$res"
  assert "$shape: board shows the in_progress column" "$ip" "$(board_status "$dir" 42)"
  marker=$(gate_marker "$dir" 42 in_progress)
  case "$marker" in
    *"PROJECTS_STATUS_INVARIANT=ok;"*"role=in_progress;"*) pass "$shape: gate ok after in_progress (role=in_progress)" ;;
    *) fail "$shape: gate after in_progress expected ok/role=in_progress, got: $marker" ;;
  esac

  res=$(helper_result "$dir" 42 in_review)
  assert "$shape: helper in_review -> updated" "updated" "$res"
  assert "$shape: board shows the in_review column" "$ir" "$(board_status "$dir" 42)"
  marker=$(gate_marker "$dir" 42 in_review)
  case "$marker" in
    *"PROJECTS_STATUS_INVARIANT=ok;"*"role=in_review;"*) pass "$shape: gate ok after in_review (role=in_review)" ;;
    *) fail "$shape: gate after in_review expected ok/role=in_review, got: $marker" ;;
  esac
  # in_progress is a lower rank than the reached in_review: still ok, not "missing".
  marker=$(gate_marker "$dir" 42 in_progress)
  case "$marker" in
    *"PROJECTS_STATUS_INVARIANT=ok;"*) pass "$shape: gate ranks in_review as having reached in_progress" ;;
    *) fail "$shape: gate expected ok for a lower expected role, got: $marker" ;;
  esac

  # The PR merged and GitHub closed the Issue while the board is still on in_review:
  # this is the drift the check exists for, and it proves the scan reads this board.
  set_issue "$dir" 42 CLOSED COMPLETED "$ir"
  lines_before=$(grep -cE "$WRITE_RE" "$dir/gh.log" || true)
  drift_run "$dir"; out="$DRIFT_OUT"
  if [ "$DRIFT_RC" -eq 1 ] && printf '%s\n' "$out" | grep -q '==> Total projects-board-drift findings: 1'; then
    pass "$shape: CLOSED COMPLETED on the in_review column is 1 drift finding (exit 1)"
  else
    fail "$shape: expected 1 finding / exit 1 before done, got rc=$DRIFT_RC: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
  fi
  lines_after=$(grep -cE "$WRITE_RE" "$dir/gh.log" || true)
  assert "$shape: --dry-run drift check issues no write" "$lines_before" "$lines_after"

  res=$(helper_result "$dir" 42 done)
  assert "$shape: helper done -> updated" "updated" "$res"
  assert "$shape: board shows the done column" "$dn" "$(board_status "$dir" 42)"
  marker=$(gate_marker "$dir" 42 done)
  case "$marker" in
    *"PROJECTS_STATUS_INVARIANT=ok;"*"role=done;"*) pass "$shape: gate ok after done (role=done)" ;;
    *) fail "$shape: gate after done expected ok/role=done, got: $marker" ;;
  esac
  drift_run "$dir"; out="$DRIFT_OUT"
  if [ "$DRIFT_RC" -eq 0 ] && printf '%s\n' "$out" | grep -q '==> Total projects-board-drift findings: 0'; then
    pass "$shape: done column is terminal -> 0 findings (exit 0)"
  else
    fail "$shape: expected 0 findings / exit 0 after done, got rc=$DRIFT_RC: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
  fi

  # The exact writes: three item-edits carrying the option ids of the three roles, in
  # transition order, and nothing that could alter the board's option set.
  ids=$(grep '^gh project item-edit' "$dir/gh.log" | sed 's/.*--single-select-option-id //' | tr '\n' ' ')
  expected_ids="$(option_id "$dir" "$ip") $(option_id "$dir" "$ir") $(option_id "$dir" "$dn") "
  assert "$shape: item-edit option ids are [in_progress, in_review, done] in order" "$expected_ids" "$ids"
  writes=$(grep -E "$WRITE_RE" "$dir/gh.log" || true)
  if [ -z "$writes" ]; then
    pass "$shape: no write other than item-edit reached gh (board option set untouched)"
  else
    fail "$shape: unexpected write subcommands in gh log: $(printf '%s' "$writes" | tr '\n' ' ' | head -c 200)"
  fi
  if grep -q '^gh project field-list' "$dir/gh.log"; then
    pass "$shape: gh log records the field-list reads (log wiring is live)"
  else
    fail "$shape: gh log has no field-list line — the shim was not on PATH"
  fi
}

ENGLISH_OPTS='[{"id":"OPT_TODO","name":"Todo"},{"id":"OPT_IP","name":"In Progress"},{"id":"OPT_IR","name":"In Review"},{"id":"OPT_DONE","name":"Done"},{"id":"OPT_CANCEL","name":"Cancelled"}]'

echo "=== T-01: legacy config on the English standard board ==="
make_board "$TEST_ROOT/legacy" 'github:
  projects:
    enabled: true
    project_number: 1' "Status" "$ENGLISH_OPTS"
run_chain legacy "$TEST_ROOT/legacy" "In Progress" "In Review" "Done" "Todo"

echo ""
echo "=== T-01b: explicit roles on the English standard board ==="
make_board "$TEST_ROOT/english" 'github:
  projects:
    enabled: true
    project_number: 1
    fields:
      status:
        options:
          - { role: todo, name: "Todo" }
          - { role: in_progress, name: "In Progress" }
          - { role: in_review, name: "In Review" }
          - { role: done, name: "Done" }
          - { role: cancelled, name: "Cancelled" }' "Status" "$ENGLISH_OPTS"
run_chain english "$TEST_ROOT/english" "In Progress" "In Review" "Done" "Todo"

echo ""
echo "=== T-02: To-Do / In progress board ==="
make_board "$TEST_ROOT/todo" 'github:
  projects:
    enabled: true
    project_number: 1
    fields:
      status:
        options:
          - { role: todo, name: "To-Do" }
          - { role: in_progress, name: "In progress" }
          - { role: in_review, name: "In Review" }
          - { role: done, name: "Done" }
          - { role: cancelled, name: "Cancelled" }' "Status" \
  '[{"id":"OPT_TODO","name":"To-Do"},{"id":"OPT_IP","name":"In progress"},{"id":"OPT_IR","name":"In Review"},{"id":"OPT_DONE","name":"Done"},{"id":"OPT_CANCEL","name":"Cancelled"}]'
run_chain todo "$TEST_ROOT/todo" "In progress" "In Review" "Done" "To-Do"

echo ""
echo "=== T-03: Japanese field name and Japanese columns ==="
make_board "$TEST_ROOT/japanese" 'github:
  projects:
    enabled: true
    project_number: 1
    fields:
      status:
        name: "ステータス"
        options:
          - { role: todo, name: "未着手" }
          - { role: in_progress, name: "進行中" }
          - { role: in_review, name: "レビュー中" }
          - { role: done, name: "完了" }
          - { role: cancelled, name: "中止" }' "ステータス" \
  '[{"id":"OPT_TODO","name":"未着手"},{"id":"OPT_IP","name":"進行中"},{"id":"OPT_IR","name":"レビュー中"},{"id":"OPT_DONE","name":"完了"},{"id":"OPT_CANCEL","name":"中止"}]'
run_chain japanese "$TEST_ROOT/japanese" "進行中" "レビュー中" "完了" "未着手"

echo ""
echo "=== T-04: board with no cancelled column ==="
make_board "$TEST_ROOT/nocancel" 'github:
  projects:
    enabled: true
    project_number: 1
    fields:
      status:
        options:
          - { role: todo, name: "Todo" }
          - { role: in_progress, name: "In Progress" }
          - { role: in_review, name: "In Review" }
          - { role: done, name: "Done" }' "Status" \
  '[{"id":"OPT_TODO","name":"Todo"},{"id":"OPT_IP","name":"In Progress"},{"id":"OPT_IR","name":"In Review"},{"id":"OPT_DONE","name":"Done"}]'
run_chain nocancel "$TEST_ROOT/nocancel" "In Progress" "In Review" "Done" "Todo"

# An abandoned Issue on this board: closed as not planned while still in progress.
set_issue "$TEST_ROOT/nocancel" 43 CLOSED NOT_PLANNED "In Progress"
edits_before=$(grep -c '^gh project item-edit' "$TEST_ROOT/nocancel/gh.log" || true)
res=$(helper_result "$TEST_ROOT/nocancel" 43 cancelled)
assert "nocancel: helper cancelled -> skipped_role_unmapped" "skipped_role_unmapped" "$res"
edits_after=$(grep -c '^gh project item-edit' "$TEST_ROOT/nocancel/gh.log" || true)
assert "nocancel: skipped_role_unmapped writes nothing" "$edits_before" "$edits_after"
assert "nocancel: the abandoned Issue keeps its column" "In Progress" "$(board_status "$TEST_ROOT/nocancel" 43)"
drift_run "$TEST_ROOT/nocancel"; out="$DRIFT_OUT"
if [ "$DRIFT_RC" -eq 0 ] && printf '%s\n' "$out" | grep -q '==> Total projects-board-drift findings: 0'; then
  pass "nocancel: NOT_PLANNED Issue is not counted as drift (0 findings, exit 0)"
else
  fail "nocancel: expected 0 findings / exit 0, got rc=$DRIFT_RC: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
fi
if printf '%s\n' "$out" | grep -q '^\[projects-board-drift\] info #43 .*no cancelled column is configured'; then # drift-check-ignore
  pass "nocancel: the abandoned Issue is listed as informational"
else
  fail "nocancel: informational line for the abandoned Issue missing: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
fi
# The done closure guard still holds without a cancelled column.
res=$(helper_result "$TEST_ROOT/nocancel" 43 done)
assert "nocancel: done write to a NOT_PLANNED Issue is refused" "skipped_terminal_conflict" "$res"
assert "nocancel: the refused write leaves the column unchanged" "In Progress" "$(board_status "$TEST_ROOT/nocancel" 43)"

# ---------------------------------------------------------------------------
# Static pins on the documentation
# ---------------------------------------------------------------------------
echo ""
echo "=== T-06: no Target document defines the Status set by English display names ==="
# One arm per shape of the old wording. Each is a definition or destination written as a
# display name; mentions of a column name as an example are not matched.
SOT_ARMS=(
  'copy these two names'
  'read by no consumer'
  'five-option union'
  '→ `Cancelled`'
  '→ `Done`'
  'terminal Status set \(`Done` / `Cancelled`\)'
  '^\| `(Done|Cancelled)` \| Work'
  'Update Status to the terminal Status (`Done`|"Done")'
)
TARGET_DOCS=(
  "$REPO_ROOT/plugins/rite/references/projects-integration.md"
  "$REPO_ROOT/docs/CONFIGURATION.md"
  "$REPO_ROOT/docs/SPEC.md"
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/README.ja.md"
  "$REPO_ROOT/plugins/rite/templates/README.md"
  "$REPO_ROOT/plugins/rite/skills/getting-started/SKILL.md"
  "$REPO_ROOT/plugins/rite/skills/lint/references/plugin-checks-rationale.md"
)
sot_hits() { local file="$1" arm; for arm in "${SOT_ARMS[@]}"; do grep -nE -- "$arm" "$file" 2>/dev/null | sed "s|^|${file#"$REPO_ROOT/"}:|"; done; }
fixture="$TEST_ROOT/sot-fixture.md"
cat > "$fixture" <<'FIX'
The consumers listed below copy these two names from here.
`fields.status.options` in `rite-config.yml` is read by no consumer.
`/rite:setup` provisions the five-option union including `Cancelled`.
`NOT_PLANNED` / `DUPLICATE` → `Cancelled` with no WARNING
`COMPLETED` → `Done` with no WARNING
outside the terminal Status set (`Done` / `Cancelled`)
| `Cancelled` | Work abandoned | `NOT_PLANNED` |
3. Update Status to the terminal Status "Done"
FIX
hits=$(sot_hits "$fixture" | wc -l | tr -d ' ')
if [ "$hits" -ge "${#SOT_ARMS[@]}" ]; then
  pass "T-06 positive control: the grammar detects each of the ${#SOT_ARMS[@]} wording shapes ($hits hits)"
else
  fail "T-06 positive control: grammar detected only $hits of ${#SOT_ARMS[@]} shapes: $(sot_hits "$fixture" | tr '\n' ' ')"
fi
findings=""
for doc in "${TARGET_DOCS[@]}"; do
  [ -f "$doc" ] || { fail "T-06: Target document missing: ${doc#"$REPO_ROOT/"}"; continue; }
  hit=$(sot_hits "$doc"); [ -n "$hit" ] && findings="${findings}${hit}"$'\n'
done
if [ -z "$findings" ]; then
  pass "T-06: no Target document keeps an English-display-name definition of the Status set"
else
  fail "T-06: English display names still define the Status set:"$'\n'"$findings"
fi
SOT="$REPO_ROOT/plugins/rite/references/projects-integration.md"
sot_248=$(awk '/^### 2\.4\.8 Terminal Status Set$/,/^## 2\.5 /' "$SOT")
for needle in '| `done` | Work completed | `COMPLETED` |' \
              '| `cancelled` | Work abandoned' \
              '`todo` < `in_progress` < `in_review` < `done`' \
              '`cancelled` has no position in this order' \
              'lands on `done` **with a WARNING**' \
              'skipped_role_unmapped'; do
  if printf '%s\n' "$sot_248" | grep -qF -- "$needle"; then
    pass "T-06: §2.4.8 states: $needle"
  else
    fail "T-06: §2.4.8 lacks: $needle"
  fi
done

echo ""
echo "=== T-07: README.md / README.ja.md keep the Status Transitions section in sync ==="
fence_after() { awk -v h="$2" '$0 == h {f=1; next} f && /^```/ {c++; if (c==2) exit; next} f && c==1 {print}' "$1"; }
para_after() { awk -v h="$2" '$0 == h {f=1; next} f && /^```/ {c++; next} f && c==2 && NF {print; exit}' "$1"; }
en_fence=$(fence_after "$REPO_ROOT/README.md" 'Status Transitions:')
ja_fence=$(fence_after "$REPO_ROOT/README.ja.md" 'ステータス遷移:')
if [ -n "$en_fence" ] && [ "$en_fence" = "$ja_fence" ]; then
  pass "T-07: the Status Transitions fence is byte-identical in both READMEs"
else
  fail "T-07: Status Transitions fences differ or are missing (en=$(printf '%s' "$en_fence" | head -c 80) ja=$(printf '%s' "$ja_fence" | head -c 80))"
fi
if printf '%s\n' "$en_fence" | grep -q 'todo → in_progress → in_review → done'; then
  pass "T-07: the fence lists the roles, not the English column names"
else
  fail "T-07: the fence does not list the roles: $(printf '%s' "$en_fence" | head -c 120)"
fi
for pair in "README.md|Status Transitions:" "README.ja.md|ステータス遷移:"; do
  file="${pair%%|*}"; heading="${pair#*|}"
  para=$(para_after "$REPO_ROOT/$file" "$heading")
  for token in 'rite-config.yml' 'fields.status.options' 'cancelled'; do
    if printf '%s\n' "$para" | grep -qF -- "$token"; then
      pass "T-07: $file paragraph after the fence mentions $token"
    else
      fail "T-07: $file paragraph after the fence lacks $token"
    fi
  done
done

echo ""
echo "=== T-08: docs/CONFIGURATION.md shows the four board shapes and the three states ==="
cfg_section=$(awk '/^### github\.projects\.fields$/ {f=1} f && /^### / && !/github\.projects\.fields/ {exit} f {print}' "$REPO_ROOT/docs/CONFIGURATION.md")
# Split the section's yaml fences into files and keep those that map roles.
blocks_dir="$TEST_ROOT/cfg-blocks"; mkdir -p "$blocks_dir"
printf '%s\n' "$cfg_section" | awk -v dir="$blocks_dir" '
  /^```yaml/ {n++; f=1; next} /^```/ {f=0; next} f {print > (dir "/" n ".yaml")}'
role_blocks=0; nocancel_blocks=0; name_sets=""
for b in "$blocks_dir"/*.yaml; do
  [ -f "$b" ] || continue
  grep -q 'role: todo' "$b" || continue
  role_blocks=$((role_blocks + 1))
  grep -q 'role: cancelled' "$b" || nocancel_blocks=$((nocancel_blocks + 1))
  name_sets="${name_sets}$(grep -oE 'name: "[^"]+"' "$b" | tr '\n' ',')"$'\n'
done
assert "T-08: four role-mapped yaml examples in github.projects.fields" "4" "$role_blocks"
assert "T-08: exactly one example omits the cancelled row" "1" "$nocancel_blocks"
distinct=$(printf '%s' "$name_sets" | sort -u | grep -c . || true)
assert "T-08: the four examples carry four different name sets" "4" "$distinct"
if printf '%s\n' "$name_sets" | grep -q 'name: "To-Do",name: "In progress"'; then
  pass "T-08: a To-Do / In progress example is present"
else
  fail "T-08: no To-Do / In progress example"
fi
if printf '%s\n' "$name_sets" | grep -q 'name: "ステータス",name: "未着手"'; then
  pass "T-08: a Japanese field-name + Japanese column example is present"
else
  fail "T-08: no Japanese example"
fi
for state in legacy explicit invalid; do
  if printf '%s\n' "$cfg_section" | grep -qE "^\| \*\*$state\*\* \|"; then
    pass "T-08: the $state state has a row in the three-state table"
  else
    fail "T-08: no $state row in the three-state table"
  fi
done
if printf '%s\n' "$cfg_section" | grep -qF 'leaves its board Status unchanged'; then
  pass "T-08: the cancelled-omitted behavior is stated"
else
  fail "T-08: the cancelled-omitted behavior is not stated"
fi

if ! print_summary "$(basename "$0")" "Status roles are the contract: helper / gate / drift check must agree on every board shape through rite-config.yml, and the documents must define the set by role, never by English column name"; then
  exit 1
fi
