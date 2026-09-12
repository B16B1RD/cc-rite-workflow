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

# --- Recovery R.2: local dry-run of the main -> develop back-merge ---
# The bash block is extracted from the release skill and run against local fixtures, so an
# edit to the skill is exercised directly rather than through a copy that can drift. Every
# abort-failure case has a shim-free twin that must reach its marker: a fixture broken before
# the merge also exits non-zero without a marker, and would otherwise pass as "stopped".
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
RELEASE_SKILL="$REPO_ROOT/.claude/skills/release/SKILL.md"
r2_block="$TMP_ROOT/r2-dryrun.sh"
# Bounded by the next heading: a removed R.2 fence must not pull in the R.3 block instead.
if ! awk '/^### R\.2 /{s=1; next}
          s && /^##+ /{exit}
          s && /^```bash$/{f=1; next}
          f && /^```$/{closed=1; exit}
          f{print}
          END{exit !closed}' "$RELEASE_SKILL" > "$r2_block"; then
  echo "FAIL: R.2 bash block (heading and closed fence) not found in $RELEASE_SKILL" >&2
  exit 1
fi
for anchor in 'RECOVERY_DRYRUN=ok' 'RECOVERY_DRYRUN=conflict' 'RECOVERY_DRYRUN=already-contained' \
              'RECOVERY_DRYRUN=tree-changed' 'git merge --abort' 'MERGE_HEAD' 'merge-base --is-ancestor'; do
  grep -qF -- "$anchor" "$r2_block" || { echo "FAIL: extracted R.2 block lacks '$anchor'" >&2; exit 1; }
done

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=rite GIT_AUTHOR_EMAIL=rite@example.invalid
export GIT_COMMITTER_NAME=rite GIT_COMMITTER_EMAIL=rite@example.invalid
real_git=$(command -v git)
fx_root=$(cd "$TMP_ROOT" && pwd -P)
repo_head_before=$(git -C "$REPO_ROOT" rev-parse HEAD)

# develop gains two commits that reach main as one squash commit: main is then not an ancestor
# of develop yet has the same tree, which is the state the recovery starts from. A separate
# `bash -e` keeps errexit active; inside a `||` list the calling shell would ignore it.
cat > "$TMP_ROOT/make-r2-fixture.sh" <<'EOF'
dir=$1 kind=$2
git init -q --bare -b develop "$dir/origin.git"
git init -q -b develop "$dir/work"
cd "$dir/work"
git remote add origin "$dir/origin.git"
printf 'a\nb\nc\n' > f.txt; git add f.txt; git commit -qm base
git branch main; git push -q origin develop main
printf 'a\nB\nc\n' > f.txt; git commit -qam d1
printf 'a\nB\nC\n' > f.txt; git commit -qam d2
git push -q origin develop
git checkout -q main; git merge -q --squash develop; git commit -qm squash
if [ "$kind" = tree-changed ]; then printf 'x\n' > main-only.txt; git add main-only.txt; git commit -qm main-only; fi
git push -q origin main; git checkout -q develop
case "$kind" in
  conflict) printf 'a\nBB\nC\n' > f.txt; git commit -qam re-edit; git push -q origin develop ;;
  already-contained) git merge -q --no-ff -s ours -m back-merge origin/main ;;
esac
EOF

r2_fail() {
  echo "FAIL: R.2 $2: $1" >&2
  echo "--- stdout ---" >&2; cat "$fx_root/$2/out" >&2 2>/dev/null || true
  echo "--- stderr ---" >&2; cat "$fx_root/$2/err" >&2 2>/dev/null || true
  exit 1
}

# make_r2_fixture <name> <kind> — builds the fixture and checks the shape each kind relies on.
make_r2_fixture() {
  local name=$1 kind=$2 w="$fx_root/$1/work" contained=no
  mkdir -p "$fx_root/$name"
  bash -e "$TMP_ROOT/make-r2-fixture.sh" "$fx_root/$name" "$kind" >"$fx_root/$name/fixture.log" 2>&1 \
    || { cat "$fx_root/$name/fixture.log" >&2; r2_fail "fixture could not be built" "$name"; }
  [ "$(git -C "$w" rev-parse origin/main)" = "$(git --git-dir="$fx_root/$name/origin.git" rev-parse main)" ] \
    || r2_fail "fixture origin/main is stale" "$name"
  if git -C "$w" merge-base --is-ancestor origin/main develop; then contained=yes; fi
  if [ "$kind" = already-contained ]; then want=yes; else want=no; fi
  [ "$contained" = "$want" ] || r2_fail "fixture ancestry is $contained (expected $want)" "$name"
  if [ "$kind" = clean ] && [ "$(git -C "$w" rev-parse 'origin/main^{tree}')" != "$(git -C "$w" rev-parse 'develop^{tree}')" ]; then
    r2_fail "fixture main tree differs from develop" "$name"
  fi
}

# run_r2 <name> <none|fail|noop> — fail: `merge --abort` exits 1; noop: exits 0 without aborting.
run_r2() {
  local name=$1 mode=$2 w="$fx_root/$1/work" path=$PATH
  if [ "$mode" != none ]; then
    mkdir -p "$fx_root/$name/shim"
    cat > "$fx_root/$name/shim/git" <<EOF
#!/bin/bash
if [ "\${1:-} \${2:-}" = "merge --abort" ]; then
  echo abort >> "$fx_root/$name/abort.log"
  [ "$mode" = fail ] && exit 1
  exit 0
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$fx_root/$name/shim/git"
    path="$fx_root/$name/shim:$PATH"
  fi
  [ "$(git -C "$w" rev-parse --show-toplevel)" = "$w" ] || r2_fail "block would run outside the fixture" "$name"
  before_head=$(git -C "$w" rev-parse develop)
  before_tree=$(git -C "$w" rev-parse 'develop^{tree}')
  r2_rc=0
  (cd "$w" && LC_ALL=C PATH="$path" bash "$r2_block") >"$fx_root/$name/out" 2>"$fx_root/$name/err" || r2_rc=$?
}

# expect_marker <name> <rc> <marker line> — the only [CONTEXT] line, and the dry-run fully undone.
expect_marker() {
  local name=$1 w="$fx_root/$1/work"
  [ "$r2_rc" = "$2" ] || r2_fail "rc=$r2_rc (expected $2)" "$name"
  [ "$(grep '^\[CONTEXT\] ' "$fx_root/$name/out" || true)" = "$3" ] || r2_fail "marker is not exactly '$3'" "$name"
  if grep -q 'ERROR:' "$fx_root/$name/err"; then r2_fail "unexpected ERROR on stderr" "$name"; fi
  if git -C "$w" rev-parse -q --verify MERGE_HEAD >/dev/null; then r2_fail "MERGE_HEAD left behind" "$name"; fi
  [ "$(git -C "$w" rev-parse HEAD)" = "$before_head" ] || r2_fail "HEAD moved" "$name"
  [ -z "$(git -C "$w" status --porcelain)" ] || r2_fail "working tree not clean" "$name"
  [ "$(git -C "$w" symbolic-ref --short HEAD)" = develop ] || r2_fail "not on develop" "$name"
}

# expect_abort_error <name> — stopped by the block's own abort check, after exactly one abort.
expect_abort_error() {
  local name=$1
  [ "$r2_rc" = 1 ] || r2_fail "rc=$r2_rc (expected 1)" "$name"
  if grep -q 'RECOVERY_DRYRUN' "$fx_root/$name/out"; then r2_fail "marker emitted despite failed abort" "$name"; fi
  grep -qF 'ERROR: dry-run の merge を取り消せていません' "$fx_root/$name/err" || r2_fail "abort error not reported" "$name"
  if grep -q '^fatal:' "$fx_root/$name/err"; then r2_fail "git failed before the abort check" "$name"; fi
  [ "$(cat "$fx_root/$name/abort.log" 2>/dev/null | wc -l)" -eq 1 ] || r2_fail "merge --abort was not called exactly once" "$name"
}

make_r2_fixture clean clean; run_r2 clean none
expect_marker clean 0 "[CONTEXT] RECOVERY_DRYRUN=ok; before_head=$before_head; before_tree=$before_tree"

make_r2_fixture conflict conflict; run_r2 conflict none
expect_marker conflict 1 "[CONTEXT] RECOVERY_DRYRUN=conflict; before_head=$before_head; before_tree=$before_tree"

make_r2_fixture already-contained already-contained; run_r2 already-contained none
expect_marker already-contained 1 "[CONTEXT] RECOVERY_DRYRUN=already-contained; before_head=$before_head"

make_r2_fixture tree-changed tree-changed
merged_tree=$(git -C "$fx_root/tree-changed/work" merge-tree --write-tree origin/main develop)
run_r2 tree-changed none
expect_marker tree-changed 0 "[CONTEXT] RECOVERY_DRYRUN=tree-changed; before_tree=$before_tree; merged_tree=$merged_tree"

make_r2_fixture clean-abort-fail clean; run_r2 clean-abort-fail fail; expect_abort_error clean-abort-fail
make_r2_fixture conflict-abort-fail conflict; run_r2 conflict-abort-fail fail; expect_abort_error conflict-abort-fail
# abort reports success but leaves MERGE_HEAD: only the post-abort MERGE_HEAD check can stop it.
make_r2_fixture clean-abort-noop clean; run_r2 clean-abort-noop noop; expect_abort_error clean-abort-noop

[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$repo_head_before" ] || { echo "FAIL: R.2 cases moved HEAD of $REPO_ROOT" >&2; exit 1; }

echo "release-promotion-verify tests passed"
