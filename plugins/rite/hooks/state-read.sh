#!/bin/bash
# rite workflow - State Read Helper
# Reads a single field from the active session's flow-state file (per-session
# or legacy). Mirrors flow-state-update.sh's path-resolution rules so reader
# bash patterns scattered across command files (e.g. start.md Phase 3 / 5.5.1 /
# 5.6 pre-condition checks) cannot accidentally read another session's stale
# residue from .rite-flow-state.
#
# Usage:
#   bash plugins/rite/hooks/state-read.sh --field <name> [--default <val>]
#
# Examples:
#   curr=$(bash plugins/rite/hooks/state-read.sh --field phase --default "")
#   parent=$(bash plugins/rite/hooks/state-read.sh --field parent_issue_number --default 0)
#   loop=$(bash plugins/rite/hooks/state-read.sh --field loop_count --default 0)
#   pr=$(bash plugins/rite/hooks/state-read.sh --field pr_number --default "null")
#
# Resolution order (matches flow-state-update.sh semantics):
#   1. schema_version=2 + valid .rite-session-id UUID + per-session file exists
#      -> per-session file (.rite/sessions/{sid}.flow-state)
#   2. legacy file exists (.rite-flow-state)
#      -> legacy
#   3. neither
#      -> $DEFAULT
#
# Why this exists (Issue #687 AC-4):
#   When schema_version=2 routes flow-state writes to per-session files,
#   inline `jq -r '.<field>' .rite-flow-state` patterns read stale residue
#   left by a prior session — observed in #687 reproduction where Phase 3
#   pre-condition fetched phase5_post_stop_hook from another session's legacy
#   file instead of phase2_post_work_memory from the active per-session file.
#
# Exit codes:
#   0 — success (value or default printed to stdout)
#   1 — argument error / invalid field name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper script existence check (verified-review cycle 34 F-09 / cycle 38 F-01 HIGH + F-09 MEDIUM):
# 旧実装は state-path-resolve.sh のみ fail-fast 検査していたが、本 helper は以下の helper にも
# `bash <missing>` invocation 経路で依存する (direct + transitive)。下記 for loop が SoT:
#   - `state-path-resolve.sh` (STATE_ROOT 解決経路で direct invoke。`||` fallback で silent suppression する独自経路を持つため特に重要)
#   - `_resolve-session-id-from-file.sh` (SESSION_ID resolution block で direct invoke)
#   - `_resolve-session-id.sh` (上記 helper 内 + `_resolve-cross-session-guard.sh` 内で transitive)
#   - `_resolve-schema-version.sh` (SCHEMA_VERSION resolution block で direct invoke)
#   - `_resolve-cross-session-guard.sh` (per-session resolver の case classification block で direct invoke)
#   - `_emit-cross-session-incident.sh` (case `foreign:*` / `corrupt:*` / `invalid_uuid:*` arm で direct invoke)
# verified-review cycle 41 C-01: 旧コメントは line 番号 (L88 / L97 / L119 / L130/137/145) で参照していたが、
# 各 helper の実行数 (35 / 56 / 149 / 138 行) と整合せず drift していた。cycle 38 F-04 で確立した
# semantic anchor 原則を本コメント自身にも適用し、関数 / case 文の semantic 名で参照する形式に統一した。
# それらが install 不整合 / deploy regression で missing の場合、bash は exit 127 を返すが
# `set -euo pipefail` の中でも `if`/`else`/`||` 文脈では非ブロッキング扱いとなり、silent fall-through
# 経路が散在する。Issue #687 (writer/reader 片肺更新型 silent regression) と同型の deploy regression を
# 構造的に塞ぐため、依存する全 helper を upfront で fail-fast 検査する (具体的なリストは下記 for loop が SoT。
# 上記 bullet list は loop と完全一致し 6 entry を列挙する。旧コメントは「5 helper」と書いていたが
# 実際の loop は 6 helper を検査しており、cycle 38 F-04 で確立した semantic anchor 原則と矛盾する
# 数値ドリフトを起こしていたため、verified-review cycle 39 で数値削除に統一。
# verified-review cycle 44 F-05 (code-quality MEDIUM): bullet list と loop の entry 数を一致させ
# (旧版は 5 entry の bullet list が `state-path-resolve.sh を本文で別途言及` する非対称構造で、
# 新規 maintainer が「list に列挙された 5 helper だけ checked される」と誤読する余地があった)。
for _helper in state-path-resolve.sh _resolve-session-id.sh _resolve-session-id-from-file.sh \
               _resolve-schema-version.sh _resolve-cross-session-guard.sh \
               _emit-cross-session-incident.sh; do
  if [ ! -x "$SCRIPT_DIR/$_helper" ]; then
    echo "ERROR: $_helper not found or not executable: $SCRIPT_DIR/$_helper" >&2
    echo "  対処: rite plugin が正しくセットアップされているか確認してください" >&2
    exit 1
  fi
done
unset _helper

# Resolve repository root via the existing helper (single SoT).
# `||` fallback は state-path-resolve.sh が将来 non-zero return する場合の defensive guard。
# stderr は pass-through し、将来 helper が WARNING/ERROR を emit した際に観測可能にする。
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)") || STATE_ROOT="$(pwd)"
LEGACY_FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Argument parsing ---
FIELD=""
DEFAULT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --field)   FIELD="${2:-}"; shift 2 ;;
    --default) DEFAULT="${2:-}"; shift 2 ;;
    --)        shift; break ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$FIELD" ]; then
  echo "ERROR: --field is required" >&2
  exit 1
fi

# Validate field name to keep the jq filter free of injection risk
# (we substitute FIELD as a literal accessor below).
if ! [[ "$FIELD" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
  echo "ERROR: invalid field name: $FIELD" >&2
  exit 1
fi

# --- Signal-specific trap (covers both _classify_err and _jq_err lifecycles) ---
# verified-review F-03 MEDIUM: 単一の cleanup 関数で _classify_err と _jq_err 両方を rm し、
# trap を file 冒頭 (per-session 分岐より前) に install することで両 tempfile の race window
# (mktemp 成功 〜 EXIT/INT/TERM/HUP 受信時) を一貫して closure 化する。canonical pattern
# (_resolve-cross-session-guard.sh / _resolve-session-id-from-file.sh と対称化)。
_classify_err=""
_jq_err=""
_rite_state_read_cleanup() {
  rm -f "${_classify_err:-}" "${_jq_err:-}"
  return 0
}
trap 'rc=$?; _rite_state_read_cleanup; exit $rc' EXIT
trap '_rite_state_read_cleanup; exit 130' INT
trap '_rite_state_read_cleanup; exit 143' TERM
trap '_rite_state_read_cleanup; exit 129' HUP

# --- Resolve session_id (matches flow-state-update.sh _resolve_session_id) ---
# UUID-format validation prevents path traversal via tampered .rite-session-id.
# PR #688 cycle 34 fix (F-01 CRITICAL): UUID validation を `_resolve-session-id.sh` 共通 helper に抽出。
# state-read.sh / flow-state-update.sh / resume-active-flag-restore.sh の 5 site で重複していた
# RFC 4122 strict pattern を 1 箇所に集約し、将来の pattern tightening (variant bit check 等) を
# 片肺更新 drift から守る。
# verified-review cycle 38 F-05 MEDIUM: `tr + _resolve-session-id.sh + fallback` の compound sequence
# 自体も 3 site (本ファイル / flow-state-update.sh / resume-active-flag-restore.sh) で重複していた。
# `_resolve-session-id-from-file.sh` 共通 helper に抽出し、将来「hex normalize / base64 UUID」等の
# 上流動作変更で同型片肺更新 drift が発生しない設計に転換した (writer/reader/resume 3 layer の DRY 化)。
SESSION_ID=$(bash "$SCRIPT_DIR/_resolve-session-id-from-file.sh" "$STATE_ROOT")

# --- Resolve schema_version (DRY: shared helper with flow-state-update.sh) ---
# PR #688 cycle 5 review (code-quality + error-handling 推奨): writer/reader で同一の inline
# schema_version 解決 logic を持っていた drift リスクを排除するため、共通 helper に抽出済。
# pipefail silent failure 対策 (Issue #687 AC-4 follow-up) も helper 内で吸収する。
SCHEMA_VERSION=$(bash "$SCRIPT_DIR/_resolve-schema-version.sh" "$STATE_ROOT")

# --- Resolve target file ---
# Mirror flow-state-update.sh _resolve_session_state_path. Additional fallback:
# when schema_version=2 routes to per-session but that file is absent, fall back
# to legacy if present. This tolerates fresh sessions that have not yet written
# their per-session file but inherit a legacy snapshot from a prior session
# (the read-side counterpart to the writer-side migration path).
if [[ "$SCHEMA_VERSION" == "2" ]] && [[ -n "$SESSION_ID" ]]; then
  STATE_FILE="$STATE_ROOT/.rite/sessions/${SESSION_ID}.flow-state"
  if [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_FLOW_STATE" ]; then
    # verified-review cycle 34 fix (F-02 HIGH): cross-session guard を `_resolve-cross-session-guard.sh`
    # 共通 helper に抽出。writer 側 (flow-state-update.sh `_resolve_session_state_path`) と reader 側
    # (state-read.sh) で重複していた legacy.session_id 抽出 + 比較 + corrupt 判定ロジックを 1 箇所に
    # 集約し、Issue #687 root cause 「writer-side guard を cycle 32 で追加、reader-side guard を
    # cycle 33 で後追い」型の片肺更新 drift を構造的に防ぐ。
    # verified-review cycle 35 fix (F-01 CRITICAL): use 2>/dev/null instead of 2>&1.
    # The 2>&1 was merging helper's stderr (jq parse error text) into the classification
    # string, breaking `case "$classification" in corrupt:*) ...` matching and silently
    # routing to the defensive `*)` arm — suppressing the `legacy_state_corrupt` sentinel
    # emit that Issue #687 was specifically designed to introduce. Helper now keeps stderr
    # clean (cycle 35 fix in _resolve-cross-session-guard.sh), so 2>/dev/null is safe.
    # PR #688 followup: cycle 41 review F-01 HIGH — helper の正当な WARNING (cycle 39 H-02 で
    # _resolve-cross-session-guard.sh:93-98 に追加された mktemp 失敗 WARNING) が `2>/dev/null` で
    # silent suppress される問題を修正。stderr を tempfile に退避し、`^WARNING:` で始まる行のみ
    # caller chain に pass-through する。これにより /tmp full / SELinux deny 環境で helper 側の
    # 詳細が両層で失われる二重 silent failure を防ぐ (writer/reader 対称化 doctrine と整合)。
    #
    # cycle 43 F-09 (MEDIUM) 対応: _classify_err mktemp 失敗時の silent fallback を canonical pattern
    # (`if ! ... then` + WARNING 3 行 + chmod 600) に揃える。旧実装 `|| _classify_err=""` は
    # mktemp 失敗 (/tmp full / permission denied / SELinux deny) を WARNING なしで silent fallback し、
    # 後続の `2>"${_classify_err:-/dev/null}"` で helper の WARNING (cycle 39 H-02 で追加) が消える
    # 入れ子の silent failure になっていた (cycle 41 F-01 のコメント「pass-through する」と乖離)。
    # 他 5 helper (state-read.sh _jq_err / _resolve-cross-session-guard.sh / flow-state-update.sh ×2 /
    # resume-active-flag-restore.sh / _resolve-session-id-from-file.sh _tr_err — cycle 43 F-08 で対称化済み)
    # の canonical pattern と統一する。trap 統合は別 Issue で追跡 (実行時間が短いため race window 小)。
    # verified-review cycle 44 F-14 LOW (security Hypothetical exception): ${TMPDIR:-/tmp} で
    # POSIX 慣習を尊重 (SELinux / hardened multi-user 環境での per-user tempdir 隔離に対応)。
    if ! _classify_err=$(mktemp "${TMPDIR:-/tmp}/rite-classify-err-reader-XXXXXX" 2>/dev/null); then
      echo "WARNING: state-read.sh: _classify_err mktemp に失敗しました (/tmp full / permission denied / SELinux deny?)" >&2
      echo "  影響: cross-session guard helper の WARNING (mktemp 失敗 / jq stderr) が pass-through されません" >&2
      echo "  対処: /tmp の空き容量・パーミッションを確認してください" >&2
      _classify_err=""
    fi
    # path-disclosure defense (cycle 41 F-14 と対称化、multi-user 環境で session_id leak 防止)
    [ -n "$_classify_err" ] && chmod 600 "$_classify_err" 2>/dev/null || true
    # verified-review F-11 LOW (defense-in-depth): `|| true` で helper の想定外 exit を完全に
    # 握り潰すと、helper の design contract (`exit 0 — always`) が将来 regression したときに
    # silent fail する。`|| _guard_rc=$?` で rc を捕捉し、非 0 時には WARNING を emit する。
    # writer 側 (flow-state-update.sh:186) との対称化を維持する原則 (本 helper の writer/reader
    # 対称化 doctrine) に従い、両者で同じ patron に揃える将来 fix も追跡する。
    if classification=$(bash "$SCRIPT_DIR/_resolve-cross-session-guard.sh" "$LEGACY_FLOW_STATE" "$SESSION_ID" 2>"${_classify_err:-/dev/null}"); then
      :
    else
      _guard_rc=$?
      echo "WARNING: _resolve-cross-session-guard.sh exited non-zero (rc=$_guard_rc) — design contract violation (helper should always exit 0)" >&2
      classification=""
    fi
    if [ -n "$_classify_err" ] && [ -s "$_classify_err" ]; then
      grep -E '^WARNING:|^  ' "$_classify_err" >&2 2>/dev/null || true
    fi
    [ -n "$_classify_err" ] && rm -f "$_classify_err"
    unset _classify_err
    # PR #688 followup F-01 MEDIUM: foreign:* / corrupt:* / invalid_uuid:* arm の workflow-incident-emit.sh
    # 呼び出しブロックを `_emit-cross-session-incident.sh` helper に集約。reader/writer × 3 classification の
    # 6 ブロック (~84 行) が semantically identical だった drift リスクを排除する。
    case "$classification" in
      same|empty)
        STATE_FILE="$LEGACY_FLOW_STATE"
        ;;
      foreign:*)
        # 別 session の legacy file → foreign session の stale data を silent return しないよう DEFAULT に降格
        legacy_sid="${classification#foreign:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" foreign reader "$SESSION_ID" "$legacy_sid"
        echo "$DEFAULT"
        exit 0
        ;;
      corrupt:*)
        # jq 失敗 (corrupt JSON / IO error) → take over は不安全 (cross-session の可能性を否定できない)
        jq_rc="${classification#corrupt:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" corrupt reader "$SESSION_ID" "$LEGACY_FLOW_STATE" "$jq_rc"
        echo "$DEFAULT"
        exit 0
        ;;
      invalid_uuid:*)
        # legacy.session_id が JSON-parseable だが UUID validation 失敗 (tampered / legacy schema)。
        # corrupt:* と semantically 等価だが root_cause_hint で incident response 時に区別可能にする。
        invalid_uuid_rc="${classification#invalid_uuid:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" invalid_uuid reader "$SESSION_ID" "$LEGACY_FLOW_STATE" "$invalid_uuid_rc"
        echo "$DEFAULT"
        exit 0
        ;;
      *)
        # Helper の出力が想定外 (defensive) — fail-safe に DEFAULT 降格
        echo "WARNING: unexpected classification from _resolve-cross-session-guard.sh: $classification" >&2
        echo "$DEFAULT"
        exit 0
        ;;
    esac
  fi
else
  STATE_FILE="$LEGACY_FLOW_STATE"
fi

# --- Read field ---
# F-C MEDIUM (PR #688 cycle 5 review test reviewer 推奨): 空ファイル / 非 JSON ファイルの edge case
# 旧実装は file 存在チェックのみで、空ファイル (`touch .rite-flow-state` 等) や非 JSON ファイル
# (例: 別プロセスが書き込み中) の場合に jq が exit 0 + 空出力を返す → caller default が
# 効かず空文字列を silent return する経路があった。`[ -s "$STATE_FILE" ]` (size > 0) を追加して
# 空ファイル時も DEFAULT に落とす (corrupt JSON 経路と挙動を一致させる)。
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
  echo "$DEFAULT"
  exit 0
fi

# Pass DEFAULT through jq's --arg so quoting/escaping is handled by jq.
# FIELD has been validated as [a-zA-Z_][a-zA-Z0-9_]* so direct interpolation
# into the filter is safe. This helper is read-only — no object construction
# (the silent-reset failure mode of writer-side jq is not applicable here).
#
# JSON null handling: jq's `// $default` operator returns $default when the
# left-hand side is null or false. So `.field // $default` evaluates to
# $default when:
#   - field is missing (jq returns null)
#   - field exists but holds JSON null
#   - field exists but holds JSON false
# This matches the caller-supplied default semantics natively — no
# post-processing is needed. (PR #688 cycle 3 review: previous post-processing
# `if [ "$value" = "null" ]` was demonstrated to be dead code via mutation
# testing; jq's `//` already handles null normalization.)
#
# ⚠️ Boolean field caveat (PR #688 cycle 5 review): jq の `// $default` は **null と
# false の両方** を $default に置換するため、本 helper は boolean field の読み取りには
# **使ってはいけない**。例: `{"active": false}` を `--default true` で読むと結果は "true"
# となり、stored false が silent に default に置換される。現状の caller (`parent_issue_number`
# / `phase` / `loop_count` / `implementation_round` / `pr_number`) はすべて非 boolean のため影響なし。
# 将来 boolean field を読む caller を追加する場合は `--default empty` で明示的に取得して
# 別途分岐するか、inline jq を使うこと。
#
# verified-review cycle 34 fix (F-11 MEDIUM): mechanical guard を追加。`--default true` / `--default false`
# が指定された場合、boolean field 読み取り意図の可能性が高いので WARNING を emit する (誤呼出経路の
# silent regression を防ぐ defense-in-depth)。
case "$DEFAULT" in
  true|false)
    echo "WARNING: state-read.sh: --default '$DEFAULT' は boolean リテラル値です。boolean field の読み取りには本 helper を使わないでください (jq の \`// \$default\` 演算子が JSON null と false の両方を default に置換するため、stored false が silent に true に置換される regression を起こします)。non-boolean field (parent_issue_number / phase / loop_count / pr_number 等) のみが現状サポート対象です。boolean field が必要な場合は \`--default empty\` を使い caller 側で明示分岐するか、inline jq を使ってください。" >&2
    ;;
esac
#
# Source: jq Manual — Alternative operator `//`
# https://jqlang.org/manual/#alternative-operator
#
# verified-review cycle 35 fix (F-09 LOW): expose jq stderr via tempfile instead of suppressing
# with 2>/dev/null. Previous behavior swallowed jq parse errors silently, making corrupt JSON
# detection impossible to debug (operator could not distinguish "field absent" from
# "file corrupt"). Symmetric with `_resolve-cross-session-guard.sh`'s jq stderr capture pattern
# (cycle 33 F-04 / cycle 34 F-07 fixes).
# verified-review cycle 38 F-04 MEDIUM: 旧コメントは「Symmetric with state-read.sh L58」と本ファイル自身
# の `--field arg parser` ブロック (jq stderr capture とは無関係) を誤参照していた self-referential drift。
# 意図したのは `_resolve-cross-session-guard.sh` の jq stderr capture 経路 (`legacy_sid=$(jq ... 2>"$jq_err")`)
# で、cycle 33 F-04 / cycle 34 F-07 fix 系列はそちらのパターンを確立した。本 PR が警戒する
# "self-referential drift fractal pattern" の再発を修正。
#
# verified-review F-03 MEDIUM: trap install は file 冒頭の `--- Signal-specific trap ---` セクションに
# 移動済 (`_classify_err` と `_jq_err` を共通の `_rite_state_read_cleanup` 関数で cleanup する)。
# 旧実装は本箇所で `_jq_err` 専用の trap を install し、`_classify_err` (line 157 area) は
# trap 不在の race window を残していた。canonical pattern (cycle 35 F-05 / 36 F-15) と統一。
# verified-review cycle 38 F-06 MEDIUM: mktemp 失敗時に WARNING emit。
# 旧実装は `2>/dev/null || _jq_err=""` で mktemp 失敗 (/tmp full / permission denied / SELinux deny) を
# silent fallback し、後続の `2>"${_jq_err:-/dev/null}"` で jq stderr が `/dev/null` に redirect される
# 二重 silent failure になっていた (jq 失敗時の `head -3 _jq_err` 観測経路が無効化される)。
# resume-active-flag-restore.sh の mktemp 失敗 WARNING 経路と writer/reader 対称化。
if ! _jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-state-read-jq-err-XXXXXX" 2>/dev/null); then
  echo "WARNING: state-read.sh: stderr 退避用 tempfile の mktemp に失敗しました (/tmp full / permission denied / SELinux deny?)" >&2
  echo "  影響: jq 失敗時の parse error 詳細が表示されません (caller は corrupt JSON を検知できますが原因 line/column が失われます)" >&2
  echo "  対処: /tmp の空き容量・パーミッションを確認してください" >&2
  _jq_err=""
fi
# PR #688 followup: cycle 41 review F-14 LOW (security Hypothetical exception) — defense-in-depth
# として chmod 600 を upfront 適用 (BSD mktemp は umask 依存で 0644 になる経路がある)。
# multi-user 環境で jq stderr 内の絶対 path / session_id leak (path-disclosure) を防ぐ。
[ -n "$_jq_err" ] && chmod 600 "$_jq_err" 2>/dev/null || true
if value=$(jq -r --arg default "$DEFAULT" ".${FIELD} // \$default" "$STATE_FILE" 2>"${_jq_err:-/dev/null}"); then
  :
else
  value="$DEFAULT"
  [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | sed 's/^/  WARNING: jq parse: /' >&2
fi

echo "$value"
