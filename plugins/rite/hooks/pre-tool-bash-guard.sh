#!/bin/bash
# rite workflow - Pre-Tool Bash Guard (PreToolUse hook)
# Blocks known-bad Bash command patterns before execution.
# Uses only Bash built-ins for pattern matching (no external processes).
#
# Denylist patterns:
#   1. gh pr diff --stat  (unsupported flag)
#   2. gh pr diff -- <path>  (unsupported file filter)
#   3. != null in jq/awk  (history expansion breaks !)
#   4. Reviewer subagent .git-write gate — enforced only in subagent contexts.
#      Four sub-checks serving one guarantee (no writes into a .git directory):
#        (L) oversized command → deny (timeout-based bypass prevention)
#        (Z) shell-command wrapper (eval / sh -c / ...) → deny (opaque quoting
#            can hide a .git write)
#        (N) native .git-writing git subcommand (config write forms / mutating
#            remote / update-ref / symbolic-ref) → deny (writes .git/config or
#            .git refs with no redirect or file verb for (H) to see)
#        (H) WRITE into a .git dir via redirect / file-mutating verb → deny
#   5. Merge-point review-result positive gate (Issue #2159) — main-session
#      (and any session) Bash that issues `gh pr merge` / REST pulls/{n}/merge /
#      GraphQL mergePullRequest is denied unless `.rite/review-results/{pr}-*.json`
#      exists with minimum form (schema_version + verdict keys, reviewers array
#      length >= sole-reviewer guard floor 2). Fail-closed on PR-number
#      unresolvable / missing / malformed / floor-under JSON. Purpose: block
#      procedure-omission bypass of /rite:pr-review, not adversarial forgery.
#
# Reviewer working-tree mutations (git checkout / reset / commit / branch / ...)
# are deliberately NOT machine-gated here (Issue #1879). They are visible and
# recoverable via `git status`; their guarantee is Layer 1 (the reviewer prompt
# READ-ONLY contract, plugins/rite/agents/_reviewer-base.md) + Layer 3
# (post-review-state-verify.sh drift detection after each review). Only the
# .git-write path keeps a machine gate: it is invisible to `git status`,
# effectively irreversible, and plants arbitrary code execution in the
# non-sandboxed main session (.git/hooks/*, .git/config core.hooksPath /
# alias.*=!sh / core.fsmonitor) — strictly worse than a source edit.
#
# Exit behavior: exit 0 — allow (no output); stdout JSON with
# permissionDecision: "deny" — block.
#
# Fail direction is pattern-specific: Patterns 1-3 (convenience) fail OPEN so an
# edge-case parse crash never false-blocks a legitimate command; Pattern 4 (the
# reviewer .git-write security boundary) fails CLOSED so a parse crash never
# silently bypasses the guard. See the two ERR traps below.
#
# hooks.json timeout: 10s — a generous ceiling for a bash-builtins gate, aligned
# with the other lightweight synchronous gates (Stop=10s, bang-backtick hook=10s).
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_PRETOOL:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRETOOL=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
# neutralize_ctrl --c0-only (deny フォールバックの JSON エスケープ用)。
# guard なし source は意図的: helper 欠落 (= plugin 破損) による source 失敗の exit 1
# も PreToolUse では non-blocking = allow として Pattern 1-3 と同じ fail-open に収束する
# (flow-state.sh / stop-loop-continuation.sh の必須依存 precedent と同一)。`|| true` を
# 付けてはならない — neutralize_ctrl 未定義のまま deny フォールバックに到達すると
# command not found で reason を失い placeholder へ縮退するだけで、guard を付ける利点がない。
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Deny フォールバック JSON 用の reason エスケープ。適用順序が契約:
# backslash → double-quote → 改行 \n 化 → neutralize_ctrl --c0-only (残存 C0+DEL を ? 化)。
# backslash エスケープが先頭でないと、後続が生成する \" / \n の backslash を二重に
# エスケープしてしまう。--c0-only なのは byte 単位の C1 置換が UTF-8 マルチバイト本文を
# 破壊するため (RFC 8259 が生バイトを禁じるのは U+0000-001F のみ)。neutralize_ctrl 失敗時は
# 非ゼロ exit し、caller が static placeholder へ縮退する (fail-closed)。
# tests/pre-tool-bash-guard.test.sh の TC-117 が本関数定義を境界行
# (`_bash_guard_escape_deny_reason() {` / `}`) で抽出して改行 / raw C0 実入力の変換を
# 直接 pin する — シグネチャ・境界行を変える際はテスト側の抽出パターンも更新すること。
_bash_guard_escape_deny_reason() {
  local _r="$1"
  _r="${_r//\\/\\\\}"
  _r="${_r//\"/\\\"}"
  _r="${_r//$'\n'/\\n}"
  printf '%s' "$_r" | neutralize_ctrl --c0-only
}
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Only inspect Bash tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || COMMAND=""
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Reviewer subagent detection — three-tier (future-proofing against SDK drift):
#   Tier 1 (primary):  transcript_path glob `*/subagents/*` — Claude Code routes
#                      subagent sessions under a "subagents/" directory; the main
#                      session does not.
#   Tier 2 (fallback): hook input JSON `subagent_type` / `agent_type` field.
#                      Presence-only check on STRING values; numeric/array/object
#                      values are rejected via `| strings` so jq's `//` operator
#                      (only null/false falsy) cannot let them through.
#   Tier 3 (fallback): env vars CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE.
# Caveat: presence-only fires on any non-empty string. If a future SDK emits
# sentinel values (`"main"` / `"none"`) on main-session hooks, upgrade to an
# allow-list check (e.g. `*-reviewer` glob). The deny-message recovery text
# covers the Tier 3 `unset` path.
#
# All three field extractions share a single jq invocation (fork overhead on the
# PreToolUse hot path). jq 失敗時の空 fallback は subagent 判定経路を silent に外す
# 危険があるため、RITE_DEBUG 設定時は失敗詳細を debug log へ追記して観測可能にする。
_jq_input_err=$(mktemp 2>/dev/null) || _jq_input_err=""
JQ_OUT=$(echo "$INPUT" | jq -r '[(.transcript_path // ""), (.subagent_type | strings // ""), (.agent_type | strings // "")] | @tsv' 2>"${_jq_input_err:-/dev/null}") || JQ_OUT=$'\t\t'
if [ -n "${RITE_DEBUG:-}" ] && [ -n "$_jq_input_err" ] && [ -s "$_jq_input_err" ]; then
  printf '[%s] pre-tool-bash-guard: jq input parse stderr: %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(head -c 200 "$_jq_input_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)" \
    >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
fi
[ -n "$_jq_input_err" ] && rm -f "$_jq_input_err"
TRANSCRIPT_PATH=$(printf '%s' "$JQ_OUT" | cut -f1)
INPUT_SUBAGENT_TYPE=$(printf '%s' "$JQ_OUT" | cut -f2)
INPUT_AGENT_TYPE=$(printf '%s' "$JQ_OUT" | cut -f3)
IS_SUBAGENT=0
case "$TRANSCRIPT_PATH" in
  */subagents/*) IS_SUBAGENT=1 ;;
esac
if [ "$IS_SUBAGENT" = "0" ]; then
  if [ -n "$INPUT_SUBAGENT_TYPE" ] || [ -n "$INPUT_AGENT_TYPE" ]; then
    IS_SUBAGENT=1
  fi
fi
if [ "$IS_SUBAGENT" = "0" ]; then
  if [ -n "${CLAUDE_SUBAGENT_TYPE:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]; then
    IS_SUBAGENT=1
  fi
fi

# Fail-open ERR trap for Patterns 1-3: if heredoc extraction or simple pattern
# matching crashes on edge-case input, allow the command rather than blocking it.
_rite_btg_pattern13_fail_open() {
  if [ -n "${RITE_DEBUG:-}" ]; then
    printf '[%s] pre-tool-bash-guard: Pattern 1-3 ERR trap fired — command allowed via fail-open\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
  fi
  exit 0
}
# Fail-closed ERR trap for Pattern 4 (the reviewer .git-write security boundary):
# a crash while evaluating a reviewer command DENIES (deny JSON + exit 2 + stderr
# WARNING) instead of allowing — the opposite direction from the fail-open trap:
# convenience patterns must not false-block, the security pattern must not
# false-allow. Installed only for the Pattern 4 block (swapped in at block entry,
# restored at block exit), so non-reviewer sessions are never denied by it.
_rite_btg_pattern4_fail_closed() {
  local _rc=$?
  trap - ERR  # prevent re-entrancy while emitting the deny
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] pre-tool-bash-guard: WARNING Pattern 4 (reviewer .git-write guard) crashed (rc=$_rc) — command DENIED via fail-closed" >&2
  if [ -n "${RITE_DEBUG:-}" ]; then
    printf '[%s] pre-tool-bash-guard: Pattern 4 ERR trap fired (rc=%s) — deny fail-closed\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$_rc" \
      >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
  fi
  local _reason="BLOCKED (reviewer-gitdir-write): Pattern 4 security-boundary evaluation crashed; denying fail-closed to avoid bypassing the reviewer .git-write guard. See the bash-guard stderr WARNING for the crash context."
  # Mirror the result-section emit contract: jq for the payload, printf fallback
  # via _bash_guard_escape_deny_reason so a jq failure still emits a valid deny.
  if ! jq -n --arg reason "$_reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }' 2>/dev/null; then
    local _escaped
    _escaped=$(_bash_guard_escape_deny_reason "$_reason" 2>/dev/null) \
      || _escaped="BLOCKED: reviewer command denied (Pattern 4 crash, fail-closed)."
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$_escaped"
  fi
  exit 2
}
trap '_rite_btg_pattern13_fail_open' ERR

# --- Denylist check (Bash built-ins only) ---

BLOCKED_PATTERN=""
BLOCKED_REASON=""
BLOCKED_ALTERNATIVE=""

# --- (L) Reviewer command length guard (O(1), primary fail-closed bound) ---
# Runs BEFORE the heredoc strip and every pattern check: that downstream work is
# whole-string, and the `${COMMAND%%<<*}` strip / Pattern 2 regex are O(n²) on
# MB-scale input (empirically ~45s / >2min). A timed-out PreToolUse hook fails
# OPEN (Claude Code cancels it and lets the tool run), so a reviewer could pad a
# .git write until parsing times out, dropping the deny. The ERR trap cannot
# catch a timeout (the process is killed externally), so the bound must be
# up-front and O(1): guard on the RAW ${#COMMAND}. A legitimate reviewer command
# is at most a few KB. Setting BLOCKED_PATTERN here short-circuits the heredoc
# strip and Patterns 1-4 (all guarded by `[ -z "$BLOCKED_PATTERN" ]`). Scoped to
# IS_SUBAGENT=1 — main-session Bash is never blocked by size.
_RITE_BTG_MAX_SUBAGENT_CMD_BYTES=65536
if [ "$IS_SUBAGENT" = "1" ] && [ "${#COMMAND}" -gt "$_RITE_BTG_MAX_SUBAGENT_CMD_BYTES" ]; then
  BLOCKED_PATTERN="reviewer-oversized-command"
  BLOCKED_REASON="This reviewer command is abnormally large (${#COMMAND} bytes, ceiling ${_RITE_BTG_MAX_SUBAGENT_CMD_BYTES}). A command this size could make the guard's parsing exceed the PreToolUse hook timeout, and a timed-out hook fails OPEN (the command would be allowed) — so oversized reviewer commands are denied fail-closed to prevent a timeout-based bypass of the reviewer .git-write guard."
  BLOCKED_ALTERNATIVE="Simplify the command — reviewer operations are at most a few KB. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement) for the read-only command set."
fi

# --- Heredoc-safe command extraction ---
# Strip heredoc content to avoid false positives on text inside commit messages,
# PR descriptions, etc. Only check the command prefix before the first heredoc
# marker. Known limitation: piped heredocs (`cat <<EOF | gh pr diff`) bypass the
# strip (the pre-`<<` command is `cat`); rare in practice. Skipped for an
# already-denied (oversized) command — the strip is O(n²) on huge input and
# CMD_CHECK is unused in that case.
if [ -z "$BLOCKED_PATTERN" ]; then
  CMD_CHECK="${COMMAND%%<<*}"
else
  CMD_CHECK=""
fi

# Pattern 1: gh pr diff --stat
if [ -z "$BLOCKED_PATTERN" ]; then
  case "$CMD_CHECK" in
    *"gh pr diff"*" --stat"*)
      BLOCKED_PATTERN="gh-pr-diff-stat"
      BLOCKED_REASON="gh pr diff does not support the --stat flag."
      BLOCKED_ALTERNATIVE="Use: gh pr view {pr_number} --json files --jq '.files[] | {path, additions, deletions}'"
      ;;
  esac
fi

# Pattern 2: gh pr diff -- <path> (file filter)
# `[^|]*` (zero-or-more) covers both forms: `gh pr diff 123 -- file` and
# `gh pr diff -- file` (when invoked from a PR branch with no positional arg).
if [ -z "$BLOCKED_PATTERN" ]; then
  if [[ "$CMD_CHECK" =~ gh[[:space:]]+pr[[:space:]]+diff[[:space:]]+[^|]*[[:space:]]?--[[:space:]] ]]; then
    BLOCKED_PATTERN="gh-pr-diff-file-filter"
    BLOCKED_REASON="gh pr diff does not support -- <path> for per-file filtering."
    BLOCKED_ALTERNATIVE="Use: gh pr diff {pr_number} | awk '/^diff --git/ { found=0 } /^diff --git.*target_pattern/ { found=1 } found { print }'"
  fi
fi

# Pattern 3: != null in jq expressions (history expansion breaks !)
if [ -z "$BLOCKED_PATTERN" ]; then
  case "$CMD_CHECK" in
    *'!= null'*|*'!=null'*)
      BLOCKED_PATTERN="jq-not-equal-null"
      BLOCKED_REASON="!= null causes bash history expansion errors. The ! character is interpreted by bash before reaching jq."
      BLOCKED_ALTERNATIVE="Use: select(.field) for truthiness check, or select(.field == null | not) for explicit null exclusion"
      ;;
  esac
fi

# Pattern 4: Reviewer subagent .git-write gate.
# Scope: only when IS_SUBAGENT=1. Main-session operations are never affected.
# This block does NOT enumerate working-tree-mutating git verbs (Issue #1879) —
# see the header. It holds one machine guarantee (no writes into .git) via the
# (Z) wrapper check, the (N) native-subcommand gate, and the (H) write
# detection below, inside a fail-CLOSED trap region.
if [ -z "$BLOCKED_PATTERN" ] && [ "$IS_SUBAGENT" = "1" ]; then
  trap '_rite_btg_pattern4_fail_closed' ERR
  # Test-only fault injection for the fail-CLOSED region (no effect in
  # production): the block uses only bash built-ins, so — unlike the deny-emit
  # path (test TC-118) — it cannot be crashed by faking an external binary. This
  # lets the fail-closed regression test raise an ERR deterministically inside
  # the guarded region. Deliberately fail-CLOSED-only: if the env var is ever
  # set in production the only effect is a DENY — it can never turn the guard
  # into allow-all. A symmetric fail-OPEN injection was intentionally NOT added
  # (an env-triggered fail-open would be an allow-all backdoor to a security
  # boundary).
  if [ "${RITE_BTG_TEST_CRASH:-}" = "pattern4" ]; then
    false
  fi
  # Normalize whitespace AND shell meta-characters into a single space so that
  # `;eval …` / `(eval …)` / multi-line commands are recognized with proper word
  # boundaries by the wrapper check, and so the .git-write tokenizer sees
  # redirect targets as separable tokens. `>` / `<` survive (the tokenizer
  # surfaces them as standalone tokens itself).
  CMD_NORMALIZED="${CMD_CHECK//$'\t'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//$'\n'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//$'\r'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//;/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//&/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//|/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//(/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//)/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\{/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\}/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\`/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\$/ }"
  while [[ "$CMD_NORMALIZED" == *"  "* ]]; do
    CMD_NORMALIZED="${CMD_NORMALIZED//  / }"
  done

  PADDED=" $CMD_NORMALIZED "

  # --- (Z) Shell-command wrapper guard ---
  # `eval` / `sh -c` / `bash -c` 等の quoted argument は静的 matching と
  # word-boundary を共有しないため、(H) の .git-write 検出を
  # `bash -c 'echo x > .git/hooks/y'` の形で trivially bypass できる。reviewer が
  # wrapper を使う legitimate な理由はほぼない (read-only な script 実行は
  # `bash <script>` で十分) ため、中身に関係なく一律 block する。
  # `bash <script.sh>` は allow し続ける必要があるため、`-c` の直前トークンが
  # shell 名であるパターンのみを block する。
  case "$PADDED" in
    *" eval "*|\
    *" sh -c "*|\
    *" bash -c "*|\
    *" zsh -c "*|\
    *" ksh -c "*|\
    *" dash -c "*|\
    *" fish -c "*)
      BLOCKED_PATTERN="reviewer-shell-wrapper"
      BLOCKED_REASON="Shell-command wrappers (eval / bash -c / sh -c / zsh -c / ksh -c / dash -c / fish -c) are blocked in reviewer contexts because their quoted argument is opaque to this guard's word-boundary matching and can hide forbidden operations (e.g. a write into a .git directory). They are therefore blocked unconditionally — even when the wrapped command is read-only. Reviewers are bound by the READ-ONLY contract in plugins/rite/agents/_reviewer-base.md."
      BLOCKED_ALTERNATIVE="For a read-only probe, drop the wrapper: run the command directly, group multiple commands in a subshell '( cmd1; cmd2 )', or put them in a file and run 'bash <script.sh>'. If this block fires on a main session (not a reviewer subagent), check whether CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE env vars are accidentally set; recover with: unset CLAUDE_SUBAGENT_TYPE CLAUDE_AGENT_TYPE"
      ;;
  esac

  # --- (N) Native .git-writing git subcommands ---
  # `git config <key> <value>` / mutating `git remote` / `git update-ref` /
  # `git symbolic-ref` write .git/config or .git refs directly — no shell
  # redirect and no file-mutating verb, so (H) cannot see them. `git config
  # core.hooksPath / core.fsmonitor / alias.*=!cmd` (and the inline `git -c
  # core.hooksPath=… <cmd>` form, which needs NO config subcommand) is the exact
  # RCE vector the header invariant names, so the write forms keep a machine
  # gate. This is a FIXED closed set whose only write target is .git itself — a
  # .git-write gate, NOT a revival of the working-tree verb enumeration
  # (Issue #1879 removed working-tree verbs; these were never in that class:
  # .git/config writes are invisible to `git status` and Layer 3 has no
  # config/ref axis, so Layer 1 would be the sole backstop without this gate).
  #
  # Global-flag handling is REQUIRED, not optional: `git -C x config …` /
  # `git --git-dir=x config …` place the subcommand after a flag, and `git -c
  # key=val <cmd>` injects config with no subcommand at all — both bypass a naive
  # "subcommand right after git" match. The removed (A)-(G) code normalized
  # global flags for exactly this reason; dropping it entirely would ship a
  # WEAKER gate than pre-PR — this block re-scopes that handling to the four
  # .git-write subcommands. The token loop below is a per-occurrence FSM: it
  # skips leading global flags, then classifies each `config`/`remote`/`update-
  # ref`/`symbolic-ref` occurrence AS IT APPEARS (deciding read-vs-write on the
  # token right after `config`/`remote`), and re-recognizes every fresh `git`
  # invocation. It replaced a flatten-then-substring-match approach that let a
  # co-located read-form exempt a real write in the same command line and let a
  # second invocation slip. Inline `-c` / `--config-env` deny immediately (a
  # reviewer never needs to SET config — "値を設定する git config は一律 deny").
  #
  # `git config` read forms stay allowed via a small allow-list (--list / -l /
  # --get / --get-all / --get-regexp) — checked at the first non-flag token after
  # `config` / `remote`; every other form denies — no strict option parsing (an
  # exotic mis-denied read form, or `config`/`remote` with no arg immediately
  # followed by a fresh `git`, is rare and recoverable via the deny message;
  # strict parsing would re-open the static-parse churn this hook just removed).
  #
  # RESIDUAL (Layer 1 backstop ONLY — same class as the (H) SCOPE limitations):
  #   - env-var config indirection (`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/
  #     `GIT_CONFIG_VALUE_n`, `GIT_DIR`) and `--config-env=<key>=<envvar>`
  #     chained through an env var (the flag itself is denied above, but the
  #     value it names lives in the environment);
  #   - aliases already persisted in .git/config;
  #   - an UNKNOWN separate-arg global flag (one not in the skip_arg list above)
  #     whose value absorbs the subcommand slot. The skip_arg list is
  #     git-version-dependent, not provably exhaustive: git can add flags, and
  #     older gits accept flags 2.43 rejects. This is NOT a regression (develop's
  #     enumeration could not catch unknown flags either), so it does not lower
  #     the gate strength vs pre-PR — it is an inherent static-matcher limit
  #     backstopped by Layer 1. Re-audit the list on a git upgrade.
  # Runtime-resolved subcommand/flag tokens (`$VAR`/`$(cmd)`) are already
  # collapsed to spaces upstream. Handled above (NOT residual):
  # path/quoted/backslashed git invocations and every KNOWN separate-arg flag.
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Per-occurrence state machine — evaluate EACH git invocation independently
    # rather than flattening the command to one string and substring-matching it.
    # A flattened match let a co-located read-form mask a real write in the SAME
    # command line (`git config --list; git config core.hooksPath /x` → the
    # ` git config --list ` substring exempted the whole string, including the
    # write) and let a second invocation slip (`git; /usr/bin/git config …`).
    # Walking token-by-token with a small FSM decides read-vs-write at each
    # `config`/`remote` occurrence and re-recognizes every fresh `git` invocation,
    # so neither evasion survives.
    #
    # noglob for the unquoted `for … in $CMD_NORMALIZED` tokenizer (same reason
    # as the (H) loop: an un-noglobbed `*` token would pathname-expand against
    # the hook CWD → over-DENY / timeout). Save/restore the prior state.
    case $- in *f*) _gn_noglob_was_set=1 ;; *) _gn_noglob_was_set=0 ;; esac
    set -f
    _gn_hit=""
    _gn_state=scan        # scan | flags | cfgarg | remarg
    _gn_skip_arg=0        # 1 = drop this token (an arg-taking global flag's value)
    for _gn_tok in $CMD_NORMALIZED; do
      # Dequote the way the shell does before the flag/subcommand is interpreted,
      # so `"git"` / `\git` / `'add'` normalize to their bare forms. `*/git` below
      # then catches path invocations (`/usr/bin/git`, `./git`). Trade-off: a
      # search over git's own source (`grep -rn 'git config' plugins/`) tokenizes
      # to a bare ` git config `, so it over-DENYs (fail-closed, rare, recoverable
      # — break the adjacency: `grep -rn git plugins/ | grep config`). Precise
      # narrowing would need the separator tracking #1879 deliberately removed.
      _gn_t="${_gn_tok//[\"\']/}"; _gn_t="${_gn_t//\\/}"
      if [ "$_gn_skip_arg" = "1" ]; then _gn_skip_arg=0; continue; fi
      case "$_gn_state" in
        cfgarg)
          # Previous token was `config`; this token decides read vs write.
          case "$_gn_t" in
            --list|-l|--get|--get-all|--get-regexp) _gn_state=scan ;;   # read → OK, keep scanning
            *) _gn_hit="git config (non-read form)"; break ;;           # anything else → write → deny
          esac ;;
        remarg)
          # Previous token was `remote`. Fail-CLOSED default like cfgarg, but the
          # grammar differs and the asymmetry matters: a `config` read option
          # (`--list`/`--get`) is a TERMINAL action (git errors if a write
          # follows), whereas `git remote -v`/`--verbose` is a MODIFIER that
          # precedes the sub-action (`git remote -v add …` still mutates). So a
          # flag here must NOT be treated as a read — it stays in remarg and the
          # real sub-action is classified next. Only `show`/`get-url` are terminal
          # read sub-actions. Everything else — the mutating sub-actions AND any
          # unrecognized/future one — denies (a mutating remote persists
          # `remote.<n>.url = ext::sh -c …` into .git/config → RCE on next fetch).
          # Trade-off: separators (`|`/`;`/`&`) are collapsed to spaces upstream,
          # so a read pipe (`git remote -v | grep origin`) tokenizes as `-v grep`
          # and the `grep` hits `*)` → over-DENY (fail-closed, recoverable — run
          # bare `git remote -v` / `git remote get-url <n>`, or break the
          # adjacency). Do NOT "fix" it by re-allowing an unknown token after a
          # flag: that is exactly the `git remote -v add …` bypass this arm closed.
          case "$_gn_t" in
            -*) : ;;                          # modifier flag (-v/--verbose/…): stay in remarg for the sub-action
            show|get-url) _gn_state=scan ;;   # terminal read sub-action → OK, keep scanning
            git|*/git) _gn_state=flags ;;     # `remote` had no sub-action; fresh invocation
            *) _gn_hit="git remote (mutating sub-action)"; break ;;   # mutating / unknown → deny
          esac ;;
        flags)
          # After a git invocation, strip leading global flags, then classify the
          # subcommand. The skip_arg list is a SUPERSET of the flags the removed
          # (A)-(G) normalization covered (`-C`/`--git-dir`/`--work-tree`/
          # `--exec-path`/`--namespace`/`-c`/`--config-env`) plus the git-2.43
          # plumbing flags `--attr-source`/`--shallow-file` and the legacy
          # `--super-prefix` (retired in git 2.43, kept for older-git coverage),
          # so (N) never allows a carrier form develop denied — not a regression
          # by construction. The list is git-version-dependent: an UNKNOWN
          # separate-arg flag whose value absorbs the subcommand is the
          # Layer-1-backstop residual noted above, not a claimed-complete gate.
          case "$_gn_t" in
            -c|-c*|--config-env|--config-env=*)
              _gn_hit="git inline config (-c / --config-env)"; break ;;   # `git -c key=val <cmd>` needs no subcommand
            -C|--git-dir|--work-tree|--namespace|--exec-path|--attr-source|--super-prefix|--shallow-file)
              _gn_skip_arg=1 ;;                    # arg-taking global flag: drop its value too
            -*) : ;;                               # self-contained / =-form / boolean global flag → skip
            git|*/git) _gn_state=flags ;;          # back-to-back invocation (previous git had no subcommand)
            update-ref|symbolic-ref) _gn_hit="git $_gn_t"; break ;;
            config) _gn_state=cfgarg ;;            # decide read/write on the next token
            remote) _gn_state=remarg ;;            # decide mutating/read on the next token
            *) _gn_state=scan ;;                   # non-dangerous subcommand (log / diff / status / …)
          esac ;;
        *)  # scan: looking for the next git invocation
          case "$_gn_t" in
            git|*/git) _gn_state=flags ;;
          esac ;;
      esac
    done
    [ "$_gn_noglob_was_set" = "1" ] || set +f

    if [ -n "$_gn_hit" ]; then
      BLOCKED_PATTERN="reviewer-gitdir-write"
      BLOCKED_REASON="Reviewer subagents must not WRITE into Git internals via native git subcommands. This command uses ${_gn_hit}, which writes .git/config or .git refs directly (or injects config inline) — no redirect or file-mutating verb involved, so the redirect/file-verb write detection cannot see it. Planting 'git config core.hooksPath / core.fsmonitor / alias.*=!cmd' (or 'git -c core.hooksPath=… <cmd>') executes arbitrary code in the non-sandboxed main session on the next git operation, and .git/config is invisible to 'git status' (no Layer 3 axis covers it). This is a fixed .git-write gate (config write forms incl. inline -c / mutating remote / update-ref / symbolic-ref, global-flag-normalized), not a working-tree verb denylist (Issue #1879)."
      BLOCKED_ALTERNATIVE="Read-only inspection stays allowed: 'git config --list', 'git config --get <key>', 'cat .git/config', 'git rev-parse --symbolic-full-name HEAD', 'git remote -v', 'git ls-remote'. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement)."
    fi
  fi

  # --- (H) reviewer WRITE into a .git directory (redirect / file-mutating verb) ---
  # pre-tool-edit-guard.sh blocks the Edit/Write path into a parent .git; this
  # closes the sibling Bash-tool gap (Issue #1864). Only WRITES into a .git dir
  # component are denied; READING .git (cat/ls/grep .git/config, `dd if=.git/…`)
  # stays allowed.
  #
  # SCOPE (deliberate — best-effort hardening, NOT full closure): a static bash
  # matcher cannot decide "does this command write to .git" in general. Matched
  # here: a redirect operand (`>`/`>>`), a positional argument of a common
  # file-writing verb (tee/cp/mv/ln/install/rsync/truncate/sponge/patch), and
  # `dd of=<path>` (`of=` is dd's sole output form). The verb list is a
  # COMMON-SET, deliberately NOT exhaustive. Out of scope for a static matcher —
  # covered by Layer 1 (reviewer prompt) ONLY, NOT by this hook and NOT by
  # Layer 3 (`.git` writes are invisible to `git status --porcelain`; a complete
  # guarantee needs filesystem permissions / sandbox):
  #   - Runtime-resolved / `$`-expanded targets (`> $VAR`, `> $(cmd)`, ANSI-C
  #     `$'\x2egit/…'`) — the `$`/`(`/`)` are collapsed to spaces above.
  #   - Glob-expanded targets (`> .git*/config`) — the tokenizer runs under
  #     `set -f`; un-noglobbing would re-open the hook-CWD pathname-expansion
  #     DoS (→ timeout → fail-open), and `.git*` is statically indistinguishable
  #     from a legit `.github` expansion.
  #   - Interpreter-embedded writes (`python3 -c "open('.git/…','w')"`).
  #   - Heredoc-body redirects (`cat <<EOF > .git/x`) — CMD_CHECK cuts at `<<`
  #     (`cat > .git/x <<EOF` IS caught); scanning raw $COMMAND would false-match
  #     `>.git` text inside heredoc/PR bodies → spurious fail-closed denies.
  #   - Flag-glued targets other than `dd of=` (`install -t.git/hooks`,
  #     `--target-directory=.git/…`) — only a .git path surfacing as its OWN
  #     token is matched (`install -t .git/hooks src` IS caught).
  # Documented traits (not gaps): a `>` or .git path inside a quoted string can
  # false-match (rare, recoverable via the deny message); `.git` is matched as a
  # genuine path COMPONENT only (`foo.git/` does not match); cp/mv/… fire even
  # when the .git path is the SOURCE; the file-verb latch persists across the
  # space-collapsed command, so it can over-DENY a later .git READ on the same
  # line (fail-closed, rare, accepted).
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Surface `>>`/`>`/`<` as standalone tokens so `x>.git/y` and `x >> .git/y`
    # both tokenize. Append order matters: `>>` before `>`.
    _gdw=" $CMD_NORMALIZED "
    _gdw="${_gdw//>>/ > }"
    _gdw="${_gdw//>/ > }"
    _gdw="${_gdw//</ < }"
    while [[ "$_gdw" == *"  "* ]]; do _gdw="${_gdw//  / }"; done
    _gd_prev=""
    _gd_fileverb=0
    # noglob for the tokenizer: `for _gd_tok in $_gdw` is UNQUOTED, so without
    # `set -f` glob metachars (`*`/`?`/`[` survive the meta-char collapse) undergo
    # pathname expansion against the hook CWD. Two fail modes closed by noglob:
    # (a) over-DENY — a `*` expanding to a CWD file named like a write-verb
    #     latches _gd_fileverb, wrongly denying a legit `.git` READ;
    # (b) TIMEOUT→FAIL-OPEN (RCE) — glob expansion is not bounded by the 64KB
    #     length guard; a large-dir glob makes this loop iterate ~1M times → hook
    #     timeout → the very .git write this block exists to deny lands.
    # `case` / `[[ == ]]` matching is unaffected by noglob. Save/restore the
    # prior noglob state (drift-safe); the restore after `done` runs on both
    # break and normal exit.
    case $- in *f*) _gd_noglob_was_set=1 ;; *) _gd_noglob_was_set=0 ;; esac
    set -f
    for _gd_tok in $_gdw; do
      # Dequote the token the way the SHELL does before opening the path, THEN
      # strip a leading `of=` (dd's write target), so `dd … of=.git/hooks/x` is
      # detected while `dd if=.git/config` (read source) is not. POSIX
      # quote-removal strips `"`, `'`, and unquoted `\` wherever they sit, so all
      # three are removed globally — a fixed surrounding strip would leave
      # obfuscated vectors (`of='.git/x'`, `> .g\it/hooks/x`) that still open the
      # real .git for the shell. Backslash removal runs BEFORE the `of=` strip so
      # `\of=.git/x` normalizes first (Issue #1864 cycle-3/4 fix). Only the
      # `.git` component match uses `_gd_p`; `_gd_prev` and `_gd_verb` use the
      # RAW `_gd_tok`. `$'…'` ANSI-C decoding is NOT done — that is a
      # `$`-expansion, already out-of-scope above.
      _gd_p="${_gd_tok//[\"\']/}"
      _gd_p="${_gd_p//\\/}"
      _gd_p="${_gd_p#of=}"
      _gd_is_gitpath=0
      case "$_gd_p" in
        .git|.git/*|*/.git|*/.git/*) _gd_is_gitpath=1 ;;
      esac
      # A .git path that is an INPUT redirect source (`… < .git/config`) is a READ.
      if [ "$_gd_prev" = "<" ]; then _gd_prev="$_gd_tok"; continue; fi
      # Redirect vector: previous surfaced token was `>` and this token is a .git path.
      if [ "$_gd_prev" = ">" ] && [ "$_gd_is_gitpath" = "1" ]; then
        BLOCKED_PATTERN="reviewer-gitdir-write"; break
      fi
      # File-mutating-verb vector: a write verb seen earlier + a .git path arg now.
      # Resolve the verb to its bare form the SAME way the shell does: strip
      # quotes/backslashes, then basename — otherwise an obfuscated verb
      # (`'tee'`, `t\ee`) evades the latch while the shell still runs it (Issue
      # #1864 cycle-5 fix). The basename catches `/usr/bin/tee`; `command cp` /
      # `exec cp` already reach here as a bare `cp` token.
      _gd_verb="${_gd_tok//[\"\']/}"; _gd_verb="${_gd_verb//\\/}"; _gd_verb="${_gd_verb##*/}"
      case "$_gd_verb" in
        tee|cp|mv|ln|install|rsync|truncate|dd|sponge|patch) _gd_fileverb=1 ;;
      esac
      if [ "$_gd_is_gitpath" = "1" ] && [ "$_gd_fileverb" = "1" ]; then
        BLOCKED_PATTERN="reviewer-gitdir-write"; break
      fi
      _gd_prev="$_gd_tok"
    done
    # Restore the prior noglob state.
    [ "$_gd_noglob_was_set" = "1" ] || set +f
    if [ "$BLOCKED_PATTERN" = "reviewer-gitdir-write" ]; then
      BLOCKED_REASON="Reviewer subagents must not WRITE into a Git internal (.git) directory. This command writes into a .git path via a shell redirect (> / >>) or a file-mutating command (tee / cp / mv / ln / install / rsync / truncate / dd of= / sponge / patch). Planting or altering .git/hooks/* or .git/config (core.hooksPath / alias.*=!sh / core.fsmonitor) executes arbitrary code in the non-sandboxed main session on the next git operation — strictly worse than a source edit and invisible to 'git status'. The Edit/Write path is already blocked by pre-tool-edit-guard.sh; this closes the Bash-tool gap (Issue #1864)."
      BLOCKED_ALTERNATIVE="Reviewers are strictly read-only — never write into .git. To INSPECT it, read instead: 'cat .git/config', 'git config --list', 'git cat-file -p <obj>', 'git show <ref>:<file>', 'git rev-parse'. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement)."
    fi
  fi

  # Restore the Patterns 1-3 fail-open trap for the shared result-emit section
  # below (it has its own fail-closed fallback for the deny-emit path).
  trap '_rite_btg_pattern13_fail_open' ERR
fi

# --- Pattern 5: Merge-point review-result positive gate (Issue #2159) ---
# Blocks merge commands that have not been through /rite:pr-review far enough
# to leave a qualifying review-results JSON. Applies to any session (not just
# subagents): the bypass path observed in the wild was main-session batch-run
# skipping pr-review. Fail direction is CLOSED (inspection failure → deny) so
# "cannot tell" never becomes "allow merge".
#
# Detection surface (CMD_CHECK after heredoc strip, same as Patterns 1-3):
#   - `gh pr merge` (CLI)
#   - REST `.../pulls/{n}/merge` (gh api)
#   - GraphQL `mergePullRequest`
# Non-merge `gh` / other Bash is untouched.
if [ -z "$BLOCKED_PATTERN" ]; then
  _mrg_is_merge=0
  # CLI: `gh pr merge` with flexible whitespace (flags/args may follow).
  # Boundary is (^|non-alnum-non-underscore) so path-prefixed binaries
  # (`/usr/bin/gh pr merge`) match — excluding `/` from the boundary class
  # would let absolute-path invocations silent-bypass the gate (measured).
  if [[ "$CMD_CHECK" =~ (^|[^[:alnum:]_])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
    _mrg_is_merge=1
  # REST merge endpoint (gh api / curl-style path fragment).
  elif [[ "$CMD_CHECK" =~ /pulls/[0-9]+/merge ]]; then
    _mrg_is_merge=1
  # GraphQL merge mutation name (argument forms vary; name is stable).
  elif [[ "$CMD_CHECK" =~ mergePullRequest ]]; then
    _mrg_is_merge=1
  fi

  if [ "$_mrg_is_merge" = "1" ]; then
    _mrg_pr=""
    # Set when `gh pr merge` tail has a non-flag token that is neither a bare
    # integer nor a /pull/{n} URL. Variable forms ("$PR", $PR) and flag values
    # that look like free tokens land here. flow-state fallback must NOT run
    # in that case — a different session's pr_number must not become the gate
    # target for an unresolved merge argv (Issue #2173).
    _mrg_nonflag_unresolved=0

    # --- PR number resolution (arg first, then flow-state only if flag-only) ---
    # 1) REST path /pulls/{n}/merge
    if [[ "$CMD_CHECK" =~ /pulls/([0-9]+)/merge ]]; then
      _mrg_pr="${BASH_REMATCH[1]}"
    fi
    # 2) `gh pr merge` tail: first bare integer token, or /pull/{n} URL form
    if [ -z "$_mrg_pr" ] && [[ "$CMD_CHECK" =~ gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+(.*) ]]; then
      _mrg_tail="${BASH_REMATCH[1]}"
      # shellcheck disable=SC2086  # intentional word-split of merge argv tail
      for _mrg_tok in $_mrg_tail; do
        case "$_mrg_tok" in
          --*) continue ;;  # flag; value may be next token (non-numeric for known flags)
        esac
        if [[ "$_mrg_tok" =~ ^[0-9]+$ ]]; then
          _mrg_pr="$_mrg_tok"
          _mrg_nonflag_unresolved=0
          break
        fi
        if [[ "$_mrg_tok" =~ /pull/([0-9]+)(/|$) ]]; then
          _mrg_pr="${BASH_REMATCH[1]}"
          _mrg_nonflag_unresolved=0
          break
        fi
        # Non-flag token that did not resolve to a PR number (variable form,
        # flag value, etc.). Keep scanning in case a later numeric token exists
        # (e.g. --body msg 2172); if none does, block flow-state fallback.
        _mrg_nonflag_unresolved=1
      done
    fi
    # 3) flow-state pr_number — only when the merge argv has no unresolved
    # non-flag token. Number-less `gh pr merge --squash` (merge skill on the PR
    # branch) still falls back; `"$PR"` / `$PR` must deny fail-loud (#2173).
    if [ -z "$_mrg_pr" ] && [ "$_mrg_nonflag_unresolved" != "1" ]; then
      _mrg_pr=$(bash "$SCRIPT_DIR/flow-state.sh" get --field pr_number --default "" 2>/dev/null) || _mrg_pr=""
      # treat unset / 0 / non-numeric as unresolved
      case "$_mrg_pr" in
        ''|0|*[!0-9]*) _mrg_pr="" ;;
      esac
    fi

    if [ -z "$_mrg_pr" ]; then
      BLOCKED_PATTERN="merge-review-pr-unresolved"
      if [ "$_mrg_nonflag_unresolved" = "1" ]; then
        BLOCKED_REASON="Cannot resolve PR number for merge: a non-flag token is present in the merge argv but is not a numeric PR number or /pull/{n} URL (e.g. variable form \"\$PR\"). flow-state is not used as a fallback for unresolved tokens — a different session PR must not gate this merge."
        BLOCKED_ALTERNATIVE="Pass the PR number explicitly as a bare integer (gh pr merge {N}) and re-run. Variable or quoted-variable forms are denied fail-loud."
      else
        BLOCKED_REASON="Cannot resolve PR number for merge (no numeric arg / URL / REST path, and flow-state pr_number is unset). Merge is denied fail-loud rather than allowed without a review-result check."
        BLOCKED_ALTERNATIVE="Pass the PR number explicitly (gh pr merge {N}) or run inside a rite session with flow-state pr_number set. After /rite:pr-review, re-run merge."
      fi
    else
      # --- review-results positive check ---
      _mrg_root=""
      if [ -n "${RITE_STATE_ROOT:-}" ] && [ -d "${RITE_STATE_ROOT}" ]; then
        _mrg_root="$RITE_STATE_ROOT"
      else
        _mrg_root=$(bash "$SCRIPT_DIR/state-path-resolve.sh" 2>/dev/null) || _mrg_root=""
      fi
      _mrg_dir="${_mrg_root:+$_mrg_root/}.rite/review-results"
      # When state root is empty, still try cwd-relative path (best-effort); empty
      # root would otherwise look in "/.rite/..." which is wrong.
      if [ -z "$_mrg_root" ]; then
        _mrg_dir=".rite/review-results"
      fi

      _mrg_ok=0
      _mrg_any=0
      _mrg_fail_kind="absent"  # absent | parse_error | missing_keys | sole_reviewer
      # nullglob so a no-match pattern expands to zero words (not the literal glob).
      _mrg_noglob_was_set=0
      case "$-" in *f*) _mrg_noglob_was_set=1 ;; esac
      set +f
      shopt -s nullglob 2>/dev/null || true
      _mrg_files=("$_mrg_dir/${_mrg_pr}-"*.json)
      shopt -u nullglob 2>/dev/null || true
      [ "$_mrg_noglob_was_set" = "1" ] && set -f || true

      for _mrg_f in "${_mrg_files[@]+"${_mrg_files[@]}"}"; do
        # Skip if array empty (bash 4.4+ empty-array iterate safety)
        [ -n "$_mrg_f" ] || continue
        [ -f "$_mrg_f" ] || continue
        _mrg_any=1
        # parse + minimum form in one jq; map outcomes to fail kinds
        _mrg_check=$(jq -r '
          if (has("schema_version")|not)
             or (.schema_version == null)
             or ((.schema_version | tostring | length) == 0)
             or (has("verdict")|not)
             or ((.reviewers | type) != "array")
            then "missing_keys"
          elif ((.reviewers | length) < 2)
            then "sole_reviewer"
          else "ok"
          end
        ' "$_mrg_f" 2>/dev/null) || _mrg_check="parse_error"
        if [ "$_mrg_check" = "ok" ]; then
          _mrg_ok=1
          break
        fi
        # Keep the most specific failure seen (prefer sole_reviewer / missing_keys
        # over a later parse_error so a mixed dir still names the real defect).
        case "$_mrg_fail_kind:$_mrg_check" in
          absent:*|parse_error:missing_keys|parse_error:sole_reviewer|missing_keys:sole_reviewer)
            _mrg_fail_kind="$_mrg_check"
            ;;
          *)
            [ "$_mrg_fail_kind" = "absent" ] && _mrg_fail_kind="$_mrg_check"
            ;;
        esac
      done

      if [ "$_mrg_ok" != "1" ]; then
        if [ "$_mrg_any" = "0" ]; then
          BLOCKED_PATTERN="merge-review-json-absent"
          BLOCKED_REASON="No review-results JSON for PR #${_mrg_pr} under ${_mrg_dir}/${_mrg_pr}-*.json. Merge requires a prior /rite:pr-review result (positive existence + minimum form)."
          BLOCKED_ALTERNATIVE="Run /rite:pr-review ${_mrg_pr} (or /rite:iterate ${_mrg_pr}) so a qualifying review-results JSON is written, then re-run merge."
        else
          case "$_mrg_fail_kind" in
            sole_reviewer)
              BLOCKED_PATTERN="merge-review-sole-reviewer"
              BLOCKED_REASON="Review-results JSON for PR #${_mrg_pr} has reviewers array length below sole-reviewer guard floor (2). A single-reviewer (or empty) result does not satisfy the merge gate."
              BLOCKED_ALTERNATIVE="Re-run /rite:pr-review ${_mrg_pr} so at least 2 reviewers are recorded, then re-run merge."
              ;;
            parse_error)
              BLOCKED_PATTERN="merge-review-json-parse"
              BLOCKED_REASON="Review-results JSON for PR #${_mrg_pr} could not be parsed (jq non-zero). A broken file is not treated as a qualifying review."
              BLOCKED_ALTERNATIVE="Remove or replace the broken ${_mrg_dir}/${_mrg_pr}-*.json and run /rite:pr-review ${_mrg_pr}, then re-run merge."
              ;;
            *)
              BLOCKED_PATTERN="merge-review-json-incomplete"
              BLOCKED_REASON="Review-results JSON for PR #${_mrg_pr} is missing required keys (schema_version non-empty, verdict present, reviewers array). Minimum form is not satisfied."
              BLOCKED_ALTERNATIVE="Run /rite:pr-review ${_mrg_pr} to write a complete review-results JSON, then re-run merge."
              ;;
          esac
        fi
      fi
      # success: leave BLOCKED_PATTERN empty — no extra output (AC-1)
    fi
  fi
fi

# --- Result ---

if [ -z "$BLOCKED_PATTERN" ]; then
  exit 0
fi

# Log block event (stderr + deny-only persistent audit trail)
CMD_SUMMARY="${COMMAND:0:80}"
CMD_SUMMARY="${CMD_SUMMARY//\"/\\\"}"
BLOCK_EVENT="[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] bash-guard: BLOCKED pattern=$BLOCKED_PATTERN cmd=\"$CMD_SUMMARY\""
echo "$BLOCK_EVENT" >&2

# Auditing must never interfere with the guard's primary deny contract. Resolve
# the shared state root when no explicit test/runtime override is present, then
# make directory creation and append one best-effort operation.
_audit_root="${RITE_STATE_ROOT:-}"
if [ -z "$_audit_root" ]; then
  _audit_root=$(bash "$SCRIPT_DIR/state-path-resolve.sh" 2>/dev/null) || _audit_root=""
fi
_audit_log="${_audit_root:+$_audit_root/}.rite/logs/bash-guard.log"
if ! { mkdir -p "$(dirname "$_audit_log")" && printf '%s\n' "$BLOCK_EVENT" >> "$_audit_log"; } 2>/dev/null; then
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] bash-guard: WARNING: unable to append deny audit log: $_audit_log" >&2
fi

# Deny with reason and alternative. jq is required to emit the final permission
# payload; an intermittent jq failure here would silently downgrade the deny to
# allow. Fall back to a literal JSON envelope + exit 2 so the deny is fail-closed.
# reason のエスケープ連鎖 (改行 \n 化 + 残存 C0 の ? 化、
# stop-loop-continuation.sh の JSON emit フォールバックと対称) は
# _bash_guard_escape_deny_reason に集約。neutralize 失敗時は raw を emit せず
# static placeholder へ縮退し、deny + exit 2 の fail-closed 契約を維持する。
_deny_reason="BLOCKED ($BLOCKED_PATTERN): $BLOCKED_REASON $BLOCKED_ALTERNATIVE"
if ! jq -n --arg reason "$_deny_reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'; then
  _deny_reason_escaped=$(_bash_guard_escape_deny_reason "$_deny_reason") \
    || _deny_reason_escaped="BLOCKED: command denied (reason neutralization failed, fail-closed). Check the bash-guard stderr log for the blocked pattern."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$_deny_reason_escaped"
  exit 2
fi
