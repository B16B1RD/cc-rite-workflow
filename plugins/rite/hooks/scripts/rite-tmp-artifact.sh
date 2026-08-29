#!/bin/bash
# rite workflow - temporary-artifact manifest recorder
#
# Single source of truth for the name-independent reap manifest read by
# `pr-cycle-cleanup.sh`. A producer that creates a throw-away branch or worktree
# whose name is NOT covered by the cleanup script's strict patterns records it
# here at creation time; cleanup then reaps it by identity (the manifest entry),
# not by guessing the name. This is the producer half of the name-independent
# reap contract (D-01): cleanup deletes ONLY what a rite producer
# explicitly recorded, so an unrelated user branch/worktree is never touched.
#
# Subcommand:
#   record --type <branch|worktree|session_worktree> --id <value>
#       Append one entry to the manifest. `value` is a local branch name
#       (type=branch) or an absolute worktree path (type=worktree /
#       type=session_worktree). `worktree` is reserved for EPHEMERAL tmp
#       artifacts consumed by pr-cycle-cleanup.sh Step 4.5's ungated reap
#       (dirty-check only — no claim/self-exclusion/live-cwd gates).
#       `session_worktree` is for `.rite/worktrees/issue-N` paths, actually
#       reaped ONLY by Step 5's gated corpse-age-guard bypass.
#       Step 4.5 has a dedicated case arm for this type too, but that arm
#       never reaps — it only drops a stale entry once the path is already
#       gone (self-heal) and otherwise preserves it verbatim for Step 5, per
#       the existing "session worktrees go through Step 5's gated reap, never
#       here" contract.
#
# Data contract (`<shared-root>/.rite/tmp-artifacts.tsv`, TAB-separated):
#   <type>\t<value>
#   - <shared-root> is resolved via state-path-resolve.sh so linked worktrees
#     and the main checkout share ONE manifest (multi-session design §1).
#   - The manifest sits directly under `.rite/`, which the nested `.rite/.gitignore`
#     (`*` plus wiki negations) keeps untracked, so it never lands in a diff. No root
#     `.gitignore` entry is added for it.
#   - Duplicate entries are harmless: cleanup reaping a gone artifact is a no-op.
#
# Exit codes:
#   0  recorded (or non-blocking append failure — WARNING on stderr)
#   1  usage error (bad/missing --type or --id, or value with TAB/newline)
#
# Non-blocking by contract: a producer must never crash because manifest
# recording failed, so append failures WARN and return 0. Only caller misuse
# (invalid arguments) is a hard error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MANIFEST_REL=".rite/tmp-artifacts.tsv"

usage() {
  echo "Usage: rite-tmp-artifact.sh record --type <branch|worktree|session_worktree> --id <value>" >&2
}

cmd="${1:-}"
[ -n "$cmd" ] && shift || true
if [ "$cmd" != "record" ]; then
  echo "ERROR: unknown or missing subcommand: '${cmd}'" >&2
  usage
  exit 1
fi

art_type=""
art_id=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --type) art_type="${2:-}"; shift 2 ;;
    --id)   art_id="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

case "$art_type" in
  branch|worktree|session_worktree) : ;;
  *) echo "ERROR: --type must be 'branch', 'worktree', or 'session_worktree' (got '${art_type}')" >&2; exit 1 ;;
esac
if [ -z "$art_id" ]; then
  echo "ERROR: --id is required and must be non-empty" >&2
  exit 1
fi
# A TAB or newline in the value would corrupt the TSV record (split one entry
# into two fields / two lines), so reject it rather than silently mangle the
# manifest. Branch names and worktree paths never legitimately contain these.
# `$'\t'`/`$'\n'` (bash ANSI-C quoting) yields the literal control char; a
# `$(printf '\n')` substitution would be stripped to "" and match everything.
_tab=$'\t'
_nl=$'\n'
case "$art_id" in
  *"$_tab"*|*"$_nl"*)
    echo "ERROR: --id must not contain TAB or newline characters" >&2
    exit 1
    ;;
esac

# Reject a leading dash and enforce a conservative shape per type. This is the
# SoT-side defense for the "cleanup deletes ONLY what a producer recorded"
# contract: a value beginning with `-` would be read as an option by the
# downstream `git branch -D` / `git worktree remove` / `rm` (option injection),
# and a relative worktree path could resolve unpredictably at reap time. The
# cleanup side also passes `--` end-of-options as defense in depth.
case "$art_id" in
  -*) echo "ERROR: --id must not start with '-' (option-injection guard)" >&2; exit 1 ;;
esac
case "$art_type" in
  branch)
    # git branch names: allow the common safe set; reject anything exotic so a
    # poisoned value can never carry shell/option metacharacters into reap.
    case "$art_id" in
      *[!A-Za-z0-9._/-]*)
        echo "ERROR: branch --id may contain only [A-Za-z0-9._/-]" >&2; exit 1 ;;
    esac
    ;;
  worktree|session_worktree)
    # Worktree paths recorded by rite are always absolute (git worktree list /
    # mktemp -d -t emit absolute paths); a relative path here is a producer bug.
    case "$art_id" in
      /*) : ;;
      *) echo "ERROR: $art_type --id must be an absolute path" >&2; exit 1 ;;
    esac
    ;;
esac

# Resolve the SHARED state root (main checkout) so every session appends to the
# same manifest, mirroring pr-cycle-cleanup.sh's resolution exactly.
repo_root=$("$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || repo_root=""
[ -n "$repo_root" ] || repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
if [ -z "$repo_root" ]; then
  echo "WARNING: rite-tmp-artifact: shared root を解決できず manifest 記録をスキップします (not inside a git repository?)" >&2
  exit 0
fi

manifest="$repo_root/$MANIFEST_REL"
manifest_dir=$(dirname "$manifest")
if ! mkdir -p "$manifest_dir" 2>/dev/null; then
  echo "WARNING: rite-tmp-artifact: '$manifest_dir' を作成できず manifest 記録をスキップします (non-blocking)" >&2
  exit 0
fi
if printf '%s\t%s\n' "$art_type" "$art_id" >> "$manifest" 2>/dev/null; then
  exit 0
fi
echo "WARNING: rite-tmp-artifact: manifest '$manifest' への追記に失敗しました (non-blocking)" >&2
exit 0
