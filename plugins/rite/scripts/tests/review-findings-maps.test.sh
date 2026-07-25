#!/bin/bash
# Tests for review-findings-maps.sh
#
# 旧 pr/fix.md ステップ 1.2.0 severity_map build inline block (~154 行) の委譲先 helper。
# 動作保持は differential equivalence test (TC-D 系) で機械的に立証する:
# 旧 inline block を参照実装として verbatim 再現し、同一 fixture / 同一 rite-config.yml の
# sandbox で実行して rc / stdout / stderr (sandbox path 正規化後) の byte 一致を比較する。
#
# Usage: bash plugins/rite/scripts/tests/review-findings-maps.test.sh
set -uo pipefail

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
      # Reject rather than degrade, and exit 125 rather than die: die exits 255,
      # which every caller reads as "not 124, so no hang" — the same silent pass
      # the rejection exists to prevent. GNU timeout accepts fractions, so this
      # shim only claims the contract for integer seconds.
      if ($d !~ /^[0-9]+$/) {
        print STDERR "_timeout: fractional seconds are not supported by the perl fallback: $d\n";
        exit 125;
      }
      my $pid = fork;
      exit 127 unless defined $pid;
      # setpgrp puts the child in its own process group so the alarm handler can
      # signal the whole tree with a negative pid. GNU timeout does the same; without
      # it the deadline only reaches the direct child, and a grandchild holding the
      # captured stdout keeps the caller blocked long past the timeout (measured 30s
      # against a 1s deadline). The runners capture output with $( ), so that stall
      # would consume the CI job limit instead of failing at 124.
      if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", -$pid; waitpid($pid, 0); exit 124; };
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
TARGET="$SCRIPT_DIR/../review-findings-maps.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# --- sandbox builder: git repo root + rite-config.yml (auto_demote_low 可変) ---
make_sandbox() {
  local name="$1" demote_cfg="$2"   # demote_cfg: default|false
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo"
  (cd "$repo" && git init -q -b main . 2>/dev/null)
  if [ "$demote_cfg" = "false" ]; then
    cat > "$repo/rite-config.yml" <<'EOF'
review:
  scope_assignment:
    auto_demote_low: false
EOF
  else
    cat > "$repo/rite-config.yml" <<'EOF'
review:
  scope_assignment:
    # auto_demote_low 未設定 → default true 挙動を検証
EOF
  fi
  echo "$repo"
}

# --- fixtures ---
write_fixture() {
  local path="$1" kind="$2"
  case "$kind" in
    clean_110)
      cat > "$path" <<'EOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"file":"src/a.ts","line":10,"severity":"HIGH","scope":"current-pr","pre_existing":false},
  {"file":"src/b.ts","line":null,"severity":"MEDIUM","scope":"current-pr","pre_existing":true}
]}
EOF
      ;;
    v10_missing_scope)
      cat > "$path" <<'EOF'
{"schema_version":"1.0","pr_number":1,"findings":[
  {"file":"src/a.ts","line":10,"severity":"HIGH"},
  {"file":"src/b.ts","line":20,"severity":"LOW"}
]}
EOF
      ;;
    invariant5_violation)
      cat > "$path" <<'EOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"file":"src/a.ts","line":10,"severity":"MEDIUM","scope":"nit-noted","pre_existing":false}
]}
EOF
      ;;
    low_current_pr)
      cat > "$path" <<'EOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"file":"src/a.ts","line":10,"severity":"LOW","scope":"current-pr","pre_existing":true}
]}
EOF
      ;;
    duplicate_anchor)
      cat > "$path" <<'EOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"file":"src/a.ts","line":null,"severity":"HIGH","scope":"current-pr","pre_existing":true},
  {"file":"src/a.ts","line":0,"severity":"LOW","scope":"nit-noted","pre_existing":true}
]}
EOF
      ;;
    invalid_json)
      printf '{"schema_version":"1.1.0","findings": [BROKEN' > "$path"
      ;;
  esac
}

# --- 参照実装: 旧 fix.md ステップ 1.2.0 severity_map build block の verbatim 再現 ---
# review_source / review_source_path は resolve marker からの literal substitute 契約のため
# 冒頭の代入 2 行のみ sed で substitute する。
REF_TEMPLATE="$TEST_DIR/reference-smap.sh.tmpl"
cat > "$REF_TEMPLATE" <<'REF_EOF'
review_source="{review_source}"
review_source_path="{review_source_path}"
# Build severity_map from JSON findings array (schema_version 検証は Selection logic 内で既に完了済み)
if [ "$review_source" = "local_file" ] || [ "$review_source" = "explicit_file" ]; then
  norm_sv=$(jq -r '.schema_version // "unknown"' "$review_source_path" 2>/dev/null || echo "unknown")
  norm_defaulted_count=0
  norm_corrected_count=0
  norm_demoted_low_count=0
  auto_demote_low=$(awk '/^review:/{r=1;next} r && /^  scope_assignment:/{s=1;next} s && /^    auto_demote_low:/{print $2; exit}' rite-config.yml 2>/dev/null | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')
  case "$auto_demote_low" in false|no|0) auto_demote_low=false ;; *) auto_demote_low=true ;; esac
  case "$norm_sv" in
    "1.0.0"|"1.0")
      norm_defaulted_count=$(jq '[.findings[]? | select(has("scope") | not)] | length' "$review_source_path" 2>/dev/null || echo 0)
      ;;
  esac
  norm_corrected_count=$(jq '[.findings[]? | select(.pre_existing == false and .scope == "nit-noted")] | length' "$review_source_path" 2>/dev/null || echo 0)
  if [ "$auto_demote_low" = "true" ]; then
    norm_demoted_low_count=$(jq '[.findings[]? | select(.severity == "LOW" and .scope == "current-pr")] | length' "$review_source_path" 2>/dev/null || echo 0)
  fi
  if [ "${norm_defaulted_count:-0}" -gt 0 ] || [ "${norm_corrected_count:-0}" -gt 0 ] || [ "${norm_demoted_low_count:-0}" -gt 0 ]; then
    if norm_tmp=$(mktemp "${TMPDIR:-/tmp}/rite-fix-normalized-XXXXXX" 2>/dev/null); then
      if jq --arg demote_low "$auto_demote_low" '
        .findings |= map(
          (if has("scope") then . else .scope = (
            if .severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM" then "current-pr"
            else "nit-noted"
            end
          ) end)
          | (if .pre_existing == false and .scope == "nit-noted" then .scope = "current-pr" else . end)
          | (if $demote_low == "true" and .severity == "LOW" and .scope == "current-pr" then .scope = "nit-noted" else . end)
        )
      ' "$review_source_path" > "$norm_tmp" 2>/dev/null; then
        if [ "${norm_defaulted_count:-0}" -gt 0 ]; then
          echo "WARNING: $norm_defaulted_count findings の scope を schema 1.0 後方互換で severity-based default mapping により補完しました" >&2
          echo "[CONTEXT] REVIEW_SOURCE_SCOPE_DEFAULTED=1; reason=scope_omitted_in_v1_0; count=$norm_defaulted_count; schema_version=$norm_sv" >&2
        fi
        if [ "${norm_corrected_count:-0}" -gt 0 ]; then
          echo "WARNING: $norm_corrected_count findings が invariant #5 違反 (pre_existing=false × scope=nit-noted) のため scope を current-pr に auto-correct しました" >&2
          echo "[CONTEXT] REVIEW_SOURCE_AUTO_CORRECTED=1; reason=pre_existing_false_scope_nit_noted; count=$norm_corrected_count" >&2
        fi
        if [ "${norm_demoted_low_count:-0}" -gt 0 ]; then
          echo "WARNING: $norm_demoted_low_count findings (LOW × current-pr) を auto_demote_low により scope=nit-noted に降格しました" >&2
          echo "[CONTEXT] REVIEW_SOURCE_AUTO_DEMOTED_LOW=1; reason=low_current_pr_demoted_to_nit_noted; count=$norm_demoted_low_count" >&2
        fi
        review_source_path="$norm_tmp"
        handed_off_norm_tmp="$norm_tmp"
        norm_tmp=""
      else
        rm -f "$norm_tmp"
        norm_tmp=""
        echo "WARNING: schema 1.1.0 normalization jq が失敗 — 原 JSON のまま続行します" >&2
        echo "[CONTEXT] REVIEW_SOURCE_NORMALIZATION_FAILED=1; reason=jq_mutation_failed" >&2
      fi
    else
      mktemp_norm_rc=$?
      echo "WARNING: schema 1.1.0 normalization 用 mktemp が失敗しました (rc=$mktemp_norm_rc) — 原 JSON のまま続行します" >&2
      echo "  対処: /tmp の容量 / inode 枯渇 / read-only filesystem / permission denied を確認してください" >&2
      echo "[CONTEXT] REVIEW_SOURCE_NORMALIZATION_FAILED=1; reason=mktemp_failure_norm_tmp; rc=$mktemp_norm_rc" >&2
    fi
  fi

  jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-jq-err-XXXXXX" 2>/dev/null) || jq_err=""

  if duplicate_keys=$(jq -r '[.findings[] | (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end))] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$review_source_path" 2>"${jq_err:-/dev/null}"); then
    if [ -n "$duplicate_keys" ]; then
      echo "WARNING: 重複 file:line を持つ finding を検出しました (severity 上書きの可能性):" >&2
      printf '%s\n' "$duplicate_keys" | sed 's/^/  - /' >&2
      echo "  jq from_entries は同一 key を後勝ちで畳み込みます。重複行に対する severity は最後の finding の値が採用されます。" >&2
      echo "  対処: review-result JSON 内の重複 file:line を手動確認してください。" >&2
    fi
  else
    jq_dup_rc=$?
    echo "WARNING: 重複 file:line 検出用 jq が失敗しました (rc=$jq_dup_rc) — silent data loss 検出を skip します" >&2
    [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | sed 's/^/  /' >&2
    echo "  影響: 同一 file:line の重複 severity 警告が出ないため、後段で最後勝ち畳み込みが silent に発生する可能性があります" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=jq_duplicate_check_failed; rc=$jq_dup_rc" >&2
  fi

  if severity_map_json=$(jq -c '[.findings[] | {key: (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end)), value: .severity}] | from_entries' "$review_source_path" 2>"${jq_err:-/dev/null}"); then
    :
  else
    jq_smap_rc=$?
    echo "ERROR: severity_map 構築用 jq が失敗しました (rc=$jq_smap_rc)" >&2
    [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | sed 's/^/  /' >&2
    echo "  対処: review-result JSON ($review_source_path) の内容と jq バイナリを確認してください" >&2
    echo "  影響: severity_map が空のまま後段に流れ、指摘 0 件と誤認される silent regression を防ぐため fail-fast します" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=severity_map_build_failed; rc=$jq_smap_rc" >&2
    [ -n "$jq_err" ] && rm -f "$jq_err"
    echo "[fix:error]"
    exit 1
  fi
  if scope_map_json=$(jq -c '[.findings[] | {key: (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end)), value: .scope}] | from_entries' "$review_source_path" 2>"${jq_err:-/dev/null}"); then
    :
  else
    jq_scmap_rc=$?
    echo "WARNING: scope_map 構築用 jq が失敗しました (rc=$jq_scmap_rc) — scope-based routing が無効化されます (legacy blocking 扱い)" >&2
    [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | sed 's/^/  /' >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=scope_map_build_failed; rc=$jq_scmap_rc" >&2
    scope_map_json="{}"
  fi
  [ -n "$jq_err" ] && rm -f "$jq_err"
fi
REF_EOF

run_reference() {
  local repo="$1" source="$2" path="$3"
  local script="$TEST_DIR/ref-rendered.sh"
  sed -e "s|^review_source=\"{review_source}\"|review_source=\"$source\"|" \
      -e "s|^review_source_path=\"{review_source_path}\"|review_source_path=\"$path\"|" "$REF_TEMPLATE" > "$script"
  local rc=0
  REF_STDOUT=$( (cd "$repo" && _timeout 10 bash "$script") 2>"$TEST_DIR/ref_stderr" ) || rc=$?
  REF_RC=$rc
  REF_STDERR=$(cat "$TEST_DIR/ref_stderr")
  return 0
}

run_helper() {
  local repo="$1" source="$2" path="$3"
  local rc=0
  HELPER_STDOUT=$( _timeout 10 bash "$TARGET" --review-source "$source" --review-source-path "$path" --repo-root "$repo" 2>"$TEST_DIR/helper_stderr" ) || rc=$?
  HELPER_RC=$rc
  HELPER_STDERR=$(cat "$TEST_DIR/helper_stderr")
  return 0
}

# sandbox 固有 path を正規化して比較可能にする (jq エラーが fixture path を含むため)
normalize() {
  sed -e "s|$TEST_DIR/[a-z0-9-]*/|SANDBOX/|g"
}

echo "=== review-findings-maps.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-1: no-op source (pr_comment) → 無出力 + exit 0
# --------------------------------------------------------------------------
echo "TC-1: no-op source"
repo=$(make_sandbox tc1 default)
write_fixture "$repo/review.json" clean_110
run_helper "$repo" pr_comment "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && [ -z "$HELPER_STDOUT" ] && [ -z "$HELPER_STDERR" ]; then
  pass "pr_comment source は no-op exit 0 (旧 if guard と同一)"
else
  fail "unexpected (rc=$HELPER_RC): out='$HELPER_STDOUT' err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-2: clean 1.1.0 → mutation なし、無出力 + exit 0
# --------------------------------------------------------------------------
echo "TC-2: clean 1.1.0 (mutation なし)"
repo=$(make_sandbox tc2 default)
write_fixture "$repo/review.json" clean_110
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && [ -z "$HELPER_STDERR" ]; then
  pass "正常系は無警告 exit 0"
else
  fail "unexpected (rc=$HELPER_RC): err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-3: schema 1.0 scope 欠落 → SCOPE_DEFAULTED flag
# --------------------------------------------------------------------------
echo "TC-3: schema 1.0 default mapping"
repo=$(make_sandbox tc3 default)
write_fixture "$repo/review.json" v10_missing_scope
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && grep -q 'REVIEW_SOURCE_SCOPE_DEFAULTED=1; reason=scope_omitted_in_v1_0; count=2; schema_version=1.0' <<<"$HELPER_STDERR"; then
  pass "SCOPE_DEFAULTED flag (count=2)"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-4: invariant #5 違反 → AUTO_CORRECTED flag
# --------------------------------------------------------------------------
echo "TC-4: invariant #5 auto-correct"
repo=$(make_sandbox tc4 default)
write_fixture "$repo/review.json" invariant5_violation
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && grep -q 'REVIEW_SOURCE_AUTO_CORRECTED=1; reason=pre_existing_false_scope_nit_noted; count=1' <<<"$HELPER_STDERR"; then
  pass "AUTO_CORRECTED flag (count=1)"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-5: LOW × current-pr → auto_demote_low default true で降格 / false で非発火
# --------------------------------------------------------------------------
echo "TC-5: auto_demote_low"
repo=$(make_sandbox tc5a default)
write_fixture "$repo/review.json" low_current_pr
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && grep -q 'REVIEW_SOURCE_AUTO_DEMOTED_LOW=1; reason=low_current_pr_demoted_to_nit_noted; count=1' <<<"$HELPER_STDERR"; then
  pass "default true で AUTO_DEMOTED_LOW flag"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi
repo=$(make_sandbox tc5b false)
write_fixture "$repo/review.json" low_current_pr
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && [ -z "$HELPER_STDERR" ]; then
  pass "auto_demote_low: false で opt-out (無警告)"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-6: line null / 0 の anchor 正規化 → 重複 file:anchor として検出される
# --------------------------------------------------------------------------
echo "TC-6: anchor 正規化 + 重複検出"
repo=$(make_sandbox tc6 default)
write_fixture "$repo/review.json" duplicate_anchor
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && grep -q 'src/a.ts:anchor' <<<"$HELPER_STDERR" && grep -q '重複 file:line を持つ finding を検出しました' <<<"$HELPER_STDERR"; then
  pass "line null/0 が anchor sentinel に正規化され重複 WARNING"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-7: invalid JSON → severity_map_build_failed + exit 1 ([fix:error] は emit しない)
# --------------------------------------------------------------------------
echo "TC-7: invalid JSON fail-fast"
repo=$(make_sandbox tc7 default)
write_fixture "$repo/review.json" invalid_json
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "1" ] \
   && grep -q 'FIX_FALLBACK_FAILED=1; reason=severity_map_build_failed' <<<"$HELPER_STDERR" \
   && grep -q 'reason=jq_duplicate_check_failed' <<<"$HELPER_STDERR" \
   && [ -z "$HELPER_STDOUT" ]; then
  pass "exit 1 + FIX_FALLBACK_FAILED、[fix:error] は stdout 分離契約で caller 責務"
else
  fail "unexpected (rc=$HELPER_RC): out='$HELPER_STDOUT' err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-8: 引数異常 — path 欠落 → exit 2 / 値なしフラグ末尾 → no-hang
# --------------------------------------------------------------------------
echo "TC-8: invocation errors"
repo=$(make_sandbox tc8 default)
rc=0
out=$(_timeout 10 bash "$TARGET" --review-source local_file --repo-root "$repo" 2>&1) || rc=$?
if [ "$rc" = "2" ]; then
  pass "path 欠落 → exit 2"
else
  fail "unexpected rc=$rc: $out"
fi
rc=0
out=$(_timeout 10 bash "$TARGET" --review-source local_file --review-source-path 2>&1) || rc=$?
if [ "$rc" != "124" ]; then
  pass "値なしフラグ末尾 no-hang (rc=$rc)"
else
  fail "hang detected (timeout)"
fi

# --------------------------------------------------------------------------
# TC-9: normalization tempfile が leak しない (script 終了時 trap 削除契約)
# --------------------------------------------------------------------------
echo "TC-9: norm_tmp leak なし"
# 共有 tmp glob の count delta は並列実行時に他プロセスの同 glob tempfile 生成/削除で
# 両方向に flaky 化する。helper の mktemp template は
# ${TMPDIR:-/tmp}/rite-fix-normalized-XXXXXX で、本テストと同じ TMPDIR 名前空間に
# 生成されるため、before/after の path 集合差分 (after にのみ存在する path) で leak を判定する。
before_paths=$(ls "${TMPDIR:-/tmp}"/rite-fix-normalized-* 2>/dev/null | LC_ALL=C sort || true)
repo=$(make_sandbox tc9 default)
write_fixture "$repo/review.json" v10_missing_scope
run_helper "$repo" local_file "$repo/review.json"
after_paths=$(ls "${TMPDIR:-/tmp}"/rite-fix-normalized-* 2>/dev/null | LC_ALL=C sort || true)
leaked_paths=$(LC_ALL=C comm -13 <(printf '%s\n' "$before_paths") <(printf '%s\n' "$after_paths"))
if [ -z "$leaked_paths" ]; then
  pass "handed_off_norm_tmp が trap EXIT で削除される (leak なし)"
else
  fail "norm_tmp leaked: $(tr '\n' ' ' <<<"$leaked_paths")"
fi

# --------------------------------------------------------------------------
# TC-D: differential equivalence — 旧 inline block (参照実装) と出力一致
# 注: 旧 block は fail-fast 時に [fix:error] を stdout に emit していたが、委譲後は
#     caller 責務に分離した ([fix:error] stdout 分離契約)。比較時は参照実装の stdout
#     から [fix:error] 行のみを除外する (それ以外は byte 一致を要求)。
# 注: 本 test が比較するのは外部観測可能な挙動 (rc/stdout/stderr/file) のみで、
#     in-process validation 変数 severity_map_json / scope_map_json の値は観測できない。
#     当該値は production で非消費 (helper の stdout contract: なし) のため、現契約では
#     機能 regression の検出漏れにはならない。将来 map を stdout emit する契約に変更する
#     場合は、clean fixture に対する期待 map 値 assert (test pin) を同時整備すること。
# --------------------------------------------------------------------------
echo "TC-D: differential equivalence vs original inline block"
run_differential() {
  local label="$1" fixture="$2" source="$3" demote_cfg="$4"
  local repo_ref repo_new
  repo_ref=$(make_sandbox "ref-$label" "$demote_cfg")
  repo_new=$(make_sandbox "new-$label" "$demote_cfg")
  write_fixture "$repo_ref/review.json" "$fixture"
  write_fixture "$repo_new/review.json" "$fixture"
  run_reference "$repo_ref" "$source" "$repo_ref/review.json"
  run_helper "$repo_new" "$source" "$repo_new/review.json"
  local ref_out_filtered ref_err_n new_err_n
  ref_out_filtered=$(grep -v '^\[fix:error\]$' <<<"$REF_STDOUT" || true)
  ref_err_n=$(normalize <<<"$REF_STDERR")
  new_err_n=$(normalize <<<"$HELPER_STDERR")
  if [ "$REF_RC" = "$HELPER_RC" ] && [ "$ref_out_filtered" = "$HELPER_STDOUT" ] && [ "$ref_err_n" = "$new_err_n" ]; then
    pass "[$label] rc + stdout([fix:error] 分離除く) + stderr byte-identical (rc=$HELPER_RC)"
  else
    fail "[$label] diverged: ref(rc=$REF_RC) out='$ref_out_filtered' err='$ref_err_n' / new(rc=$HELPER_RC) out='$HELPER_STDOUT' err='$new_err_n'"
  fi
}

run_differential "noop-source"      clean_110            pr_comment   default
run_differential "clean-110"        clean_110            local_file   default
run_differential "v10-default-map"  v10_missing_scope    local_file   default
run_differential "invariant5"       invariant5_violation explicit_file default
run_differential "demote-low-on"    low_current_pr       local_file   default
run_differential "demote-low-off"   low_current_pr       local_file   false
run_differential "dup-anchor"       duplicate_anchor     local_file   default
run_differential "invalid-json"     invalid_json         local_file   default

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
