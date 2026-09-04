# shellcheck shell=bash
# rite workflow - Git remote owner/repo resolution
#
# Responsibility: resolve "owner" and "repo" from the `origin` remote URL
# without depending on `gh` recognizing the remote's host. `gh repo view`
# fails with "none of the git remotes configured for this repository point
# to a known GitHub host" when `origin` uses an SSH Host alias set up in
# ~/.ssh/config (e.g. `git@github.com-work:owner/repo.git`) — even though
# the alias resolves fine for plain git operations and `gh` is otherwise
# authenticated. Parsing the remote URL directly sidesteps gh's
# host allowlist entirely: the host segment is discarded regardless of
# what it says, so an unrecognized alias can never break this path.
#
# Usage (standalone subprocess only — callers never source this file;
# running the resolver as its own process means it cannot perturb a
# caller's `set -euo pipefail` / trap regime):
#   line=$(bash lib/git-remote.sh resolve-owner-repo) || fall back
#   IFS=$'\t' read -r owner repo <<< "$line"
#
# Output contract: on success, stdout is exactly one line "owner<TAB>repo"
# and exit is 0. On failure (no origin remote, or URL doesn't parse to an
# owner/repo path), stderr gets one ERROR line and exit is 1 — callers are
# expected to fall back to `gh repo view` in that case, not treat it as fatal.

resolve_owner_repo() {
  local url path
  url=$(git config --get remote.origin.url 2>/dev/null)
  if [ -z "$url" ]; then
    echo "ERROR: git-remote: no URL configured for remote 'origin'" >&2
    return 1
  fi
  case "$url" in
    *://*)
      # protocol-style: scheme://[user@]host[:port]/owner/repo[.git]
      path="${url#*://}"
      path="${path#*@}"
      path="${path#*/}"
      ;;
    *)
      # scp-like: [user@]host:owner/repo[.git] (the alias case — host is
      # whatever ~/.ssh/config maps it to, e.g. github.com-work)
      path="${url#*:}"
      ;;
  esac
  path="${path%.git}"
  # The origin URL itself is deliberately NOT echoed in the ERROR messages
  # below: protocol-style origins can embed credentials
  # (https://TOKEN@host/...), and callers may surface this stderr in their
  # own diagnostics. Inspect with: git config --get remote.origin.url
  case "$path" in
    */*)
      if [ -z "${path%%/*}" ] || [ -z "${path#*/}" ]; then
        echo "ERROR: git-remote: owner or repo segment is empty in the origin URL path" >&2
        return 1
      fi
      ;;
    *)
      echo "ERROR: git-remote: origin URL does not contain an owner/repo path" >&2
      return 1
      ;;
  esac
  local owner="${path%%/*}" repo="${path#*/}"
  # Reject charset outside GitHub's owner/repo alphabet and, critically, any
  # embedded `/` left in $repo (a 3+ segment origin path, e.g.
  # `host:a/b/c.git`). Callers pass this value straight into `gh ... --repo`,
  # which re-parses `[HOST/]OWNER/REPO` — an unrejected extra segment would
  # make gh treat the first segment as a HOST, redirecting the call to a
  # different GitHub instance chosen by whatever `origin` happens to contain.
  case "$owner$repo" in
    *[!A-Za-z0-9._-]*)
      echo "ERROR: git-remote: owner/repo contains characters outside the allowed set: $owner/$repo" >&2
      return 1
      ;;
  esac
  printf '%s\t%s\n' "$owner" "$repo"
}

# -----------------------------------------------------------------------
# Standalone CLI dispatch. Sourcing this file is a no-op here (the guard is
# false); running it as `bash lib/git-remote.sh <subcommand>` dispatches.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    resolve-owner-repo)
      resolve_owner_repo
      exit $?
      ;;
    *)
      echo "ERROR: git-remote.sh: unknown subcommand '${1:-}' (expected: resolve-owner-repo)" >&2
      exit 2
      ;;
  esac
fi
