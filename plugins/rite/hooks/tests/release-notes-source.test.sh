#!/bin/bash
# Release skill Phase 3.3: the release notes and the release target come from the confirmed
# origin/main SHA, never from the working tree. The bash blocks are extracted from the skill and
# run against local fixtures, so an edit to the skill is exercised directly. Every stop case has
# a success twin built by the same fixture generator: a fixture broken before the checked step
# would also exit non-zero, and would otherwise pass as "stopped".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
RELEASE_SKILL="$REPO_ROOT/.claude/skills/release/SKILL.md"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Pick the single fence inside "### 3.3 " (bounded by the next heading) that contains $1.
extract_fence() {
  local anchor=$1 out=$2 count
  count=$(awk -v a="$anchor" -v out="$out" '
    /^### 3\.3 /{s=1; next}
    s && /^##+ /{exit}
    s && !f && /^```bash$/{f=1; buf=""; next}
    s && f && /^```$/{f=0; if (index(buf, a)) {n++; printf "%s", buf > out}; next}
    s && f{buf = buf $0 "\n"}
    END{print n+0}' "$RELEASE_SKILL")
  [ "$count" = 1 ] || fail "expected exactly one 3.3 fence containing '$anchor', found $count"
}

notes_block="$TMP_ROOT/notes.sh"
tag_block="$TMP_ROOT/tag.sh"
create_block="$TMP_ROOT/create.sh"
# The notes and the tag target must not depend on switching or updating the work tree.
awk '/^### 3\.3 /{s=1; next} s && /^##+ /{exit} s' "$RELEASE_SKILL" | grep -E 'git (checkout|pull)' \
  && fail "3.3 still switches or updates the work tree"
# Nothing updates the local main branch anymore, so no check may compare against it.
grep -nE 'git log main([^/[:alnum:]]|$)' "$RELEASE_SKILL" && fail "release skill still reads the local main branch"
extract_fence 'RELEASE_NOTES_SHA=' "$notes_block"
extract_fence 'git ls-remote --tags' "$tag_block"
extract_fence 'gh release create' "$create_block"
# The existing tag must be checked before the release is created, or the check cannot prevent it.
tag_fence_line=$(grep -n 'git ls-remote --tags' "$RELEASE_SKILL" | head -1 | cut -d: -f1)
create_fence_line=$(grep -n 'gh release create' "$RELEASE_SKILL" | head -1 | cut -d: -f1)
[ "$tag_fence_line" -lt "$create_fence_line" ] || fail "the tag check comes after the release creation ($tag_fence_line >= $create_fence_line)"
grep -qF -- 'git fetch --tags origin' "$RELEASE_SKILL" || fail "4.1 does not fetch tags before comparing them"
for anchor in 'git fetch origin main' 'rev-parse --verify' 'git show "$release_sha:CHANGELOG.md"' \
              '[CONTEXT] RELEASE_NOTES_SHA=' '[CONTEXT] RELEASE_NOTES_PATH='; do
  grep -qF -- "$anchor" "$notes_block" || fail "extracted notes block lacks '$anchor'"
done
grep -qF -- 'CHANGELOG.md >' "$notes_block" && fail "notes block reads the working-tree CHANGELOG.md"
grep -qF -- '--target "{RELEASE_NOTES_SHA}"' "$create_block" || fail "create block does not target {RELEASE_NOTES_SHA}"
grep -qF -- '--target main' "$create_block" && fail "create block still targets main"
grep -qF -- '--target main' "$RELEASE_SKILL" && fail "release skill still mentions --target main"
grep -qF -- 'gh release view v{VERSION} --json body' "$RELEASE_SKILL" || fail "4.1 lacks the non-empty release body check"
for block in "$notes_block" "$tag_block" "$create_block"; do
  sed -i.bak 's/{VERSION}/9.9.9/g' "$block" && rm -f "$block.bak"
done

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null LC_ALL=C
export GIT_AUTHOR_NAME=rite GIT_AUTHOR_EMAIL=rite@example.invalid
export GIT_COMMITTER_NAME=rite GIT_COMMITTER_EMAIL=rite@example.invalid
repo_head_before=$(git -C "$REPO_ROOT" rev-parse HEAD)

# $2 selects the CHANGELOG.md content on origin/main. The work tree stays on develop, whose
# CHANGELOG.md has no 9.9.9 section, and local main lags origin/main.
make_fixture() {
  local dir=$1 kind=$2
  mkdir -p "$dir/tmp"
  git init -q --bare -b main "$dir/origin.git"
  git init -q -b main "$dir/work"
  (
    cd "$dir/work"
    git remote add origin "$dir/origin.git"
    printf '# Changelog\n\n## [9.9.8]\n\n- old\n' > CHANGELOG.md
    git add CHANGELOG.md; git commit -qm base; git push -q origin main
    git branch develop
    case "$kind" in
      ok) printf '# Changelog\n\n## [9.9.9] - 2026-01-01\n\n- new entry\n\n## [9.9.8]\n\n- old\n' > CHANGELOG.md ;;
      no-heading) printf '# Changelog\n\n## [9.9.90]\n\n- other\n\n## [9.9.8]\n\n- old\n' > CHANGELOG.md ;;
      near-heading) printf '# Changelog\n\n## [9x9x9]\n\n- other\n\n## [9.9.8]\n\n- old\n' > CHANGELOG.md ;;
      blank) printf '# Changelog\n\n## [9.9.9]\n\n   \n\n## [9.9.8]\n\n- old\n' > CHANGELOG.md ;;
      no-file) git rm -q CHANGELOG.md; printf 'x\n' > other.txt ;;
    esac
    git add -A; git commit -qm release; git push -q origin main
    git reset -q --hard HEAD~1
    git checkout -q develop
  )
}

# Runs the notes block in fixture $1; sets rc, out (stdout), err (stderr).
run_notes() {
  local dir=$1
  [ "$(git -C "$dir/work" rev-parse --show-toplevel)" = "$(cd "$dir/work" && pwd -P)" ] || fail "fixture work tree not resolved"
  rc=0
  (cd "$dir/work" && TMPDIR="$dir/tmp" bash "$notes_block" >"$dir/out" 2>"$dir/err") || rc=$?
  out=$(cat "$dir/out"); err=$(cat "$dir/err")
}

# T-01: extraction from origin/main while the work tree is on develop.
fx="$TMP_ROOT/ok"; make_fixture "$fx" ok
origin_sha=$(git -C "$fx/work" rev-parse origin/main)
[ "$origin_sha" != "$(git -C "$fx/work" rev-parse main)" ] || fail "T-01 fixture: local main must lag origin/main"
[ "$(git -C "$fx/work" branch --show-current)" = develop ] || fail "T-01 fixture: work tree must stay on develop"
run_notes "$fx"
[ "$rc" = 0 ] || fail "T-01 rc=$rc err=$err"
notes_path=$(printf '%s\n' "$out" | sed -n 's/^\[CONTEXT\] RELEASE_NOTES_PATH=//p')
expected_markers=$(printf '[CONTEXT] RELEASE_NOTES_SHA=%s\n[CONTEXT] RELEASE_NOTES_PATH=%s' "$origin_sha" "$notes_path")
[ "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ')" = "$expected_markers" ] || fail "T-01 markers: $out"
[ "$(cat "$notes_path")" = "$(printf '\n- new entry\n')" ] || fail "T-01 notes content: $(cat "$notes_path")"

# T-05: gh release create targets the same SHA and uses the same notes file.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/bin/bash
{ printf '%s\n' "$@"; echo '--end--'; } >> "$GH_ARGV_LOG"
EOF
chmod +x "$TMP_ROOT/bin/gh"
export GH_ARGV_LOG="$TMP_ROOT/gh-argv-t05.log"
sed -i.bak -e "s|{RELEASE_NOTES_SHA}|$origin_sha|g" -e "s|{RELEASE_NOTES_PATH}|$notes_path|g" "$create_block" && rm -f "$create_block.bak"
[ "$(PATH="$TMP_ROOT/bin:$PATH" command -v gh)" = "$TMP_ROOT/bin/gh" ] || fail "T-05 gh stub not first on PATH"
PATH="$TMP_ROOT/bin:$PATH" bash "$create_block" || fail "T-05 create block failed"
expected_argv=$(printf '%s\n' release create v9.9.9 --title v9.9.9 --notes-file "$notes_path" --target "$origin_sha" --end--)
[ "$(cat "$GH_ARGV_LOG")" = "$expected_argv" ] || fail "T-05 gh argv: $(cat "$GH_ARGV_LOG")"
rm -f "$notes_path"

# T-02 / T-03 / T-04: stop before any marker, with the step-specific error, leaving no scratch file.
for case_spec in 'no-heading|の節がありません' 'near-heading|の節がありません' 'blank|の節の本文が空です' 'no-file|の CHANGELOG.md を読めませんでした'; do
  kind=${case_spec%%|*} msg=${case_spec#*|}
  fx="$TMP_ROOT/$kind"; make_fixture "$fx" "$kind"
  run_notes "$fx"
  [ "$rc" = 1 ] || fail "$kind rc=$rc out=$out err=$err"
  printf '%s\n' "$err" | grep -qF -- "$msg" || fail "$kind error message: $err"
  [ "$(printf '%s\n' "$err" | grep -c '^ERROR: ')" = 1 ] || fail "$kind expected one ERROR line: $err"
  printf '%s\n' "$out" | grep -q '^\[CONTEXT\] ' && fail "$kind emitted a marker: $out"
  [ -z "$(ls -A "$fx/tmp")" ] || fail "$kind left scratch files: $(ls -A "$fx/tmp")"
done

# T-06 .. T-09 (AC-1 / AC-2): the existing remote tag decides whether the release may be created.
# The tag check and the create block run as one script so a stop really keeps gh unused.
chain="$TMP_ROOT/chain.sh"
# $2 puts a tag on origin: "other" points elsewhere, "match"/"annotated" point at origin/main.
tag_fixture() {
  local dir=$1 kind=$2
  make_fixture "$dir" ok
  (
    cd "$dir/work"
    case "$kind" in
      other) git tag v9.9.9 main && git push -q origin refs/tags/v9.9.9 ;;
      match) git tag v9.9.9 origin/main && git push -q origin refs/tags/v9.9.9 ;;
      annotated) git tag -a -m release v9.9.9 origin/main && git push -q origin refs/tags/v9.9.9 ;;
      none) ;;
    esac
    git tag -d v9.9.9 >/dev/null 2>&1 || true
  )
}
# Each fixture is its own repository, so the notes SHA is substituted per fixture.
build_chain() {
  local dir=$1 sha
  sha=$(git -C "$dir/work" rev-parse origin/main)
  sed "s|{RELEASE_NOTES_SHA}|$sha|g" "$tag_block" > "$chain"
  cat "$create_block" >> "$chain"
}
run_chain() {
  local dir=$1 label=$2
  build_chain "$dir"
  rc=0
  GH_ARGV_LOG="$TMP_ROOT/gh-argv-$label.log"; : > "$GH_ARGV_LOG"
  (cd "$dir/work" && GH_ARGV_LOG="$GH_ARGV_LOG" PATH="$TMP_ROOT/bin:$PATH" bash "$chain" >"$dir/out" 2>"$dir/err") || rc=$?
  out=$(cat "$dir/out"); err=$(cat "$dir/err")
}
fx="$TMP_ROOT/tag-other"; tag_fixture "$fx" other
run_chain "$fx" tag-other
[ "$rc" = 1 ] || fail "T-06 mismatched tag rc=$rc out=$out"
printf '%s\n' "$err" | grep -qF -- 'と一致しません' || fail "T-06 error message: $err"
printf '%s\n' "$out" | grep -q '^\[CONTEXT\] RELEASE_TAG_STATE=' && fail "T-06 emitted a state marker: $out"
[ ! -s "$TMP_ROOT/gh-argv-tag-other.log" ] || fail "T-06 called gh: $(cat "$TMP_ROOT/gh-argv-tag-other.log")"
for tag_case in none:absent match:matched annotated:matched; do
  kind=${tag_case%%:*} state=${tag_case#*:}
  fx="$TMP_ROOT/tag-$kind"; tag_fixture "$fx" "$kind"
  run_chain "$fx" "tag-$kind"
  [ "$rc" = 0 ] || fail "T-07/08/09 $kind rc=$rc err=$err"
  [ "$(printf '%s\n' "$out" | grep '^\[CONTEXT\] ')" = "[CONTEXT] RELEASE_TAG_STATE=$state" ] || fail "$kind markers: $out"
  grep -qF -- "--target" "$TMP_ROOT/gh-argv-tag-$kind.log" || fail "$kind did not reach the release creation"
done
# ls-remote failure stops the chain; the twin without the stub reaches gh.
cat > "$TMP_ROOT/bin/git" <<'EOF'
#!/bin/bash
[ "$1" = ls-remote ] && [ "${FAIL_LS_REMOTE:-0}" = 1 ] && exit 1
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TMP_ROOT/bin/git"
export REAL_GIT; REAL_GIT=$(command -v git)
for mode in 1 0; do
  fx="$TMP_ROOT/tag-lsremote-$mode"; tag_fixture "$fx" none
  [ "$(PATH="$TMP_ROOT/bin:$PATH" command -v git)" = "$TMP_ROOT/bin/git" ] || fail "T-09 git stub not first on PATH"
  build_chain "$fx"
  rc=0
  GH_ARGV_LOG="$TMP_ROOT/gh-argv-ls-$mode.log"; : > "$GH_ARGV_LOG"
  (cd "$fx/work" && FAIL_LS_REMOTE=$mode GH_ARGV_LOG="$GH_ARGV_LOG" PATH="$TMP_ROOT/bin:$PATH" bash "$chain" >"$fx/out" 2>"$fx/err") || rc=$?
  if [ "$mode" = 1 ]; then
    [ "$rc" = 1 ] || fail "T-09 ls-remote failure rc=$rc"
    grep -qF 'ERROR: 既存タグ v9.9.9 を確認できませんでした' "$fx/err" || fail "T-09 error message: $(cat "$fx/err")"
    [ ! -s "$TMP_ROOT/gh-argv-ls-1.log" ] || fail "T-09 called gh after a failed tag check"
  else
    [ "$rc" = 0 ] || fail "T-09 twin rc=$rc err=$(cat "$fx/err")"
    grep -qF -- "--target" "$TMP_ROOT/gh-argv-ls-0.log" || fail "T-09 twin did not reach the release creation"
  fi
done
rm -f "$TMP_ROOT/bin/git"

# T-10 (AC-3): 4.1 can only compare the tag after fetching it — the release creates it on the remote only.
fx="$TMP_ROOT/tag-fetch"; tag_fixture "$fx" match
git -C "$fx/work" rev-parse -q --verify "v9.9.9^{commit}" >/dev/null && fail "T-10 fixture: the tag must be remote-only"
git -C "$fx/work" fetch --tags origin >/dev/null 2>&1 || fail "T-10 fetch --tags failed"
[ "$(git -C "$fx/work" rev-parse "v9.9.9^{commit}")" = "$(git -C "$fx/work" rev-parse origin/main)" ] || fail "T-10 tag does not point at the notes SHA"

[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$repo_head_before" ] || fail "repository HEAD changed"
echo "PASS: release notes come from the confirmed origin/main SHA"
