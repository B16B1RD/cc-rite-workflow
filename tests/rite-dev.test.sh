#!/usr/bin/env bash
set -euo pipefail

# Runtime identity and lifecycle inputs belong to each fixture, never the
# live Claude/Codex/Grok session launching the tests.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST
unset CLAUDE_ENV_FILE RITE_STATE_ROOT RITE_RUNTIME_EXPLICIT _RITE_HOOK_REDIRECTED

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n' "$1"
}

assert_eq() {
  local label=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local label=$1 haystack=$2 needle=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (missing '$needle')"
  fi
}

make_repo() {
  local repo=$1
  mkdir -p "$repo/scripts" "$repo/plugins/rite/skills/open" "$repo/plugins/rite/skills/lint" \
    "$repo/.grok/plugins"
  cp "$SCRIPT_UNDER_TEST" "$repo/scripts/rite-dev"
  chmod +x "$repo/scripts/rite-dev"
  printf '%s\n' '---' 'name: open' '---' > "$repo/plugins/rite/skills/open/SKILL.md"
  printf '%s\n' '---' 'name: lint' '---' > "$repo/plugins/rite/skills/lint/SKILL.md"
  printf '[plugins]\n' > "$repo/.grok/config.toml"
  ln -s ../../plugins/rite "$repo/.grok/plugins/rite"
  git -C "$repo" init -q
}

make_host_stub() {
  local bin=$1 host=$2
  mkdir -p "$bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "RITE_HOST=%s\n" "$RITE_HOST" > "$RITE_STUB_LOG"' \
    'printf "RITE_PLUGIN_ROOT=%s\n" "$RITE_PLUGIN_ROOT" >> "$RITE_STUB_LOG"' \
    'printf "CODEX_HOME=%s\n" "${CODEX_HOME:-}" >> "$RITE_STUB_LOG"' \
    'printf "ARG=%s\n" "$@" >> "$RITE_STUB_LOG"' \
    'if [[ ${RITE_HOST:-} == codex ]]; then mkdir -p "$CODEX_HOME/skills/.system"; fi' \
    'if [[ -n ${RITE_STUB_STDERR:-} ]]; then printf "%s\n" "$RITE_STUB_STDERR" >&2; fi' \
    'exit "${RITE_STUB_EXIT:-0}"' \
    > "$bin/$host"
  chmod +x "$bin/$host"
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_UNDER_TEST=$(cd -- "$SCRIPT_DIR/.." && pwd)/scripts/rite-dev
REPO="$TEST_ROOT/repo"
BIN="$TEST_ROOT/bin"
LOG="$TEST_ROOT/host.log"
make_repo "$REPO"
REPO_PHYS=$(cd -- "$REPO" && pwd -P)
make_host_stub "$BIN" claude
make_host_stub "$BIN" codex
make_host_stub "$BIN" grok

# Existing project settings and local profile contents must survive launches.
# These files live only inside the disposable fixture.
settings_files=(.claude/settings.json .claude/settings.local.json .codex-dev/config.toml .grok/config.toml)
mkdir -p "$REPO/.claude" "$REPO/.codex-dev" "$TEST_ROOT/settings-before"
printf '{"enabledPlugins":{"rite@rite-marketplace":true}}\n' > "$REPO/.claude/settings.json"
printf '{"permissions":{"allow":["Read"]}}\n' > "$REPO/.claude/settings.local.json"
printf 'model = "fixture-model"\n' > "$REPO/.codex-dev/config.toml"
for settings_file in "${settings_files[@]}"; do
  mkdir -p "$TEST_ROOT/settings-before/$(dirname "$settings_file")"
  cp "$REPO/$settings_file" "$TEST_ROOT/settings-before/$settings_file"
done

set +e
no_arg_out=$(cd "$REPO" && "$REPO/scripts/rite-dev" 2>&1)
no_arg_rc=$?
unknown_out=$(cd "$REPO" && "$REPO/scripts/rite-dev" unknown 2>&1)
unknown_rc=$?
set -e
assert_eq 'host 未指定は exit 2' 2 "$no_arg_rc"
assert_contains 'host 未指定は usage を表示' "$no_arg_out" 'Usage: scripts/rite-dev'
assert_eq '未対応 host は非ゼロ終了' 1 "$unknown_rc"
assert_contains '未対応 host を診断' "$unknown_out" "unknown host 'unknown'"

MISSING_BIN="$TEST_ROOT/missing-bin"
mkdir -p "$MISSING_BIN"
ln -s "$(command -v bash)" "$MISSING_BIN/bash"
ln -s "$(command -v dirname)" "$MISSING_BIN/dirname"
ln -s "$(command -v git)" "$MISSING_BIN/git"
for missing_host in claude codex grok; do
  set +e
  missing_out=$(PATH="$MISSING_BIN" "$REPO/scripts/rite-dev" "$missing_host" 2>&1)
  missing_rc=$?
  set -e
  assert_eq "$missing_host 不在は非ゼロ終了" 1 "$missing_rc"
  assert_contains "$missing_host 不在を診断" "$missing_out" "$missing_host executable not found"
done

RITE_STUB_LOG="$LOG" PATH="$BIN:$PATH" "$REPO/scripts/rite-dev" claude 'two words' tail
claude_log=$(<"$LOG")
assert_contains 'Claude host 環境変数を設定' "$claude_log" 'RITE_HOST=claude'
assert_contains 'Claude plugin root 環境変数を設定' "$claude_log" "RITE_PLUGIN_ROOT=$REPO_PHYS/plugins/rite"
assert_contains 'Claude はグローバル rite を無効化' "$claude_log" $'ARG=--settings\nARG={"enabledPlugins":{"rite@rite-marketplace":false}}'
assert_contains 'Claude は作業ツリープラグインを指定' "$claude_log" $'ARG=--plugin-dir\nARG='"$REPO_PHYS/plugins/rite"
assert_contains 'Claude の語境界を保持' "$claude_log" $'ARG=two words\nARG=tail'

RITE_STUB_LOG="$LOG" PATH="$BIN:$PATH" "$REPO/scripts/rite-dev" codex 'two words' tail
codex_log=$(<"$LOG")
assert_contains 'Codex host 環境変数を設定' "$codex_log" 'RITE_HOST=codex'
assert_contains 'Codex plugin root 環境変数を設定' "$codex_log" "RITE_PLUGIN_ROOT=$REPO_PHYS/plugins/rite"
assert_contains 'Codex は分離 CODEX_HOME を使用' "$codex_log" "CODEX_HOME=$REPO_PHYS/.codex-dev"
assert_contains 'Codex は auto approval mode を使用' "$codex_log" 'ARG=--approve-for-me'
assert_contains 'Codex は repository cwd を指定' "$codex_log" $'ARG=--cd\nARG='"$REPO_PHYS"
assert_contains 'Codex の語境界を保持' "$codex_log" $'ARG=two words\nARG=tail'
[[ -d "$REPO/.codex-dev/skills" && ! -L "$REPO/.codex-dev/skills" ]] && \
  pass 'Codex skills root は実ディレクトリ' || fail 'Codex skills root は実ディレクトリ'
[[ -L "$REPO/.codex-dev/skills/open" && -L "$REPO/.codex-dev/skills/lint" ]] && \
  pass 'rite スキルを個別リンク' || fail 'rite スキルを個別リンク'
[[ -d "$REPO/.codex-dev/skills/.system" && ! -e "$REPO/plugins/rite/skills/.system" ]] && \
  pass 'Codex 管理物は配布ソースへ混入しない' || fail 'Codex 管理物は配布ソースへ混入しない'

repo_link="$TEST_ROOT/repo-link"
ln -s "$REPO" "$repo_link"
RITE_STUB_LOG="$LOG" PATH="$BIN:$PATH" "$repo_link/scripts/rite-dev" codex
symlink_codex_log=$(<"$LOG")
assert_contains 'symlink checkout 経由でも Codex 照合が成立' "$symlink_codex_log" "RITE_PLUGIN_ROOT=$REPO_PHYS/plugins/rite"
assert_contains 'symlink checkout 経由でも物理 repository cwd を指定' "$symlink_codex_log" $'ARG=--cd\nARG='"$REPO_PHYS"

wrong_link_repo="$TEST_ROOT/wrong-link"
make_repo "$wrong_link_repo"
mkdir -p "$wrong_link_repo/.codex-dev/skills" "$wrong_link_repo/unrelated/open"
ln -s "$wrong_link_repo/unrelated/open" "$wrong_link_repo/.codex-dev/skills/open"
set +e
wrong_link_out=$(RITE_STUB_LOG="$LOG" PATH="$BIN:$PATH" "$wrong_link_repo/scripts/rite-dev" codex 2>&1)
wrong_link_rc=$?
set -e
assert_eq '異実体 Codex skill link は非ゼロ終了' 1 "$wrong_link_rc"
assert_contains '異実体 Codex skill link を診断' "$wrong_link_out" "$wrong_link_repo/.codex-dev/skills/open"

RITE_STUB_LOG="$LOG" PATH="$BIN:$PATH" "$REPO/scripts/rite-dev" grok 'two words' tail
grok_log=$(<"$LOG")
assert_contains 'Grok host 環境変数を設定' "$grok_log" 'RITE_HOST=grok'
assert_contains 'Grok plugin root 環境変数を設定' "$grok_log" "RITE_PLUGIN_ROOT=$REPO_PHYS/plugins/rite"
assert_contains 'Grok は repository cwd を指定' "$grok_log" $'ARG=--cwd\nARG='"$REPO_PHYS"
assert_contains 'Grok の語境界を保持' "$grok_log" $'ARG=two words\nARG=tail'

for failing_host in claude codex grok; do
  host_stderr="$TEST_ROOT/$failing_host.stderr"
  set +e
  RITE_STUB_LOG="$LOG" RITE_STUB_EXIT=7 RITE_STUB_STDERR="$failing_host fixture failure" \
    PATH="$BIN:$PATH" "$REPO/scripts/rite-dev" "$failing_host" \
    > "$TEST_ROOT/$failing_host.stdout" 2> "$host_stderr"
  host_rc=$?
  set -e
  assert_eq "$failing_host の終了コードを伝播" 7 "$host_rc"
  assert_eq "$failing_host の stderr を伝播" "$failing_host fixture failure" "$(<"$host_stderr")"
  for settings_file in "${settings_files[@]}"; do
    if cmp -s "$TEST_ROOT/settings-before/$settings_file" "$REPO/$settings_file"; then
      pass "$failing_host 起動後も $settings_file を保持"
    else
      fail "$failing_host 起動が $settings_file を変更"
    fi
  done
done

conflict_repo="$TEST_ROOT/conflict"
make_repo "$conflict_repo"
mkdir -p "$conflict_repo/.codex-dev/skills/open"
printf 'keep\n' > "$conflict_repo/.codex-dev/skills/open/sentinel"
set +e
conflict_out=$(RITE_STUB_LOG="$LOG" PATH="$BIN:$PATH" "$conflict_repo/scripts/rite-dev" codex 2>&1)
conflict_rc=$?
set -e
assert_eq '競合する Codex skill path は非ゼロ終了' 1 "$conflict_rc"
assert_contains '競合する Codex skill path を診断' "$conflict_out" "$conflict_repo/.codex-dev/skills/open"
[[ $(<"$conflict_repo/.codex-dev/skills/open/sentinel") == keep ]] && \
  pass '競合 path を上書きしない' || fail '競合 path を上書きしない'

bad_grok_repo="$TEST_ROOT/bad-grok"
make_repo "$bad_grok_repo"
mv "$bad_grok_repo/.grok/plugins/rite" "$bad_grok_repo/.grok/plugins/rite.original"
ln -s ../wrong "$bad_grok_repo/.grok/plugins/rite"
set +e
bad_grok_out=$(RITE_STUB_LOG="$LOG" PATH="$BIN:$PATH" "$bad_grok_repo/scripts/rite-dev" grok 2>&1)
bad_grok_rc=$?
set -e
assert_eq '誤った Grok plugin link は非ゼロ終了' 1 "$bad_grok_rc"
assert_contains '誤った Grok plugin link を診断' "$bad_grok_out" "$bad_grok_repo/.grok/plugins/rite"
[[ $(readlink "$bad_grok_repo/.grok/plugins/rite") == ../wrong ]] && \
  pass '誤った Grok plugin link を上書きしない' || fail '誤った Grok plugin link を上書きしない'

printf '\nPASS: %d, FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
