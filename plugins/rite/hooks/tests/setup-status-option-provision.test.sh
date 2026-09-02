#!/usr/bin/env bash
# setup Phase 3.4 Status option union provisioning.
# SKILL.md から bash を抽出して mock gh で実行する（コピーは SKILL.md との drift を生む）。
# 抽出失敗は skip せず exit 1（CI が緑のまま残らないようにする）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

SKILL="$SCRIPT_DIR/../../skills/setup/SKILL.md"
assert_file_exists_or_fail "setup/SKILL.md exists" "$SKILL" || {
  print_summary "$(basename "$0")" "setup SKILL.md missing" || exit 1
  exit 1
}

extract_provision_bash() {
  awk '
    /^```bash$/ { fence=1; buf=""; next }
    fence && /^```$/ {
      if (buf ~ /STATUS_OPTION_UNION_PROVISION/) { printf "%s", buf; found=1; exit }
      fence=0; buf=""
      next
    }
    fence { buf = buf $0 "\n" }
    END { if (!found && buf ~ /STATUS_OPTION_UNION_PROVISION/) printf "%s", buf }
  ' "$SKILL"
}

SNIPPET_RAW=$(extract_provision_bash)
if ! printf '%s' "$SNIPPET_RAW" | grep -q 'STATUS_OPTION_UNION_PROVISION'; then
  echo "FAIL: SKILL.md からの STATUS_OPTION_UNION_PROVISION block 抽出に失敗しました" >&2
  echo "  抽出結果: $(printf '%s' "$SNIPPET_RAW" | wc -l) 行" >&2
  exit 1
fi

WORKDIR=$(make_plain_sandbox)
MOCKBIN="$WORKDIR/bin"
mkdir -p "$MOCKBIN"
SNIPPET="$WORKDIR/provision.sh"
printf '%s' "$SNIPPET_RAW" | sed -e 's/{owner}/test-owner/g' -e 's/{project-number}/11/g' > "$SNIPPET"

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

echo "=== T-static-cancelled: Phase 3.4 required 5 組 (name/color/description) ==="
assert_grep_in_section "T-static Todo/GRAY/Not started" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^## Phase 3.5' \
  '"name":"Todo","color":"GRAY","description":"Not started"'
assert_grep_in_section "T-static In Progress/YELLOW" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^## Phase 3.5' \
  '"name":"In Progress","color":"YELLOW","description":"Work in progress"'
assert_grep_in_section "T-static In Review/BLUE" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^## Phase 3.5' \
  '"name":"In Review","color":"BLUE","description":"Under review"'
assert_grep_in_section "T-static Done/GREEN" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^## Phase 3.5' \
  '"name":"Done","color":"GREEN","description":"Completed"'
assert_grep_in_section "T-static Cancelled/GRAY" "$SKILL" \
  'STATUS_OPTION_UNION_PROVISION' '^## Phase 3.5' \
  '"name":"Cancelled","color":"GRAY","description":"Cancelled \(not planned\)"'

echo "=== T-no-replace-fallback: 旧 id 無し 4 要素 GraphQL 全置換フェンスが無い ==="
assert_not_grep "T-no-replace-fallback no Todo GRAY GraphQL literal" "$SKILL" \
  '\{name: "Todo", color: GRAY, description: "Not started"\}'
assert_not_grep "T-no-replace-fallback no In Review gating heading" "$SKILL" \
  'If the Status field does not have "In Review"'

echo "=== T-read-fail: options query 非0 / JSON 不正 / Status field 不在 → mutation 0 かつ 非0 ==="
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

echo "=== T-union-custom: Blocked の id が mutation payload に残る ==="
d_custom="$WORKDIR/custom"
mkdir -p "$d_custom"
printf '%s\n' "$status_field_list" > "$d_custom/field-list.json"
printf '%s\n' "$opt4_custom" > "$d_custom/options.json"
rc=$(MOCK_GH_DIR="$d_custom" PATH="$MOCKBIN:$PATH" \
  bash "$SNIPPET" >"$d_custom/stdout" 2>"$d_custom/stderr" && echo 0 || echo $?)
assert "T-union-custom exits 0" "0" "$rc"
opts=$(jq '.variables.input.singleSelectOptions' "$d_custom/mutation.json")
if printf '%s' "$opts" | jq -e '.[] | select(.id=="ID_BLOCKED" and .name=="Blocked" and .color=="RED" and .description=="Waiting")' >/dev/null; then
  pass "T-union-custom Blocked kept as same object"
else
  fail "T-union-custom Blocked not preserved: $opts"
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

if ! print_summary "$(basename "$0")" "setup Status option union provision"; then
  exit 1
fi
exit 0
