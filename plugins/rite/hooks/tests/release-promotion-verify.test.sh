#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/.."
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state/.rite"

cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
  jq -n --arg base "${MOCK_BASE:-main}" --arg head "${MOCK_HEAD:-develop}" \
    --arg oid "0123456789abcdef0123456789abcdef01234567" \
    '{baseRefName:$base,headRefName:$head,headRefOid:$oid}'
elif [ "$1" = "api" ]; then
  oid="0123456789abcdef0123456789abcdef01234567"
  case " $* " in
    *"/pulls/"*"/commits"*) printf '%s\n' "$oid" ;;
    *"/pulls/"*) printf '%s\n' "${MOCK_COMMIT_COUNT:-1}" ;;
    *)
      if [ "${MOCK_UNREVIEWED:-0}" = 1 ]; then printf '[]\n'
      else jq -n --arg oid "$oid" '[{merged_at:"2026-08-01T00:00:00Z",merge_commit_sha:$oid}]'; fi
      ;;
  esac
else
  exit 64
fi
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Keep repository resolution deterministic while isolating state output.
export PATH="$TMP_ROOT/bin:$PATH"
export RITE_STATE_ROOT="$TMP_ROOT/state"

head_oid=$(bash "$HOOKS_DIR/release-promotion-verify.sh" 88)
test "$head_oid" = "0123456789abcdef0123456789abcdef01234567"
jq -e '.pr_number == 88 and .base == "main" and .head == "develop" and (.commits | length == 1)' \
  "$TMP_ROOT/state/.rite/release-promotions/88.json" >/dev/null

promotions_dir="$TMP_ROOT/state/.rite/release-promotions"

# T-01: the attestation directory carries its own `*` exclusion (AC-1).
gitignore_body=$(cat "$promotions_dir/.gitignore" 2>/dev/null || true)
if [ "$gitignore_body" != "*" ]; then
  echo "FAIL: attestation dir .gitignore is not the star-only exclusion (got: '$gitignore_body')" >&2
  exit 1
fi

# T-02: a pre-existing non-empty .gitignore is left untouched (AC-2), matching the
# primitive's contract. Guards against a future rewrite that clobbers user edits.
printf '*.json\n' > "$promotions_dir/.gitignore"
bash "$HOOKS_DIR/release-promotion-verify.sh" 88 >/dev/null
preserved=$(cat "$promotions_dir/.gitignore")
if [ "$preserved" != "*.json" ]; then
  echo "FAIL: existing .gitignore was overwritten (got: '$preserved')" >&2
  exit 1
fi
rm -f "$promotions_dir/.gitignore"

# T-03/T-04: a .gitignore that cannot be written must warn on stderr without
# disturbing stdout or the attestation (AC-3, AC-4). The failure is injected as a
# dangling symlink rather than `chmod a-w` so it also holds when tests run as root.
rm -f "$promotions_dir/88.json"
ln -s /nonexistent/nope "$promotions_dir/.gitignore"
gi_err_file=$(mktemp)
# `set -e` is active, so capture the exit code on the failure branch rather than
# reading `$?` on the next line (which would never be reached on a non-zero rc).
gi_rc=0
gi_out=$(bash "$HOOKS_DIR/release-promotion-verify.sh" 88 2>"$gi_err_file") || gi_rc=$?
gi_err=$(cat "$gi_err_file")
rm -f "$gi_err_file" "$promotions_dir/.gitignore"

if [ "$gi_rc" -ne 0 ]; then
  echo "FAIL: .gitignore write failure aborted the run (rc=$gi_rc)" >&2
  exit 1
fi
if [ "$gi_out" != "0123456789abcdef0123456789abcdef01234567" ]; then
  echo "FAIL: stdout is not the bare head_oid under .gitignore failure (got: '$gi_out')" >&2
  exit 1
fi
# The warning must actually appear — otherwise the write silently succeeded and
# T-03/T-04 would pass without ever exercising the failure path.
if ! printf '%s\n' "$gi_err" | grep -q 'WARNING:.*\.gitignore'; then
  echo "FAIL: no WARNING emitted for the .gitignore write failure" >&2
  exit 1
fi
# The cause must be emitted at all, and stay indented under the WARNING. Both halves are
# needed: the column-0 check alone counts zero whether the cause is correctly indented or
# missing entirely, so dropping the cause line would slip through it (same pairing as
# review-result-state-root.test.sh TC-8, which asserts indented>=1 and bare==0 together).
# LC_ALL=C is required — the cause is a locale-dependent OS message, and a UTF-8 locale
# gives up on lines it cannot decode, matching nothing.
if ! printf '%s\n' "$gi_err" | LC_ALL=C grep -qE '^  .*/\.gitignore: '; then
  echo "FAIL: .gitignore failure cause was not emitted alongside the WARNING" >&2
  exit 1
fi
if [ "$(printf '%s\n' "$gi_err" | LC_ALL=C grep -cE '^[^ ].*/\.gitignore: ')" -ne 0 ]; then
  echo "FAIL: .gitignore failure cause leaked to column 0 instead of staying indented" >&2
  exit 1
fi
jq -e '.pr_number == 88 and .base == "main" and .head == "develop"' \
  "$promotions_dir/88.json" >/dev/null || {
  echo "FAIL: attestation was not written when .gitignore creation failed" >&2
  exit 1
}

if MOCK_UNREVIEWED=1 bash "$HOOKS_DIR/release-promotion-verify.sh" 89 >/dev/null 2>&1; then
  echo "FAIL: unreviewed commit was accepted" >&2
  exit 1
fi
if MOCK_BASE=develop MOCK_HEAD=feature bash "$HOOKS_DIR/release-promotion-verify.sh" 90 >/dev/null 2>&1; then
  echo "FAIL: non-promotion PR shape was accepted" >&2
  exit 1
fi
if MOCK_COMMIT_COUNT=251 bash "$HOOKS_DIR/release-promotion-verify.sh" 91 >/dev/null 2>&1; then
  echo "FAIL: incomplete capped commit list was accepted" >&2
  exit 1
fi

echo "release-promotion-verify tests passed"
