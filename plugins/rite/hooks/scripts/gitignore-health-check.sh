#!/usr/bin/env bash
# gitignore-health-check.sh
#
# Verify that `.gitignore` still excludes `.rite/wiki/` — the last-line-of-defense
# rule added in PR #564 that prevents wiki-ingest-trigger.sh temporary writes from
# silently leaking into the develop branch PR diff. If a future `.gitignore`
# cleanup PR inadvertently removes this rule, the regression must be detected
# immediately (Issue #567).
#
# Detection strategy (strategy-aware, per `.gitignore` header L101-113 spec):
#
#   separate_branch (default): `.rite/wiki/` must be ignored outright.
#       Use `git check-ignore -v .rite/wiki/raw/.rite-lint-probe` with a probe
#       path (no real file created — git evaluates the path pattern statically).
#       A healthy state returns rc=0 and the matched pattern contains
#       `.rite/wiki/`. Any other outcome is drift.
#
#   same_branch: `.rite/wiki/` exclusion must have a negation override so
#       `git add .rite/wiki/...` works during /rite:wiki:ingest on the same
#       branch. Per `.gitignore` spec, `git check-ignore -v` is NOT deterministic
#       under negation rules — it can return rc=0/1 for both healthy and broken
#       states. `git add --dry-run` is the canonical sanity check.
#       We create a real probe file, run `git add --dry-run` on it, and verify
#       rc=0 + stdout contains `add '...negation-probe'`. The probe is cleaned
#       up regardless of outcome via the signal-specific trap below.
#
# On drift, emit a `gitignore_drift` workflow incident sentinel on stdout so
# Phase 5.4.4.1 in start.md can auto-register a tracking Issue.
#
# Issue #567 — `.gitignore` silent-leak regression guard.
# Companion to:
#   - PR #564: added `.rite/wiki/` to `.gitignore` as last-line-of-defense
#   - plugins/rite/hooks/workflow-incident-emit.sh: sentinel formatter
#   - plugins/rite/commands/lint.md Phase 3.9: invocation site
#
# Usage:
#   gitignore-health-check.sh [--repo-root DIR] [--quiet]
#                             [--branch-strategy-override STRATEGY] [-h|--help]
#
# Options:
#   --repo-root DIR                   Repository root (default: git rev-parse --show-toplevel)
#   --quiet                           Suppress informational output
#   --branch-strategy-override VAL    Override wiki.branch_strategy from rite-config.yml
#                                     (one of: separate_branch | same_branch) — smoke test only
#   -h, --help                        Show this help
#
# Exit codes (non-blocking contract, identical to drift-check / wiki-growth-check):
#   0  Health verified (or wiki disabled / legitimate no-op — skip silently)
#   1  Drift detected (warning — caller MUST keep [lint:success])
#   2  Invocation error (bad args, missing repo)
#
# Output:
#   Always prints `==> Total gitignore-health-check findings: N` on stdout.
#   On drift (exit 1), additionally prints a `[CONTEXT] WORKFLOW_INCIDENT=1;
#   type=gitignore_drift; ...` sentinel line via workflow-incident-emit.sh.
#
set -uo pipefail

# Resolve script directory early using POSIX-portable idiom.
# `readlink -f` is a GNU extension unsupported by macOS BSD readlink — using it
# would silently fall back to an empty string when coreutils is absent, and the
# sentinel emit site (`$_SCRIPT_DIR/../workflow-incident-emit.sh`) would resolve
# to a relative path under CWD (cd'd to REPO_ROOT later), breaking drift
# detection silently. Peer scripts (wiki-ingest-commit.sh / wiki-worktree-*.sh)
# all use this same `cd -P "$(dirname "${BASH_SOURCE[0]}")"` pattern.
_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Signal-specific trap (canonical pattern from references/bash-trap-patterns.md):
# - EXIT preserves original exit code via `rc=$?`
# - INT/TERM/HUP exit with POSIX-conventional codes (130/143/129)
# - Tempfiles + same_branch probe file are cleaned in all paths
# - BSD/macOS rm portability: empty-arg guard via `[ -n "${var:-}" ] && rm -f "$var"`
#   (some BSD rm variants emit "cannot remove ''" on empty args)
check_ignore_err=""
add_dry_err=""
negation_probe=""
_rite_gitignore_cleanup() {
  [ -n "${check_ignore_err:-}" ] && rm -f "$check_ignore_err"
  [ -n "${add_dry_err:-}" ] && rm -f "$add_dry_err"
  # same_branch probe file: always remove so lint runs never pollute the tree
  [ -n "${negation_probe:-}" ] && rm -f "${negation_probe}" 2>/dev/null
  # Also remove the probe parent directories (.rite/wiki/raw/, .rite/wiki/) if this
  # script created them and they are empty. `rmdir` fails on non-empty directories,
  # which protects pre-existing raw source files from being unintentionally removed.
  rmdir .rite/wiki/raw .rite/wiki 2>/dev/null || true
}
trap 'rc=$?; _rite_gitignore_cleanup; exit $rc' EXIT
trap '_rite_gitignore_cleanup; exit 130' INT
trap '_rite_gitignore_cleanup; exit 143' TERM
trap '_rite_gitignore_cleanup; exit 129' HUP

REPO_ROOT=""
QUIET=0
STRATEGY_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: gitignore-health-check.sh [options]

Options:
  --repo-root DIR                   Repository root (default: git rev-parse --show-toplevel)
  --quiet                           Suppress informational output
  --branch-strategy-override VAL    Override wiki.branch_strategy (separate_branch | same_branch)
                                    Used for smoke testing only; production runs read rite-config.yml.
  -h, --help                        Show this help

Exit codes:
  0  Health verified (or wiki disabled / legitimate no-op)
  1  Drift detected (warning, non-blocking)
  2  Invocation error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)                 REPO_ROOT="$2"; shift 2 ;;
    --quiet)                     QUIET=1; shift ;;
    --branch-strategy-override)  STRATEGY_OVERRIDE="$2"; shift 2 ;;
    -h|--help)                   usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log_info() {
  [ "$QUIET" -eq 0 ] && echo "$@"
}

# --- Resolve repo root ---
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: not inside a git repository (git rev-parse --show-toplevel failed)" >&2
    echo "==> Total gitignore-health-check findings: 0"
    exit 2
  }
fi
cd "$REPO_ROOT" || {
  echo "ERROR: cannot cd to repo root: $REPO_ROOT" >&2
  echo "==> Total gitignore-health-check findings: 0"
  exit 2
}

# --- Read config ---
config_file="rite-config.yml"
if [ ! -f "$config_file" ]; then
  log_info "gitignore-health-check: rite-config.yml not found, skipping (exit 0)"
  echo "==> Total gitignore-health-check findings: 0"
  exit 0
fi

wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' "$config_file" 2>/dev/null) || wiki_section=""
if [ -z "$wiki_section" ]; then
  log_info "gitignore-health-check: wiki section absent in rite-config.yml — skipping (exit 0)"
  echo "==> Total gitignore-health-check findings: 0"
  exit 0
fi

# wiki.enabled (opt-out default true)
wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' \
  | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *)          wiki_enabled="true" ;;
esac
if [ "$wiki_enabled" = "false" ]; then
  log_info "gitignore-health-check: wiki.enabled=false, skipping (exit 0)"
  echo "==> Total gitignore-health-check findings: 0"
  exit 0
fi

# wiki.branch_strategy (default: separate_branch)
if [ -n "$STRATEGY_OVERRIDE" ]; then
  branch_strategy="$STRATEGY_OVERRIDE"
else
  branch_strategy=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+branch_strategy:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*branch_strategy:[[:space:]]*//' \
    | tr -d '[:space:]"'"'"'')
fi
case "$branch_strategy" in
  separate_branch|same_branch) ;;
  "") branch_strategy="separate_branch" ;;
  *)
    echo "WARNING: gitignore-health-check: unknown wiki.branch_strategy '$branch_strategy' — treating as separate_branch" >&2
    branch_strategy="separate_branch"
    ;;
esac

# --- Layer 1: parent exclusion verify (separate_branch + same_branch 共通) ---
# `git check-ignore -v` with a probe path that does NOT exist on disk. This is
# the canonical way to ask git "is this path ignored by the current .gitignore?"
# without polluting the working tree.
probe_path=".rite/wiki/raw/.rite-lint-probe"
check_ignore_err=$(mktemp /tmp/rite-gitignore-check-XXXXXX 2>/dev/null) || check_ignore_err=""
if [ -z "$check_ignore_err" ]; then
  echo "WARNING: gitignore-health-check: mktemp failed — check-ignore stderr won't be surfaced" >&2
fi

findings=0
check_ignore_out=""
check_ignore_rc=0
if check_ignore_out=$(git check-ignore -v "$probe_path" 2>"${check_ignore_err:-/dev/null}"); then
  check_ignore_rc=0
else
  check_ignore_rc=$?
fi

# check_ignore_rc values:
#   0  = matched an ignore rule (or matched a negation — `!pattern` prefix on output)
#   1  = no rule matched (path is NOT ignored)
#   2+ = git error
if [ "$check_ignore_rc" -ge 2 ]; then
  echo "WARNING: gitignore-health-check: git check-ignore failed (rc=$check_ignore_rc) — skipping separate_branch verify" >&2
  [ -n "$check_ignore_err" ] && [ -s "$check_ignore_err" ] && head -3 "$check_ignore_err" | sed 's/^/  /' >&2
  echo "==> Total gitignore-health-check findings: 0"
  exit 2
fi

parent_rule_matched=0
parent_rule_line=""
if [ "$check_ignore_rc" -eq 0 ]; then
  # `git check-ignore -v` output: `<source>:<line>:<pattern>\t<path>`
  # The pattern field contains `.rite/wiki/` (or a more specific subpath rule)
  # when the parent exclusion is healthy. The pattern field is always preceded
  # by a colon (`:` separator after line number) in this output format, so a
  # minimal `:<pattern>` match is sufficient and avoids the `.rite/wiki/` path
  # field (suffix) from producing a false positive.
  if printf '%s' "$check_ignore_out" | grep -qE ':\.rite/wiki/'; then
    parent_rule_matched=1
    parent_rule_line="$check_ignore_out"
  fi
fi

case "$branch_strategy" in
  separate_branch)
    if [ "$parent_rule_matched" -eq 0 ]; then
      echo "==> gitignore-health-check: DRIFT DETECTED (separate_branch): '.rite/wiki/' rule missing from .gitignore" >&2
      echo "==> git check-ignore -v $probe_path returned rc=$check_ignore_rc, output: ${check_ignore_out:-<empty>}" >&2
      echo "==> Hint: PR #564 added '.rite/wiki/' as last-line-of-defense against wiki-ingest-trigger.sh silent leaks. Restore the rule." >&2
      findings=$((findings + 1))
    else
      log_info "gitignore-health-check: separate_branch layer 1 healthy — ${parent_rule_line}"
    fi
    ;;

  same_branch)
    # For same_branch, we also need a negation override so `git add .rite/wiki/...`
    # works during /rite:wiki:ingest. Per .gitignore L101-113 spec, `git check-ignore`
    # cannot deterministically verify negation. Use `git add --dry-run` with a real
    # probe file (cleaned up by trap on exit).
    negation_probe=".rite/wiki/raw/.rite-lint-negation-probe"
    # mkdir/touch failure classified as invocation error (exit 2) so lint.md
    # Phase 3.9 Result handling routes it to the `error` branch (recorded as
    # warning with diagnostic message) rather than silent healthy skip (exit 0).
    # This distinguishes "verify impossible due to env constraint" (exit 2) from
    # "rule healthy" (exit 0), matching the header L45-L49 exit code contract.
    mkdir -p "$(dirname "$negation_probe")" 2>/dev/null || {
      echo "ERROR: gitignore-health-check: cannot mkdir $(dirname "$negation_probe")" >&2
      echo "  対処: read-only filesystem / permission / disk full のいずれかを確認してください" >&2
      echo "==> Total gitignore-health-check findings: 0"
      exit 2
    }
    touch "$negation_probe" 2>/dev/null || {
      echo "ERROR: gitignore-health-check: cannot touch $negation_probe" >&2
      echo "  対処: read-only filesystem / permission / disk full のいずれかを確認してください" >&2
      echo "==> Total gitignore-health-check findings: 0"
      exit 2
    }

    # >>> DRIFT-CHECK ANCHOR: same_branch add_dry_run rc capture <<<
    # Downstream reference: plugins/rite/commands/wiki/init.md Phase 1.3.4 verification
    # block. Keep the mktemp stderr capture + if-wrapper rc capture structure one-for-one
    # with init.md's copy — Wiki 経験則 patterns/high「canonical reference 文書のサンプル
    # コードは canonical 実装と一字一句同期する」.
    add_dry_err=$(mktemp /tmp/rite-gitignore-adddry-XXXXXX 2>/dev/null) || add_dry_err=""
    add_dry_out=""
    add_dry_rc=0
    if add_dry_out=$(git add --dry-run -- "$negation_probe" 2>"${add_dry_err:-/dev/null}"); then
      add_dry_rc=0
    else
      add_dry_rc=$?
    fi
    # >>> DRIFT-CHECK ANCHOR END: same_branch add_dry_run rc capture <<<

    # >>> DRIFT-CHECK ANCHOR: same_branch negation grep-qF healthy check <<<
    # Downstream reference: plugins/rite/commands/wiki/init.md Phase 1.3.4 verification
    # block. Keep the `grep -qF "add '${negation_probe}'"` full-path fixed-string match
    # one-for-one with init.md's copy — simple `grep -q "^add '"` 単純 prefix は
    # false positive を招く.
    # Healthy negation: rc=0 + stdout like `add '.rite/wiki/raw/.rite-lint-negation-probe'`
    # Broken negation: rc=1 + stderr contains "paths are ignored"
    if [ "$add_dry_rc" -eq 0 ] && printf '%s' "$add_dry_out" | grep -qF "add '${negation_probe}'"; then
      log_info "gitignore-health-check: same_branch layer 2 healthy — negation override works (git add --dry-run rc=0)"
    else
      echo "==> gitignore-health-check: DRIFT DETECTED (same_branch): negation override for '.rite/wiki/' missing or broken" >&2
      echo "==> git add --dry-run $negation_probe returned rc=$add_dry_rc" >&2
      [ -n "$add_dry_err" ] && [ -s "$add_dry_err" ] && head -3 "$add_dry_err" | sed 's/^/  /' >&2
      echo "==> Hint: same_branch strategy requires '!.rite/wiki/' negation entry in .gitignore (see .gitignore L66-75 for setup steps)." >&2
      findings=$((findings + 1))
    fi
    # >>> DRIFT-CHECK ANCHOR END: same_branch negation grep-qF healthy check <<<
    # probe cleanup handled by trap
    ;;
esac

# --- Emit sentinel on drift ---
if [ "$findings" -gt 0 ]; then
  # Delegate sentinel formatting to workflow-incident-emit.sh. `$_SCRIPT_DIR`
  # was resolved at the top of this script using the POSIX-portable
  # `cd -P "$(dirname "${BASH_SOURCE[0]}")"` idiom (macOS BSD-compatible).
  emit_script="$_SCRIPT_DIR/../workflow-incident-emit.sh"
  if [ -f "$emit_script" ]; then
    # Emit to stdout so the sentinel reaches the orchestrator's conversation context.
    # `|| true` preserves non-blocking contract (emit failure must not halt lint).
    bash "$emit_script" \
      --type gitignore_drift \
      --details "gitignore health check: .rite/wiki/ rule drift detected (strategy=$branch_strategy)" \
      --root-cause-hint "PR may have removed .rite/wiki/ exclusion or negation from .gitignore" \
      --pr-number 0 || true
  else
    echo "WARNING: gitignore-health-check: workflow-incident-emit.sh not found at $emit_script — sentinel not emitted" >&2
  fi
  echo "==> Total gitignore-health-check findings: $findings"
  exit 1
fi

echo "==> Total gitignore-health-check findings: 0"
exit 0
