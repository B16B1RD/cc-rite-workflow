#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
LIB="$SCRIPT_DIR/../scripts/lib/projects-status-config.sh"
TEST_DIR=$(make_plain_sandbox)
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$TEST_DIR"

before_options=$(set +o)
before_traps=$(trap -p)
source "$LIB"
assert 'source preserves shell options' "$before_options" "$(set +o)"
assert 'source preserves caller traps' "$before_traps" "$(trap -p)"
assert 'source creates no files' '' "$(ls -A)"

write_config() {
  printf 'github:\n  projects:\n    fields:\n      status:\n%s\n' "$1" > rite-config.yml
}
core_options='          - { role: todo, name: "未着手" }
          - { role: in_progress, name: "進行中" }
          - { role: in_review, name: "レビュー中" }
          - { role: done, name: "完了" }'
explicit_config() { write_config "        options:
$core_options${1-}"; }
assert_invalid() {
  local label="$1" rc=0 output
  output=$(projects_status_mode 2>error.txt) || rc=$?
  if [[ "$rc" -ne 0 && -s error.txt && -z "$output" ]]; then pass "$label"; else
    fail "$label"; printf 'rc=%s stdout=%s stderr=%s\n' "$rc" "$output" "$(<error.txt)"
  fi
}

assert_invalid 'missing config fails with stderr and no stdout'
printf 'wiki:\n  enabled: false\n' > rite-config.yml
assert 'absent status config is legacy' legacy "$(projects_status_mode)"
assert 'legacy defaults are silent' '' "$(projects_status_mode 2>&1 >/dev/null)"
for pair in 'todo|Todo' 'in_progress|In Progress' 'in_review|In Review' 'done|Done' 'cancelled|Cancelled'; do
  role=${pair%%|*}; name=${pair#*|}
  assert "legacy $role name" "$name" "$(projects_status_name_for_role "$role")"
  assert "legacy $name role" "$role" "$(projects_status_role_for_name "$name")"
done
assert 'default field candidates preserve order' $'ステータス\nStatus' "$(projects_status_field_candidates)"
write_config '        options:
          - { name: "ローカル", default: true }
          - { name: "role: todo" }'
assert 'no-role flow options retain legacy mode' legacy "$(projects_status_mode)"
assert 'no-role localized option does not change default' Todo "$(projects_status_name_for_role todo)"
write_config '        options:
          - name: "未着手"
            default: true
          - name: "完了"'
assert 'no-role block options retain legacy mode' legacy "$(projects_status_mode)"
printf '        name: "進捗"\n' >> rite-config.yml
assert 'field name after legacy block options works' 進捗 "$(projects_status_field_candidates)"

explicit_config
assert 'four required roles activate explicit mode' explicit "$(projects_status_mode)"
assert 'localized role lookup' 完了 "$(projects_status_name_for_role done)"
assert 'localized reverse lookup' in_review "$(projects_status_role_for_name レビュー中)"
assert 'unmapped cancellation is empty' '' "$(projects_status_name_for_role cancelled)"
assert 'unknown role is empty' '' "$(projects_status_name_for_role unknown)"
assert 'unknown name is empty' '' "$(projects_status_role_for_name Unknown)"
assert 'legacy English name is unmapped in explicit mode' '' "$(projects_status_role_for_name Done)"
explicit_config '
          - { role: cancelled, name: "中止" }'
assert 'optional cancellation mapping' 中止 "$(projects_status_name_for_role cancelled)"
explicit_config "
          - { role: cancelled, name: Won't do } # comment"
assert 'apostrophe in unquoted name stays literal' "Won't do" "$(projects_status_name_for_role cancelled)"

write_config "        name: \"進捗 #, 状態\" # comment
        options:
$core_options
      priority:
        options:
          - { role: unknown, name: \"irrelevant\" }
wiki:
  status:
    role: ignored"
assert 'only status section roles are validated' explicit "$(projects_status_mode)"
assert 'configured field is sole candidate with punctuation intact' '進捗 #, 状態' "$(projects_status_field_candidates)"
write_config '        options:
          # role: invalid in a comment is ignored
          - { name: "Todo: #queue, {queue}", role: todo, default: true } # suffix
          - { role: in_progress, name: In Progress }
          - { role: in_review, name: "Review \"quoted\"" }
          - { role: done, name: "C:\\Done" }'
assert 'quoted separators and comment characters stay in name' 'Todo: #queue, {queue}' "$(projects_status_name_for_role todo)"
assert 'unquoted name with spaces' 'In Progress' "$(projects_status_name_for_role in_progress)"
assert 'escaped quote is decoded' 'Review "quoted"' "$(projects_status_name_for_role in_review)"
assert 'backslash lookup is literal' done "$(projects_status_role_for_name 'C:\Done')"

for invalid_options in \
  '- { name: "No role" }' \
  '- { role: unknown, name: "Other" }' \
  '- { role: done, name: "Again" }' \
  '- { role: cancelled, name: "完了" }' \
  '- { role: cancelled, name: "" }' \
  '- { role: cancelled, name: "   " }' \
  '- { role: cancelled }' \
  '- { role: cancelled, name: [Cancelled] }' \
  '- { role: cancelled, name: "Cancelled", extra: true }' \
  '- { role: cancelled, name: "Cancelled", role: done }' \
  '- role: cancelled
            name: "中止"' \
  '- { role: cancelled,
              name: "中止" }'; do
  explicit_config "
          $invalid_options"
  assert_invalid "invalid option rejected: $invalid_options"
done
write_config '        options:
          - { role: todo, name: "Todo" }'
assert_invalid 'missing required roles rejected'
write_config '        options: [{ role: todo, name: "Todo" }]'
assert_invalid 'inline options array rejected'
for invalid_options in \
  '- garbage' \
  '- { name: "Todo"' \
  '- { "role": todo, name: "Todo" }' \
  '- "role": todo
            name: "Todo"'; do
  write_config "        options:
          $invalid_options"
  assert_invalid "unsupported syntax does not fall back to legacy: $invalid_options"
done
write_config '        name: ""'
assert_invalid 'empty explicit field name rejected'
for key in github projects fields status options; do
  for quote in '"' "'"; do
    explicit_config
    sed "s/^\( *\)$key:/\1$quote$key$quote:/" rite-config.yml > quoted-config.yml
    mv quoted-config.yml rite-config.yml
    assert_invalid "quoted $key key rejected: $quote"
  done
done
explicit_config '
          - { role: cancelled, name: "完了" }'
for query in 'projects_status_name_for_role todo' 'projects_status_role_for_name 完了' 'projects_status_field_candidates'; do
  if $query >/dev/null 2>error.txt; then fail "invalid config blocks $query"; else pass "invalid config blocks $query"; fi
done

for pair in todo:1 in_progress:2 in_review:3 done:4 cancelled:0 unknown:0; do
  assert "rank $pair" "${pair#*:}" "$(projects_status_rank "${pair%%:*}")"
done
for role in done cancelled; do
  if projects_status_is_terminal "$role"; then pass "$role is terminal"; else fail "$role is terminal"; fi
done
for role in todo in_progress in_review unknown; do
  if projects_status_is_terminal "$role"; then fail "$role is not terminal"; else pass "$role is not terminal"; fi
done

explicit_config
git init -q
mkdir nested
cd nested
assert 'nested cwd resolves repository-root config' 完了 "$(projects_status_name_for_role done)"
override_config="$TEST_DIR/override-config.yml"
sed 's/name: "完了"/name: "候補完了"/' "$TEST_DIR/rite-config.yml" > "$override_config"
assert 'absolute override bypasses repository-root config' 候補完了 "$(RITE_STATUS_CONFIG_PATH="$override_config" projects_status_name_for_role done)"
if RITE_STATUS_CONFIG_PATH=../override-config.yml projects_status_mode >/dev/null 2>override-error.txt; then
  fail 'relative override is rejected'
else
  assert_grep 'relative override explains absolute-path contract' override-error.txt 'must be an absolute path'
fi
print_summary 'projects-status-config.test.sh'
