#!/usr/bin/env bash
# gitignore-health-check.sh
#
# Verify that `$state_root/.rite/.gitignore` is the 3-line composition generated
# by setup and hooks (`*` / `!wiki/` / `!wiki/**`). `$state_root` is the main
# checkout (`state-path-resolve.sh`), not a linked worktree's show-toplevel.
# Lint never writes that file.
#
# Detection strategy:
#
#   nested file: byte-identical to `_rite_nested_gitignore_expected`
#       (star then wiki negations). Missing or mismatched is drift.
#
#   separate_branch: nested composition is SoT; root `.rite/wiki/` is not required.
#
#   same_branch: `git add --dry-run` on a wiki probe must succeed.
#       `git check-ignore -v` is NOT deterministic under negation rules.
#       We create a real probe file, run `git add --dry-run` on it, and verify
#       rc=0 + stdout contains `add '...negation-probe'`. The probe is cleaned
#       up regardless of outcome via the signal-specific trap below.
#
# On drift, print a plain WARNING to stderr (exit 1) so the LLM surfaces the
# `.rite/wiki/` rule regression in the conversation context.
#
# `.gitignore` silent-leak regression guard.
# Companion to:
#   - the rule that added `.rite/wiki/` to `.gitignore` as last-line-of-defense
#   - plugins/rite/skills/lint/SKILL.md Phase 3.9: invocation site
#
# Usage:
#   gitignore-health-check.sh [--repo-root DIR] [--quiet]
#                             [--branch-strategy-override STRATEGY]
#                             [--verify-negation] [-h|--help]
#
# Options:
#   --repo-root DIR                   Repository root (default: git rev-parse --show-toplevel)
#   --quiet                           Suppress informational output
#   --branch-strategy-override VAL    Override wiki.branch_strategy from rite-config.yml
#                                     (one of: separate_branch | same_branch) — smoke test only
#   --verify-negation                 Post-injection negation verification mode for
#                                     wiki/init.md ステップ 1.3.4 (delegation target).
#                                     Skips config/strategy/parent-exclusion checks (caller
#                                     is same_branch + just injected the negation) and is
#                                     fully non-blocking: every outcome exits 0 and the
#                                     result is surfaced via stdout `✅ ... OK` / stderr
#                                     `WARNING`. See the dedicated block below.
#   -h, --help                        Show this help
#
# Exit codes (non-blocking contract, identical to drift-check / wiki-growth-check):
#   0  Health verified (or wiki disabled / legitimate no-op — skip silently)
#   1  Drift detected (warning — caller MUST keep [lint:success])
#   2  Invocation error (bad args, missing repo)
#   NOTE: --verify-negation overrides this table — it ALWAYS exits 0 (non-blocking),
#         matching wiki/init.md ステップ 1.3.4 which proceeds to ステップ 2 regardless.
#
# Output:
#   Default (lint) mode: always prints `==> Total gitignore-health-check findings: N`
#   on stdout; on drift (exit 1) additionally prints a plain `WARNING: ...` to stderr.
#   --verify-negation mode: prints `✅ .gitignore negation verification OK: ...` to stdout
#   on success, or `WARNING: ...` to stderr on failure/skip. Does NOT print the
#   `==> Total ... findings: N` line (it is not a drift-count aggregator).
#
set -uo pipefail
# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"
# shellcheck source=../gitignore-ensure.sh
source "$(dirname "${BASH_SOURCE[0]}")/../gitignore-ensure.sh"

# Absolute hooks dir captured before any `cd` so later `cd "$REPO_ROOT"` cannot
# break a relative BASH_SOURCE. state-path-resolve.sh is invoked as a subprocess
# (not sourced): that helper starts with `set -euo pipefail`, which must not
# leak into this script's `set -uo pipefail`.
_GHC_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || {
  echo "ERROR: gitignore-health-check: cannot resolve hooks directory" >&2
  echo "==> Total gitignore-health-check findings: unknown (verification failed)"
  exit 2
}

# Signal-specific trap (canonical pattern from references/bash-trap-patterns.md):
# - EXIT preserves original exit code via `rc=$?`
# - INT/TERM/HUP exit with POSIX-conventional codes (130/143/129)
# - Tempfiles + same_branch probe file are cleaned in all paths
# - BSD/macOS rm portability: empty-arg guard via `[ -n "${var:-}" ] && rm -f "$var"`
#   (some BSD rm variants emit "cannot remove ''" on empty args)
check_ignore_err=""
add_dry_err=""
negation_probe=""
nested_expected=""
_rite_gitignore_cleanup() {
  [ -n "${check_ignore_err:-}" ] && rm -f "$check_ignore_err"
  [ -n "${add_dry_err:-}" ] && rm -f "$add_dry_err"
  [ -n "${nested_expected:-}" ] && rm -f "$nested_expected"
  # same_branch probe file: always remove so lint runs never pollute the tree
  [ -n "${negation_probe:-}" ] && rm -f "${negation_probe}" 2>/dev/null
  # Also remove the probe parent directories (.rite/wiki/raw/, .rite/wiki/) if this
  # script created them and they are empty. `rmdir` fails on non-empty directories,
  # which protects pre-existing raw source files from being unintentionally removed.
  #
  # rmdir suppression for --verify-negation (rmdir 副作用抑止): wiki/init.md ステップ
  # 1.3.4 runs DURING init, right before ステップ 2 creates the wiki directory tree.
  # Its original inline block removed only the probe file (not the dirs) so the
  # freshly-created .rite/wiki/raw/ survives for downstream steps. Skip rmdir here to
  # preserve that contract; default (lint) mode keeps the empty-dir cleanup.
  if [ "${VERIFY_NEGATION:-0}" -eq 0 ]; then
    rmdir .rite/wiki/raw .rite/wiki 2>/dev/null || true
  fi
}
trap 'rc=$?; _rite_gitignore_cleanup; exit $rc' EXIT
trap '_rite_gitignore_cleanup; exit 130' INT
trap '_rite_gitignore_cleanup; exit 143' TERM
trap '_rite_gitignore_cleanup; exit 129' HUP

REPO_ROOT=""
QUIET=0
STRATEGY_OVERRIDE=""
VERIFY_NEGATION=0

usage() {
  cat <<'EOF'
Usage: gitignore-health-check.sh [options]

Options:
  --repo-root DIR                   Repository root (default: git rev-parse --show-toplevel)
  --quiet                           Suppress informational output
  --branch-strategy-override VAL    Override wiki.branch_strategy (separate_branch | same_branch)
                                    Used for smoke testing only; production runs read rite-config.yml.
  --verify-negation                 Post-injection negation verification for wiki/init.md
                                    ステップ 1.3.4 (non-blocking, always exits 0).
  -h, --help                        Show this help

Exit codes:
  0  Health verified (or wiki disabled / legitimate no-op; --verify-negation always)
  1  Drift detected (warning, non-blocking)
  2  Invocation error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)                 REPO_ROOT="$2"; shift 2 ;;
    --quiet)                     QUIET=1; shift ;;
    --branch-strategy-override)  STRATEGY_OVERRIDE="$2"; shift 2 ;;
    --verify-negation)           VERIFY_NEGATION=1; shift ;;
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

# --- --verify-negation mode (wiki/init.md ステップ 1.3.4 delegation target) ---
# init.md §1.3.4 は same_branch 戦略の negation 注入「直後」に呼ばれる post-injection
# verification。caller が same_branch 確定 + negation を inject 済みなので、config 読込 /
# strategy 判定 / Layer 1 parent-exclusion は不要 — それらを全てスキップして early-exit する。
# lint.md Phase 3.9 経路 (drift guard; exit 1=drift / exit 2=env error) とは契約が異なり、
# 本モードは全分岐 non-blocking (exit 0) で、結果は stdout `✅ ... OK` / stderr `WARNING`
# として surface する (init.md は exit code を読まず stdout/stderr で分岐し ステップ 2 へ進む)。
#
# コア検証 (git add --dry-run + grep -qF "add '<probe>'") は同ファイル same_branch case の
# `DRIFT-CHECK ANCHOR: same_branch ...` 節と意図的に同型。init.md はこのロジックの inline copy を
# 持たず本モードへ委譲するため、同期対象は同一ファイル内の 2 箇所に閉じる (cross-file drift を防ぐ)。
if [ "$VERIFY_NEGATION" -eq 1 ]; then
  negation_probe=".rite/wiki/raw/.rite-lint-negation-probe"
  # probe 作成失敗は non-blocking skip (init.md §1.3.4 契約: WARNING + ステップ 2 進行)。
  # lint 経路の same_branch case が exit 2 (invocation error) にするのとは対照的に exit 0。
  if ! { mkdir -p "$(dirname "$negation_probe")" 2>/dev/null && touch "$negation_probe" 2>/dev/null; }; then
    echo "WARNING: negation probe の作成に失敗しました (read-only fs / permission / disk full の可能性)" >&2
    echo "  negation verification を skip して呼び出し元の次ステップに進行します (non-blocking)" >&2
    echo "  same_branch 戦略の git add で negation が効いていなければそこで改めてエラーが出ます" >&2
    exit 0
  fi

  # >>> DRIFT-CHECK ANCHOR: same_branch add_dry_run rc capture (verify-negation copy) <<<
  # Keep one-for-one with the same_branch case copy below (mktemp stderr capture +
  # if-wrapper rc capture). Wiki 経験則 patterns/high「canonical 実装と一字一句同期」.
  add_dry_err=$(mktemp "${TMPDIR:-/tmp}/rite-gitignore-adddry-XXXXXX" 2>/dev/null) || add_dry_err=""
  add_dry_out=""
  add_dry_rc=0
  if add_dry_out=$(git add --dry-run -- "$negation_probe" 2>"${add_dry_err:-/dev/null}"); then
    add_dry_rc=0
  else
    add_dry_rc=$?
  fi
  # >>> DRIFT-CHECK ANCHOR END: same_branch add_dry_run rc capture (verify-negation copy) <<<

  # >>> DRIFT-CHECK ANCHOR: same_branch negation grep-qF healthy check (verify-negation copy) <<<
  if [ "$add_dry_rc" -eq 0 ] && printf '%s' "$add_dry_out" | grep -qF "add '${negation_probe}'"; then
    echo "✅ .gitignore negation verification OK: $add_dry_out"
  else
    echo "WARNING: .gitignore negation verification failed (rc=$add_dry_rc)" >&2
    echo "  stdout: $add_dry_out" >&2
    if [ -n "$add_dry_err" ] && [ -s "$add_dry_err" ]; then
      echo "  stderr (先頭 3 行):" >&2
      head -3 "$add_dry_err" | neutralize_ctrl --keep-newline | sed 's/^/    /' >&2
    fi
    echo "  対処: .gitignore の .rite/wiki/ 行直後 (gitignore-wiki-section-end anchor 直後) に" >&2
    echo "        !.rite/wiki/ と !.rite/wiki/** が配置されているか確認してください" >&2
  fi
  # >>> DRIFT-CHECK ANCHOR END: same_branch negation grep-qF healthy check (verify-negation copy) <<<
  # probe + tempfile cleanup は EXIT trap が担う (rmdir は VERIFY_NEGATION ガードで抑止し、
  # init.md が後続ステップで使う .rite/wiki/raw/ を残す)。
  exit 0
fi

# --- Read config ---
config_file="rite-config.yml"
if [ ! -f "$config_file" ]; then
  log_info "gitignore-health-check: rite-config.yml not found, skipping (exit 0)"
  echo "==> Total gitignore-health-check findings: 0"
  exit 0
fi

# --- Always-on: `$state_root/.rite/.gitignore` must match the generation helper ---
# Generation lives in setup / session-start (`_ensure_rite_nested_gitignore`).
# Compare at state_root (main checkout), not worktree show-toplevel: generation
# writes $state_root/.rite/.gitignore. A raw linked worktree has no nested file.
# This check never writes. Missing or mismatched file is drift — not a skip —
# so lint cannot report healthy when setup has not created the nested file.
nested_expected=""
nested_expected=$(mktemp "${TMPDIR:-/tmp}/rite-gitignore-nested-exp-XXXXXX" 2>/dev/null) || nested_expected=""
if [ -z "$nested_expected" ]; then
  echo "WARNING: gitignore-health-check: mktemp failed — nested gitignore expected content won't be compared" >&2
  echo "==> Total gitignore-health-check findings: unknown (verification failed)"
  exit 2
fi
_rite_nested_gitignore_expected > "$nested_expected"
state_root=$(bash "$_GHC_HOOKS_DIR/state-path-resolve.sh") || state_root=""
if [ -z "$state_root" ]; then
  echo "WARNING: gitignore-health-check: state-path-resolve.sh failed" >&2
  echo "==> Total gitignore-health-check findings: unknown (verification failed)"
  exit 2
fi
nested_gi="$state_root/.rite/.gitignore"
if [ ! -f "$nested_gi" ]; then
  echo "==> gitignore-health-check: DRIFT DETECTED (nested): '$nested_gi' missing" >&2
  echo "==> Hint: run /rite:setup or /rite:setup --upgrade (generation only; lint does not write)." >&2
  echo "WARNING: gitignore-health-check: $nested_gi missing" >&2
  echo "==> Total gitignore-health-check findings: 1"
  exit 1
fi
if ! cmp -s "$nested_gi" "$nested_expected"; then
  echo "==> gitignore-health-check: DRIFT DETECTED (nested): '$nested_gi' is not the 3-line composition (* / !wiki/ / !wiki/**)" >&2
  echo "==> Hint: /rite:setup --upgrade writes .rite/.gitignore only when missing or empty. For composition drift, replace the file with the 3-line composition by hand. lint does not rewrite." >&2
  echo "WARNING: gitignore-health-check: $nested_gi composition drift" >&2
  echo "==> Total gitignore-health-check findings: 1"
  exit 1
fi
log_info "gitignore-health-check: nested $nested_gi composition healthy"

# --- Always-on: verify .rite/sessions/ is ignored (per-session state leak guard) ---
# Unlike the .rite/worktrees/ block below, this is NOT gated on multi_session.enabled:
# `.rite/sessions/{session_id}.flow-state` (per-session flow/compact state)
# is written on EVERY rite session regardless of multi_session, so the leak surface is
# always present. Placed BEFORE the wiki early-exits so a wiki.enabled=false config is
# still verified. Non-blocking & always-on: drift → WARNING + exit 1; healthy → fall
# through. Mirrors the separate_branch Layer-1 probe: a static `git check-ignore -v` (no
# file created) asks git whether a session state path is ignored. If not, per-session
# state files (.rite/sessions/{session_id}.flow-state) would leak into dev-branch diffs.
sessions_probe=".rite/sessions/.rite-lint-probe"
sessions_ci_out=""
sessions_ci_rc=0
if sessions_ci_out=$(git check-ignore -v "$sessions_probe" 2>/dev/null); then sessions_ci_rc=0; else sessions_ci_rc=$?; fi
# 実効判定: マッチルールが親 `.rite/` 広域ルールでも healthy とする。git のディレクトリ pruning に
# より check-ignore -v は最初に一致した親ルールを報告するため、特定ルール表記 (`:.rite/sessions/`)
# への文字列一致を要求すると広域 + 個別の重複構成で個別ルールが実在しても偽陽性 DRIFT になる。
# ただし check-ignore -v は negation ルール (`!pattern`) にマッチした場合も rc=0 を返す
# (verbose モードは negation マッチも「マッチあり」として数える) ため、rc==0 だけでは
# 「実際には ignore されず leak する」構成を healthy と誤判定する。-v の出力形式
# `<source>:<linenum>:<pattern>\t<pathname>` の pattern 先頭が `!` でないことも healthy 条件とする。
sessions_ci_negated=0
if [ "$sessions_ci_rc" -eq 0 ] && printf '%s' "$sessions_ci_out" | grep -qE ':[0-9]+:!'; then
  sessions_ci_negated=1
fi
if [ "$sessions_ci_rc" -eq 0 ] && [ "$sessions_ci_negated" -eq 0 ]; then
  log_info "gitignore-health-check: sessions layer healthy — .rite/sessions/ ignored (${sessions_ci_out})"
elif [ "$sessions_ci_rc" -ge 2 ]; then
  echo "WARNING: gitignore-health-check: git check-ignore failed (rc=$sessions_ci_rc) for .rite/sessions/ verify — skipping sessions check" >&2
else
  if [ "$sessions_ci_negated" -eq 1 ]; then
    echo "==> gitignore-health-check: DRIFT DETECTED (sessions): '.rite/sessions/' matched only a negation rule (${sessions_ci_out}) — effectively NOT ignored" >&2
  else
    echo "==> gitignore-health-check: DRIFT DETECTED (sessions): '.rite/sessions/' rule missing from .gitignore" >&2
  fi
  echo "==> per-session state files (.rite/sessions/{session_id}.flow-state) would leak into dev-branch diffs." >&2
  echo "==> Hint: /rite:setup --upgrade writes .rite/.gitignore only when missing or empty. For composition drift, replace the file with the 3-line composition by hand. lint does not rewrite." >&2
  echo "WARNING: gitignore-health-check: .rite/sessions/ not effectively ignored" >&2
  echo "==> Total gitignore-health-check findings: 1"
  exit 1
fi

# --- Multi-session: verify .rite/worktrees/ is ignored when enabled (design §2) ---
# Independent of wiki settings — placed BEFORE the wiki early-exits so a
# wiki.enabled=false + multi_session.enabled=true config is still verified.
# Non-blocking & opt-in: drift → WARNING + exit 1; healthy or disabled → fall
# through to the wiki checks. Mirrors the separate_branch Layer-1 probe: a static
# `git check-ignore -v` (no file created) asks git whether session worktree paths
# are ignored. If not, session worktrees (.rite/worktrees/issue-{N}) would leak
# into dev-branch diffs.
ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' "$config_file" 2>/dev/null) || ms_section=""
ms_enabled="false"
if [ -n "$ms_section" ]; then
  ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' \
    | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
  case "$ms_enabled" in
    true|yes|1) ms_enabled="true" ;;
    *)          ms_enabled="false" ;;
  esac
fi
if [ "$ms_enabled" = "true" ]; then
  ms_probe=".rite/worktrees/issue-0/.rite-lint-probe"
  ms_ci_out=""
  ms_ci_rc=0
  if ms_ci_out=$(git check-ignore -v "$ms_probe" 2>/dev/null); then ms_ci_rc=0; else ms_ci_rc=$?; fi
  # 実効判定: sessions ブロックと同じ理由で「rc==0 かつ negation マッチでない」を healthy 条件と
  # する (親 `.rite/` 広域ルール一致でも実効的に ignore されていれば偽陽性にしない。negation
  # マッチは rc=0 でも実際には ignore されないため DRIFT — 詳細は sessions ブロックのコメント参照)。
  ms_ci_negated=0
  if [ "$ms_ci_rc" -eq 0 ] && printf '%s' "$ms_ci_out" | grep -qE ':[0-9]+:!'; then
    ms_ci_negated=1
  fi
  if [ "$ms_ci_rc" -eq 0 ] && [ "$ms_ci_negated" -eq 0 ]; then
    log_info "gitignore-health-check: multi_session layer healthy — .rite/worktrees/ ignored (${ms_ci_out})"
  elif [ "$ms_ci_rc" -ge 2 ]; then
    echo "WARNING: gitignore-health-check: git check-ignore failed (rc=$ms_ci_rc) for .rite/worktrees/ verify — skipping multi_session check" >&2
  else
    if [ "$ms_ci_negated" -eq 1 ]; then
      echo "==> gitignore-health-check: DRIFT DETECTED (multi_session): '.rite/worktrees/' matched only a negation rule (${ms_ci_out}) — effectively NOT ignored" >&2
    else
      echo "==> gitignore-health-check: DRIFT DETECTED (multi_session): '.rite/worktrees/' rule missing from .gitignore" >&2
    fi
    echo "==> multi_session.enabled=true but session worktrees (.rite/worktrees/issue-{N}) would leak into dev-branch diffs." >&2
    echo "==> Hint: /rite:setup --upgrade writes .rite/.gitignore only when missing or empty. For composition drift, replace the file with the 3-line composition by hand. lint does not rewrite." >&2
    echo "WARNING: gitignore-health-check: .rite/worktrees/ not effectively ignored while multi_session.enabled=true" >&2
    echo "==> Total gitignore-health-check findings: 1"
    exit 1
  fi
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
check_ignore_err=$(mktemp "${TMPDIR:-/tmp}/rite-gitignore-check-XXXXXX" 2>/dev/null) || check_ignore_err=""
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
  [ -n "$check_ignore_err" ] && [ -s "$check_ignore_err" ] && head -3 "$check_ignore_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  # Report "unknown" (not "0") so lint aggregators don't mistake an invocation
  # failure for a clean run. exit 2 still signals invocation error to callers.
  echo "==> Total gitignore-health-check findings: unknown (verification failed)"
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
    # Nested `*` / `!wiki/` / `!wiki/**` is the SoT. Root `.rite/wiki/` is not
    # required and is not generated — do not DRIFT on its absence (AC-4).
    log_info "gitignore-health-check: separate_branch: nested composition is SoT (root .rite/wiki/ not required)"
    ;;

  same_branch)
    # For same_branch, we also need a negation override so `git add .rite/wiki/...`
    # works during /rite:wiki-ingest. Per .gitignore L101-113 spec, `git check-ignore`
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
    # Sibling reference: the `--verify-negation` early-exit block above (its
    # `(verify-negation copy)` ANCHOR). Keep the mktemp stderr capture + if-wrapper rc
    # capture structure one-for-one with that copy — Wiki 経験則 patterns/high
    # 「canonical 実装と一字一句同期」. (wiki/init.md ステップ 1.3.4 holds no
    # inline copy; it delegates here via `gitignore-health-check.sh --verify-negation`.)
    add_dry_err=$(mktemp "${TMPDIR:-/tmp}/rite-gitignore-adddry-XXXXXX" 2>/dev/null) || add_dry_err=""
    add_dry_out=""
    add_dry_rc=0
    if add_dry_out=$(git add --dry-run -- "$negation_probe" 2>"${add_dry_err:-/dev/null}"); then
      add_dry_rc=0
    else
      add_dry_rc=$?
    fi
    # >>> DRIFT-CHECK ANCHOR END: same_branch add_dry_run rc capture <<<

    # >>> DRIFT-CHECK ANCHOR: same_branch negation grep-qF healthy check <<<
    # Sibling reference: the `--verify-negation` early-exit block above (its
    # `(verify-negation copy)` ANCHOR). Keep the `grep -qF "add '${negation_probe}'"`
    # full-path fixed-string match one-for-one with that copy — simple `grep -q "^add '"`
    # 単純 prefix は false positive を招く. (wiki/init.md ステップ 1.3.4 delegates here.)
    # Healthy negation: rc=0 + stdout like `add '.rite/wiki/raw/.rite-lint-negation-probe'`
    # Broken negation: rc=1 + stderr contains "paths are ignored"
    if [ "$add_dry_rc" -eq 0 ] && printf '%s' "$add_dry_out" | grep -qF "add '${negation_probe}'"; then
      log_info "gitignore-health-check: same_branch layer 2 healthy — negation override works (git add --dry-run rc=0)"
    else
      echo "==> gitignore-health-check: DRIFT DETECTED (same_branch): negation override for '.rite/wiki/' missing or broken" >&2
      echo "==> git add --dry-run $negation_probe returned rc=$add_dry_rc" >&2
      [ -n "$add_dry_err" ] && [ -s "$add_dry_err" ] && head -3 "$add_dry_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "==> Hint: same_branch requires .rite/.gitignore 3-line composition (* / !wiki/ / !wiki/**) so git add .rite/wiki/raw/*.md succeeds. lint does not rewrite." >&2
      findings=$((findings + 1))
    fi
    # >>> DRIFT-CHECK ANCHOR END: same_branch negation grep-qF healthy check <<<
    # probe cleanup handled by trap
    ;;
esac

# --- Warn on drift ---
# Drift detail was already printed to stderr above (the DRIFT DETECTED block per
# strategy). Surface a final plain WARNING so a silently-broken .gitignore rule
# does not go unnoticed. LLM surfaces this in the conversation context.
if [ "$findings" -gt 0 ]; then
  echo "WARNING: gitignore-health-check: gitignore drift detected (strategy=$branch_strategy)" >&2
  echo "==> Total gitignore-health-check findings: $findings"
  exit 1
fi

echo "==> Total gitignore-health-check findings: 0"
exit 0
