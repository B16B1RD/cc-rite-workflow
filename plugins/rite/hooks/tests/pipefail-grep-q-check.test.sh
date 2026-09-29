#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
SCRIPT="$SCRIPT_DIR/../scripts/pipefail-grep-q-check.sh"
SBX="$(make_plain_sandbox)"; trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/plugins/rite/hooks" "$SBX/plugins/rite/scripts"
fixture="$SBX/plugins/rite/hooks/fixture.sh"

cat > "$fixture" <<'EOF'
set -euo pipefail
printf '%s|%s\n' a b | grep -q x
{ cmd; } | grep -q x
docker ps | grep -q x
enable -p | grep -q mapfile
printf '%s\n' "$json" | jq -r '.items[]' | grep -q child
set +o pipefail
stream_many | grep -q disabled
EOF
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "true site yields warning rc" "1" "$rc"
assert "only the true jq producer is detected" "1" "$(printf '%s' "$out" | grep -c '^\[pipefail-grep-q\]')"
assert "quoted pipe in printf is not misparsed" "0" "$(printf '%s' "$out" | grep -c 'immediate producer.*%s' || true)"
assert "brace group is exempt" "0" "$(printf '%s' "$out" | grep -c 'immediate producer.*{ cmd' || true)"
assert "bounded docker ps probe is exempt" "0" "$(printf '%s' "$out" | grep -c 'producer.*docker ps' || true)"
assert "immediate jq stage is reported" "1" "$(printf '%s' "$out" | grep -c "producer before grep -q: jq -r" || true)"
assert "bounded enable probe is exempt" "0" "$(printf '%s' "$out" | grep -c 'producer.*enable -p' || true)"
assert "pipeline after pipefail disable is not reported" "0" "$(printf '%s' "$out" | grep -c 'producer.*stream_many' || true)"

printf '%s\n' 'set -o pipefail' 'echo "$output" | grep -q x' 'echo "prefix ${name}" | grep -q x' \
  'echo -n "$flagged_opt" | grep -q x' 'echo prefix "$second_arg" | grep -q x' 'echo `backquoted` | grep -q x' \
  'echo literal | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "echo of an expansion is not exempt" "1" "$rc"
assert "echo of a variable is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: echo "\$output"$' || true)"
assert "echo of a string with an expansion is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: echo "prefix' || true)"
assert "echo with an option before the expansion is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*flagged_opt' || true)"
assert "expansion in a later argument is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*second_arg' || true)"
assert "backquote command substitution is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*backquoted' || true)"
assert "echo of a literal stays exempt" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*echo literal' || true)"

printf '%s\n' 'set -o pipefail' "echo 'literal \$ sign' | grep -q x" 'if ! echo "$negated" | grep -q x; then :; fi' \
  'printf '"'"'%s'"'"' "$printf_var" | grep -q x' 'printf '"'"'%s\n'"'"' fixed_word | grep -q x' \
  '! echo literal_bang | grep -q x' 'if ! echo literal_if_bang | grep -q x; then :; fi' \
  'while ! echo literal_while_bang | grep -q x; do :; done' 'until echo literal_until | grep -q x; do :; done' \
  'if false; then :; elif echo literal_elif | grep -q x; then :; fi' \
  'for i in 1; do echo literal_do | grep -q x; done' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "producer stage with a literal dollar is reported" "1" "$(printf '%s\n' "$out" | grep -c "producer before grep -q: echo 'literal" || true)"
assert "negated echo of an expansion is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*negated' || true)"
assert "printf of an expansion is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*printf_var' || true)"
assert "printf of a literal stays exempt" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*fixed_word' || true)"
assert "bang prefix before a literal echo is stripped" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*literal_bang' || true)"
assert "if-bang prefix before a literal echo is stripped" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*literal_if_bang' || true)"
assert "while-bang prefix before a literal echo is stripped" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*literal_while_bang' || true)"
assert "until prefix before a literal echo is stripped" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*literal_until' || true)"
assert "elif prefix before a literal echo is stripped" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*literal_elif' || true)"
assert "do prefix before a literal echo is stripped" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*literal_do' || true)"

printf '%s\n' 'set -o pipefail' 'printf '"'"'%s|%s\n'"'"' "$pipe_a" "$pipe_b" | grep -q x' \
  'X=$HOME echo prefix_assign | grep -q x' 'echo redir_word 2>"$log" | grep -q x' \
  'printf '"'"'%s\n'"'"' brace_expand {1..3} | grep -q x' 'echo glob_word * | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "printf with a literal pipe in its format and an expansion is reported" "1" "$(printf '%s\n' "$out" | grep -cxF "[pipefail-grep-q] plugins/rite/hooks/fixture.sh:2: immediate producer before grep -q: printf '%s|%s\n' \"\$pipe_a\" \"\$pipe_b\"" || true)"
assert "expansion in a prefix assignment is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*prefix_assign' || true)"
assert "expansion in a redirection is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*redir_word' || true)"
assert "printf of a brace expansion is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*brace_expand' || true)"
assert "echo of a glob is reported" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*glob_word' || true)"

# Each producer holds one trigger and no other character of the exemption class,
# so a finding can only come from that trigger. The last two are controls: a digit
# in an argument is not a format width, and echo does not interpret a format.
printf '%s\n' 'set -o pipefail' 'echo qmark_word ? | grep -q x' 'echo bracket_word [ab] | grep -q x' \
  'printf '"'"'%300000s'"'"' width_word | grep -q x' 'printf '"'"'%.5000f'"'"' 1 | grep -q x' \
  'printf '"'"'%-300000s'"'"' flag_minus | grep -q x' 'printf '"'"'%0300000d'"'"' 7 | grep -q x' \
  'printf '"'"'%s\n'"'"' 300000 | grep -q x' 'echo width_echo %300000s | grep -q x' \
  'printf '"'"'%+300000d'"'"' 1 | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
finding() { printf '[pipefail-grep-q] plugins/rite/hooks/fixture.sh:%s: immediate producer before grep -q: %s' "$1" "$2"; }
assert "echo of a question-mark glob is reported" "1" "$(printf '%s\n' "$out" | grep -cxF "$(finding 2 'echo qmark_word ?')" || true)"
assert "echo of a bracket glob is reported" "1" "$(printf '%s\n' "$out" | grep -cxF "$(finding 3 'echo bracket_word [ab]')" || true)"
assert "printf with a numeric field width is reported" "1" "$(printf '%s\n' "$out" | grep -cxF "$(finding 4 "printf '%300000s' width_word")" || true)"
assert "printf with a numeric precision is reported" "1" "$(printf '%s\n' "$out" | grep -cxF "$(finding 5 "printf '%.5000f' 1")" || true)"
assert "printf with a left-justify flag and a numeric width is reported" "1" "$(printf '%s\n' "$out" | grep -cxF "$(finding 6 "printf '%-300000s' flag_minus")" || true)"
assert "printf with a zero flag and a numeric width is reported" "1" "$(printf '%s\n' "$out" | grep -cxF "$(finding 7 "printf '%0300000d' 7")" || true)"
assert "printf with a plus flag and a numeric width is reported" "1" "$(printf '%s\n' "$out" | grep -cxF "$(finding 10 "printf '%+300000d' 1")" || true)"
assert "a digit in a printf argument and a width-like echo word stay exempt" "7" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\]' || true)"

printf '%s\n' 'stream_many | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "same pipeline without pipefail is clean" "0" "$rc"
assert "pipefail-off run has no finding" "0" "$(printf '%s' "$out" | grep -c '^\[pipefail-grep-q\]' || true)"

printf '%s\n' \
  'set -o pipefail' \
  "cat <<'EOF'" \
  'set +o pipefail' \
  'heredoc_data | grep -q x' \
  'EOF' \
  'real_after_heredoc | grep -q x' \
  'set +o pipefail' \
  'cat <<-TABEOF' \
  $'\tset -o pipefail' \
  $'\tignored_tabbed_data | grep -q x' \
  $'\tTABEOF' \
  'set -o pipefail' \
  'delay=$((1 << attempt))' \
  'real_after_shift | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "heredoc data does not alter shell state" "1" "$rc"
assert "real pipeline after heredoc is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_heredoc' || true)"
assert "quoted heredoc body is not scanned" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*heredoc_data' || true)"
assert "tab-stripped heredoc body is not scanned" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*ignored_tabbed_data' || true)"
assert "arithmetic shift is not treated as heredoc" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_shift' || true)"

printf '%s\n' 'set -o pipefail' 'stderr_stream |& grep -q x' 'multiline_stderr_stream |&' '  grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "pipe-and pipeline is detected" "1" "$rc"
assert "pipe-and reports its immediate producer" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: stderr_stream$' || true)"
assert "multiline pipe-and is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: multiline_stderr_stream$' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'echo harmless # |' \
  'real_after_comment | grep -q x' \
  'echo harmless # \' \
  'real_after_comment_backslash | grep -q x' \
  'echo harmless;# \' \
  'real_after_metachar_comment | grep -q x' \
  "printf '%s' '|'" \
  'real_after_quoted_pipe | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "comment and quoted trailing pipes do not continue lines" "1" "$rc"
assert "pipeline after comment pipe is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_comment$' || true)"
assert "pipeline after comment backslash is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_comment_backslash' || true)"
assert "pipeline after metachar comment is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_metachar_comment' || true)"
assert "pipeline after quoted pipe is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_quoted_pipe' || true)"

printf '%s\n' \
  'set -o pipefail' \
  "printf '%s' 'literal" \
  'set +o pipefail' \
  "fake_stream | grep -q x'" \
  'real_after_single_quote | grep -q x' \
  'printf "%s" "literal' \
  'set +o pipefail' \
  'fake_double_stream | grep -q x"' \
  'real_after_double_quote | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "multiline quoted data does not alter shell state" "1" "$rc"
assert "single-quoted data pipeline is not scanned" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*fake_stream' || true)"
assert "double-quoted data pipeline is not scanned" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*fake_double_stream' || true)"
assert "pipeline after multiline single quote is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_single_quote' || true)"
assert "pipeline after multiline double quote is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_double_quote' || true)"

printf '%s\n' \
  'set -o pipefail' \
  "printf '%s' \$'it\\'s'" \
  'real_after_ansi_quote | grep -q x' \
  'value=`set +o pipefail' \
  'printf ok`' \
  'real_after_backtick | grep -q x' \
  'value="$(printf "%s' \
  'set +o pipefail' \
  '" ok)"' \
  'real_after_nested_quote | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "extended quote forms do not leak subshell state" "1" "$rc"
assert "pipeline after ANSI-C quote is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_ansi_quote' || true)"
assert "pipeline after backtick substitution is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_backtick' || true)"
assert "pipeline after nested command quote is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_nested_quote' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'stream_source "multi' \
  'line" |' \
  'grep -q x' \
  'stderr_source "multi' \
  'line" |&' \
  'grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "contextual quote-close pipeline tails are detected" "1" "$rc"
assert "quote-close pipe reports producer" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: stream_source' || true)"
assert "quote-close pipe-and reports producer" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: stderr_source' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'value=$(cat <<EOF' \
  'fake_substitution_data | grep -q x' \
  'EOF' \
  ')' \
  'real_after_substitution_heredoc | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "substitution heredoc data is skipped" "1" "$rc"
assert "substitution heredoc fake pipeline is not scanned" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*fake_substitution_data' || true)"
assert "pipeline after substitution heredoc is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_substitution_heredoc' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'cat <<EOF \' \
  '  > /dev/null' \
  'payload' \
  'EOF' \
  'cat << \' \
  "  'SPLIT'" \
  'set +o pipefail' \
  'SPLIT' \
  "cat <<\$'ANSI'" \
  'fake_ansi_data | grep -q x' \
  'ANSI' \
  'real_after_continued_heredocs | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "continued heredoc declarations preserve analysis" "1" "$rc"
assert "continued heredoc body state does not leak" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_continued_heredocs' || true)"
assert "ANSI-C heredoc body is not scanned" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*fake_ansi_data' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'cat <<EO\' \
  'F' \
  'set +o pipefail' \
  'EOF' \
  'cat <\' \
  '<JOINED' \
  'fake_joined_data | grep -q x' \
  'JOINED' \
  'real_after_joined_heredocs | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "backslash-newline joins heredoc tokens without spaces" "1" "$rc"
assert "joined delimiter body state does not leak" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*real_after_joined_heredocs' || true)"
assert "joined operator heredoc body is not scanned" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*fake_joined_data' || true)"

printf '%s\n' \
  'set +o pipefail' \
  'set -o \' \
  'pipefail' \
  'cat <<EOF \' \
  '  ignored_argument' \
  'payload' \
  'EOF' \
  'continued_stream \' \
  '  --arg | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "backslash join preserves surrounding whitespace" "1" "$rc"
assert "continued pipefail activation is retained" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: continued_stream.*--arg' || true)"
assert "continued producer retains a visible separator" "0" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: continued_stream--arg' || true)"

printf '%s\n' \
  '( set -o pipefail; subshell_stream | grep -q x )' \
  'captured=$(set -o pipefail; substitution_stream | grep -q x)' \
  'late_stream | grep -q x; set -o pipefail' \
  'set -o pipefail' \
  '( set +o pipefail; disabled_subshell_stream | grep -q x )' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "scoped activations produce findings" "1" "$rc"
assert "subshell activation is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*subshell_stream' || true)"
assert "command-substitution activation is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*substitution_stream' || true)"
assert "activation after a pipeline is not retroactive" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*late_stream' || true)"
assert "scoped deactivation suppresses its pipeline" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*disabled_subshell_stream' || true)"

printf '%s\n' \
  'set -o pipefail; first_active | grep -q x' \
  'inherited_active | grep -q x' \
  'set +o pipefail; first_disabled | grep -q x' \
  'inherited_disabled | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "top-level same-line activation yields findings" "1" "$rc"
assert "top-level activation applies on its line" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*first_active' || true)"
assert "top-level activation persists to the next line" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*inherited_active' || true)"
assert "top-level deactivation applies on its line" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*first_disabled' || true)"
assert "top-level deactivation persists to the next line" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*inherited_disabled' || true)"

printf '%s\n' \
  '(' \
  '  set -o pipefail' \
  '  multiline_inner_active | grep -q x' \
  ')' \
  'multiline_outer_disabled | grep -q x' \
  'set -o pipefail' \
  '(' \
  '  set +o pipefail' \
  '  multiline_inner_disabled | grep -q x' \
  ')' \
  'multiline_outer_active | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "multiline scopes preserve real findings" "1" "$rc"
assert "multiline inner activation is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*multiline_inner_active' || true)"
assert "multiline activation is restored after close" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*multiline_outer_disabled' || true)"
assert "multiline inner deactivation is respected" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*multiline_inner_disabled' || true)"
assert "multiline deactivation is restored after close" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*multiline_outer_active' || true)"

printf '%s\n' \
  'set -o pipefail; first_on | grep -q x; set +o pipefail; second_off | grep -q x' \
  'first_still_off | grep -q x; set -o pipefail; second_on | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "mixed same-line pipelines retain active findings" "1" "$rc"
assert "on-to-off first pipeline is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*first_on' || true)"
assert "on-to-off second pipeline is suppressed" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*second_off' || true)"
assert "off-to-on first pipeline is suppressed" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*first_still_off' || true)"
assert "off-to-on second pipeline is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*second_on' || true)"

printf '%s\n' 'set -o pipefail; stream_one | echo done; stream_many | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "prior exempt consumer cannot hide later producer" "1" "$rc"
assert "producer is cut at the command-list boundary" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: stream_many$' || true)"

printf '%s\n' 'set -o pipefail; echo done & async_stream | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "async-list boundary cannot hide later producer" "1" "$rc"
assert "single ampersand cuts the immediate producer" "1" "$(printf '%s\n' "$out" | grep -c 'producer before grep -q: async_stream$' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'unused() {' \
  '  expanded=${value:-fallback}' \
  '  { echo nested; }' \
  '  set +o pipefail' \
  '  function_inner_disabled | grep -q x' \
  '}' \
  'function_outer_active | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "function body state is analyzed without leaking" "1" "$rc"
assert "function-local deactivation suppresses inner pipeline" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*function_inner_disabled' || true)"
assert "function definition restores outer state" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*function_outer_active' || true)"

printf '%s\n' \
  'set -o pipefail; set +o pipefail & background_parent_on | grep -q x' \
  'set +o pipefail; set -o pipefail & background_parent_off | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "background toggle isolation retains active finding" "1" "$rc"
assert "background disable does not change active parent" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*background_parent_on' || true)"
assert "background enable does not change disabled parent" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*background_parent_off' || true)"

printf '%s\n' \
  'called_active() { called_active_stream | grep -q x; }' \
  'set -o pipefail' \
  'called_active' \
  'set -o pipefail' \
  'called_disabled() { called_disabled_stream | grep -q x; }' \
  'set +o pipefail' \
  'called_disabled' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "function call-state analysis retains active finding" "1" "$rc"
assert "definition-off call-on function is detected" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*called_active_stream' || true)"
assert "definition-on call-off function is suppressed" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*called_disabled_stream' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'split_style()' \
  '{' \
  '  set +o pipefail' \
  '}' \
  'function keyword_style' \
  '{' \
  '  set +o pipefail' \
  '}' \
  'after_split_definitions | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "multiline function headers preserve outer state" "1" "$rc"
assert "both multiline declaration styles restore state" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_split_definitions' || true)"

printf '%s\n' \
  'enable_pf() { set -o pipefail; }' \
  'disable_pf() { set +o pipefail; }' \
  'set +o pipefail' \
  'enable_pf; after_enable_call | grep -q x' \
  'disable_pf; after_disable_call | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "function option side effects retain active finding" "1" "$rc"
assert "enable helper changes caller state" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_enable_call' || true)"
assert "disable helper changes caller state" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*after_disable_call' || true)"

printf '%s\n' \
  'callee_on() { nested_on_stream | grep -q x; }' \
  'caller_on() { set -o pipefail; callee_on; }' \
  'callee_off() { nested_off_stream | grep -q x; }' \
  'caller_off() { set +o pipefail; callee_off; }' \
  'set +o pipefail; caller_on' \
  'set -o pipefail; caller_off' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "nested call-state propagation retains active finding" "1" "$rc"
assert "nested caller activation reaches callee" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*nested_on_stream' || true)"
assert "nested caller deactivation reaches callee" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*nested_off_stream' || true)"

printf '%s\n' \
  'nested_enable() { set -o pipefail; }' \
  'enable_wrapper() { nested_enable; }' \
  'nested_disable() { set +o pipefail; }' \
  'disable_wrapper() { nested_disable; }' \
  'set +o pipefail; enable_wrapper' \
  'after_enable_wrapper | grep -q x' \
  'disable_wrapper' \
  'after_disable_wrapper | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "wrapper exit-effect propagation retains active finding" "1" "$rc"
assert "nested enable effect returns through wrapper" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_enable_wrapper' || true)"
assert "nested disable effect returns through wrapper" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*after_disable_wrapper' || true)"

printf '%s\n' \
  'disable_conditional() { set +o pipefail; }' \
  'set -o pipefail' \
  'if false; then disable_conditional; fi' \
  'after_false_branch | grep -q x' \
  'producer_disable() { set +o pipefail; stream_many; }' \
  'producer_disable | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "non-current-shell effects retain active findings" "1" "$rc"
assert "untaken conditional effect is not applied" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_false_branch' || true)"
assert "pipeline function effect is not applied to parent" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*producer_disable' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'if false; then set +o pipefail; fi' \
  'after_direct_false_disable | grep -q x' \
  'set +o pipefail' \
  'if false; then set -o pipefail; fi' \
  'after_direct_false_enable | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "direct conditional toggles preserve real active finding" "1" "$rc"
assert "untaken direct disable is not applied" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_direct_false_disable' || true)"
assert "untaken direct enable is not applied" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*after_direct_false_enable' || true)"

printf '%s\n' \
  'set +o pipefail' \
  'if true; then set -o pipefail; fi' \
  'after_direct_true_enable | grep -q x' \
  'if true; then set +o pipefail; fi' \
  'after_direct_true_disable | grep -q x' \
  'set -o pipefail' \
  'if false; then' \
  '  set +o pipefail' \
  'fi' \
  'after_multiline_false_disable | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "literal conditional model retains active findings" "1" "$rc"
assert "taken direct enable is applied" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_direct_true_enable' || true)"
assert "taken direct disable is applied" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*after_direct_true_disable' || true)"
assert "multiline untaken disable is not applied" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_multiline_false_disable' || true)"

printf '%s\n' \
  'arg_enable() { set -o pipefail; }' \
  'arg_disable() { set +o pipefail; }' \
  'set +o pipefail; arg_enable on; after_arg_enable | grep -q x' \
  'arg_disable off; after_arg_disable | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "argument-bearing helper effects retain active finding" "1" "$rc"
assert "argument-bearing enable changes parent" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_arg_enable' || true)"
assert "argument-bearing disable changes parent" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*after_arg_disable' || true)"

printf '%s\n' \
  'set -o pipefail' \
  'if probe | grep -q ready; then set +o pipefail; fi' \
  'after_unknown_piped_disable | grep -q x' \
  'set +o pipefail' \
  'if probe | grep -q ready; then set -o pipefail; fi' \
  'after_unknown_piped_enable | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "unknown piped conditions preserve possible findings" "1" "$rc"
assert "unknown piped disable cannot erase active possibility" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_unknown_piped_disable' || true)"
assert "unknown piped enable retains active possibility" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_unknown_piped_enable' || true)"

printf '%s\n' \
  'maybe_disable() { if false; then set +o pipefail; fi; }' \
  'maybe_enable() { if false; then set -o pipefail; fi; }' \
  'set -o pipefail; maybe_disable; after_helper_false_disable | grep -q x' \
  'set +o pipefail; maybe_enable; after_helper_false_enable | grep -q x' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "helper literal-false summaries preserve active finding" "1" "$rc"
assert "helper untaken disable is identity" "1" "$(printf '%s\n' "$out" | grep -c 'producer.*after_helper_false_disable' || true)"
assert "helper untaken enable is identity" "0" "$(printf '%s\n' "$out" | grep -c 'producer.*after_helper_false_enable' || true)"

printf '%s\n' 'set -o pipefail' 'stream_many | grep -q x # drift-check-ignore: bounded fixture' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "ignore marker suppresses finding" "0" "$rc"
assert "ignored run reports zero" "1" "$(printf '%s' "$out" | grep -c 'Total pipefail-grep-q findings: 0')"

# Every tests/ directory under the scan roots is scanned like production code.
tests_dirs=(plugins/rite/hooks/tests plugins/rite/scripts/tests plugins/rite/hooks/scripts/tests)
for d in "${tests_dirs[@]}"; do
  mkdir -p "$SBX/$d"
  printf '%s\n' 'set -o pipefail' 'stream_many | grep -q x' > "$SBX/$d/tests-site.sh"
done
printf '%s\n' 'set -o pipefail' 'stream_many | grep -q x' > "$SBX/plugins/rite/hooks/production-site.sh"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "production twin outside tests is detected" "1" "$rc"
assert "production twin yields one finding" "1" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\].*production-site\.sh:' || true)"
for d in "${tests_dirs[@]}"; do
  assert "tests twin in $d is detected" "1" "$(printf '%s\n' "$out" | grep -cxF "[pipefail-grep-q] $d/tests-site.sh:2: immediate producer before grep -q: stream_many" || true)"
  rm -f "$SBX/$d/tests-site.sh"
done
rm -f "$SBX/plugins/rite/hooks/production-site.sh"

REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
out=$(bash "$SCRIPT" --all --repo-root "$REPO_ROOT" --quiet 2>&1); rc=$?
assert "full-tree scan is clean" "0" "$rc"
assert "full-tree scan reports no findings" "0" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\]' || true)"
assert "wiki-lint-orphans disabled sites are not reported" "0" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\] plugins/rite/hooks/scripts/wiki-lint-orphans\.sh:' || true)"
assert "wiki-growth consumers are clean" "0" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\] plugins/rite/hooks/scripts/wiki-growth-check\.sh:' || true)"
assert "wiki-lint-broken-refs disabled sites are not reported" "0" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\] plugins/rite/hooks/scripts/wiki-lint-broken-refs\.sh:' || true)"
assert "backfill consumer is clean" "0" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\] plugins/rite/scripts/backfill-sub-issues\.sh:' || true)"
assert "review-source-resolve remains outside the finding set" "0" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\].*review-source-resolve\.sh:' || true)"

missing_root="$SBX/does-not-exist"
out=$(bash "$SCRIPT" --all --repo-root "$missing_root" --quiet 2>&1); rc=$?
assert "missing repository root is an error" "2" "$rc"
assert "missing repository root is diagnosed" "1" "$(printf '%s\n' "$out" | grep -c '^ERROR: repository root is not a directory:')"

empty_root="$SBX/empty-root"; mkdir -p "$empty_root"
out=$(bash "$SCRIPT" --all --repo-root "$empty_root" --quiet 2>&1); rc=$?
assert "missing scan roots fail closed" "2" "$rc"
out=$(bash "$SCRIPT" --all --skip-if-no-target --repo-root "$empty_root" --quiet 2>&1); rc=$?
assert "explicit consumer-repo skip remains clean" "0" "$rc"
print_summary "pipefail-grep-q-check.sh"
