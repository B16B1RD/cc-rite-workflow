#!/bin/bash
# Tests for plugins/rite/hooks/stop-loop-continuation.sh
# Verifies the Stop hook re-injects continuation commands when a handoff is pending,
# allows FINALIZE when the last assistant already has an iterate completion notice,
# fail-safes to bounce when inspect cannot run, and consumes the marker one-shot.
set -euo pipefail

pr_text() { printf 'PR #%s' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HOOK="$PLUGIN_ROOT/hooks/stop-loop-continuation.sh"
FS="$PLUGIN_ROOT/hooks/flow-state.sh"

if [ ! -x "$HOOK" ]; then
  echo "ERROR: $HOOK not found or not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

# Create a git sandbox so state-path-resolve.sh returns the sandbox root.
new_sandbox() {
  local d
  d=$(make_plain_sandbox --soft) || return 1
  (cd "$d" && git init -q && echo a > a && git add a && \
    git -c user.email=t@test.local -c user.name=test commit -q -m init) >/dev/null
  echo "$d"
}

# Emit a Stop payload JSON for the given cwd / session_id.
stop_payload() {
  local cwd="$1" sid="${2:-$SID}" active="${3:-false}"
  jq -nc --arg c "$cwd" --arg s "$sid" --argjson a "$active" \
    '{session_id:$s, cwd:$c, hook_event_name:"Stop", stop_hook_active:$a}'
}

state_file_for() { echo "$1/.rite/sessions/${SID}.flow-state"; }

# --- TC-1: handoff present → block with continuation command in reason ---
echo "=== TC-1: handoff present → decision:block re-injects the command ==="
d=$(new_sandbox)
RITE_STATE_ROOT="$d" bash "$FS" set --phase review --issue 1168 --branch b --pr 99 \
  --next n --handoff "/rite:fix 99" --session "$SID" >/dev/null
out=$(stop_payload "$d" | bash "$HOOK")
assert "TC-1: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "/rite:fix 99"; then
  pass "TC-1: reason contains the handoff command"
else
  fail "TC-1: reason missing handoff command: $out"
fi
# Symmetric to TC-7 (AC-3 bidirectional): the continuation branch must NOT use the
# FINALIZE completion-notice phrasing — pins both sides of the prefix split.
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
  fail "TC-1: continuation reason wrongly used the FINALIZE completion-notice phrasing: $out"
else
  pass "TC-1: continuation reason is distinct from the FINALIZE branch"
fi

# --- TC-2: handoff consumed (deleted) after the block (one-shot) ---
echo ""
echo "=== TC-2: handoff is deleted from flow-state after block (one-shot consume) ==="
sf=$(state_file_for "$d")
assert "TC-2: handoff deleted after block" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf")"
out2=$(stop_payload "$d" "$SID" true | bash "$HOOK")
assert "TC-2: second stop allows (no output)" "" "$out2"

# --- TC-3: no flow-state file → allow stop ---
echo ""
echo "=== TC-3: no flow-state file → allow (no output) ==="
d3=$(new_sandbox)
out=$(stop_payload "$d3" | bash "$HOOK")
assert "TC-3: allow when no flow-state" "" "$out"

# --- TC-4: flow-state without handoff → allow stop ---
echo ""
echo "=== TC-4: flow-state without handoff → allow (no output) ==="
d4=$(new_sandbox)
RITE_STATE_ROOT="$d4" bash "$FS" set --phase review --issue 1168 --branch b --pr 99 \
  --next n --session "$SID" >/dev/null
out=$(stop_payload "$d4" | bash "$HOOK")
assert "TC-4: allow when handoff absent" "" "$out"

# --- TC-5: missing session_id in payload → allow stop ---
echo ""
echo "=== TC-5: payload missing session_id → allow (no output) ==="
d5=$(new_sandbox)
RITE_STATE_ROOT="$d5" bash "$FS" set --phase fix --issue 1168 --branch b --pr 99 \
  --next n --handoff "/rite:pr-review 99" --session "$SID" >/dev/null
out=$(jq -nc --arg c "$d5" '{cwd:$c, hook_event_name:"Stop"}' | bash "$HOOK")
assert "TC-5: allow when session_id missing" "" "$out"

# --- TC-6: fix→review direction (handoff = /rite:pr-review) blocks ---
echo ""
echo "=== TC-6: fix→review handoff also blocks with the review command ==="
d6=$(new_sandbox)
RITE_STATE_ROOT="$d6" bash "$FS" set --phase fix --issue 1168 --branch b --pr 99 \
  --next n --handoff "/rite:pr-review 99" --session "$SID" >/dev/null
out=$(stop_payload "$d6" | bash "$HOOK")
assert "TC-6: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "/rite:pr-review 99"; then
  pass "TC-6: reason contains the review command"
else
  fail "TC-6: reason missing review command: $out"
fi
# Symmetric to TC-7 (AC-3 bidirectional): the fix→review continuation branch must NOT
# use the FINALIZE completion-notice phrasing.
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
  fail "TC-6: continuation reason wrongly used the FINALIZE completion-notice phrasing: $out"
else
  pass "TC-6: continuation reason is distinct from the FINALIZE branch"
fi

# --- TC-7: FINALIZE handoff present → block with completion-notice reason (AC-1/AC-3) ---
echo ""
echo "=== TC-7: FINALIZE handoff → decision:block re-injects the completion-notice directive ==="
d7=$(new_sandbox)
RITE_STATE_ROOT="$d7" bash "$FS" set --phase review --issue 1176 --branch b --pr 99 \
  --next n --handoff "FINALIZE:review:mergeable:99" --session "$SID" >/dev/null
out=$(stop_payload "$d7" | bash "$HOOK")
assert "TC-7: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_reason7=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_reason7" | grep -q "完了通知"; then
  pass "TC-7: reason requests the ステップ5 completion notice"
else
  fail "TC-7: reason missing completion-notice directive: $out"
fi
# The FINALIZE branch must NOT re-inject a continuation command (would falsely restart the loop).
if printf '%s' "$_reason7" | grep -q "停止せず、次を実行してください"; then
  fail "TC-7: FINALIZE reason wrongly used the continuation phrasing: $out"
else
  pass "TC-7: FINALIZE reason is distinct from the continuation branch"
fi
# The terminal result identifier should be surfaced for context.
if printf '%s' "$_reason7" | grep -q "review:mergeable:99"; then
  pass "TC-7: reason surfaces the terminal result (review:mergeable:99)"
else
  fail "TC-7: reason missing the terminal result identifier: $out"
fi

# --- TC-8: FINALIZE handoff consumed one-shot → second stop allows (AC-2/AC-5) ---
echo ""
echo "=== TC-8: FINALIZE handoff is one-shot — second stop allows (no infinite block) ==="
sf8=$(state_file_for "$d7")
assert "TC-8: FINALIZE handoff deleted after block" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf8")"
out8=$(stop_payload "$d7" "$SID" true | bash "$HOOK")
assert "TC-8: second stop allows (no output)" "" "$out8"

# --- TC-9: replied-only / cancelled-by-user FINALIZE variants also block with the finalize reason (AC-1) ---
echo ""
echo "=== TC-9: [fix:replied-only] / [fix:cancelled-by-user] FINALIZE handoffs block once ==="
for _ho in "FINALIZE:fix:replied-only:99" "FINALIZE:fix:cancelled-by-user:99"; do
  d9=$(new_sandbox)
  RITE_STATE_ROOT="$d9" bash "$FS" set --phase fix --issue 1176 --branch b --pr 99 \
    --next n --handoff "$_ho" --session "$SID" >/dev/null
  out=$(stop_payload "$d9" | bash "$HOOK")
  assert "TC-9: ${_ho} → decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
  if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
    pass "TC-9: ${_ho} reason requests the completion notice"
  else
    fail "TC-9: ${_ho} reason missing completion-notice directive: $out"
  fi
  # one-shot: second stop allows
  out_b=$(stop_payload "$d9" "$SID" true | bash "$HOOK")
  assert "TC-9: ${_ho} second stop allows (one-shot)" "" "$out_b"
done

# --- TC-10: FINALIZE handoff with empty result part still blocks once (edge case) ---
# ${HANDOFF#FINALIZE:} becomes "" when a sub-skill emits a malformed "FINALIZE:" handoff
# (e.g. a typo dropping the {result}:{pr} suffix). The hook must still take the FINALIZE
# branch and force the completion notice rather than silently allowing the stop.
echo ""
echo "=== TC-10: FINALIZE: (empty result part) still blocks with the completion-notice reason ==="
d10=$(new_sandbox)
RITE_STATE_ROOT="$d10" bash "$FS" set --phase review --issue 1176 --branch b --pr 99 \
  --next n --handoff "FINALIZE:" --session "$SID" >/dev/null
out=$(stop_payload "$d10" | bash "$HOOK")
assert "TC-10: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
  pass "TC-10: empty-result FINALIZE still requests the completion notice"
else
  fail "TC-10: empty-result FINALIZE missing completion-notice directive: $out"
fi
# one-shot: second stop allows (no infinite block even for the malformed handoff)
out_b=$(stop_payload "$d10" "$SID" true | bash "$HOOK")
assert "TC-10: second stop allows (one-shot)" "" "$out_b"

# --- TC-11: WIKICHAIN handoff → block with the cleanup-chain continuation reason (AC-2/AC-3) ---
echo ""
echo "=== TC-11: WIKICHAIN handoff → decision:block re-injects the cleanup chain continuation ==="
d11=$(new_sandbox)
RITE_STATE_ROOT="$d11" bash "$FS" set --phase cleanup --issue 1245 --branch b --pr 99 \
  --next n --handoff "WIKICHAIN:cleanup:99" --session "$SID" >/dev/null
out=$(stop_payload "$d11" | bash "$HOOK")
assert "TC-11: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_reason11=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_reason11" | grep -q "wiki-lint チェーン"; then
  pass "TC-11: reason identifies the cleanup → ingest → lint chain"
else
  fail "TC-11: reason missing the chain identification: $out"
fi
if printf '%s' "$_reason11" | grep -q "$(pr_text 99)"; then
  pass "TC-11: reason surfaces the PR number from the handoff"
else
  fail "TC-11: reason missing the PR number: $out"
fi
if printf '%s' "$_reason11" | grep -q "ステップ 10"; then
  pass "TC-11: reason directs continuation to cleanup ステップ 10-12"
else
  fail "TC-11: reason missing the cleanup step continuation directive: $out"
fi
# Distinctness pins (symmetric to TC-1/TC-7 bidirectional checks): the WIKICHAIN branch must
# use neither the FINALIZE completion-notice phrasing nor the review↔fix loop phrasing.
if printf '%s' "$_reason11" | grep -q "完了通知"; then
  fail "TC-11: WIKICHAIN reason wrongly used the FINALIZE completion-notice phrasing: $out"
else
  pass "TC-11: WIKICHAIN reason is distinct from the FINALIZE branch"
fi
if printf '%s' "$_reason11" | grep -q "review↔fix"; then
  fail "TC-11: WIKICHAIN reason wrongly used the review↔fix loop phrasing: $out"
else
  pass "TC-11: WIKICHAIN reason is distinct from the continuation branch"
fi

# --- TC-12: WIKICHAIN handoff consumed one-shot → second stop allows (AC-3) ---
echo ""
echo "=== TC-12: WIKICHAIN handoff is one-shot — second stop allows (no infinite block) ==="
sf12=$(state_file_for "$d11")
assert "TC-12: WIKICHAIN handoff deleted after block" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf12")"
out12=$(stop_payload "$d11" "$SID" true | bash "$HOOK")
assert "TC-12: second stop allows (no output)" "" "$out12"

# --- TC-13: unknown handoff prefix → fail-loud WARNING + verbatim re-inject ---
# The case catch-all must not silently absorb future prefixes into a named-branch behavior:
# it blocks (handoff non-empty → block axis) but surfaces a WARNING on stderr so a missing
# case arm is observable instead of masquerading as the review↔fix continuation.
echo ""
echo "=== TC-13: unknown handoff prefix → block + WARNING (no silent default absorption) ==="
d13=$(new_sandbox)
RITE_STATE_ROOT="$d13" bash "$FS" set --phase cleanup --issue 1245 --branch b --pr 99 \
  --next n --handoff "FUTUREPREFIX:something:99" --session "$SID" >/dev/null
err13=$(mktemp)
out=$(stop_payload "$d13" | bash "$HOOK" 2>"$err13")
assert "TC-13: decision=block (handoff non-empty axis preserved)" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "FUTUREPREFIX:something:99"; then
  pass "TC-13: reason re-injects the handoff verbatim"
else
  fail "TC-13: reason missing the verbatim handoff: $out"
fi
if grep -q "unknown handoff prefix" "$err13"; then
  pass "TC-13: WARNING surfaced on stderr for the unknown prefix"
else
  fail "TC-13: missing unknown-prefix WARNING on stderr: $(cat "$err13")"
fi
# The unknown-prefix branch must not claim the review↔fix loop identity.
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "review↔fix"; then
  fail "TC-13: unknown-prefix reason wrongly claimed the review↔fix loop identity: $out"
else
  pass "TC-13: unknown-prefix reason avoids the review↔fix loop phrasing"
fi
rm -f "$err13"
# one-shot: second stop allows
out_b=$(stop_payload "$d13" "$SID" true | bash "$HOOK")
assert "TC-13: second stop allows (one-shot)" "" "$out_b"

# --- TC-14: unknown-prefix WARNING neutralizes control bytes ---
# The stderr WARNING must not pass raw control bytes (ANSI escapes etc.) to the operator's
# terminal — same neutralize_ctrl shared-helper convention (control-char-neutralize.sh) as
# flow-state.sh _emit_jq_err_snippet, covering C0 + DEL + C1 0x80-0x9f byte-wise. The
# decision:block reason keeps the handoff verbatim (TC-13 contract): neutralize scope is
# the WARNING line only.
echo ""
echo "=== TC-14: unknown-prefix WARNING neutralizes control bytes (WARNING-only scope) ==="
d14=$(new_sandbox)
RITE_STATE_ROOT="$d14" bash "$FS" set --phase cleanup --issue 1269 --branch b --pr 99 \
  --next n --handoff "$(printf 'EVILPREFIX:\x1b[31mred\x1b[0m:99')" --session "$SID" >/dev/null
err14=$(mktemp)
out14=$(stop_payload "$d14" | bash "$HOOK" 2>"$err14")
assert "TC-14: decision=block (block axis unaffected by neutralize)" "block" "$(printf '%s' "$out14" | jq -r '.decision // "NONE"')"
if grep -q $'\x1b' "$err14"; then
  fail "TC-14: WARNING leaked a raw ESC byte to stderr: $(cat -v "$err14")"
else
  pass "TC-14: WARNING contains no raw control bytes"
fi
if grep -qF 'EVILPREFIX:?[31mred?[0m:99' "$err14"; then
  pass "TC-14: control bytes replaced with ? in the WARNING"
else
  fail "TC-14: neutralized handoff missing from WARNING: $(cat -v "$err14")"
fi
# Scope pin: the reason keeps the raw handoff verbatim (re-injection contract). If the
# neutralize scope is ever widened to the reason, update this pin deliberately.
if printf '%s' "$out14" | jq -r '.reason // ""' | grep -q $'\x1b'; then
  pass "TC-14: reason keeps the handoff verbatim (neutralize does not widen to re-injection)"
else
  fail "TC-14: reason lost the verbatim handoff bytes: $out14"
fi
rm -f "$err14"

# --- TC-15: unknown-prefix WARNING neutralizes C1 8-bit control bytes ---
# U+009B (UTF-8: 0xc2 0x9b) is valid UTF-8, so it survives the flow-state JSON round-trip
# (raw 0x9b would be replaced with U+FFFD by jq) and reaches the WARNING line — the realistic
# C1 attack byte sequence (xterm-class terminals interpret C1 as control even in UTF-8 mode).
# The former ${HANDOFF//[[:cntrl:]]/?} let the 0x9b byte through because glibc does not
# classify C1 as cntrl; byte-wise neutralize_ctrl replaces it, so no raw 0x9b on stderr.
echo ""
echo "=== TC-15: unknown-prefix WARNING neutralizes C1 bytes (U+009B via JSON round-trip) ==="
d15=$(new_sandbox)
RITE_STATE_ROOT="$d15" bash "$FS" set --phase cleanup --issue 1274 --branch b --pr 99 \
  --next n --handoff "$(printf 'EVILPREFIX:\xc2\x9bCSI:99')" --session "$SID" >/dev/null
err15=$(mktemp)
out15=$(stop_payload "$d15" | bash "$HOOK" 2>"$err15")
assert "TC-15: decision=block (block axis unaffected by C1 neutralize)" "block" "$(printf '%s' "$out15" | jq -r '.decision // "NONE"')"
if grep -qE 'WARNING:.*unknown handoff prefix' "$err15"; then
  pass "TC-15: unknown-prefix WARNING emitted (C1 経路に到達した sanity pin)"
else
  fail "TC-15: missing unknown-prefix WARNING on stderr: $(cat -v "$err15")"
fi
if LC_ALL=C grep -q $'\x9b' "$err15"; then
  fail "TC-15: WARNING leaked a raw C1 0x9b byte to stderr: $(cat -v "$err15")"
else
  pass "TC-15: WARNING contains no raw C1 0x9b byte"
fi
rm -f "$err15"

# --- TC-16: JSON emit fallback neutralizes raw C0 bytes → valid JSON ---
# The manual-escape fallback (taken when the final `jq -n` emit fails) only escaped
# \ / " / \n, letting raw C0 bytes (e.g. ESC from a control-byte handoff) through into
# the JSON string literal — invalid JSON per RFC 8259. The fix appends
# `neutralize_ctrl --c0-only` after the manual escapes: C0+DEL → ?, while UTF-8
# multibyte text (the Japanese continuation directive) stays intact (the default
# neutralize mode would byte-wise destroy it — that asymmetry is why --c0-only exists).
# jq full absence is NOT testable here: the payload parse at the top of the hook would
# fail first and the hook fail-opens. The realistic fallback trigger is an emit-only jq
# failure, simulated by a fake jq that fails only for `jq -n` and delegates the rest
# (payload parse / consume-handoff) to the real jq.
echo ""
echo "=== TC-16: JSON emit fallback — raw C0 neutralized, valid JSON, Japanese preserved ==="
d16=$(new_sandbox)
RITE_STATE_ROOT="$d16" bash "$FS" set --phase cleanup --issue 1275 --branch b --pr 99 \
  --next n --handoff "$(printf 'EVILPREFIX:\x1b[31mred\x1b[0m:99')" --session "$SID" >/dev/null
fake_bin=$(mktemp -d)
real_jq=$(command -v jq)
cat > "$fake_bin/jq" <<EOF
#!/bin/bash
if [ "\$1" = "-n" ]; then exit 1; fi
exec "$real_jq" "\$@"
EOF
chmod +x "$fake_bin/jq"
err16=$(mktemp)
out16=$(stop_payload "$d16" | PATH="$fake_bin:$PATH" bash "$HOOK" 2>"$err16")
# Sanity pin: the fallback path actually emitted (not the primary jq path).
if [ -n "$out16" ]; then
  pass "TC-16: fallback emitted output despite jq -n failure"
else
  fail "TC-16: no output — fallback path not reached: $(cat -v "$err16")"
fi
if printf '%s' "$out16" | LC_ALL=C grep -q $'\x1b'; then
  fail "TC-16: fallback JSON leaked a raw ESC byte: $(printf '%s' "$out16" | cat -v)"
else
  pass "TC-16: fallback JSON contains no raw C0 bytes"
fi
# RFC 8259 validity — raw C0 in a string literal would make this parse fail.
if printf '%s' "$out16" | "$real_jq" -e . >/dev/null 2>&1; then
  pass "TC-16: fallback output is valid JSON"
else
  fail "TC-16: fallback output is not parseable JSON: $(printf '%s' "$out16" | cat -v)"
fi
assert "TC-16: decision=block survives the fallback" "block" "$(printf '%s' "$out16" | "$real_jq" -r '.decision // "NONE"')"
_reason16=$(printf '%s' "$out16" | "$real_jq" -r '.reason // ""')
# The Japanese continuation directive must survive (--c0-only does not touch UTF-8
# multibyte bytes; the default neutralize mode would shred it into ? runs).
if printf '%s' "$_reason16" | grep -q "停止せず"; then
  pass "TC-16: Japanese directive text preserved in the fallback reason"
else
  fail "TC-16: Japanese directive text lost from the fallback reason: $out16"
fi
# The handoff's ESC bytes are ?-neutralized inside the re-injected reason.
if printf '%s' "$_reason16" | grep -qF 'EVILPREFIX:?[31mred?[0m:99'; then
  pass "TC-16: handoff control bytes neutralized to ? in the fallback reason"
else
  fail "TC-16: neutralized handoff missing from the fallback reason: $out16"
fi
rm -rf "$fake_bin" "$err16"
# one-shot: second stop allows (fallback path still consumes the handoff)
out_b=$(stop_payload "$d16" "$SID" true | bash "$HOOK")
assert "TC-16: second stop allows (one-shot)" "" "$out_b"

# --- TC-17: JSON emit fallback neutralize failure → static placeholder, block preserved ---
# TC-16 pins the escape-succeeded side of the fallback (handoff re-injected with C0 → ?).
# This TC pins the next failure layer: the fallback's own `neutralize_ctrl --c0-only` (a
# fixed-argument tr pipe the helper header calls "実質失敗しない") also fails, forcing the
# `_r_esc` static placeholder degradation. Forced via a fake tr that exits 1 only when $1
# carries the neutralize_ctrl `\000-` range string — other tr uses inside the hook chain
# (flow-state contains_ctrl's `tr -d ...` has $1=-d) delegate to the real tr, so the
# consume-handoff path stays intact. A known prefix (`/rite:fix 99`) is used instead of
# TC-16's EVILPREFIX: the unknown-prefix arm would hit the WARNING-side neutralize (its own
# placeholder) first, entangling two degradations — the known prefix isolates the JSON emit
# placeholder. Non-vacuous proof (TC-116 vacuous lesson): the normal reason carries the
# handoff command + Japanese directive, so asserting "placeholder text present + normal
# reason absent" proves the degradation actually fired.
echo ""
echo "=== TC-17: JSON emit fallback neutralize failure → placeholder degradation, block preserved ==="
d17=$(new_sandbox)
RITE_STATE_ROOT="$d17" bash "$FS" set --phase review --issue 1282 --branch b --pr 99 \
  --next n --handoff "/rite:fix 99" --session "$SID" >/dev/null
fake_bin17=$(mktemp -d)
real_jq=$(command -v jq)
real_tr=$(command -v tr)
cat > "$fake_bin17/jq" <<EOF
#!/bin/bash
if [ "\$1" = "-n" ]; then exit 1; fi
exec "$real_jq" "\$@"
EOF
cat > "$fake_bin17/tr" <<EOF
#!/bin/bash
case "\$1" in *000-*) exit 1 ;; esac
exec "$real_tr" "\$@"
EOF
chmod +x "$fake_bin17/jq" "$fake_bin17/tr"
err17=$(mktemp)
out17=$(stop_payload "$d17" | PATH="$fake_bin17:$PATH" bash "$HOOK" 2>"$err17")
# Sanity pin: the placeholder path still emitted (did not degrade into a silent allow).
if [ -n "$out17" ]; then
  pass "TC-17: placeholder path emitted output despite jq -n + tr failure"
else
  fail "TC-17: no output — placeholder path not reached: $(cat -v "$err17")"
fi
if printf '%s' "$out17" | "$real_jq" -e . >/dev/null 2>&1; then
  pass "TC-17: placeholder output is valid JSON"
else
  fail "TC-17: placeholder output is not parseable JSON: $(printf '%s' "$out17" | cat -v)"
fi
assert "TC-17: decision=block survives the placeholder degradation" "block" "$(printf '%s' "$out17" | "$real_jq" -r '.decision // "NONE"')"
_reason17=$(printf '%s' "$out17" | "$real_jq" -r '.reason // ""')
# 縮退の発生証明 (非 vacuous): placeholder 文言 + /rite:recover 案内あり、通常 reason
# (handoff コマンド再注入 / 日本語継続指示) なし。
if printf '%s' "$_reason17" | grep -q "rite handoff continuation pending (reason neutralization failed)" \
   && printf '%s' "$_reason17" | grep -qF "/rite:recover"; then
  pass "TC-17: reason degraded to the static placeholder with recovery guidance"
else
  fail "TC-17: expected static placeholder reason, got: $out17"
fi
if printf '%s' "$_reason17" | grep -qF "/rite:fix 99" || printf '%s' "$_reason17" | grep -q "停止せず"; then
  fail "TC-17: normal-path reason leaked into the placeholder degradation: $out17"
else
  pass "TC-17: normal-path reason absent (degradation actually fired, non-vacuous)"
fi
rm -rf "$fake_bin17" "$err17"
# one-shot: second stop allows (the placeholder path still consumes the handoff)
out17b=$(stop_payload "$d17" "$SID" true | bash "$HOOK")
assert "TC-17: second stop allows (one-shot consume preserved through placeholder path)" "" "$out17b"

# --- TC-18: FINALIZE:review:mergeable + transcript に残件欄なし → 差し戻し (AC-3 / T-03) ---
echo ""
echo "=== TC-18: FINALIZE:review:mergeable transcript missing remaining field → bounce once ==="
d18=$(new_sandbox)
RITE_STATE_ROOT="$d18" bash "$FS" set --phase review --issue 2346 --branch b --pr 99 \
  --next n --handoff "FINALIZE:review:mergeable:99" --session "$SID" >/dev/null
tp18=$(mktemp)
cat > "$tp18" <<'EOF'
{"type":"user","message":{"role":"user","content":"ok"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## /rite:iterate 完了\n\n- PR: #99\n- 終了理由: review:mergeable\n- ブランチ: b\n"}]}}
EOF
out=$(jq -nc --arg c "$d18" --arg s "$SID" --arg tp "$tp18" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-18: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_reason18=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_reason18" | grep -q "未処理 non-blocking"; then
  pass "TC-18: reason requires the remaining-field"
else
  fail "TC-18: reason missing remaining-field directive: $out"
fi
if printf '%s' "$_reason18" | grep -q "欄がありません"; then
  pass "TC-18: reason reports the field is missing from the last notice"
else
  fail "TC-18: reason did not report missing field: $out"
fi
sf18=$(state_file_for "$d18")
assert "TC-18: handoff deleted after block (one-shot)" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf18")"
out18b=$(jq -nc --arg c "$d18" --arg s "$SID" --arg tp "$tp18" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:true}' | bash "$HOOK")
assert "TC-18: second stop allows (one-shot / no infinite block)" "" "$out18b"
rm -f "$tp18"

# --- TC-19: FINALIZE:review:mergeable + transcript_path 欠落 → 検査不能 fail-safe 差し戻し ---
echo ""
echo "=== TC-19: FINALIZE:review:mergeable without transcript → fail-safe bounce ==="
d19=$(new_sandbox)
RITE_STATE_ROOT="$d19" bash "$FS" set --phase review --issue 2346 --branch b --pr 99 \
  --next n --handoff "FINALIZE:review:mergeable:99" --session "$SID" >/dev/null
out=$(stop_payload "$d19" | bash "$HOOK")
assert "TC-19: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_reason19=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_reason19" | grep -q "判定できなかった"; then
  pass "TC-19: inspect-fail fail-safe asks to re-output the remaining field"
else
  fail "TC-19: inspect-fail reason missing fail-safe wording: $out"
fi
if printf '%s' "$_reason19" | grep -q "未処理 non-blocking"; then
  pass "TC-19: inspect-fail reason still requires the remaining field"
else
  fail "TC-19: inspect-fail reason missing remaining-field directive: $out"
fi

# --- TC-20: FINALIZE:fix:replied-only は残件欄検査の対象外 ---
echo ""
echo "=== TC-20: FINALIZE:fix:replied-only does not require remaining-field inspection ==="
d20=$(new_sandbox)
RITE_STATE_ROOT="$d20" bash "$FS" set --phase fix --issue 2346 --branch b --pr 99 \
  --next n --handoff "FINALIZE:fix:replied-only:99" --session "$SID" >/dev/null
out=$(stop_payload "$d20" | bash "$HOOK")
assert "TC-20: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_reason20=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_reason20" | grep -q "未処理 non-blocking"; then
  fail "TC-20: replied-only reason wrongly required remaining field: $out"
else
  pass "TC-20: replied-only reason does not mention remaining field"
fi
if printf '%s' "$_reason20" | grep -q "完了通知"; then
  pass "TC-20: replied-only still requests the completion notice"
else
  fail "TC-20: replied-only reason lost the completion-notice directive: $out"
fi

# --- TC-21: FINALIZE:review:mergeable + 完了通知 + 残件欄あり → 差し戻さない (AC-1 / T-01) ---
echo ""
echo "=== TC-21: FINALIZE:review:mergeable with notice + remaining field allows stop ==="
d21=$(new_sandbox)
RITE_STATE_ROOT="$d21" bash "$FS" set --phase review --issue 2349 --branch b --pr 99 \
  --next n --handoff "FINALIZE:review:mergeable:99" --session "$SID" >/dev/null
tp21=$(mktemp)
cat > "$tp21" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## /rite:iterate 完了\n\n- PR: #99\n- 終了理由: review:mergeable\n- 未処理 non-blocking: 0 件\n"}]}}
EOF
out=$(jq -nc --arg c "$d21" --arg s "$SID" --arg tp "$tp21" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-21: notice+field allows stop (no output)" "" "$out"
sf21=$(state_file_for "$d21")
assert "TC-21: handoff consumed even when allowing" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf21")"
out21b=$(jq -nc --arg c "$d21" --arg s "$SID" --arg tp "$tp21" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:true}' | bash "$HOOK")
assert "TC-21: second stop still allows" "" "$out21b"
rm -f "$tp21"

# --- TC-22: FINALIZE:fix:replied-only + 完了通知あり → 差し戻さない (AC-1 / T-01) ---
echo ""
echo "=== TC-22: FINALIZE:fix:replied-only with completion notice allows stop ==="
d22=$(new_sandbox)
RITE_STATE_ROOT="$d22" bash "$FS" set --phase fix --issue 2349 --branch b --pr 99 \
  --next n --handoff "FINALIZE:fix:replied-only:99" --session "$SID" >/dev/null
tp22=$(mktemp)
cat > "$tp22" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## /rite:iterate 完了\n\n- PR: #99\n- 終了理由: fix:replied-only\n"}]}}
EOF
out=$(jq -nc --arg c "$d22" --arg s "$SID" --arg tp "$tp22" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-22: replied-only notice allows stop (no output)" "" "$out"
sf22=$(state_file_for "$d22")
assert "TC-22: handoff consumed even when allowing" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf22")"
rm -f "$tp22"

# --- TC-23: FINALIZE:fix:cancelled-by-user + 中断通知あり → 差し戻さない (AC-1) ---
echo ""
echo "=== TC-23: FINALIZE:fix:cancelled-by-user with interrupt notice allows stop ==="
d23=$(new_sandbox)
RITE_STATE_ROOT="$d23" bash "$FS" set --phase fix --issue 2349 --branch b --pr 99 \
  --next n --handoff "FINALIZE:fix:cancelled-by-user:99" --session "$SID" >/dev/null
tp23=$(mktemp)
cat > "$tp23" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## /rite:iterate 中断\n\n- PR: #99\n- 終了理由: fix:cancelled-by-user\n"}]}}
EOF
out=$(jq -nc --arg c "$d23" --arg s "$SID" --arg tp "$tp23" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-23: cancelled notice allows stop (no output)" "" "$out"
sf23=$(state_file_for "$d23")
assert "TC-23: handoff consumed even when allowing" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$sf23")"
rm -f "$tp23"

# --- TC-24: FINALIZE + 最終 assistant が空 / jq 不能 → 差し戻す (AC-3 / T-03) ---
echo ""
echo "=== TC-24: FINALIZE with unparseable transcript fail-safe bounces ==="
d24=$(new_sandbox)
RITE_STATE_ROOT="$d24" bash "$FS" set --phase review --issue 2349 --branch b --pr 99 \
  --next n --handoff "FINALIZE:review:mergeable:99" --session "$SID" >/dev/null
tp24=$(mktemp)
printf 'not-json\n' > "$tp24"
out=$(jq -nc --arg c "$d24" --arg s "$SID" --arg tp "$tp24" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-24: decision=block (inspect-fail fail-safe)" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_reason24=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_reason24" | grep -q "完了通知"; then
  pass "TC-24: inspect-fail still requests the completion notice"
else
  fail "TC-24: inspect-fail reason missing completion-notice directive: $out"
fi
rm -f "$tp24"

# --- TC-25: 継続 handoff は完了通知があっても差し戻す（FINALIZE 限定の検査範囲） ---
echo ""
echo "=== TC-25: continuation handoff still blocks even when iterate notice is present ==="
d25=$(new_sandbox)
RITE_STATE_ROOT="$d25" bash "$FS" set --phase review --issue 2349 --branch b --pr 99 \
  --next n --handoff "/rite:fix 99" --session "$SID" >/dev/null
tp25=$(mktemp)
cat > "$tp25" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## /rite:iterate 完了\n"}]}}
EOF
out=$(jq -nc --arg c "$d25" --arg s "$SID" --arg tp "$tp25" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-25: decision=block (notice does not suppress continuation)" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "/rite:fix 99"; then
  pass "TC-25: continuation reason still re-injects /rite:fix"
else
  fail "TC-25: continuation reason lost the command: $out"
fi
rm -f "$tp25"

# --- TC-26: parseable transcript, last assistant has no notice heading → bounce (AC-2 production) ---
echo ""
echo "=== TC-26: parseable transcript without notice heading bounces (AC-2 missing branch) ==="
d26=$(new_sandbox)
RITE_STATE_ROOT="$d26" bash "$FS" set --phase fix --issue 2349 --branch b --pr 99 \
  --next n --handoff "FINALIZE:fix:replied-only:99" --session "$SID" >/dev/null
tp26=$(mktemp)
cat > "$tp26" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"[fix:replied-only] 指摘に返信して完了しました\n"}]}}
EOF
out=$(jq -nc --arg c "$d26" --arg s "$SID" --arg tp "$tp26" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-26: decision=block (missing notice with parseable last text)" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if printf '%s' "$out" | jq -r '.reason // ""' | grep -q "完了通知"; then
  pass "TC-26: missing-notice path still requests the completion notice"
else
  fail "TC-26: missing-notice reason lost completion-notice directive: $out"
fi
rm -f "$tp26"

# --- TC-27: mergeable remaining field present but heading absent → bounce ---
echo ""
echo "=== TC-27: mergeable remaining field without heading still bounces ==="
d27=$(new_sandbox)
RITE_STATE_ROOT="$d27" bash "$FS" set --phase review --issue 2349 --branch b --pr 99 \
  --next n --handoff "FINALIZE:review:mergeable:99" --session "$SID" >/dev/null
tp27=$(mktemp)
cat > "$tp27" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"未処理 non-blocking: 0 件\n"}]}}
EOF
out=$(jq -nc --arg c "$d27" --arg s "$SID" --arg tp "$tp27" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-27: decision=block (remaining field does not substitute for heading)" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
rm -f "$tp27"

# --- TC-28: replied-only + unparseable transcript → bounce (AC-3 isolated from remaining-field) ---
echo ""
echo "=== TC-28: replied-only unparseable transcript fail-safe bounces (AC-3 isolated) ==="
d28=$(new_sandbox)
RITE_STATE_ROOT="$d28" bash "$FS" set --phase fix --issue 2349 --branch b --pr 99 \
  --next n --handoff "FINALIZE:fix:replied-only:99" --session "$SID" >/dev/null
tp28=$(mktemp)
printf 'not-json\n' > "$tp28"
out=$(jq -nc --arg c "$d28" --arg s "$SID" --arg tp "$tp28" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-28: decision=block (inspect-fail without remaining-field contract)" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
rm -f "$tp28"

# --- TC-29: heading at start of 128KiB last text → allow (pipefail SIGPIPE pin) ---
echo ""
echo "=== TC-29: heading at start of large last text allows stop (no SIGPIPE false missing) ==="
d29=$(new_sandbox)
RITE_STATE_ROOT="$d29" bash "$FS" set --phase fix --issue 2349 --branch b --pr 99 \
  --next n --handoff "FINALIZE:fix:replied-only:99" --session "$SID" >/dev/null
tp29=$(mktemp)
python3 - "$tp29" <<'PY'
import json, sys
path = sys.argv[1]
text = "## /rite:iterate 完了\n" + ("x" * 131072)
rec = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
out=$(jq -nc --arg c "$d29" --arg s "$SID" --arg tp "$tp29" \
  '{session_id:$s, cwd:$c, transcript_path:$tp, hook_event_name:"Stop", stop_hook_active:false}' | bash "$HOOK")
assert "TC-29: large heading-at-start allows stop (no output)" "" "$out"
rm -f "$tp29"

write_queue() {
  local dir="$1" sid="${2:-$SID}"
  mkdir -p "$dir/.rite/state"
  jq -n '{issues:[2502], cursor:0, mode:"merge", failed:[], outstanding:[], active:true, updated_at:"2026-09-02T00:00:00Z"}' \
    > "$dir/.rite/state/run-queue-${sid}.json"
}

sidecar_for() { echo "$1/.rite/state/run-queue-${SID}.watchdog"; }
queue_for() { echo "$1/.rite/state/run-queue-${SID}.json"; }

run_stop() {
  local dir="$1" errf="${2:-/dev/null}"
  stop_payload "$dir" | bash "$HOOK" 2>"$errf"
}

setup_watchdog_fs() {
  local dir="$1" phase="$2" pr="${3:-99}"
  RITE_STATE_ROOT="$dir" bash "$FS" set --phase "$phase" --issue 2502 \
    --branch "fix/issue-2502-x" --pr "$pr" --next n --session "$SID" >/dev/null
  write_queue "$dir"
}

# --- T-01: handoff empty + active queue → block with batch frame ---
echo ""
echo "=== T-01: handoff empty + active queue → decision:block with batch frame ==="
d=$(new_sandbox)
setup_watchdog_fs "$d" review 99
out=$(run_stop "$d")
assert "T-01: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_r=$(printf '%s' "$out" | jq -r '.reason // ""')
for needle in "mode=merge" "cursor=0/1" "Issue #2502" "PR #99" "phase=review" "/rite:iterate 99" "queue_file="; do
  if printf '%s' "$_r" | grep -qF "$needle"; then
    pass "T-01: reason contains $needle"
  else
    fail "T-01: reason missing $needle: $out"
  fi
done
if printf '%s' "$_r" | grep -q "review↔fix ループ"; then
  fail "T-01: watchdog reason used handoff continuation phrasing: $out"
else
  pass "T-01: watchdog reason is distinct from handoff continuation"
fi

# --- T-02: handoff non-empty wins; sidecar not created ---
echo ""
echo "=== T-02: handoff non-empty keeps existing reason; no sidecar ==="
d=$(new_sandbox)
RITE_STATE_ROOT="$d" bash "$FS" set --phase review --issue 2502 --branch b --pr 99 \
  --next n --handoff "/rite:fix 99" --session "$SID" >/dev/null
write_queue "$d"
out=$(run_stop "$d")
assert "T-02: decision=block" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
_r=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_r" | grep -q "/rite:fix 99"; then
  pass "T-02: reason is existing continuation"
else
  fail "T-02: reason lost handoff command: $out"
fi
if printf '%s' "$_r" | grep -qE 'queue_file=|Batch:'; then
  fail "T-02: handoff reason leaked batch frame: $out"
else
  pass "T-02: handoff reason has no batch frame"
fi
if [ -e "$(sidecar_for "$d")" ]; then
  fail "T-02: sidecar should not be created on handoff path"
else
  pass "T-02: sidecar absent"
fi

# --- T-03: queue absent / active:false / cursor>=total → allow ---
echo ""
echo "=== T-03: non-active queue variants allow stop ==="
d=$(new_sandbox)
RITE_STATE_ROOT="$d" bash "$FS" set --phase review --issue 2502 --branch b --pr 99 \
  --next n --session "$SID" >/dev/null
out=$(run_stop "$d")
assert "T-03a: no queue allows stop" "" "$out"

write_queue "$d"
jq '.active=false' "$(queue_for "$d")" > "$(queue_for "$d").tmp" && mv "$(queue_for "$d").tmp" "$(queue_for "$d")"
out=$(run_stop "$d")
assert "T-03b: active:false allows stop" "" "$out"

jq '.active=true | .cursor=1' "$(queue_for "$d")" > "$(queue_for "$d").tmp" && mv "$(queue_for "$d").tmp" "$(queue_for "$d")"
out=$(run_stop "$d")
assert "T-03c: cursor>=total allows stop" "" "$out"

# --- T-04: 3 blocks then 4th allows; active stays true; 4 keys unchanged ---
echo ""
echo "=== T-04: progress-less K=3 then 4th allows; active remains true ==="
d=$(new_sandbox)
setup_watchdog_fs "$d" review 99
i=1
while [ "$i" -le 3 ]; do
  out=$(run_stop "$d")
  assert "T-04: stop $i blocks" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
  i=$((i + 1))
done
err=$(mktemp)
out=$(run_stop "$d" "$err")
assert "T-04: 4th stop allows (no stdout)" "" "$out"
if grep -q "WARNING: batch-run が 3 回連続で進捗なく停止しました" "$err" && grep -q "/rite:batch-run" "$err"; then
  pass "T-04: 4th stop WARNING includes resume command"
else
  fail "T-04: 4th stop stderr missing WARNING: $(cat "$err")"
fi
assert "T-04: queue active remains true" "true" "$(jq -r '.active' "$(queue_for "$d")")"
rm -f "$err"

# --- T-05: each of 4 progress keys resets count; unchanged keys increment ---
echo ""
echo "=== T-05: progress keys reset count; unchanged keys increment ==="
reset_and_check() {
  local dir="$1" label="$2"
  jq '.count=2 | .cursor=0 | .updated_at="2026-09-02T00:00:00Z" | .phase="review" | .pr_number="99"' \
    "$(sidecar_for "$dir")" > "$(sidecar_for "$dir").tmp" && mv "$(sidecar_for "$dir").tmp" "$(sidecar_for "$dir")"
  # first after reset should block as count=1 (not trip K)
  out=$(run_stop "$dir")
  assert "T-05 $label: first after change blocks" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
  assert "T-05 $label: sidecar count is 1" "1" "$(jq -r '.count' "$(sidecar_for "$dir")")"
}

d=$(new_sandbox)
setup_watchdog_fs "$d" review 99
run_stop "$d" >/dev/null
run_stop "$d" >/dev/null
assert "T-05 setup: count=2" "2" "$(jq -r '.count' "$(sidecar_for "$d")")"

jq '.updated_at="2026-09-02T00:00:01Z"' "$(queue_for "$d")" > "$(queue_for "$d").tmp" && mv "$(queue_for "$d").tmp" "$(queue_for "$d")"
reset_and_check "$d" "updated_at"

jq '.cursor=0 | .updated_at="2026-09-02T00:00:01Z"' "$(queue_for "$d")" > "$(queue_for "$d").tmp" && mv "$(queue_for "$d").tmp" "$(queue_for "$d")"
# cursor change: bump issues so cursor=0 still active? change cursor to 0 is no-op.
# Use a two-issue queue and cursor 0 → keep, then we'll set sidecar to cursor 0 and change queue cursor? 
# Simpler: rewrite queue with cursor still 0 but we already tested updated_at.
# For cursor: set sidecar cursor to 1 (mismatch) while queue cursor is 0.
jq '.count=2 | .cursor=1 | .updated_at="2026-09-02T00:00:01Z" | .phase="review" | .pr_number="99"' \
  "$(sidecar_for "$d")" > "$(sidecar_for "$d").tmp" && mv "$(sidecar_for "$d").tmp" "$(sidecar_for "$d")"
out=$(run_stop "$d")
assert "T-05 cursor: first after change blocks" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
assert "T-05 cursor: sidecar count is 1" "1" "$(jq -r '.count' "$(sidecar_for "$d")")"

sf=$(state_file_for "$d")
jq '.phase="fix"' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
jq '.count=2 | .cursor=0 | .updated_at="2026-09-02T00:00:01Z" | .phase="review" | .pr_number="99"' \
  "$(sidecar_for "$d")" > "$(sidecar_for "$d").tmp" && mv "$(sidecar_for "$d").tmp" "$(sidecar_for "$d")"
out=$(run_stop "$d")
assert "T-05 phase: first after change blocks" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
assert "T-05 phase: sidecar count is 1" "1" "$(jq -r '.count' "$(sidecar_for "$d")")"

jq '.pr_number=77' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
jq '.count=2 | .cursor=0 | .updated_at="2026-09-02T00:00:01Z" | .phase="fix" | .pr_number="99"' \
  "$(sidecar_for "$d")" > "$(sidecar_for "$d").tmp" && mv "$(sidecar_for "$d").tmp" "$(sidecar_for "$d")"
out=$(run_stop "$d")
assert "T-05 pr_number: first after change blocks" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
assert "T-05 pr_number: sidecar count is 1" "1" "$(jq -r '.count' "$(sidecar_for "$d")")"

# unchanged 4 keys increment
run_stop "$d" >/dev/null
assert "T-05 unchanged: count increments to 2" "2" "$(jq -r '.count' "$(sidecar_for "$d")")"

# --- T-06: corrupt queue JSON ---
echo ""
echo "=== T-06: corrupt run-queue JSON allows stop with WARNING ==="
d=$(new_sandbox)
RITE_STATE_ROOT="$d" bash "$FS" set --phase review --issue 2502 --branch b --pr 99 \
  --next n --session "$SID" >/dev/null
mkdir -p "$d/.rite/state"
printf 'not-json{{' > "$(queue_for "$d")"
err=$(mktemp)
out=$(run_stop "$d" "$err")
assert "T-06: stdout empty" "" "$out"
if grep -q "WARNING: run-queue が破損しています" "$err" && grep -q "$(queue_for "$d")" "$err"; then
  pass "T-06: WARNING includes queue path"
else
  fail "T-06: stderr missing WARNING+path: $(cat "$err")"
fi
rm -f "$err"

# --- T-07: other session_id queue ignored ---
echo ""
echo "=== T-07: other session_id active queue is ignored ==="
d=$(new_sandbox)
RITE_STATE_ROOT="$d" bash "$FS" set --phase review --issue 2502 --branch b --pr 99 \
  --next n --session "$SID" >/dev/null
write_queue "$d" "other-session-id"
out=$(run_stop "$d")
assert "T-07: other session queue allows stop" "" "$out"

# --- routing buckets ---
echo ""
echo "=== T-routing: phase buckets pin hint literals ==="
assert_hint() {
  local label="$1" phase="$2" extra="$3" want="$4" not_want="$5"
  local dir out r
  dir=$(new_sandbox)
  setup_watchdog_fs "$dir" "$phase" 99
  if [ -n "$extra" ]; then
    jq "$extra" "$(state_file_for "$dir")" > "$(state_file_for "$dir").tmp" \
      && mv "$(state_file_for "$dir").tmp" "$(state_file_for "$dir")"
  fi
  out=$(run_stop "$dir")
  r=$(printf '%s' "$out" | jq -r '.reason // ""')
  if printf '%s' "$r" | grep -qF "$want"; then
    pass "T-routing $label: hint contains $want"
  else
    fail "T-routing $label: missing $want in $r"
  fi
  if [ -n "$not_want" ] && printf '%s' "$r" | grep -qF "$not_want"; then
    fail "T-routing $label: leaked $not_want in $r"
  else
    [ -n "$not_want" ] && pass "T-routing $label: does not contain $not_want"
  fi
}
assert_hint "ready" ready "" "/rite:merge 99" "/rite:iterate"
assert_hint "merge" merge "" "/rite:cleanup fix/issue-2502-x" "/rite:iterate"
assert_hint "init" init "" "/rite:open 2502" "/rite:iterate"
assert_hint "lint" lint "" "/rite:open 2502" "ステップ 6"
assert_hint "ingest-active" ingest "" "/rite:cleanup の残りステップ" "ステップ 6"
assert_hint "completed-inactive" completed ".active=false" "batch-run ステップ 6（cursor 前進）" "/rite:iterate"
assert_hint "unknown-phase" unknown_phase "" "batch-run ステップ 1 から再判定" "/rite:iterate"
assert_hint "cb-fire" review '.stop_reason="circuit-breaker:max-cycles"' "batch-run ステップ 6（failed 記録 + cursor 前進）" "/rite:iterate"

# flow-state absent → ステップ 1
d=$(new_sandbox)
write_queue "$d"
out=$(run_stop "$d")
_r=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_r" | grep -q "batch-run ステップ 1 から再判定"; then
  pass "T-routing fs-absent: ステップ 1 再判定"
else
  fail "T-routing fs-absent: $out"
fi

# --- T-11: cleanup + flow-state active=false → step 6 ---
echo ""
echo "=== T-11: phase=cleanup and flow-state active=false routes to step 6 ==="
d=$(new_sandbox)
setup_watchdog_fs "$d" cleanup 99
jq '.active=false' "$(state_file_for "$d")" > "$(state_file_for "$d").tmp" \
  && mv "$(state_file_for "$d").tmp" "$(state_file_for "$d")"
out=$(run_stop "$d")
_r=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_r" | grep -q "batch-run ステップ 6（cursor 前進）"; then
  pass "T-11: reason routes to cursor advance"
else
  fail "T-11: $out"
fi
if printf '%s' "$_r" | grep -q "/rite:cleanup の残りステップ"; then
  fail "T-11: inactive cleanup used in-progress hint: $out"
else
  pass "T-11: inactive cleanup does not use in-progress hint"
fi

# WIKICHAIN consumed + 2nd stop with active cleanup must not jump to cursor advance
echo ""
echo "=== T-wikichain-2nd: active cleanup after WIKICHAIN consume continues cleanup ==="
d=$(new_sandbox)
RITE_STATE_ROOT="$d" bash "$FS" set --phase cleanup --issue 2502 --branch b --pr 99 \
  --next n --handoff "WIKICHAIN:cleanup:99" --session "$SID" >/dev/null
write_queue "$d"
out=$(run_stop "$d")
assert "T-wikichain-1st: handoff blocks" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
out=$(run_stop "$d")
_r=$(printf '%s' "$out" | jq -r '.reason // ""')
if printf '%s' "$_r" | grep -q "/rite:cleanup の残りステップ"; then
  pass "T-wikichain-2nd: continues cleanup remaining steps"
else
  fail "T-wikichain-2nd: $out"
fi
if printf '%s' "$_r" | grep -q "ステップ 6（cursor 前進）"; then
  fail "T-wikichain-2nd: replaced wiki chain with cursor advance: $out"
else
  pass "T-wikichain-2nd: does not jump to cursor advance"
fi

# --- T-12: sidecar unwritable still blocks; 2nd call also blocks ---
echo ""
echo "=== T-12: sidecar write failure still blocks (and 2nd call still blocks) ==="
d=$(new_sandbox)
setup_watchdog_fs "$d" review 99
chmod a-w "$d/.rite/state"
err=$(mktemp)
out=$(run_stop "$d" "$err") || true
chmod u+w "$d/.rite/state"
assert "T-12: 1st still blocks" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
if grep -q "sidecar の書込に失敗" "$err"; then
  pass "T-12: WARNING on sidecar write failure"
else
  fail "T-12: missing sidecar WARNING: $(cat "$err")"
fi
chmod a-w "$d/.rite/state"
err2=$(mktemp)
out=$(run_stop "$d" "$err2") || true
chmod u+w "$d/.rite/state"
assert "T-12: 2nd still blocks (K cannot fire)" "block" "$(printf '%s' "$out" | jq -r '.decision // "NONE"')"
rm -f "$err" "$err2"

if ! print_summary "$(basename "$0")" "stop-loop-continuation.sh (review↔fix loop continuation + FINALIZE terminal backstop + skip bounce when iterate notice already present + remaining-field inspect on mergeable + WIKICHAIN cleanup-chain gate + C1 8-bit coverage via shared neutralize_ctrl + JSON emit fallback C0 neutralization + neutralize-failure placeholder degradation + notice missing/inspect-fail isolation + SIGPIPE-safe heading scan + batch run-queue watchdog)"; then
  exit 1
fi
