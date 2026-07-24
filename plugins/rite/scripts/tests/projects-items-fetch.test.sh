#!/bin/bash
# Tests for projects-items-fetch.sh
#
# 旧 issue/list.md Phase 4.2 inline block (~44 行) の委譲先 helper。
# 動作保持は differential equivalence test (TC-D 系) で機械的に立証する:
# 旧 inline block を参照実装として verbatim 再現し、同一 mock シナリオで
# stdout 形状 (path / sentinel) と正規化 JSON の byte 一致を比較する。
#
# Usage: bash plugins/rite/scripts/tests/projects-items-fetch.test.sh
set -euo pipefail

# _timeout <seconds> <command...> — portable timeout(1) for this test (Issue #2008).
# GNU `timeout` is absent on macOS (BSD / no coreutils); fall back to a perl
# fork/waitpid shim reproducing timeout(1)'s exit-code contract: 124 on timeout,
# 128+N on signal death, the child's status otherwise (a naive
# `perl -e 'alarm; exec'` would exit 142 and defeat hang-detection assertions).
# This file does not source _test-helpers.sh, so the shim is inlined here — keep
# it byte-identical with _test-helpers.sh (timeout-shim.test.sh asserts no drift).
_timeout() {
  local _d="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_d" "$@"
  else
    perl -e '
      my $d = shift;
      # alarm truncates to an integer, so a fractional deadline silently becomes
      # alarm 0 — no timeout at all, and waitpid blocks until the CI job limit.
      # Reject rather than degrade.
      die "_timeout: fractional seconds are not supported by the perl fallback: $d\n" unless $d =~ /^[0-9]+$/;
      my $pid = fork;
      exit 127 unless defined $pid;
      if ($pid == 0) { exec { $ARGV[0] } @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", $pid; waitpid($pid, 0); exit 124; };
      alarm $d; waitpid $pid, 0;
      my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$_d" "$@"
  fi
}

# Fail closed when no backend exists. Every `_timeout` caller reads a non-124 rc
# as "no hang", so a missing backend would silently turn each hang assertion into
# a pass. Abort at source time rather than degrade.
if ! command -v timeout >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: neither timeout(1) nor perl(1) is available — _timeout cannot detect" >&2
  echo "  hangs, and every hang assertion in this suite would silently pass." >&2
  echo "  Install GNU coreutils (timeout) or perl before running the test suite." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../projects-items-fetch.sh"
MOCK_DIR="$SCRIPT_DIR"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

MOCK_BIN_DIR="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
ln -s "$MOCK_DIR/mock-gh.sh" "$MOCK_BIN_DIR/gh"

# tempfile leak 検査のため mktemp の出力先を隔離する
ISOLATED_TMP="$TEST_DIR/isolated-tmp"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# jq fault-injection shim: pif_normalize_fail シナリオでのみ最終正規化の `jq -s` を失敗させる。
# 最終 jq -s は gh の出力ではなく中間 pages file を読むため mock-gh.sh では駆動できない
# (helper 固有 hardening — 旧 inline block に jq -s 失敗 handling が無いため TC-D 対象外)。
# 他のシナリオ / `-s` なしの jq 呼び出しは real jq に pass-through する。
REAL_JQ="$(command -v jq)"
cat > "$MOCK_BIN_DIR/jq" <<SHIM_EOF
#!/bin/bash
if [ "\${MOCK_GH_SCENARIO:-}" = "pif_normalize_fail" ]; then
  for arg in "\$@"; do
    if [ "\$arg" = "-s" ]; then
      echo "jq: error: simulated normalization failure (pif_normalize_fail)" >&2
      exit 2
    fi
  done
fi
exec "$REAL_JQ" "\$@"
SHIM_EOF
chmod +x "$MOCK_BIN_DIR/jq"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# Helper: run the target with mock gh in an isolated TMPDIR.
# Sets LAST_OUTPUT / LAST_RC. Each call resets the isolated tmp dir.
run_fetch() {
  local scenario="$1"
  shift
  rm -rf "$ISOLATED_TMP"
  mkdir -p "$ISOLATED_TMP"
  local rc=0
  local output
  output=$(
    MOCK_GH_SCENARIO="$scenario" \
    TMPDIR="$ISOLATED_TMP" \
    PATH="$MOCK_BIN_DIR:$PATH" \
    _timeout 10 bash "$TARGET" "$@" 2>"$TEST_DIR/last_stderr"
  ) || rc=$?
  LAST_OUTPUT="$output"
  LAST_RC=$rc
  return 0
}

# --- 参照実装: 旧 issue/list.md Phase 4.2 inline block の verbatim 再現 ---
# {project_number} / {owner} は旧 block で許可されていた唯一の substitute。
# テストでは 6 / test-owner に固定する (mock は値を検査しない)。
REF_SCRIPT="$TEST_DIR/reference-inline-block.sh"
cat > "$REF_SCRIPT" <<'REF_EOF'
tmpfile=$(mktemp); pages=$(mktemp); err=$(mktemp)
pid=$(gh project view 6 --owner test-owner --format json 2>"$err" | jq -r '.id')
if [ -z "$pid" ] || [ "$pid" = "null" ]; then echo "[projects:fetch-failed] could not resolve project id: $(tr '\n' ' ' < "$err")"; rm -f "$tmpfile" "$pages" "$err"; exit 0; fi
cursor=""; : > "$pages"; ok=1; fail_reason=""
QUERY='
query($pid: ID!, $cursor: String) {
  node(id: $pid) {
    ... on ProjectV2 {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          content { ... on Issue { number } ... on PullRequest { number } }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
          }
        }
      }
    }
  }
}'
while : ; do
  if [ -n "$cursor" ]; then
    page=$(gh api graphql -f query="$QUERY" -f pid="$pid" -f cursor="$cursor" 2>"$err") || { ok=0; fail_reason="gh api graphql failed: $(tr '\n' ' ' < "$err")"; break; }
  else
    page=$(gh api graphql -f query="$QUERY" -f pid="$pid" 2>"$err") || { ok=0; fail_reason="gh api graphql failed: $(tr '\n' ' ' < "$err")"; break; }
  fi
  gqe=$(echo "$page" | jq -r '.errors // [] | map(.message) | join("; ")' 2>/dev/null)
  if [ -n "$gqe" ]; then ok=0; fail_reason="graphql errors: $gqe"; break; fi
  echo "$page" | jq -e '.data.node.items' >/dev/null 2>&1 || { ok=0; fail_reason="missing .data.node.items (possible partial response)"; break; }
  echo "$page" | jq -c '.data.node.items.nodes[]?' >> "$pages"
  hn=$(echo "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')
  cursor=$(echo "$page" | jq -r '.data.node.items.pageInfo.endCursor')
  [ "$hn" = "true" ] && [ -n "$cursor" ] && [ "$cursor" != "null" ] || break
done
if [ "$ok" != "1" ]; then echo "[projects:fetch-failed] ${fail_reason:-graphql paging error}"; rm -f "$tmpfile" "$pages" "$err"; exit 0; fi
jq -s '{items: ([ .[] | { content: { number: (.content.number // null) }, status: ([ .fieldValues.nodes[]? | select(.field.name? == "Status") | .name ] | first // null) } ] | map(select(.content.number == null | not)))}' "$pages" > "$tmpfile"
rm -f "$pages" "$err"
echo "$tmpfile"
REF_EOF

run_reference() {
  local scenario="$1"
  local rc=0
  local output
  output=$(
    MOCK_GH_SCENARIO="$scenario" \
    TMPDIR="$ISOLATED_TMP" \
    PATH="$MOCK_BIN_DIR:$PATH" \
    _timeout 10 bash "$REF_SCRIPT" 2>"$TEST_DIR/ref_stderr"
  ) || rc=$?
  REF_OUTPUT="$output"
  REF_RC=$rc
  return 0
}

echo "=== projects-items-fetch.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-1: pif_success → stdout は path、正規化 JSON が期待形 (draft 除外 / status null 許容)
# --------------------------------------------------------------------------
echo "TC-1: success single page"
run_fetch pif_success --project-number 6 --owner test-owner
if [ "$LAST_RC" = "0" ] && [ -f "$LAST_OUTPUT" ]; then
  expected='{"items":[{"content":{"number":101},"status":"In Progress"},{"content":{"number":102},"status":null}]}'
  actual=$(jq -c . "$LAST_OUTPUT")
  if [ "$actual" = "$expected" ]; then
    pass "normalized JSON matches (draft excluded, null status kept)"
  else
    fail "normalized JSON mismatch: $actual"
  fi
else
  fail "expected tempfile path on stdout (rc=$LAST_RC, output=$LAST_OUTPUT)"
fi

# --------------------------------------------------------------------------
# TC-2: pif_multi_page → 2 頁分の item が揃う (pagination)
# --------------------------------------------------------------------------
echo "TC-2: multi-page pagination"
run_fetch pif_multi_page --project-number 6 --owner test-owner
if [ "$LAST_RC" = "0" ] && [ -f "$LAST_OUTPUT" ]; then
  numbers=$(jq -c '[.items[].content.number]' "$LAST_OUTPUT")
  if [ "$numbers" = "[101,102]" ]; then
    pass "both pages collected ($numbers)"
  else
    fail "pagination incomplete: $numbers"
  fi
else
  fail "expected tempfile path on stdout (rc=$LAST_RC, output=$LAST_OUTPUT)"
fi

# --------------------------------------------------------------------------
# TC-3: project view 失敗 → fetch-failed sentinel + exit 0
# --------------------------------------------------------------------------
echo "TC-3: project view failure"
run_fetch pif_project_view_fail --project-number 6 --owner test-owner
if [ "$LAST_RC" = "0" ] && [[ "$LAST_OUTPUT" == "[projects:fetch-failed] could not resolve project id:"* ]]; then
  pass "fetch-failed sentinel + exit 0"
else
  fail "unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-4: project id null → fetch-failed sentinel
# --------------------------------------------------------------------------
echo "TC-4: project id null"
run_fetch pif_view_null_id --project-number 6 --owner test-owner
if [ "$LAST_RC" = "0" ] && [[ "$LAST_OUTPUT" == "[projects:fetch-failed] could not resolve project id:"* ]]; then
  pass "fetch-failed sentinel on null id"
else
  fail "unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-5: graphql 失敗 → fetch-failed sentinel
# --------------------------------------------------------------------------
echo "TC-5: graphql failure"
run_fetch pif_graphql_fail --project-number 6 --owner test-owner
if [ "$LAST_RC" = "0" ] && [[ "$LAST_OUTPUT" == "[projects:fetch-failed] gh api graphql failed:"* ]]; then
  pass "fetch-failed sentinel on graphql failure"
else
  fail "unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-6: graphql errors 配列 → メッセージ連結
# --------------------------------------------------------------------------
echo "TC-6: graphql errors array"
run_fetch pif_graphql_errors --project-number 6 --owner test-owner
if [ "$LAST_RC" = "0" ] && [ "$LAST_OUTPUT" = "[projects:fetch-failed] graphql errors: Something went wrong; Rate limited" ]; then
  pass "errors joined with '; '"
else
  fail "unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-7: data.node null → missing items 経路
# --------------------------------------------------------------------------
echo "TC-7: missing .data.node.items"
run_fetch pif_missing_items --project-number 6 --owner test-owner
if [ "$LAST_RC" = "0" ] && [ "$LAST_OUTPUT" = "[projects:fetch-failed] missing .data.node.items (possible partial response)" ]; then
  pass "missing items sentinel"
else
  fail "unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-8: placeholder 残留 ({project_number}) → fetch-failed + exit 0 (gh 未呼出)
# --------------------------------------------------------------------------
echo "TC-8: placeholder residue"
run_fetch pif_success --project-number "{project_number}" --owner test-owner
if [ "$LAST_RC" = "0" ] && [[ "$LAST_OUTPUT" == "[projects:fetch-failed] invalid --project-number:"* ]]; then
  pass "placeholder residue caught as invalid number"
else
  fail "unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-9: --owner 欠落 → fetch-failed + exit 0
# --------------------------------------------------------------------------
echo "TC-9: missing owner"
run_fetch pif_success --project-number 6
if [ "$LAST_RC" = "0" ] && [ "$LAST_OUTPUT" = "[projects:fetch-failed] missing --owner" ]; then
  pass "missing owner caught"
else
  fail "unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-10: 値なしフラグ末尾 → no-hang (shift hardening)
# --------------------------------------------------------------------------
echo "TC-10: value-less trailing flag no-hang"
run_fetch pif_success --project-number 6 --owner
if [ "$LAST_RC" != "124" ] && [ "$LAST_RC" = "0" ] && [[ "$LAST_OUTPUT" == "[projects:fetch-failed]"* ]]; then
  pass "no hang, fails closed (rc=$LAST_RC)"
else
  fail "hang or unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-11: 失敗経路で tempfile leak なし / 成功経路は hand-off の 1 file のみ残る
# --------------------------------------------------------------------------
echo "TC-11: tempfile lifecycle"
run_fetch pif_graphql_fail --project-number 6 --owner test-owner
leak_count=$(find "$ISOLATED_TMP" -type f | wc -l | tr -d ' ')
if [ "$leak_count" = "0" ]; then
  pass "failure path leaves no tempfiles"
else
  fail "failure path leaked $leak_count tempfile(s): $(find "$ISOLATED_TMP" -type f)"
fi
run_fetch pif_success --project-number 6 --owner test-owner
remain_count=$(find "$ISOLATED_TMP" -type f | wc -l | tr -d ' ')
if [ "$remain_count" = "1" ] && [ -f "$LAST_OUTPUT" ]; then
  pass "success path hands off exactly one result file"
else
  fail "expected exactly 1 handed-off file, got $remain_count"
fi
# The leak counts above cannot detect a revert to bare `mktemp`: GNU mktemp honours
# $TMPDIR without a template, so the files land in $ISOLATED_TMP either way and the
# counts are identical. Asserting the basename pins the explicit template on the
# blocking Linux leg, where the BSD behaviour the change targets is unobservable
# (Issue #2008 review G-05).
case "$(basename "$LAST_OUTPUT")" in
  rite-projects-items-result-*)
    pass "result tempfile uses the explicit rite-projects-items-result-XXXXXX template" ;;
  *)
    fail "result tempfile basename '$(basename "$LAST_OUTPUT")' does not match rite-projects-items-result-* — bare mktemp regression?" ;;
esac

# --------------------------------------------------------------------------
# TC-12: jq normalization 失敗 → fetch-failed sentinel + tempfile 非 leak
#        (jq shim による fault injection。旧 inline block は jq -s 失敗を
#         handling しないため TC-D 差分比較の対象外)
# --------------------------------------------------------------------------
echo "TC-12: jq normalization failure"
run_fetch pif_normalize_fail --project-number 6 --owner test-owner
if [ "$LAST_RC" = "0" ] && [[ "$LAST_OUTPUT" == "[projects:fetch-failed] jq normalization failed:"* ]]; then
  pass "fetch-failed sentinel on jq normalization failure"
else
  fail "unexpected (rc=$LAST_RC): $LAST_OUTPUT"
fi
norm_leak_count=$(find "$ISOLATED_TMP" -type f | wc -l | tr -d ' ')
if [ "$norm_leak_count" = "0" ]; then
  pass "normalization failure path leaves no tempfiles"
else
  fail "normalization failure path leaked $norm_leak_count tempfile(s): $(find "$ISOLATED_TMP" -type f)"
fi

# --------------------------------------------------------------------------
# TC-D: differential equivalence — 旧 inline block (参照実装) と出力一致
# --------------------------------------------------------------------------
echo "TC-D: differential equivalence vs original inline block"
for scenario in pif_success pif_multi_page pif_project_view_fail pif_view_null_id pif_graphql_fail pif_graphql_errors pif_missing_items; do
  rm -rf "$ISOLATED_TMP"
  mkdir -p "$ISOLATED_TMP"
  run_reference "$scenario"
  # run_fetch は ISOLATED_TMP を reset するため、参照実装の成功 file は先に内容を退避する
  ref_content=""
  if [ -f "$REF_OUTPUT" ]; then
    ref_content=$(cat "$REF_OUTPUT")
  fi
  run_fetch "$scenario" --project-number 6 --owner test-owner
  if [ -f "$LAST_OUTPUT" ] && [ -n "$ref_content" ]; then
    # 両者成功: 正規化 JSON の byte 一致を比較
    new_content=$(cat "$LAST_OUTPUT")
    if [ "$new_content" = "$ref_content" ]; then
      pass "[$scenario] result JSON byte-identical"
    else
      fail "[$scenario] result JSON differs: ref=$ref_content new=$new_content"
    fi
  elif [ ! -f "$LAST_OUTPUT" ] && [ -z "$ref_content" ]; then
    # 両者失敗: sentinel 行の byte 一致を比較
    if [ "$LAST_OUTPUT" = "$REF_OUTPUT" ] && [ "$LAST_RC" = "$REF_RC" ]; then
      pass "[$scenario] failure sentinel byte-identical (rc=$LAST_RC)"
    else
      fail "[$scenario] sentinel differs: ref(rc=$REF_RC)='$REF_OUTPUT' new(rc=$LAST_RC)='$LAST_OUTPUT'"
    fi
  else
    fail "[$scenario] success/failure shape diverged: ref='$REF_OUTPUT' new='$LAST_OUTPUT'"
  fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
