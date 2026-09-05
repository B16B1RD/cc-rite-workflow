#!/bin/bash
# Tests for review-findings-maps.sh
#
# fix.md ステップ 1.2.0 の委譲先 helper (schema normalization + 致命性仕分け + maps build)。
#
# normalization 部 ((a) scope default mapping / (b) invariant #5 auto-correct) の動作保持は
# differential equivalence test (TC-D 系) で立証する: 旧 inline block を参照実装として再現し、
# rc / stdout / stderr (sandbox path 正規化 + 致命性仕分け由来の行を除外) の byte 一致を比較する。
# **TC-D の主張範囲は (a) と (b) に限る** — 致命性仕分けは旧 block に存在しない新規動作のため、
# 参照実装との比較ではなく TC-10 以降の直接テストで pin する。
#
# Usage: bash plugins/rite/scripts/tests/review-findings-maps.test.sh
set -uo pipefail

# _timeout <seconds> <command...> — portable timeout(1) for this test.
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

# --- sandbox builder: 入力 JSON を置く作業ディレクトリ ---
# helper は rite-config.yml を読まなくなった (旧 LOW 自動降格設定の廃止) ため、リポジトリも
# config も要らない。入力ファイルを隔離するためだけのディレクトリを作る。
make_sandbox() {
  local name="$1"
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo"
  echo "$repo"
}

# --- fixtures ---
# 正常系 fixture の gated finding はすべて verification.measured を持つ。未判定は AC-5 の error
# 経路であり、正常系に混ぜると全ケースが停止するため undetermined 系 fixture が分けて担う。
write_fixture() {
  local path="$1" kind="$2"
  case "$kind" in
    clean_110)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"HIGH","scope":"current-pr","pre_existing":false,"verification":{"measured":true}},
  {"id":"F-02","file":"src/b.ts","line":null,"severity":"CRITICAL","scope":"follow-up","pre_existing":true,"verification":{"measured":true}}
]}
FIXEOF
      ;;
    v10_missing_scope)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"HIGH","verification":{"measured":true}},
  {"id":"F-02","file":"src/b.ts","line":20,"severity":"LOW","verification":{"measured":true}}
]}
FIXEOF
      ;;
    invariant5_violation)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"HIGH","scope":"nit-noted","pre_existing":false,"verification":{"measured":true}}
]}
FIXEOF
      ;;
    mixed_triage)
      # AC-1 / AC-2: 実測あり HIGH 1 / 実測あり MEDIUM 1 / 実測あり LOW 1 / nit-noted 1 /
      # **実測なし HIGH 1** (致命判定 3 連言のうち実測条件だけを判別する finding)
      # 既に非空の non_blocking_findings[] を置き、移送が append であって置換でないことを pin する
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"HIGH","scope":"current-pr","pre_existing":true,"verification":{"measured":true}},
  {"id":"F-02","file":"src/b.ts","line":20,"severity":"MEDIUM","scope":"current-pr","pre_existing":true,"verification":{"measured":true}},
  {"id":"F-03","file":"src/c.ts","line":30,"severity":"LOW","scope":"current-pr","pre_existing":true,"verification":{"measured":true}},
  {"id":"F-04","file":"src/d.ts","line":40,"severity":"LOW","scope":"nit-noted","pre_existing":true},
  {"id":"F-06","file":"src/f.ts","line":60,"severity":"HIGH","scope":"current-pr","pre_existing":true,"verification":{"measured":false}}
],"non_blocking_findings":[
  {"id":"F-05","file":"src/e.ts","line":50,"severity":"MEDIUM","scope":"current-pr","pre_existing":true}
]}
FIXEOF
      ;;
    all_fatal)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"HIGH","scope":"current-pr","pre_existing":true,"verification":{"measured":true}},
  {"id":"F-02","file":"src/b.ts","line":20,"severity":"CRITICAL","scope":"current-pr","pre_existing":true,"verification":{"measured":true}}
]}
FIXEOF
      ;;
    all_non_fatal)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"MEDIUM","scope":"current-pr","pre_existing":true,"verification":{"measured":true}},
  {"id":"F-02","file":"src/b.ts","line":20,"severity":"LOW-MEDIUM","scope":"follow-up","pre_existing":true,"verification":{"measured":true}}
]}
FIXEOF
      ;;
    nit_only)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"LOW","scope":"nit-noted","pre_existing":true},
  {"id":"F-02","file":"src/b.ts","line":20,"severity":"MEDIUM","scope":"nit-noted","pre_existing":true}
]}
FIXEOF
      ;;
    undetermined)
      # review-measured-gate.sh が形式崩れアンカーに対して出す実形状: gate 対象 finding の
      # verification キーごと欠落 (measured=false と確定させない = 未判定)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"HIGH","scope":"current-pr","pre_existing":true,"verification":{"measured":true}},
  {"id":"F-02","file":"src/b.ts","line":20,"severity":"MEDIUM","scope":"current-pr","pre_existing":true,
   "description":"Verification: repro <br> => marker と => が別セグメントのため gate が verification を設定しない"}
]}
FIXEOF
      ;;
    undetermined_empty_verification)
      # verification が object でも measured が boolean でなければ未判定 (read 側型ガードの受理形)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"MEDIUM","scope":"current-pr","pre_existing":true,"verification":{}}
]}
FIXEOF
      ;;
    bad_severity)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"BLOCKER","scope":"current-pr","pre_existing":true,"verification":{"measured":true}}
]}
FIXEOF
      ;;
    nb_missing_id)
      # 入力時点で non_blocking_findings[] に id を持たない要素がある (保存境界が非ブロッキングと
      # 決めている欠陥。本 helper もこれを停止理由にしてはならない)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"MEDIUM","scope":"current-pr","pre_existing":true,"verification":{"measured":true}}
],"non_blocking_findings":[
  {"file":"src/z.ts","line":99,"severity":"LOW","scope":"current-pr","pre_existing":true}
]}
FIXEOF
      ;;
    nonarray_nb)
      # non_blocking_findings が非配列。移送 jq の `+` が型エラーになり、tempfile を作った後に
      # 失敗する唯一の plain-fixture 経路 (mv 差し替え無しで到達できる)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"MEDIUM","scope":"current-pr","pre_existing":true,"verification":{"measured":true}}
],"non_blocking_findings":"oops"}
FIXEOF
      ;;
    nonstring_id)
      # 移送対象 finding の id が非文字列。撤去した自己検証はこの入力でだけ挙動が分かれた
      # (旧: exit 1 / 新: 移送完走)。入力時点の欠陥で停止しないことを pin する
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":123,"file":"src/a.ts","line":10,"severity":"MEDIUM","scope":"current-pr","pre_existing":true,"verification":{"measured":true}},
  {"id":"F-02","file":"src/a.ts","line":20,"severity":"HIGH","scope":"current-pr","pre_existing":true,"verification":{"measured":true}}
],"non_blocking_findings":[]}
FIXEOF
      ;;
    dup_id_union)
      # 移送後に findings[] と non_blocking_findings[] で id が衝突する入力
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":10,"severity":"MEDIUM","scope":"current-pr","pre_existing":true,"verification":{"measured":true}}
],"non_blocking_findings":[
  {"id":"F-01","file":"src/z.ts","line":99,"severity":"LOW","scope":"current-pr","pre_existing":true}
]}
FIXEOF
      ;;
    duplicate_anchor)
      cat > "$path" <<'FIXEOF'
{"schema_version":"1.1.0","pr_number":1,"findings":[
  {"id":"F-01","file":"src/a.ts","line":null,"severity":"HIGH","scope":"current-pr","pre_existing":true,"verification":{"measured":true}},
  {"id":"F-02","file":"src/a.ts","line":0,"severity":"LOW","scope":"nit-noted","pre_existing":true}
]}
FIXEOF
      ;;
    invalid_json)
      printf '{"schema_version":"1.1.0","findings": [BROKEN' > "$path"
      ;;
  esac
}

# --- 参照実装: 旧 fix.md ステップ 1.2.0 の normalization + severity_map build の再現 ---
# TC-D が主張する範囲は (a) scope default mapping と (b) invariant #5 auto-correct のみ。
# 旧 LOW 自動降格分岐は廃止したため参照実装からも除去した。致命性仕分けは旧 block に無い
# 新規動作なので参照比較の対象にせず、TC-10 以降で直接 pin する。
REF_TEMPLATE="$TEST_DIR/reference-smap.sh.tmpl"
cat > "$REF_TEMPLATE" <<'REF_EOF'
review_source="{review_source}"
review_source_path="{review_source_path}"
if [ "$review_source" = "local_file" ] || [ "$review_source" = "explicit_file" ]; then
  norm_sv=$(jq -r '.schema_version // "unknown"' "$review_source_path" 2>/dev/null || echo "unknown")
  norm_defaulted_count=0
  norm_corrected_count=0
  case "$norm_sv" in
    "1.0.0"|"1.0")
      norm_defaulted_count=$(jq '[.findings[]? | select(has("scope") | not)] | length' "$review_source_path" 2>/dev/null || echo 0)
      ;;
  esac
  norm_corrected_count=$(jq '[.findings[]? | select(.pre_existing == false and .scope == "nit-noted")] | length' "$review_source_path" 2>/dev/null || echo 0)
  if [ "${norm_defaulted_count:-0}" -gt 0 ] || [ "${norm_corrected_count:-0}" -gt 0 ]; then
    if norm_tmp=$(mktemp "${TMPDIR:-/tmp}/rite-fix-normalized-XXXXXX" 2>/dev/null); then
      if jq '
        .findings |= map(
          (if has("scope") then . else .scope = (
            if .severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM" then "current-pr"
            else "nit-noted"
            end
          ) end)
          | (if .pre_existing == false and .scope == "nit-noted" then .scope = "current-pr" else . end)
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
    rm -f "${handed_off_norm_tmp:-}" "${jq_err:-}"
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
  rm -f "${handed_off_norm_tmp:-}" "${jq_err:-}"
fi
exit 0
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
  HELPER_STDOUT=$( _timeout 10 bash "$TARGET" --review-source "$source" --review-source-path "$path" 2>"$TEST_DIR/helper_stderr" ) || rc=$?
  HELPER_RC=$rc
  HELPER_STDERR=$(cat "$TEST_DIR/helper_stderr")
  return 0
}

# sandbox 固有 path を正規化して比較可能にする (jq エラーが fixture path を含むため)
normalize() {
  sed -e "s|$TEST_DIR/[a-z0-9-]*/|SANDBOX/|g"
}

# 致命性仕分け由来の行を落とす (TC-D の主張範囲は normalization に限る)
strip_triage() {
  grep -v -e 'FIX_FATAL_TRIAGE=' -e 'non_blocking_findings\[\] へ移送しました' || true
}

echo "=== review-findings-maps.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-1: no-op source (pr_comment) → 無出力 + exit 0
# --------------------------------------------------------------------------
echo "TC-1: no-op source"
repo=$(make_sandbox tc1)
write_fixture "$repo/review.json" clean_110
run_helper "$repo" pr_comment "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && [ -z "$HELPER_STDOUT" ] && [ -z "$HELPER_STDERR" ]; then
  pass "pr_comment source は no-op exit 0 (旧 if guard と同一)"
else
  fail "unexpected (rc=$HELPER_RC): out='$HELPER_STDOUT' err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-2: clean 1.1.0 (全件致命) → normalization 警告なし + moved=0
# --------------------------------------------------------------------------
echo "TC-2: clean 1.1.0 (全件致命)"
repo=$(make_sandbox tc2)
write_fixture "$repo/review.json" clean_110
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] \
   && grep -q 'FIX_FATAL_TRIAGE=applied; fatal=2; moved=0' <<<"$HELPER_STDERR" \
   && [ -z "$(strip_triage <<<"$HELPER_STDERR")" ]; then
  pass "正常系は normalization 無警告 + fatal=2/moved=0"
else
  fail "unexpected (rc=$HELPER_RC): err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-3: schema 1.0 scope 欠落 → SCOPE_DEFAULTED flag
# --------------------------------------------------------------------------
echo "TC-3: schema 1.0 default mapping"
repo=$(make_sandbox tc3)
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
repo=$(make_sandbox tc4)
write_fixture "$repo/review.json" invariant5_violation
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && grep -q 'REVIEW_SOURCE_AUTO_CORRECTED=1; reason=pre_existing_false_scope_nit_noted; count=1' <<<"$HELPER_STDERR"; then
  pass "AUTO_CORRECTED flag (count=1)"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-5 (T-04): nit-noted は仕分けの対象外 (AC-4)
# --------------------------------------------------------------------------
echo "TC-5 (T-04): nit-noted 不変"
repo=$(make_sandbox tc5)
write_fixture "$repo/review.json" nit_only
before=$(jq -S . "$repo/review.json")
run_helper "$repo" local_file "$repo/review.json"
after=$(jq -S . "$repo/review.json")
if [ "$HELPER_RC" = "0" ] \
   && grep -q 'FIX_FATAL_TRIAGE=applied; fatal=0; moved=0' <<<"$HELPER_STDERR" \
   && [ "$before" = "$after" ]; then
  pass "nit-noted は移送も修正対象化もされずファイル不変"
else
  fail "unexpected (rc=$HELPER_RC): err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-6: line null / 0 の anchor 正規化 → 重複 file:anchor として検出される
# --------------------------------------------------------------------------
echo "TC-6: anchor 正規化 + 重複検出"
repo=$(make_sandbox tc6)
write_fixture "$repo/review.json" duplicate_anchor
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] && grep -q 'src/a.ts:anchor' <<<"$HELPER_STDERR" && grep -q '重複 file:line を持つ finding を検出しました' <<<"$HELPER_STDERR"; then
  pass "line null/0 が anchor sentinel に正規化され重複 WARNING"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-7: invalid JSON → json_invalid + exit 1 ([fix:error] は emit しない)
# --------------------------------------------------------------------------
echo "TC-7: invalid JSON fail-fast"
repo=$(make_sandbox tc7)
write_fixture "$repo/review.json" invalid_json
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "1" ] \
   && grep -q 'FIX_FALLBACK_FAILED=1; reason=json_invalid' <<<"$HELPER_STDERR" \
   && [ -z "$HELPER_STDOUT" ]; then
  pass "exit 1 + json_invalid、[fix:error] は stdout 分離契約で caller 責務"
else
  fail "unexpected (rc=$HELPER_RC): out='$HELPER_STDOUT' err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-8: 引数異常 — path 欠落 → exit 2 / 値なしフラグ末尾 → no-hang
# --------------------------------------------------------------------------
echo "TC-8: invocation errors"
rc=0
out=$(_timeout 10 bash "$TARGET" --review-source local_file 2>&1) || rc=$?
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
# TC-9: tempfile が leak しない (script 終了時 trap 削除契約)
# --------------------------------------------------------------------------
echo "TC-9: tempfile leak なし"
before_paths=$(ls "${TMPDIR:-/tmp}"/rite-fix-normalized-* 2>/dev/null | LC_ALL=C sort || true)
repo=$(make_sandbox tc9)
write_fixture "$repo/review.json" v10_missing_scope
run_helper "$repo" local_file "$repo/review.json"
# 移送 tempfile は mv が消費する。**mktemp 失敗経路を leg に足さない** — その経路は tempfile を
# 1 度も作らないので triage.* の不在はどの実装でも成立し、assert が恒真になる。
# 「tempfile を作ったまま失敗する」経路は移送 jq 失敗と mv 失敗の 2 つ。前者は plain fixture で
# 到達でき (下の leg)、後者は PATH stub で到達する (TC-14b)。
repo_moved=$(make_sandbox tc9-moved)
write_fixture "$repo_moved/review.json" mixed_triage
run_helper "$repo_moved" local_file "$repo_moved/review.json"
leaked_triage_moved=$(ls "$repo_moved"/review.json.triage.* 2>/dev/null || true)
# 移送 jq が失敗する経路 — リダイレクトが jq 起動前に tempfile を作るため、inline rm が
# 回収しなければここに残る (恒真ではない)
repo_jqfail=$(make_sandbox tc9-jqfail)
write_fixture "$repo_jqfail/review.json" nonarray_nb
jqfail_before=$(cat "$repo_jqfail/review.json")
run_helper "$repo_jqfail" local_file "$repo_jqfail/review.json"
leaked_triage_jqfail=$(ls "$repo_jqfail"/review.json.triage.* 2>/dev/null || true)
tc9_jqfail_ok=1
[ "$HELPER_RC" = "1" ] || tc9_jqfail_ok=0
# `rc=` は移送 jq の emit site だけが付ける。判別子なしだと前方 3 site (severity enum 検査 /
# 実測判定検査 / 件数算出) で停止する退行でも緑のまま通り、直後の leak assert が恒真化する。
# `[1-9]` にして rc 非ゼロ性も同時に pin する (mv leg と同型)
grep -qE 'FIX_FALLBACK_FAILED=1; reason=fatal_triage_jq_failed; rc=[1-9]' <<<"$HELPER_STDERR" || tc9_jqfail_ok=0
[ "$(cat "$repo_jqfail/review.json")" = "$jqfail_before" ] || tc9_jqfail_ok=0
if [ "$tc9_jqfail_ok" = "1" ]; then
  pass "移送 jq 失敗で exit 1 / 入力は無変更 (部分適用なし)"
else
  fail "jq 失敗分岐が期待どおりでない (rc=$HELPER_RC): $HELPER_STDERR"
fi
# normalization tempfile の sweep は **全 leg の run_helper 後**に取る (先に確定させると後続 leg が
# 作った分が母集団から漏れる)
after_paths=$(ls "${TMPDIR:-/tmp}"/rite-fix-normalized-* 2>/dev/null | LC_ALL=C sort || true)
leaked_paths=$(LC_ALL=C comm -13 <(printf '%s\n' "$before_paths") <(printf '%s\n' "$after_paths"))
if [ -z "$leaked_paths" ] && [ -z "$leaked_triage_moved" ] && [ -z "$leaked_triage_jqfail" ]; then
  pass "normalization tempfile と移送 tempfile (成功経路 / jq 失敗経路) が回収される"
else
  fail "tempfile leaked: $(tr '\n' ' ' <<<"$leaked_paths$leaked_triage_moved$leaked_triage_jqfail")"
fi

# --------------------------------------------------------------------------
# TC-10 (T-01/T-02): 致命性仕分け — fatal だけ残り、非致命は append 移送される
# --------------------------------------------------------------------------
echo "TC-10 (T-01/T-02): 致命性仕分けの件数と形"
repo=$(make_sandbox tc10)
write_fixture "$repo/review.json" mixed_triage
run_helper "$repo" local_file "$repo/review.json"
tc10_ok=1
grep -q 'FIX_FATAL_TRIAGE=applied; fatal=1; moved=3' <<<"$HELPER_STDERR" || tc10_ok=0
[ "$HELPER_RC" = "0" ] || tc10_ok=0
# findings[] の残余は「致命 + nit-noted」で、入力順を保つ
[ "$(jq -c '[.findings[].id]' "$repo/review.json")" = '["F-01","F-04"]' ] || tc10_ok=0
# non_blocking_findings[] は既存要素 (F-05) を保持したまま末尾に append される
[ "$(jq -c '[.non_blocking_findings[].id]' "$repo/review.json")" = '["F-05","F-02","F-03","F-06"]' ] || tc10_ok=0
# 移送分だけが demotion_reason を持ち、severity は元のまま
[ "$(jq -c '[.non_blocking_findings[] | {id, d: (.demotion_reason // null), s: .severity}]' "$repo/review.json")" \
  = '[{"id":"F-05","d":null,"s":"MEDIUM"},{"id":"F-02","d":"non_fatal","s":"MEDIUM"},{"id":"F-03","d":"non_fatal","s":"LOW"},{"id":"F-06","d":"non_fatal","s":"HIGH"}]' ] || tc10_ok=0
# 実測条件の判別: 実測なし HIGH は severity が CRITICAL/HIGH でも致命にならず移送される
# (この 1 行が無いと `def fatal` から実測条件を落とした mutant がスイート全 green を通過する)
[ "$(jq -r '.non_blocking_findings[] | select(.id == "F-06") | .verification.measured' "$repo/review.json")" = "false" ] || tc10_ok=0
# 既存の非移送要素 (F-05) は一切書き換わらない
[ "$(jq -c '.non_blocking_findings[0]' "$repo/review.json")" \
  = '{"id":"F-05","file":"src/e.ts","line":50,"severity":"MEDIUM","scope":"current-pr","pre_existing":true}' ] || tc10_ok=0
# id は 2 配列の和集合で一意
[ "$(jq '[.findings[].id, .non_blocking_findings[].id] | (unique | length) == length' "$repo/review.json")" = "true" ] || tc10_ok=0
if [ "$tc10_ok" = "1" ]; then
  pass "fatal=1/moved=3、実測なし HIGH の移送、append 保持、demotion_reason=non_fatal、severity 不変、id 和集合一意"
else
  fail "unexpected (rc=$HELPER_RC): err='$HELPER_STDERR' json=$(jq -c . "$repo/review.json")"
fi

# --------------------------------------------------------------------------
# TC-11 (T-06): 両端 — 全件致命 (moved=0) / 全件非致命 (fatal=0)
# --------------------------------------------------------------------------
echo "TC-11 (T-06): 両端"
repo=$(make_sandbox tc11a)
write_fixture "$repo/review.json" all_fatal
before=$(jq -S . "$repo/review.json")
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] \
   && grep -q 'FIX_FATAL_TRIAGE=applied; fatal=2; moved=0' <<<"$HELPER_STDERR" \
   && [ "$(jq -S . "$repo/review.json")" = "$before" ]; then
  pass "全件致命は moved=0 でファイル無変更"
else
  fail "all_fatal unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi
repo=$(make_sandbox tc11b)
write_fixture "$repo/review.json" all_non_fatal
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] \
   && grep -q 'FIX_FATAL_TRIAGE=applied; fatal=0; moved=2' <<<"$HELPER_STDERR" \
   && [ "$(jq -c '.findings' "$repo/review.json")" = '[]' ] \
   && [ "$(jq -c '[.non_blocking_findings[].id]' "$repo/review.json")" = '["F-01","F-02"]' ]; then
  pass "全件非致命は fatal=0 で findings[] が空になる (mergeable 相当)"
else
  fail "all_non_fatal unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-12 (T-05): 未判定は error 停止 (AC-5)
# --------------------------------------------------------------------------
echo "TC-12 (T-05): 未判定 error"
repo=$(make_sandbox tc12a)
write_fixture "$repo/review.json" undetermined
before=$(jq -S . "$repo/review.json")
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "1" ] \
   && grep -q 'FIX_FALLBACK_FAILED=1; reason=measured_undetermined; findings=F-02' <<<"$HELPER_STDERR" \
   && [ -z "$HELPER_STDOUT" ] \
   && [ "$(jq -S . "$repo/review.json")" = "$before" ]; then
  pass "verification キー欠落 (gate の形式崩れアンカー実形状) で exit 1 + 入力無変更"
else
  fail "unexpected (rc=$HELPER_RC): out='$HELPER_STDOUT' err='$HELPER_STDERR'"
fi
repo=$(make_sandbox tc12b)
write_fixture "$repo/review.json" undetermined_empty_verification
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "1" ] && grep -q 'reason=measured_undetermined; findings=F-01' <<<"$HELPER_STDERR"; then
  pass "verification: {} (measured 非 boolean) も未判定として exit 1"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-13: severity enum 違反 → exit 1
# --------------------------------------------------------------------------
echo "TC-13: severity enum 違反"
repo=$(make_sandbox tc13)
write_fixture "$repo/review.json" bad_severity
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "1" ] && grep -q 'FIX_FALLBACK_FAILED=1; reason=severity_enum_violation; findings=F-01' <<<"$HELPER_STDERR"; then
  pass "enum 外 severity で exit 1 (scope enum 違反と同形の語彙)"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-14: 入力時点の id 欠陥 (欠落 / 独立採番による重複) で移送を止めない
# 保存境界 (hooks/review-result-save.sh) が同じ条件を意図的に非ブロッキングと決めているため、
# ここで hard fail にすると同一条件の enforcement level が経路によって逆になる。
# --------------------------------------------------------------------------
echo "TC-14: 入力時点の id 欠陥で停止しない"
repo=$(make_sandbox tc14-dup)
write_fixture "$repo/review.json" dup_id_union
run_helper "$repo" local_file "$repo/review.json"
tc14_ok=1
[ "$HELPER_RC" = "0" ] || tc14_ok=0
grep -q 'FIX_FATAL_TRIAGE=applied; fatal=0; moved=1' <<<"$HELPER_STDERR" || tc14_ok=0
grep -q 'FIX_FALLBACK_FAILED' <<<"$HELPER_STDERR" && tc14_ok=0
# 移送要素の id は入力時のまま保存される
[ "$(jq -r '[.non_blocking_findings[] | select(.demotion_reason == "non_fatal") | .id] | join(",")' "$repo/review.json")" = "F-01" ] || tc14_ok=0
if [ "$tc14_ok" = "1" ]; then
  pass "入力時点の和集合重複では停止せず移送を完了する (保存境界と同じ非ブロッキング扱い)"
else
  fail "unexpected (rc=$HELPER_RC): err='$HELPER_STDERR'"
fi

# id 欠落 (nb 側) も同様に停止させない
repo=$(make_sandbox tc14-noid)
write_fixture "$repo/review.json" nb_missing_id
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] \
   && grep -q 'FIX_FATAL_TRIAGE=applied; fatal=0; moved=1' <<<"$HELPER_STDERR" \
   && ! grep -q 'FIX_FALLBACK_FAILED' <<<"$HELPER_STDERR"; then
  pass "入力時点の nb 側 id 欠落でも移送は完了する"
else
  fail "unexpected (rc=$HELPER_RC): err='$HELPER_STDERR'"
fi

# 非文字列 id — 撤去した自己検証はこの入力でだけ挙動が分かれた (旧: exit 1 / 新: 移送完走)。
# 自己検証を復活させる変更をここが落とす
repo=$(make_sandbox tc14-nonstr)
write_fixture "$repo/review.json" nonstring_id
run_helper "$repo" local_file "$repo/review.json"
if [ "$HELPER_RC" = "0" ] \
   && grep -q 'FIX_FATAL_TRIAGE=applied; fatal=1; moved=1' <<<"$HELPER_STDERR" \
   && ! grep -q 'FIX_FALLBACK_FAILED' <<<"$HELPER_STDERR" \
   && [ "$(jq -c '[.non_blocking_findings[] | .id]' "$repo/review.json")" = "[123]" ]; then
  pass "非文字列 id でも停止せず移送を完了し id を保存する"
else
  fail "unexpected (rc=$HELPER_RC): err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-14b: 書き込み失敗分岐 — mktemp 失敗 / mv 失敗のいずれも実挙動で pin する
# (Issue §4.5 MUST「書き込み失敗は非ゼロ終了、部分適用を残さない」の直接 pin)
# mv は PATH stub で失敗させる (本 repo の hooks/tests で確立した手段)
# --------------------------------------------------------------------------
echo "TC-14b: 書き込み失敗分岐"
repo=$(make_sandbox tc14b-mktemp)
mkdir -p "$repo/ro"
write_fixture "$repo/ro/review.json" mixed_triage
before=$(jq -S . "$repo/ro/review.json")
chmod 555 "$repo/ro"
run_helper "$repo" local_file "$repo/ro/review.json"
chmod 755 "$repo/ro"
if [ "$HELPER_RC" = "1" ] \
   && grep -q 'FIX_FALLBACK_FAILED=1; reason=fatal_triage_mktemp_failed' <<<"$HELPER_STDERR" \
   && ! grep -qE 'reason=fatal_triage_mktemp_failed; rc=0(;|$)' <<<"$HELPER_STDERR" \
   && [ "$(jq -S . "$repo/ro/review.json")" = "$before" ]; then
  pass "mktemp 失敗で exit 1 / rc は非ゼロ / 入力は無変更"
else
  fail "mktemp 失敗分岐が期待どおりでない (rc=$HELPER_RC): $HELPER_STDERR"
fi

# mv 失敗: PATH の先頭に非ゼロ終了する mv を置いて実分岐へ入れる。helper は裸の `mv` を呼ぶため
# 追加の権限も外部依存も要らない。rc=0 を報告する形 (`if ! mv ...` の否定パイプライン) への
# 退行は、rc が 0 になることで assert が落ちる。
repo=$(make_sandbox tc14b-mv)
mkdir -p "$repo/bin"
printf '#!/bin/bash\nexit 1\n' > "$repo/bin/mv"
chmod +x "$repo/bin/mv"
write_fixture "$repo/review.json" mixed_triage
before=$(jq -S . "$repo/review.json")
# 他 leg と同じく `_timeout` を経由する (素の起動だと stub 下で helper が hang したとき
# スイートが無限に待つ)
HELPER_STDERR=$( ( export PATH="$repo/bin:$PATH"; _timeout 10 bash "$TARGET" \
  --review-source local_file --review-source-path "$repo/review.json" ) 2>&1 >/dev/null ) && HELPER_RC=0 || HELPER_RC=$?
tc14b_mv_ok=1
[ "$HELPER_RC" = "1" ] || tc14b_mv_ok=0
grep -qE 'FIX_FALLBACK_FAILED=1; reason=fatal_triage_mv_failed; rc=[1-9]' <<<"$HELPER_STDERR" || tc14b_mv_ok=0
[ "$(jq -S . "$repo/review.json")" = "$before" ] || tc14b_mv_ok=0
[ -z "$(ls "$repo"/review.json.triage.* 2>/dev/null || true)" ] || tc14b_mv_ok=0
if [ "$tc14b_mv_ok" = "1" ]; then
  pass "mv 失敗で exit 1 / rc は非ゼロ / 入力は無変更 / tempfile は回収される"
else
  fail "mv 失敗分岐が期待どおりでない (rc=$HELPER_RC): $HELPER_STDERR"
fi

# --------------------------------------------------------------------------
# TC-15: 再入冪等性 — 2 回実行が 1 回実行と byte 一致
# --------------------------------------------------------------------------
echo "TC-15: 再入冪等性"
repo=$(make_sandbox tc15)
write_fixture "$repo/review.json" mixed_triage
run_helper "$repo" local_file "$repo/review.json"
once=$(cat "$repo/review.json")
run_helper "$repo" local_file "$repo/review.json"
twice=$(cat "$repo/review.json")
if [ "$HELPER_RC" = "0" ] \
   && [ "$once" = "$twice" ] \
   && grep -q 'FIX_FATAL_TRIAGE=applied; fatal=1; moved=0' <<<"$HELPER_STDERR"; then
  pass "2 回実行が 1 回実行と byte 一致 (二重移送しない)"
else
  fail "unexpected (rc=$HELPER_RC): err='$HELPER_STDERR'"
fi

# --------------------------------------------------------------------------
# TC-16: explicit_file が local_file と同じ経路を通ることの pin
# (T-07 / AC-6 は fix/SKILL.md の選択 UI 規定に属し本スイートでは検査しない。
#  当該規定の静的 pin は hooks/tests/fix-fatal-triage-contract.test.sh が持つ)
# --------------------------------------------------------------------------
echo "TC-16: explicit_file / local_file の経路一致"
repo=$(make_sandbox tc16)
write_fixture "$repo/p0.json" mixed_triage
run_helper "$repo" local_file "$repo/p0.json"
p0_json=$(cat "$repo/p0.json")
p0_err=$(normalize <<<"$HELPER_STDERR")
# fix.md Priority 3 と同じ手順: raw_json 文字列 → tempfile → 同 helper → 読み戻し
write_fixture "$repo/src.json" mixed_triage
raw_json=$(cat "$repo/src.json")
p3_file="$repo/p3.json"
printf '%s' "$raw_json" > "$p3_file"
run_helper "$repo" explicit_file "$p3_file"
p3_json=$(cat "$p3_file")
p3_err=$(normalize <<<"$HELPER_STDERR")
if [ "$HELPER_RC" = "0" ] && [ "$p0_json" = "$p3_json" ] && [ "$p0_err" = "$p3_err" ]; then
  pass "explicit_file が local_file と同じ guard 分岐を通り JSON / stderr が一致"
else
  fail "explicit_file diverged: err0='$p0_err' err3='$p3_err'"
fi

# --------------------------------------------------------------------------
# TC-17 (T-08): アーカイブ由来テール PR fixture の cycle 別 fatal 件数 (AC-7)
# 期待値は「HIGH 以上かつ実測」列 = 致命性仕分けの fatal 定義そのもの。
# fixture は実アーカイブから生成し、Issue / PR 番号は除去済み。
# --------------------------------------------------------------------------
echo "TC-17 (T-08): テール PR fixture の cycle 別件数"
tail_dir="$SCRIPT_DIR/fixtures/fatal-triage-tail"
# cycle-NN:fatal:moved
expected_cycles="01:6:1 02:4:2 03:5:1 04:5:1 05:2:1 06:1:1 07:0:0"
tc17_ok=1
tc17_detail=""
for spec in $expected_cycles; do
  cyc=${spec%%:*}; rest=${spec#*:}; exp_fatal=${rest%%:*}; exp_moved=${rest##*:}
  src="$tail_dir/cycle-$cyc.json"
  if [ ! -f "$src" ]; then
    tc17_ok=0; tc17_detail="$tc17_detail missing:$cyc"; continue
  fi
  repo=$(make_sandbox "tc17-$cyc")
  cp "$src" "$repo/review.json"
  run_helper "$repo" local_file "$repo/review.json"
  if [ "$HELPER_RC" != "0" ]; then
    tc17_ok=0; tc17_detail="$tc17_detail rc$cyc=$HELPER_RC"; continue
  fi
  if ! grep -q "FIX_FATAL_TRIAGE=applied; fatal=$exp_fatal; moved=$exp_moved" <<<"$HELPER_STDERR"; then
    tc17_ok=0
    tc17_detail="$tc17_detail cycle$cyc(want fatal=$exp_fatal moved=$exp_moved got '$(grep -o 'FIX_FATAL_TRIAGE=[^"]*' <<<"$HELPER_STDERR")')"
  fi
done
if [ "$tc17_ok" = "1" ]; then
  pass "7 cycle すべてで fatal / moved 件数が机上シミュレーションと一致"
else
  fail "cycle 別件数が不一致:$tc17_detail"
fi

# --------------------------------------------------------------------------
# TC-18 (T-09): 旧 LOW 自動降格の config キーが配布物 / docs / config / テストに残っていない (AC-8)
# --------------------------------------------------------------------------
echo "TC-18 (T-09): 旧 config キーの残存なし"
REPO_TOP=$(cd "$SCRIPT_DIR/../../../.." && pwd)
# needle は連結で組む — 本スキャナ自身が探索対象ディレクトリ配下にあるため、リテラルで
# 書くと自分自身にマッチして常に FAIL する
needle="auto_demote""_low"
# CHANGELOG は過去リリースの履歴記述であり書き換えない (配布物・docs・config・テストのみ走査)
residue=$(grep -rn --include='*.md' --include='*.sh' --include='*.yml' -- "$needle" \
  "$REPO_TOP/plugins" "$REPO_TOP/docs" "$REPO_TOP/rite-config.yml" 2>/dev/null || true)
if [ -z "$residue" ]; then
  pass "plugins / docs / rite-config.yml に旧 config キーの残存なし"
else
  fail "旧 config キーが残存: $(tr '\n' ' ' <<<"$residue")"
fi

# --------------------------------------------------------------------------
# TC-D: differential equivalence — normalization ((a)/(b)) のみを旧 inline block と比較
# 注: 旧 block は fail-fast 時に [fix:error] を stdout に emit していたが、委譲後は caller 責務に
#     分離した ([fix:error] stdout 分離契約)。比較時は参照実装の stdout から当該行を除外する。
# 注: 致命性仕分け由来の stderr 行 (FIX_FATAL_TRIAGE / 移送 WARNING) は strip_triage で落とす。
#     仕分けそのものは TC-10〜TC-17 が pin する。
# 注: invalid JSON は helper が json_invalid で先に停止するため差分が出る (意図した診断改善)。
#     TC-7 が単独で pin するので TC-D の対象から外す。
# --------------------------------------------------------------------------
echo "TC-D: differential equivalence (normalization のみ)"
run_differential() {
  local label="$1" fixture="$2" source="$3"
  local repo_ref repo_new
  repo_ref=$(make_sandbox "ref-$label")
  repo_new=$(make_sandbox "new-$label")
  write_fixture "$repo_ref/review.json" "$fixture"
  write_fixture "$repo_new/review.json" "$fixture"
  run_reference "$repo_ref" "$source" "$repo_ref/review.json"
  run_helper "$repo_new" "$source" "$repo_new/review.json"
  local ref_out_filtered ref_err_n new_err_n
  ref_out_filtered=$(grep -v '^\[fix:error\]$' <<<"$REF_STDOUT" || true)
  ref_err_n=$(normalize <<<"$REF_STDERR")
  new_err_n=$(normalize <<<"$HELPER_STDERR" | strip_triage)
  if [ "$REF_RC" = "$HELPER_RC" ] && [ "$ref_out_filtered" = "$HELPER_STDOUT" ] && [ "$ref_err_n" = "$new_err_n" ]; then
    pass "[$label] rc + stdout + stderr(仕分け行を除く) byte-identical (rc=$HELPER_RC)"
  else
    fail "[$label] diverged: ref(rc=$REF_RC) out='$ref_out_filtered' err='$ref_err_n' / new(rc=$HELPER_RC) out='$HELPER_STDOUT' err='$new_err_n'"
  fi
}

run_differential "noop-source"      clean_110            pr_comment
run_differential "clean-110"        clean_110            local_file
run_differential "v10-default-map"  v10_missing_scope    local_file
run_differential "invariant5"       invariant5_violation explicit_file
run_differential "dup-anchor"       duplicate_anchor     local_file

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
