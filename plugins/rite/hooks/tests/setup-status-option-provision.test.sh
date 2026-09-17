#!/usr/bin/env bash
# setup の新規 Project provisioning、既存 Project 検証、role 設定移行。
# SKILL.md から bash を抽出して実行する（コピーは SKILL.md との drift を生む）。
# 抽出失敗は skip せず exit 1（CI が緑のまま残らないようにする）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

SKILL="$SCRIPT_DIR/../../skills/setup/SKILL.md"
PLUGIN_ROOT="$SCRIPT_DIR/../.."
assert_file_exists_or_fail "setup/SKILL.md exists" "$SKILL" || {
  print_summary "$(basename "$0")" "setup SKILL.md missing" || exit 1
  exit 1
}

extract_marked_bash() {
  awk -v marker="$1" '
    /^```bash$/ { fence=1; buf=""; next }
    fence && /^```$/ {
      if (buf ~ marker) { printf "%s", buf; found=1; exit }
      fence=0; buf=""
      next
    }
    fence { buf = buf $0 "\n" }
    END { if (!found && buf ~ marker) printf "%s", buf }
  ' "$SKILL"
}

SNIPPET_RAW=$(extract_marked_bash STATUS_OPTION_UNION_PROVISION)
if ! printf '%s' "$SNIPPET_RAW" | grep -c >/dev/null 'STATUS_OPTION_UNION_PROVISION'; then
  echo "FAIL: SKILL.md からの STATUS_OPTION_UNION_PROVISION block 抽出に失敗しました" >&2
  echo "  抽出結果: $(printf '%s' "$SNIPPET_RAW" | wc -l) 行" >&2
  exit 1
fi
VERIFY_RAW=$(extract_marked_bash STATUS_OPTION_EXISTING_VERIFY)
MIGRATION_RAW=$(extract_marked_bash STATUS_OPTIONS_ROLE_MIGRATION)
BACKUP_RAW=$(extract_marked_bash STATUS_OPTIONS_UPGRADE_BACKUP)
COMMIT_RAW=$(extract_marked_bash STATUS_OPTION_EXISTING_CONFIG_COMMIT)
CANDIDATE_RAW=$(extract_marked_bash STATUS_OPTION_CONFIG_CANDIDATE_CREATE)
for marker in STATUS_OPTION_EXISTING_VERIFY STATUS_OPTIONS_ROLE_MIGRATION STATUS_OPTIONS_UPGRADE_BACKUP STATUS_OPTION_EXISTING_CONFIG_COMMIT STATUS_OPTION_CONFIG_CANDIDATE_CREATE; do
  raw_var=VERIFY_RAW; [ "$marker" = STATUS_OPTIONS_ROLE_MIGRATION ] && raw_var=MIGRATION_RAW
  [ "$marker" = STATUS_OPTIONS_UPGRADE_BACKUP ] && raw_var=BACKUP_RAW
  [ "$marker" = STATUS_OPTION_EXISTING_CONFIG_COMMIT ] && raw_var=COMMIT_RAW
  [ "$marker" = STATUS_OPTION_CONFIG_CANDIDATE_CREATE ] && raw_var=CANDIDATE_RAW
  if ! printf '%s' "${!raw_var}" | grep -c >/dev/null "$marker"; then
    echo "FAIL: SKILL.md からの $marker block 抽出に失敗しました" >&2
    exit 1
  fi
done

WORKDIR=$(make_plain_sandbox)
MOCKBIN="$WORKDIR/bin"
mkdir -p "$MOCKBIN"
SNIPPET="$WORKDIR/provision.sh"
printf '%s' "$SNIPPET_RAW" | sed -e 's/{owner}/test-owner/g' -e 's/{project-number}/11/g' > "$SNIPPET"
VERIFY="$WORKDIR/verify.sh"
printf '%s' "$VERIFY_RAW" | sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" -e 's/{owner}/test-owner/g' -e 's/{project-number}/11/g' > "$VERIFY"
MIGRATION="$WORKDIR/migrate.sh"
printf '%s' "$MIGRATION_RAW" | sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" > "$MIGRATION"
BACKUP="$WORKDIR/backup.sh"
printf '%s' "$BACKUP_RAW" > "$BACKUP"
COMMIT="$WORKDIR/commit-config.sh"
printf '%s' "$COMMIT_RAW" | sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" > "$COMMIT"
CANDIDATE_CREATE="$WORKDIR/candidate-create.sh"
printf '%s' "$CANDIDATE_RAW" > "$CANDIDATE_CREATE"

cat > "$MOCKBIN/gh" <<'MOCK'
#!/usr/bin/env bash
set -u
logdir="${MOCK_GH_DIR:?}"
printf '%s\n' "$*" >> "$logdir/calls"
if [ "${1:-}" = "project" ] && [ "${2:-}" = "field-list" ]; then
  if [ "${MOCK_GH_FIELD_LIST_FAIL:-}" = "1" ]; then
    echo "error: field-list failed" >&2
    exit 1
  fi
  cat "$logdir/field-list.json"
  exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  has_input=0
  for a in "$@"; do
    [ "$a" = "--input" ] && has_input=1
  done
  if [ "$has_input" = "1" ]; then
    cat > "$logdir/mutation.json"
    echo mutation >> "$logdir/kinds"
    if [ "${MOCK_GH_MUTATION_FAIL:-}" = "1" ]; then
      echo "error: mutation failed" >&2
      exit 1
    fi
    printf '%s\n' '{"data":{"updateProjectV2Field":{"projectV2Field":{"name":"Status"}}}}'
    exit 0
  fi
  echo query >> "$logdir/kinds"
  if [ "${MOCK_GH_QUERY_FAIL:-}" = "1" ]; then
    echo "error: options query failed" >&2
    exit 1
  fi
  cat "$logdir/options.json"
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 99
MOCK
chmod +x "$MOCKBIN/gh"

status_field_list='{"fields":[{"id":"FIELD_STATUS","name":"Status"}]}'
no_status_field_list='{"fields":[{"id":"FIELD_PRIO","name":"Priority"}]}'

opt4='{"data":{"node":{"options":[
  {"id":"ID_TODO","name":"Todo","color":"GRAY","description":"Not started"},
  {"id":"ID_IP","name":"In Progress","color":"YELLOW","description":"Work in progress"},
  {"id":"ID_IR","name":"In Review","color":"BLUE","description":"Under review"},
  {"id":"ID_DONE","name":"Done","color":"GREEN","description":"Completed"}
]}}}'

opt3='{"data":{"node":{"options":[
  {"id":"ID_TODO","name":"Todo","color":"GRAY","description":"Not started"},
  {"id":"ID_IP","name":"In Progress","color":"YELLOW","description":"Work in progress"},
  {"id":"ID_DONE","name":"Done","color":"GREEN","description":"Completed"}
]}}}'

opt4_custom='{"data":{"node":{"options":[
  {"id":"ID_TODO","name":"Todo","color":"GRAY","description":"Not started"},
  {"id":"ID_IP","name":"In Progress","color":"YELLOW","description":"Work in progress"},
  {"id":"ID_IR","name":"In Review","color":"BLUE","description":"Under review"},
  {"id":"ID_DONE","name":"Done","color":"GREEN","description":"Completed"},
  {"id":"ID_BLOCKED","name":"Blocked","color":"RED","description":"Waiting"}
]}}}'

opt5='{"data":{"node":{"options":[
  {"id":"ID_TODO","name":"Todo","color":"GRAY","description":"Not started"},
  {"id":"ID_IP","name":"In Progress","color":"YELLOW","description":"Work in progress"},
  {"id":"ID_IR","name":"In Review","color":"BLUE","description":"Under review"},
  {"id":"ID_DONE","name":"Done","color":"GREEN","description":"Completed"},
  {"id":"ID_CANC","name":"Cancelled","color":"GRAY","description":"Cancelled (not planned)"}
]}}}'

mutation_count() {
  if [ -f "$1/kinds" ]; then
    grep -c '^mutation$' "$1/kinds" || true
  else
    echo 0
  fi
}

migration_mode() {
  (
    cd "$1" || exit 1
    source "$PLUGIN_ROOT/hooks/scripts/lib/projects-status-config.sh"
    projects_status_mode
  )
}

echo "=== T-routing: new / existing の排他的経路を固定 ==="
assert_grep "T-routing selection retained" "$SKILL" 'project_selection=new|existing'
assert_grep "T-routing new enters provisioning" "$SKILL" 'project_selection=new.*3\.3\.6'
assert_grep "T-routing existing enters verification" "$SKILL" 'project_selection=existing.*3\.4'
assert_grep "T-routing provisioning is new-only" "$SKILL" 'project_selection=new.*ときだけ実行'
assert_grep "T-routing verification is existing-only" "$SKILL" 'project_selection=existing.*ときだけ実行'
assert_grep "T-routing final config is reverified" "$SKILL" 'candidate directory.*STATUS_OPTION_EXISTING_VERIFY'
assert_grep "T-routing preview names role migration" "$SKILL" 'Status role migration: \{status_role_migration_status\}'
assert_grep "T-routing existing writes candidate first" "$SKILL" 'project_selection=existing.*下記 block を実行'
assert_grep "T-routing failed candidate preserves root" "$SKILL" 'project root の既存 config は変更しない'

echo "=== T-static-cancelled: 新規 Project provisioning の required 5 組 ==="
assert_grep_in_section "T-static Todo/GRAY/Not started" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^### 3.4' \
  '"name":"Todo","color":"GRAY","description":"Not started"'
assert_grep_in_section "T-static In Progress/YELLOW" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^### 3.4' \
  '"name":"In Progress","color":"YELLOW","description":"Work in progress"'
assert_grep_in_section "T-static In Review/BLUE" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^### 3.4' \
  '"name":"In Review","color":"BLUE","description":"Under review"'
assert_grep_in_section "T-static Done/GREEN" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^### 3.4' \
  '"name":"Done","color":"GREEN","description":"Completed"'
assert_grep_in_section "T-static Cancelled/GRAY" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^### 3.4' \
  '"name":"Cancelled","color":"GRAY","description":"Cancelled \(not planned\)"'

echo "=== T-no-replace-fallback: 旧 id 無し 4 要素 GraphQL 全置換フェンスが無い ==="
assert_not_grep "T-no-replace-fallback no Todo GRAY GraphQL literal" "$SKILL" \
  '\{name: "Todo", color: GRAY, description: "Not started"\}'
assert_not_grep "T-no-replace-fallback no In Review gating heading" "$SKILL" \
  'If the Status field does not have "In Review"'

echo "=== T-read-fail: field-list 非0 / options query 非0 / JSON 不正 / Status field 不在 → mutation 0 かつ 非0 ==="
# field-list fail
d_flfail="$WORKDIR/flfail"
mkdir -p "$d_flfail"
printf '%s\n' "$status_field_list" > "$d_flfail/field-list.json"
printf '%s\n' "$opt4" > "$d_flfail/options.json"
rc=$(MOCK_GH_DIR="$d_flfail" MOCK_GH_FIELD_LIST_FAIL=1 PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_flfail/stdout" 2>"$d_flfail/stderr" && echo 0 || echo $?)
assert "T-read-fail field-list exits non-zero" "1" "$rc"
assert "T-read-fail field-list issues no mutation" "0" "$(mutation_count "$d_flfail")"

# query fail
d_qfail="$WORKDIR/qfail"
mkdir -p "$d_qfail"
printf '%s\n' "$status_field_list" > "$d_qfail/field-list.json"
printf '%s\n' "$opt4" > "$d_qfail/options.json"
rc=$(MOCK_GH_DIR="$d_qfail" MOCK_GH_QUERY_FAIL=1 PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_qfail/stdout" 2>"$d_qfail/stderr" && echo 0 || echo $?)
assert "T-read-fail query non-zero exits non-zero" "1" "$rc"
assert "T-read-fail query issues no mutation" "0" "$(mutation_count "$d_qfail")"

# JSON invalid
d_badjson="$WORKDIR/badjson"
mkdir -p "$d_badjson"
printf '%s\n' "$status_field_list" > "$d_badjson/field-list.json"
printf '%s\n' 'not-json' > "$d_badjson/options.json"
rc=$(MOCK_GH_DIR="$d_badjson" PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_badjson/stdout" 2>"$d_badjson/stderr" && echo 0 || echo $?)
assert "T-read-fail invalid JSON exits non-zero" "1" "$rc"
assert "T-read-fail invalid JSON issues no mutation" "0" "$(mutation_count "$d_badjson")"

# Status field missing
d_nostatus="$WORKDIR/nostatus"
mkdir -p "$d_nostatus"
printf '%s\n' "$no_status_field_list" > "$d_nostatus/field-list.json"
printf '%s\n' "$opt4" > "$d_nostatus/options.json"
rc=$(MOCK_GH_DIR="$d_nostatus" PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_nostatus/stdout" 2>"$d_nostatus/stderr" && echo 0 || echo $?)
assert "T-read-fail missing Status field exits non-zero" "1" "$rc"
assert "T-read-fail missing Status field issues no mutation" "0" "$(mutation_count "$d_nostatus")"

# mutation itself fails
d_mutfail="$WORKDIR/mutfail"
mkdir -p "$d_mutfail"
printf '%s\n' "$status_field_list" > "$d_mutfail/field-list.json"
printf '%s\n' "$opt4" > "$d_mutfail/options.json"
rc=$(MOCK_GH_DIR="$d_mutfail" MOCK_GH_MUTATION_FAIL=1 PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_mutfail/stdout" 2>"$d_mutfail/stderr" && echo 0 || echo $?)
assert "T-mutation-fail exits non-zero" "1" "$rc"
assert "T-mutation-fail attempted mutation once" "1" "$(mutation_count "$d_mutfail")"

echo "=== T-happy-add: 既存 4 option → mutation 1、要素単位で id 保持 + Cancelled は id 無し ==="
d_happy="$WORKDIR/happy"
mkdir -p "$d_happy"
printf '%s\n' "$status_field_list" > "$d_happy/field-list.json"
printf '%s\n' "$opt4" > "$d_happy/options.json"
rc=$(MOCK_GH_DIR="$d_happy" PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_happy/stdout" 2>"$d_happy/stderr" && echo 0 || echo $?)
assert "T-happy-add exits 0" "0" "$rc"
assert "T-happy-add mutation once" "1" "$(mutation_count "$d_happy")"
opts=$(jq '.variables.input.singleSelectOptions' "$d_happy/mutation.json")
assert "T-happy-add five options" "5" "$(printf '%s' "$opts" | jq 'length')"
if printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_TODO" and .name=="Todo" and .color=="GRAY" and .description=="Not started")' >/dev/null \
  && printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_IP" and .name=="In Progress" and .color=="YELLOW" and .description=="Work in progress")' >/dev/null \
  && printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_IR" and .name=="In Review" and .color=="BLUE" and .description=="Under review")' >/dev/null \
  && printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_DONE" and .name=="Done" and .color=="GREEN" and .description=="Completed")' >/dev/null; then
  pass "T-happy-add existing four kept as same objects (id/name/color/description)"
else
  fail "T-happy-add existing four not preserved as same objects: $opts"
fi
if printf '%s' "$opts" | jq -e '.[] | select(.name=="Cancelled" and .color=="GRAY" and .description=="Cancelled (not planned)" and (has("id")|not))' >/dev/null; then
  pass "T-happy-add Cancelled added without id"
else
  fail "T-happy-add Cancelled must be id-less object: $opts"
fi

echo "=== T-in-review-missing: 既存 3 (In Review なし) → In Review と Cancelled を id 無しで同時追加 ==="
d_ir="$WORKDIR/inreview-missing"
mkdir -p "$d_ir"
printf '%s\n' "$status_field_list" > "$d_ir/field-list.json"
printf '%s\n' "$opt3" > "$d_ir/options.json"
rc=$(MOCK_GH_DIR="$d_ir" PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_ir/stdout" 2>"$d_ir/stderr" && echo 0 || echo $?)
assert "T-in-review-missing exits 0" "0" "$rc"
assert "T-in-review-missing mutation once" "1" "$(mutation_count "$d_ir")"
opts=$(jq '.variables.input.singleSelectOptions' "$d_ir/mutation.json")
assert "T-in-review-missing five options" "5" "$(printf '%s' "$opts" | jq 'length')"
if printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_TODO" and .name=="Todo")' >/dev/null \
  && printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_IP" and .name=="In Progress")' >/dev/null \
  && printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_DONE" and .name=="Done")' >/dev/null; then
  pass "T-in-review-missing existing three kept with ids"
else
  fail "T-in-review-missing existing three not kept with ids: $opts"
fi
if printf '%s' "$opts" | jq -e '.[] | select(.name=="In Review" and .color=="BLUE" and (has("id")|not))' >/dev/null \
  && printf '%s' "$opts" | jq -e '.[] | select(.name=="Cancelled" and (has("id")|not))' >/dev/null; then
  pass "T-in-review-missing adds In Review and Cancelled without id"
else
  fail "T-in-review-missing In Review/Cancelled must be id-less: $opts"
fi

echo "=== T-union-custom: Blocked の id が mutation payload に残り、Cancelled を id 無しで足す ==="
d_custom="$WORKDIR/custom"
mkdir -p "$d_custom"
printf '%s\n' "$status_field_list" > "$d_custom/field-list.json"
printf '%s\n' "$opt4_custom" > "$d_custom/options.json"
rc=$(MOCK_GH_DIR="$d_custom" PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_custom/stdout" 2>"$d_custom/stderr" && echo 0 || echo $?)
assert "T-union-custom exits 0" "0" "$rc"
opts=$(jq '.variables.input.singleSelectOptions' "$d_custom/mutation.json")
assert "T-union-custom six options" "6" "$(printf '%s' "$opts" | jq 'length')"
if printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_BLOCKED" and .name=="Blocked" and .color=="RED" and .description=="Waiting")' >/dev/null; then
  pass "T-union-custom Blocked kept as same object"
else
  fail "T-union-custom Blocked not preserved: $opts"
fi
if printf '%s' "$opts" | jq -e '.[] | select(.name=="Cancelled" and .color=="GRAY" and .description=="Cancelled (not planned)" and (has("id")|not))' >/dev/null; then
  pass "T-union-custom Cancelled added without id"
else
  fail "T-union-custom Cancelled must be id-less object: $opts"
fi

echo "=== T-idempotent: 既存 5 option → mutation 0 かつ exit 0 ==="
d_noop="$WORKDIR/noop"
mkdir -p "$d_noop"
printf '%s\n' "$status_field_list" > "$d_noop/field-list.json"
printf '%s\n' "$opt5" > "$d_noop/options.json"
rc=$(MOCK_GH_DIR="$d_noop" PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_noop/stdout" 2>"$d_noop/stderr" && echo 0 || echo $?)
assert "T-idempotent exits 0" "0" "$rc"
assert "T-idempotent mutation zero" "0" "$(mutation_count "$d_noop")"
if grep -q 'STATUS_OPTIONS_PROVISION=noop' "$d_noop/stdout"; then
  pass "T-idempotent emits noop marker"
else
  fail "T-idempotent missing noop marker: $(cat "$d_noop/stdout")"
fi

echo "=== T-existing-verify: explicit 4 role の既存 Project は検証のみ、schema mutation 0 ==="
d_verify="$WORKDIR/verify-ok"
mkdir -p "$d_verify"
printf '%s\n' "$status_field_list" > "$d_verify/field-list.json"
printf '%s\n' '{"data":{"node":{"options":[{"name":"To-Do"},{"name":"In progress"},{"name":"In Review"},{"name":"Done"}]}}}' > "$d_verify/options.json"
cat > "$d_verify/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { role: todo, name: "To-Do" }
          - { role: in_progress, name: "In progress" }
          - { role: in_review, name: "In Review" }
          - { role: done, name: "Done" }
YAML
rc=$(cd "$d_verify" && MOCK_GH_DIR="$d_verify" PATH="$MOCKBIN:$PATH" bash "$VERIFY" >stdout 2>stderr && echo 0 || echo $?)
assert "T-existing-verify exits 0" "0" "$rc"
assert "T-existing-verify mutation zero" "0" "$(mutation_count "$d_verify")"
assert "T-existing-verify field-create zero" "0" "$(grep -c 'project field-create' "$d_verify/calls" || true)"
assert_grep "T-existing-verify emits ok" "$d_verify/stdout" 'STATUS_OPTIONS_VERIFY=ok'

echo "=== T-existing-missing: 不足名と実 option 一覧を出して変更せず停止 ==="
d_missing="$WORKDIR/verify-missing"
mkdir -p "$d_missing"
printf '%s\n' "$status_field_list" > "$d_missing/field-list.json"
printf '%s\n' '{"data":{"node":{"options":[{"name":"Todo"},{"name":"In Progress"},{"name":"In Review"},{"name":"Done"}]}}}' > "$d_missing/options.json"
cat > "$d_missing/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { role: todo, name: "Todo" }
          - { role: in_progress, name: "In Progress" }
          - { role: in_review, name: "Review" }
          - { role: done, name: "Done" }
YAML
rc=$(cd "$d_missing" && MOCK_GH_DIR="$d_missing" PATH="$MOCKBIN:$PATH" bash "$VERIFY" >stdout 2>stderr && echo 0 || echo $?)
assert "T-existing-missing exits non-zero" "1" "$rc"
assert "T-existing-missing mutation zero" "0" "$(mutation_count "$d_missing")"
assert_grep "T-existing-missing marker includes missing Review" "$d_missing/stdout" 'STATUS_OPTIONS_VERIFY=error; missing=\["Review"\]'
assert_grep "T-existing-missing marker includes available names" "$d_missing/stdout" 'available=\["Todo","In Progress","In Review","Done"\]'

echo "=== T-existing-legacy-no-cancelled: 未生成 config は標準5 role、2案を表示 ==="
d_legacy_verify="$WORKDIR/verify-legacy"
mkdir -p "$d_legacy_verify"
printf '%s\n' "$status_field_list" > "$d_legacy_verify/field-list.json"
printf '%s\n' "$opt4" > "$d_legacy_verify/options.json"
rc=$(cd "$d_legacy_verify" && MOCK_GH_DIR="$d_legacy_verify" PATH="$MOCKBIN:$PATH" bash "$VERIFY" >stdout 2>stderr && echo 0 || echo $?)
assert "T-existing-legacy-no-cancelled exits non-zero" "1" "$rc"
assert "T-existing-legacy-no-cancelled mutation zero" "0" "$(mutation_count "$d_legacy_verify")"
assert_grep "T-existing-legacy-no-cancelled suggests board column" "$d_legacy_verify/stderr" 'Cancelled を追加'
assert_grep "T-existing-legacy-no-cancelled suggests explicit config" "$d_legacy_verify/stderr" 'cancelled を省略した explicit role 設定'

echo "=== T-existing-nested-cwd: repository root の explicit config を使う ==="
d_nested="$WORKDIR/verify-nested/repo"
mkdir -p "$d_nested/sub"
git -C "$d_nested" init -q
printf '%s\n' "$status_field_list" > "$d_nested/field-list.json"
printf '%s\n' '{"data":{"node":{"options":[{"name":"To-Do"},{"name":"In progress"},{"name":"In Review"},{"name":"Done"}]}}}' > "$d_nested/options.json"
cat > "$d_nested/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { role: todo, name: "To-Do" }
          - { role: in_progress, name: "In progress" }
          - { role: in_review, name: "In Review" }
          - { role: done, name: "Done" }
YAML
rc=$(cd "$d_nested/sub" && MOCK_GH_DIR="$d_nested" PATH="$MOCKBIN:$PATH" bash "$VERIFY" >"$d_nested/stdout" 2>"$d_nested/stderr" && echo 0 || echo $?)
assert "T-existing-nested-cwd exits 0" "0" "$rc"
assert_grep "T-existing-nested-cwd uses custom names" "$d_nested/stdout" 'STATUS_OPTIONS_VERIFY=ok'
assert "T-existing-nested-cwd mutation zero" "0" "$(mutation_count "$d_nested")"
assert "T-existing-nested-cwd creates no nested config" "0" "$([ -e "$d_nested/sub/rite-config.yml" ] && echo 1 || echo 0)"

echo "=== T-existing-candidate: 不一致候補は root を不変にし、一致候補だけ原子的に反映 ==="
root_before=$(cksum "$d_nested/rite-config.yml")
mkdir -p "$d_nested/.tmp"
rc=$(cd "$d_nested" && TMPDIR=.tmp bash "$CANDIDATE_CREATE" >candidate-create-bad-stdout 2>candidate-create-bad-stderr && echo 0 || echo $?)
assert "T-existing-candidate relative TMPDIR create exits 0" "0" "$rc"
candidate_bad=$(sed -n 's/.*RITE_SETUP_CONFIG_CANDIDATE=//p' "$d_nested/candidate-create-bad-stdout")
project_root_marker=$(sed -n 's/.*RITE_SETUP_PROJECT_ROOT=\([^;]*\);.*/\1/p' "$d_nested/candidate-create-bad-stdout")
d_candidate_bad=${candidate_bad%/*}
assert_grep "T-existing-candidate relative TMPDIR becomes absolute" "$d_nested/candidate-create-bad-stdout" 'RITE_SETUP_CONFIG_CANDIDATE=/'
cat > "$d_candidate_bad/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { role: todo, name: "Todo" }
          - { role: in_progress, name: "In Progress" }
          - { role: in_review, name: "In Review" }
          - { role: done, name: "Done" }
          - { role: cancelled, name: "Cancelled" }
YAML
: > "$d_nested/calls"
rc=$(cd "$d_candidate_bad" && RITE_SETUP_CONFIG_CANDIDATE="$d_candidate_bad/rite-config.yml" MOCK_GH_DIR="$d_nested" PATH="$MOCKBIN:$PATH" bash "$VERIFY" >"$d_nested/post-stdout" 2>"$d_nested/post-stderr" && echo 0 || echo $?)
assert "T-existing-candidate mismatch exits non-zero" "1" "$rc"
assert_grep "T-existing-candidate reports mismatch" "$d_nested/post-stdout" 'STATUS_OPTIONS_VERIFY=error; missing=\["Todo","In Progress","Cancelled"\]'
assert "T-existing-candidate mismatch preserves root" "$root_before" "$(cksum "$d_nested/rite-config.yml")"
assert "T-existing-candidate mutation zero" "0" "$(mutation_count "$d_nested")"

rc=$(cd "$d_nested" && TMPDIR=.tmp bash "$CANDIDATE_CREATE" >candidate-create-ok-stdout 2>candidate-create-ok-stderr && echo 0 || echo $?)
assert "T-existing-candidate second relative TMPDIR create exits 0" "0" "$rc"
candidate_ok=$(sed -n 's/.*RITE_SETUP_CONFIG_CANDIDATE=//p' "$d_nested/candidate-create-ok-stdout")
d_candidate_ok=${candidate_ok%/*}
cat > "$d_candidate_ok/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { role: todo, name: "To-Do" }
          - { role: in_progress, name: "In progress" }
          - { role: in_review, name: "In Review" }
          - { role: done, name: "Done" }
language: ja
YAML
rc=$(cd "$d_candidate_ok" && RITE_SETUP_CONFIG_CANDIDATE="$d_candidate_ok/rite-config.yml" MOCK_GH_DIR="$d_nested" PATH="$MOCKBIN:$PATH" bash "$VERIFY" >"$d_nested/candidate-ok-stdout" 2>"$d_nested/candidate-ok-stderr" && echo 0 || echo $?)
assert "T-existing-candidate match verifies" "0" "$rc"
actual_jq=$(command -v jq)
mkdir -p "$d_nested/jq-fail-bin"
cat > "$d_nested/jq-fail-bin/jq" <<MOCK
#!/usr/bin/env bash
mode="\${MOCK_JQ_FAIL:-}"
args="\$*"
case "\$mode" in
  required_names) [ "\$args" = '-R .' ] && { echo 'forced required-name encoding failure' >&2; exit 1; } ;;
  missing_json) [[ "\$args" == -cn* ]] && { echo 'forced missing-json failure' >&2; exit 1; } ;;
  missing_count) [ "\$args" = 'length' ] && { echo 'forced missing-count failure' >&2; exit 1; } ;;
esac
exec "$actual_jq" "\$@"
MOCK
chmod +x "$d_nested/jq-fail-bin/jq"
for jq_failure in required_names missing_json missing_count; do
  root_jq_before=$(cksum "$d_nested/rite-config.yml")
  rc=$(cd "$d_candidate_ok" && MOCK_JQ_FAIL="$jq_failure" RITE_SETUP_CONFIG_CANDIDATE="$d_candidate_ok/rite-config.yml" MOCK_GH_DIR="$d_nested" PATH="$d_nested/jq-fail-bin:$MOCKBIN:$PATH" bash "$VERIFY" >"$d_nested/jq-$jq_failure-stdout" 2>"$d_nested/jq-$jq_failure-stderr" && echo 0 || echo $?)
  assert "T-existing-candidate jq $jq_failure exits non-zero" "1" "$rc"
  assert_grep "T-existing-candidate jq $jq_failure emits error marker" "$d_nested/jq-$jq_failure-stdout" 'STATUS_OPTIONS_VERIFY=error; reason='
  assert "T-existing-candidate jq $jq_failure preserves root" "$root_jq_before" "$(cksum "$d_nested/rite-config.yml")"
  assert "T-existing-candidate jq $jq_failure retains uncommitted candidate" "1" "$([ -e "$d_candidate_ok/rite-config.yml" ] && echo 1 || echo 0)"
done
candidate_sum=$(cksum "$d_candidate_ok/rite-config.yml" | awk '{ print $1 ":" $2 }')
rc=$(cd "$d_candidate_ok" && RITE_SETUP_PROJECT_ROOT="$project_root_marker" RITE_SETUP_CONFIG_CANDIDATE="$d_candidate_ok/rite-config.yml" bash "$COMMIT" >"$d_nested/commit-stdout" 2>"$d_nested/commit-stderr" && echo 0 || echo $?)
assert "T-existing-candidate commit exits 0" "0" "$rc"
assert "T-existing-candidate commit installs candidate" "$candidate_sum" "$(cksum "$d_nested/rite-config.yml" | awk '{ print $1 ":" $2 }')"
assert_grep "T-existing-candidate commit marker" "$d_nested/commit-stdout" 'STATUS_OPTION_CONFIG_COMMIT=updated'
assert "T-existing-candidate directory cleaned" "0" "$([ -e "$d_candidate_ok" ] && echo 1 || echo 0)"

root_fail_before=$(cksum "$d_nested/rite-config.yml")
rc=$(cd "$d_nested" && TMPDIR=.tmp bash "$CANDIDATE_CREATE" >candidate-create-mv-fail-stdout 2>candidate-create-mv-fail-stderr && echo 0 || echo $?)
assert "T-existing-candidate mv-fail fixture create exits 0" "0" "$rc"
candidate_mv_fail=$(sed -n 's/.*RITE_SETUP_CONFIG_CANDIDATE=//p' "$d_nested/candidate-create-mv-fail-stdout")
d_candidate_mv_fail=${candidate_mv_fail%/*}
cp "$d_nested/rite-config.yml" "$candidate_mv_fail"
mkdir -p "$d_nested/mv-fail-bin"
cat > "$d_nested/mv-fail-bin/mv" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$d_nested/mv-fail-bin/mv"
rc=$(cd "$d_candidate_mv_fail" && PATH="$d_nested/mv-fail-bin:$PATH" RITE_SETUP_PROJECT_ROOT="$d_nested" RITE_SETUP_CONFIG_CANDIDATE="$candidate_mv_fail" bash "$COMMIT" >"$d_nested/mv-fail-stdout" 2>"$d_nested/mv-fail-stderr" && echo 0 || echo $?)
assert "T-existing-candidate mv failure exits non-zero" "1" "$rc"
assert_grep "T-existing-candidate mv failure marker" "$d_nested/mv-fail-stdout" 'STATUS_OPTION_CONFIG_COMMIT=error; reason=replace_failed'
assert "T-existing-candidate mv failure preserves root" "$root_fail_before" "$(cksum "$d_nested/rite-config.yml")"
assert "T-existing-candidate mv failure removes candidate directory" "0" "$([ -e "$d_candidate_mv_fail" ] && echo 1 || echo 0)"
assert "T-existing-candidate mv failure removes root temp" "0" "$(find "$d_nested" -maxdepth 1 -name 'rite-config.yml.setup.*' | wc -l | tr -d ' ')"

rc=$(cd "$d_nested" && TMPDIR=.tmp bash "$CANDIDATE_CREATE" >candidate-create-signal-stdout 2>candidate-create-signal-stderr && echo 0 || echo $?)
assert "T-existing-candidate signal fixture create exits 0" "0" "$rc"
candidate_signal=$(sed -n 's/.*RITE_SETUP_CONFIG_CANDIDATE=//p' "$d_nested/candidate-create-signal-stdout")
d_candidate_signal=${candidate_signal%/*}
cp "$d_nested/rite-config.yml" "$candidate_signal"
mkdir -p "$d_nested/signal-bin"
cat > "$d_nested/signal-bin/cat" <<'MOCK'
#!/usr/bin/env bash
kill -TERM "$PPID"
sleep 1
exit 143
MOCK
chmod +x "$d_nested/signal-bin/cat"
rc=$(cd "$d_candidate_signal" && PATH="$d_nested/signal-bin:$PATH" RITE_SETUP_PROJECT_ROOT="$d_nested" RITE_SETUP_CONFIG_CANDIDATE="$candidate_signal" bash "$COMMIT" >"$d_nested/signal-stdout" 2>"$d_nested/signal-stderr" && echo 0 || echo $?)
assert "T-existing-candidate signal exits 143" "143" "$rc"
assert "T-existing-candidate signal preserves root" "$root_fail_before" "$(cksum "$d_nested/rite-config.yml")"
assert "T-existing-candidate signal removes candidate directory" "0" "$([ -e "$d_candidate_signal" ] && echo 1 || echo 0)"
assert "T-existing-candidate signal removes root temp" "0" "$(find "$d_nested" -maxdepth 1 -name 'rite-config.yml.setup.*' | wc -l | tr -d ' ')"

echo "=== T-upgrade-backup: nested cwd でも root config を backup ==="
backup_before=$(cksum "$d_nested/rite-config.yml" | awk '{ print $1 ":" $2 }')
rc=$(cd "$d_nested/sub" && bash "$BACKUP" >"$d_nested/backup-stdout" 2>"$d_nested/backup-stderr" && echo 0 || echo $?)
assert "T-upgrade-backup nested exits 0" "0" "$rc"
backup_path=$(sed -n 's/^\[CONTEXT\] STATUS_OPTIONS_UPGRADE_BACKUP=ok; path=//p' "$d_nested/backup-stdout")
assert "T-upgrade-backup root copy matches" "$backup_before" "$(cksum "$backup_path" | awk '{ print $1 ":" $2 }')"
assert "T-upgrade-backup creates no cwd backup" "0" "$(find "$d_nested/sub" -maxdepth 1 -name 'rite-config.yml.bak.*' | wc -l | tr -d ' ')"

echo "=== T-upgrade-role-migration: legacy は5 role化、explicit不変、invalid無変更 ==="
d_migrate="$WORKDIR/migrate-legacy"
mkdir -p "$d_migrate"
cat > "$d_migrate/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        enabled: true
        options:
          - { name: "Todo", default: true }
          - { name: "In Progress" }
          - { name: "In Review" }
          - { name: "Done" }
      priority:
        enabled: true
YAML
rc=$(cd "$d_migrate" && bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade legacy exits 0" "0" "$rc"
assert "T-upgrade legacy has five roles" "5" "$(grep -c 'role:' "$d_migrate/rite-config.yml")"
assert_not_grep "T-upgrade legacy removes status default" "$d_migrate/rite-config.yml" 'name: "Todo", default: true'
assert_grep "T-upgrade legacy adds cancelled" "$d_migrate/rite-config.yml" 'role: cancelled, name: "Cancelled"'
assert "T-upgrade legacy result is resolver-valid explicit" "explicit" "$(migration_mode "$d_migrate")"
assert_grep "T-upgrade legacy preserves adjacent section" "$d_migrate/rite-config.yml" '^      priority:'

d_empty="$WORKDIR/migrate-empty-nested/repo"
mkdir -p "$d_empty/sub"
git -C "$d_empty" init -q
cat > "$d_empty/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options: []
      priority:
        enabled: true
YAML
rc=$(cd "$d_empty/sub" && bash "$MIGRATION" >"$d_empty/stdout" 2>"$d_empty/stderr" && echo 0 || echo $?)
assert "T-upgrade empty nested exits 0" "0" "$rc"
assert "T-upgrade empty nested result is explicit" "explicit" "$(migration_mode "$d_empty")"
assert_grep "T-upgrade empty nested preserves adjacent section" "$d_empty/rite-config.yml" '^      priority:'
assert "T-upgrade empty nested creates no cwd config" "0" "$([ -e "$d_empty/sub/rite-config.yml" ] && echo 1 || echo 0)"
assert "T-upgrade empty nested leaves no config temp" "0" "$(find "$d_empty" -maxdepth 1 -name 'rite-config.yml.status-role.*' | wc -l | tr -d ' ')"

d_tmp_inside="$WORKDIR/migrate-tmp-inside/repo"
mkdir -p "$d_tmp_inside/.tmp"
git -C "$d_tmp_inside" init -q
cat > "$d_tmp_inside/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { name: "Todo" }
          - { name: "In Progress" }
          - { name: "In Review" }
          - { name: "Done" }
YAML
rc=$(cd "$d_tmp_inside" && TMPDIR=.tmp bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade relative repository-local TMPDIR exits 0" "0" "$rc"
assert "T-upgrade relative repository-local TMPDIR validates transformed candidate" "explicit" "$(migration_mode "$d_tmp_inside")"
assert "T-upgrade relative repository-local TMPDIR cleans scratch" "0" "$(find "$d_tmp_inside/.tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

d_block="$WORKDIR/migrate-block"
mkdir -p "$d_block"
cat > "$d_block/rite-config.yml" <<'YAML'
github:
 projects:
  fields:
   status:
    options:
     - name: "Todo"
       default: true

     # option 間のコメントも旧配列の一部
     - name: "In Progress"
     - name: "In Review"
     - name: "Done"
   priority:
    enabled: true
YAML
rc=$(cd "$d_block" && bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade block/blank/variable-indent exits 0" "0" "$rc"
assert "T-upgrade block/blank/variable-indent result is explicit" "explicit" "$(migration_mode "$d_block")"
assert "T-upgrade block/blank/variable-indent has five roles" "5" "$(grep -c 'role:' "$d_block/rite-config.yml")"
assert_not_grep "T-upgrade block/blank removes all unroled options" "$d_block/rite-config.yml" '^[[:space:]]*- name:'
assert_grep "T-upgrade block/blank preserves adjacent section" "$d_block/rite-config.yml" '^[[:space:]]*priority:'

d_crlf="$WORKDIR/migrate-crlf"
mkdir -p "$d_crlf"
printf '%s\r\n' \
  'github:' \
  '  projects:' \
  '    fields:' \
  '      status:' \
  '' \
  '        options:' \
  '          - { name: "Todo", default: true }' \
  '' \
  '          # CRLF comment inside the legacy option list' \
  '          - { name: "In Progress" }' \
  '          - { name: "In Review" }' \
  '          - { name: "Done" }' \
  '      priority:' \
  '        enabled: true' > "$d_crlf/rite-config.yml"
rc=$(cd "$d_crlf" && bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade CRLF blank/comment exits 0" "0" "$rc"
assert "T-upgrade CRLF result is explicit" "explicit" "$(migration_mode "$d_crlf")"
assert "T-upgrade CRLF preserves line endings" "0" "$(awk 'sub(/\r$/, "") { next } { bad++ } END { print bad+0 }' "$d_crlf/rite-config.yml")"
assert_grep "T-upgrade CRLF preserves adjacent section" "$d_crlf/rite-config.yml" '^[[:space:]]*priority:'

d_explicit="$WORKDIR/migrate-explicit"
mkdir -p "$d_explicit"
cat > "$d_explicit/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { role: todo, name: "To-Do" }
          - { role: in_progress, name: "In progress" }
          - { role: in_review, name: "Review" }
          - { role: done, name: "Complete" }
YAML
before=$(cksum "$d_explicit/rite-config.yml")
rc=$(cd "$d_explicit" && bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade explicit exits 0" "0" "$rc"
assert "T-upgrade explicit unchanged" "$before" "$(cksum "$d_explicit/rite-config.yml")"

d_invalid="$WORKDIR/migrate-invalid"
mkdir -p "$d_invalid"
cat > "$d_invalid/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { role: todo, name: "Todo" }
          - { name: "In Progress" }
YAML
before=$(cksum "$d_invalid/rite-config.yml")
rc=$(cd "$d_invalid" && bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade invalid exits non-zero" "1" "$rc"
assert "T-upgrade invalid unchanged" "$before" "$(cksum "$d_invalid/rite-config.yml")"

d_missing_options="$WORKDIR/migrate-missing-options"
mkdir -p "$d_missing_options"
cat > "$d_missing_options/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      priority:
        enabled: true
YAML
before=$(cksum "$d_missing_options/rite-config.yml")
rc=$(cd "$d_missing_options" && bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade missing options defers to back-add" "0" "$rc"
assert "T-upgrade missing options leaves config unchanged" "$before" "$(cksum "$d_missing_options/rite-config.yml")"
assert_grep "T-upgrade missing options emits noop" "$d_missing_options/stdout" 'STATUS_OPTIONS_ROLE_MIGRATION=noop; reason=status_options_absent'

d_tmp_fail="$WORKDIR/migrate-tmp-fail"
mkdir -p "$d_tmp_fail/bin"
cat > "$d_tmp_fail/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { name: "Todo" }
          - { name: "In Progress" }
          - { name: "In Review" }
          - { name: "Done" }
YAML
cat > "$d_tmp_fail/bin/mktemp" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$d_tmp_fail/bin/mktemp"
rc=$(cd "$d_tmp_fail" && PATH="$d_tmp_fail/bin:$PATH" bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade mktemp failure exits non-zero" "1" "$rc"
assert_grep "T-upgrade mktemp failure emits marker" "$d_tmp_fail/stdout" 'STATUS_OPTIONS_ROLE_MIGRATION=error; reason=tmp_create_failed'

d_signal="$WORKDIR/migrate-signal"
signal_tmp="$WORKDIR/migrate-signal-tmp"
mkdir -p "$d_signal/bin" "$signal_tmp"
cat > "$d_signal/rite-config.yml" <<'YAML'
github:
  projects:
    fields:
      status:
        options:
          - { name: "Todo" }
          - { name: "In Progress" }
          - { name: "In Review" }
          - { name: "Done" }
YAML
actual_awk=$(command -v awk)
cat > "$d_signal/bin/awk" <<MOCK
#!/usr/bin/env bash
count=0
[ -f '$d_signal/awk-count' ] && count=\$(cat '$d_signal/awk-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$d_signal/awk-count'
if [ "\$count" -eq 1 ]; then exec '$actual_awk' "\$@"; fi
kill -TERM "\$PPID"
sleep 1
exit 143
MOCK
chmod +x "$d_signal/bin/awk"
rc=$(cd "$d_signal" && TMPDIR="$signal_tmp" PATH="$d_signal/bin:$PATH" bash "$MIGRATION" >stdout 2>stderr && echo 0 || echo $?)
assert "T-upgrade signal exits 143" "143" "$rc"
assert "T-upgrade signal removes scratch" "0" "$(find "$signal_tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
assert "T-upgrade signal preserves config" "legacy" "$(migration_mode "$d_signal")"

if ! print_summary "$(basename "$0")" "setup Status option provisioning / verification / role migration"; then
  exit 1
fi
exit 0
