#!/usr/bin/env bash
# dollar-zero-check.sh
#
# Detect positional-parameter-zero references inside fenced code blocks in
# plugins/rite/skills/**/*.md.
#
# Why this is a defect class rather than a style rule
# ---------------------------------------------------
# The Skill loader expands parameter-zero references in the skill body to the
# **invocation argument string** before the body reaches the LLM. The expansion
# is not limited to prose — it happens inside fenced code blocks too. So a skill
# invoked as `/rite:cleanup 2044` receives an awk program whose line-match
# condition has become the literal text `2044`, which matches nothing.
#
# The failure is silent and invisible to every other check: the file on disk is
# correct, so grep and shell tests both pass. It was found only by reading the
# skill body as delivered. The observed impact was a YAML reader returning empty
# for every key, which the caller's opt-out default absorbed into a wrong
# configuration value — reported to the user as a normal skip.
#
# Detected pattern
# ----------------
#   Any parameter-zero reference on a line that sits inside a fenced code block.
#   Both the bare form and every brace form are matched — `${0}`, but also the
#   modified spellings `${0##*/}`, `${0%.*}`, `${0:-x}`, `${0/a/b}`. The loader
#   expands all of them, so matching only the two unmodified spellings would
#   leave the next writer a way to reintroduce the defect that reads as safe.
#
#   The fence's info string is NOT considered: the loader expands regardless of
#   the declared language, so a `text` or `sh` fence is exactly as vulnerable as
#   a `bash` one. Restricting the scan to `bash` fences would leave a silent
#   hole for the next writer who picks a different tag.
#
# Unscannable files are an error, not a clean bill
# ------------------------------------------------
#   A file this script could not scan (unbalanced fences, unreadable, missing
#   --target path) exits 2, not 0. The exit code is the only channel the caller
#   reads: `/rite:lint` Phase 3.5 maps rc=0 to `success` and shows the script's
#   output only for `warning`/`error`, and its summary is skipped entirely in
#   E2E flow — so a WARNING on stderr paired with rc=0 reaches nobody. Folding
#   "scanned everything, found nothing" together with "could not scan" would
#   reproduce, inside the guard, the exact defect class the guard exists to
#   prevent.
#
# Not detected (by construction)
# ------------------------------
#   - References in prose outside any fence — mentioning the parameter in an
#     explanation is safe and common (this file's own header does it).
#   - Real shell scripts (hooks/**/*.sh) — files executed by bash are never
#     passed through the Skill loader, so the same idiom is safe there. Scanning
#     them would produce nothing but false positives.
#
# Fix direction when this check fires
# -----------------------------------
#   Move the awk/shell program into a helper script under hooks/scripts/ and
#   call it from the skill body. Real files are immune to the expansion, and the
#   helper becomes independently testable. For YAML reads of the `wiki:` section
#   the canonical helper already exists: hooks/scripts/lib/wiki-config.sh
#   (`parse_wiki_scalar`).
#
# Usage:
#   dollar-zero-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#                        [--skip-if-no-target]
#
# Exit codes: 0 = clean (or not-applicable skip), 1 = pattern detected,
#             2 = invocation error, or one or more files could not be scanned.
#
# --skip-if-no-target: when --all finds no scan directory under the repo root
#   (a consumer repo that installs rite from the marketplace and does not
#   self-host plugins/rite/skills), treat the run as not-applicable and exit 0
#   instead of the exit-2 invocation-error diagnostic. Mirrors the same flag in
#   bang-backtick-check.sh / tmp-hardcode-check.sh.

set -uo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0
SKIP_IF_NO_TARGET=0

usage() {
  cat <<'EOF'
Usage: dollar-zero-check.sh [options]

Options:
  --all              Scan plugins/rite/skills/**/*.md
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr (per-finding
                     output on stdout is preserved; still exits non-zero on
                     detection)
  --skip-if-no-target
                     With --all, exit 0 (not 2) when no scan directory exists
                     under the repo root — the consumer-repo case where rite is
                     a marketplace plugin only
  -h, --help         Show this help

Exit codes:
  0  No fenced parameter-zero reference detected (or not-applicable skip)
  1  Pattern detected
  2  Invocation error (bad args), or one or more files could not be scanned
     (missing --target path, unbalanced fences, awk failure) — the result is
     not a clean bill, so it must not be reported as success
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --skip-if-no-target) SKIP_IF_NO_TARGET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  SCAN_DIR="plugins/rite/skills"
  if [ ! -d "$SCAN_DIR" ]; then
    if [ "$SKIP_IF_NO_TARGET" -eq 1 ]; then
      echo "[dollar-zero] not applicable: no $SCAN_DIR under $REPO_ROOT — clean skip (--skip-if-no-target)" >&2
      exit 0
    fi
    echo "ERROR: --all requested but $SCAN_DIR does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: this script was invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, pass --target FILE explicitly, or pass --skip-if-no-target to treat as not-applicable" >&2
    exit 2
  fi
  while IFS= read -r f; do
    TARGETS+=("$f")
  done < <(find "$SCAN_DIR" -type f -name '*.md' 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
# The per-file scratch file gets its own mktemp rather than a suffix appended to
# FINDINGS_FILE. A derived path is predictable and not created by mktemp, so it
# loses the O_CREAT|O_EXCL guarantee — an attacker-planted symlink at that path
# would be followed and its target truncated. The sibling checkers avoid the
# problem by appending straight to their mktemp'd file; this one needs a second
# handle because it discards per-file output on an unscannable file.
PART_FILE="$(mktemp)" || { rm -f "$FINDINGS_FILE"; echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -f "$FINDINGS_FILE" "$PART_FILE"' EXIT

# Files the scanner could not read or parse. Kept separate from findings so the
# exit code can distinguish "nothing to report" from "did not look".
SKIPPED=0

# ----- Scan one file ---------------------------------------------------------
#
# Fence tracking follows CommonMark closely enough for skill bodies: an opening
# fence is 3+ backticks or tildes indented at most 3 spaces, and only a fence of
# the same character and at least the same length closes it. The indent bound is
# what keeps an indented awk pattern that happens to contain a fence-looking
# literal from being mistaken for a real fence.
#
# An unbalanced fence means the block structure cannot be trusted, so the whole
# file is skipped with a WARNING. Skipping loses a detection; guessing produces
# findings on lines that are not code. Losing a detection is the cheaper error —
# the reader still gets a loud warning naming the file.
check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file — not scanned" >&2
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  awk -v F="$file" '
    BEGIN { in_fence = 0; fence_char = ""; fence_len = 0; findings = 0 }
    {
      # Fence open/close detection. match() on the leading run of the fence
      # character gives the length without relying on gsub side effects.
      indent = 0
      probe = $0
      while (substr(probe, 1, 1) == " ") { indent++; probe = substr(probe, 2) }
      is_fence = 0
      if (indent <= 3 && (substr(probe, 1, 3) == "```" || substr(probe, 1, 3) == "~~~")) {
        ch = substr(probe, 1, 1)
        n = 0
        while (substr(probe, n + 1, 1) == ch) n++
        is_fence = 1
      }
      if (is_fence) {
        if (in_fence == 0) {
          in_fence = 1; fence_char = ch; fence_len = n
        } else if (ch == fence_char && n >= fence_len) {
          # A closing fence carries no info string.
          rest = substr(probe, n + 1)
          gsub(/[ \t]/, "", rest)
          if (rest == "") { in_fence = 0; fence_char = ""; fence_len = 0 }
        }
        next
      }
      if (in_fence == 0) next
      # Matches the bare form and every brace form in one pattern: an optional
      # opening brace is enough, because what follows it (`}`, `##*/`, `:-x`, …)
      # never changes the fact that the loader rewrites the reference. Writing
      # out the closing brace instead would match only the unmodified `${0}`.
      # The brace is inside a bracket expression so the ERE never sees a brace a
      # POSIX awk would read as an interval quantifier.
      if (match($0, /\$[{]?0/)) {
        printf "[dollar-zero] %s:%d: parameter-zero reference inside a fenced code block (the Skill loader expands it to the invocation arguments) — move the program to a helper script under hooks/scripts/\n", F, NR
        findings++
      }
    }
    END {
      if (in_fence != 0) {
        printf "WARNING: unbalanced code fence in %s — file skipped (detection is dropped rather than guessed)\n", F > "/dev/stderr"
        exit 3
      }
    }
  ' "$file" > "$PART_FILE"
  local awk_rc=$?
  # rc=3 is this script's own unbalanced-fence signal. It deliberately avoids 2,
  # which gawk and mawk return on a fatal error (unreadable file, broken binary)
  # — collapsing the two would let a file the scanner never opened be reported
  # as "skipped on purpose", and the awk-failure branch below would be dead code.
  case "$awk_rc" in
    0) cat "$PART_FILE" >> "$FINDINGS_FILE" ;;
    3) SKIPPED=$((SKIPPED + 1)) ;;
    *)
      echo "WARNING: awk failed on $file (rc=$awk_rc) — file not scanned" >&2
      SKIPPED=$((SKIPPED + 1))
      ;;
  esac
  : > "$PART_FILE"
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  total=$(wc -l < "$FINDINGS_FILE" | tr -d '[:space:]')
else
  total=0
fi
log "==> Total dollar-zero findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "ERROR: ${SKIPPED} file(s) could not be scanned — this run is not a clean bill" >&2
  echo "  See the WARNING lines above for which files and why." >&2
  exit 2
fi
exit 0
