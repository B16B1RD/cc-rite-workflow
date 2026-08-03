#!/bin/bash
# rite workflow - Work Memory Update (shared helper)
# Provides a function to update local work memory files (.rite-work-memory/issue-{n}.md).
# Handles: lock acquisition, YAML frontmatter parsing, atomic file write, lock release.
#
# Usage (source from another script or inline):
#   source {plugin_root}/hooks/work-memory-update.sh
#   WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
#     WM_NEXT_ACTION="rite:lint を実行" WM_BODY_TEXT="Post-implementation." \
#     WM_PLUGIN_ROOT="/path/to/plugin" \
#     update_local_work_memory
#
# Required environment variables:
#   WM_SOURCE       - Source identifier (e.g., "implement", "lint", "fix")
#   WM_PHASE        - Phase value (e.g., "lint", "implement", "pr", "review", "fix"; see PHASE_ENUM_V3 in flow-state.sh for the flat phase enum)
#   WM_PHASE_DETAIL - Phase detail description
#   WM_NEXT_ACTION  - Next action description
#   WM_BODY_TEXT    - Body text after YAML frontmatter closing --- (サマリー領域のみ。
#                     既存ファイルの `## Detail` 以下の蓄積内容は更新時に保持される —
#                     stock の先頭 Phase:/Branch: 行のみ最新値で再生成)
#   WM_PLUGIN_ROOT  - Absolute path to the plugin root directory
#
# Optional environment variables:
#   WM_ISSUE_NUMBER         - Override issue number detection (skip branch-based parsing).
#                             Use when the caller already knows the issue number (e.g., pre-compact).
#                             (default: extracted from branch name)
#   WM_SKIP_LOCK            - If "true", skip lock acquisition/release. Use when the caller
#                             already holds an outer lock protecting the work memory file.
#                             (default: "false")
#   WM_PR_NUMBER            - PR number override. Effective only when WM_READ_FROM_FLOW_STATE != "true";
#                             otherwise the value is read from flow-state (lint pattern).
#                             (default: carried forward from the existing WM — except the flow-state
#                             "PR not created" sentinel 0, which is NOT carried forward and falls back
#                             to "null"; else "null")
#   WM_LOOP_COUNT           - Loop count override. Same effective conditions as WM_PR_NUMBER.
#                             (default: carried forward from the existing WM, else 0. Unlike
#                             WM_PR_NUMBER there is no 0 exclusion — 0 is a real value here.)
#
#   Carry-forward fires only when the variable is unset or empty. Any non-empty value suppresses
#   it, including the literal string "null" (which some callers pass when flow-state cannot be
#   resolved) — such a call writes null and does NOT fall back to the existing WM value.
#   It is also suppressed when the existing WM parses as corrupt with an issue_number_mismatch,
#   or with an unreadable error kind: carrying those forward would transcribe another Issue's
#   values into this one.
#
#   Both fields pass through numeric validation before being written, whichever path above
#   supplied the value: a value containing a non-digit character is demoted to the YAML literal
#   null with a WARNING on stderr; an empty value or the literal "null" — whichever path supplied
#   it — is written as null without a WARNING.
#
#   WM_REQUIRE_FLOW_STATE   - If "true", skip if flow-state phase cannot be resolved via
#                             flow-state.sh (per-session and legacy file both absent, or phase
#                             is null/empty). Uses flow-state.sh under the hood so schema_version=2
#                             per-session files are resolved transparently. (default: "false")
#   WM_READ_FROM_FLOW_STATE - If "true", read pr_number/loop_count from .rite-flow-state (lint pattern).
#                             When set, overrides WM_PR_NUMBER/WM_LOOP_COUNT and values from existing WM.
#                             (default: "false")
#
# Observability note:
#   本 helper が stderr へ出す WARNING (値の読み戻し不能 / corrupt 判定からの carry-forward /
#   数値バリデーション降格 / Detail 抽出失敗) は、いずれも縮退時に rc=0 を返す経路で出る。
#   したがって rc で表示を分岐する呼び出し形では捕捉できず、stderr 自体を捨てる呼び出し形にも
#   届かない。届くのは本 helper の stderr をそのまま伝播させる起動元とテストに限られる。
#   stderr 退避形へ揃えるだけでは解決せず、rc ゲートを外す設計判断が別途要る (本 helper の管轄外)。
#
# Security note:
#   WM_* 環境変数の sanitize は caller 責務とする設計だったが、orchestrator 経由で LLM 出力 / Issue
#   タイトル / next_action 等の動的文字列が直接 frontmatter に流入する経路があり defense-in-depth が
#   不在だった。そこで `_sanitize_yaml_value()` helper を導入し、frontmatter 書き込み箇所すべてで
#   適用する (`"` を `\"` に escape、改行を除去)。WM_BODY_TEXT は frontmatter 外なので除外。
#   caller 責務は引き続き有効 (helper は defense-in-depth の二段目)。
#
# Exit codes:
#   0: Success (work memory updated)
#   1: Skipped (no issue number in branch or flow state required but missing)
#   2: Lock acquisition failed (non-fatal, logged as warning)

# Source lock helper at file load time (not inside the function)
# This avoids re-sourcing on every function call and prevents BASH_SOURCE issues.
source "$(dirname "${BASH_SOURCE[0]}")/work-memory-lock.sh"
# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

# verified-review F-04 MEDIUM: flow-state.sh 呼び出し boilerplate を helper 関数に抽出。
# (a) helper executable check と (b) `if cmd; then :; else rc=$?; ...; return 2; fi` 形式の
# fail-fast capture は本ファイル内の複数 site で同一構造になるため、共通 helper に集約して
# spec 変更を 1 箇所で完結させる。
#
# verified-review F-05 (MEDIUM): 本 helper の集約スコープは work-memory-update.sh 内 3 site のみ。
# resume layer の 2 site (resume-active-flag-restore.sh の curr_phase / curr_next 抽出ブロック) は
# **この helper では consolidate しない**。したがって resume layer の片肺更新リスクは別 Issue で
# 追跡する必要がある (「writer/reader/resume 3 layer DRY 化」を謳わないこと — 実装と整合させる)。
#
# Arguments:
#   $1 var_name  caller 側で値を受け取る変数名 (e.g., "_phase")
#   $2 field     flow-state.sh の --field に渡す値 (e.g., "phase" / "pr_number" / "loop_count")
#   $3 default   flow-state.sh の --default に渡す値 (e.g., "" / "null" / "0")
# Returns:
#   0 — success (var_name に値が代入される)
#   2 — helper 不在 / helper exit != 0 (fail-fast)
_wm_state_read_field() {
  local _var_name="$1"
  local _field="$2"
  local _default="$3"
  if [ ! -x "$WM_PLUGIN_ROOT/hooks/flow-state.sh" ]; then
    echo "rite: ${WM_SOURCE}: flow-state.sh not found at $WM_PLUGIN_ROOT/hooks/" >&2
    return 2
  fi
  local _val _rc
  if _val=$(bash "$WM_PLUGIN_ROOT/hooks/flow-state.sh" get --field "$_field" --default "$_default"); then
    printf -v "$_var_name" '%s' "$_val"
    return 0
  else
    _rc=$?
    echo "rite: ${WM_SOURCE}: flow-state.sh failed (rc=$_rc) for --field $_field" >&2
    return 2
  fi
}

update_local_work_memory() {
  local issue_number current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  issue_number="${WM_ISSUE_NUMBER:-}"
  if [ -n "$issue_number" ] && ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "rite: ${WM_SOURCE:-work-memory-update}: invalid WM_ISSUE_NUMBER: $issue_number" >&2
    issue_number=""
  fi
  if [ -z "$issue_number" ]; then
    issue_number=$(echo "$current_branch" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
  fi
  if [ -z "$issue_number" ]; then
    return 1
  fi

  # legacy `.rite-flow-state` 直接 `[ ! -f ]` check を flow-state.sh 経由に変更
  # (caller migration of legacy flow-state reads)。
  # cycle 10 で WM_READ_FROM_FLOW_STATE 分岐の同種 read を移行済みだが、本箇所
  # (WM_REQUIRE_FLOW_STATE check) は cycle 11 review で取り残しが指摘された。
  # (verified-review cycle 29 F-04 MEDIUM: cycle 28 で確立した semantic anchor 規範を本箇所
  # にも適用。旧 "line 130 / line 72" は code shift で drift 済み)
  # schema_version=2 環境で per-session file (`.rite/sessions/{sid}.flow-state`)
  # のみ存在し legacy file 不在のとき、旧 check は false negative で skip し work memory が更新されない
  # (例: lint pattern で session 起点の caller が WM_REQUIRE_FLOW_STATE=true を渡しても skip される)。
  # flow-state.sh は per-session/legacy 両方を transparent に解決し、両方不在時のみ default ("") を
  # 返すため、空文字判定で「flow-state が解決できない」状態を正確に検出できる。
  #
  # verified-review cycle 33 fix (F-01 HIGH): flow-state.sh 起動失敗 (ENOENT / WM_PLUGIN_ROOT 不正 /
  # permission denied 等) が「両 file 不在 → DEFAULT 返却」と区別不能で silent skip される regression
  # を解消する。helper が **存在しない** ケースは return 2 で fail-fast、**存在するが exit != 0** の
  # ケース (jq エラー / 内部失敗) も独立 exit code 捕捉で fail-fast。**存在し exit == 0 だが空文字**
  # のみが legitimate な「両 file 不在」として return 1 で skip される (Fail-Fast First 原則)。
  if [ "${WM_REQUIRE_FLOW_STATE:-false}" = "true" ]; then
    local _phase=""
    _wm_state_read_field _phase phase "" || return $?
    if [ -z "$_phase" ]; then
      return 1
    fi
  fi

  local local_wm=".rite-work-memory/issue-${issue_number}.md"
  local lockdir="${local_wm}.lockdir"

  # Defensive: ensure parent directory exists before lock acquisition
  mkdir -p .rite-work-memory 2>/dev/null || { echo "rite: ${WM_SOURCE}: failed to create .rite-work-memory directory" >&2; return 2; }
  chmod 700 .rite-work-memory 2>/dev/null || true

  if [ "${WM_SKIP_LOCK:-false}" = "true" ]; then
    :  # Lock skipping; RETURN trap set later in this function after mktemp (anchor: tmp_wm_mktemp below)
  else
    WM_LOCK_STALE_THRESHOLD="${WM_LOCK_STALE_THRESHOLD:-300}"

    if ! acquire_wm_lock "$lockdir"; then
      echo "rite: ${WM_SOURCE}: local work memory lock failed" >&2
      return 2
    fi

    # Ensure lock is released on function return (normal or abnormal exit)
    trap 'release_wm_lock "$lockdir"' RETURN
  fi

  local sync_rev=1
  local loop_cnt="${WM_LOOP_COUNT:-0}"
  local pr_num="${WM_PR_NUMBER:-null}"
  local parse_script="${WM_PLUGIN_ROOT}/hooks/work-memory-parse.py"

  # 既存ファイルの値の読み戻し。sync_revision の increment に加え、pr_number / loop_count を
  # carry-forward する — env override も flow-state 読み取りも伴わない更新経路では、読み戻さない
  # 限り更新のたびに既定値へ巻き戻り、work-memory-format.md の field 定義が宣言する意味を実ファイル
  # が満たせない。下の -z ガードが見るのは env 変数の空 / 非空だけで、渡された値が実値か placeholder
  # かは判定しない (caller を列挙して説明しない — call site が増えるたびに記述が偽になるため)。
  if [ -f "$local_wm" ] && [ -f "$parse_script" ]; then
    # work-memory-parse.py は corrupt 判定 (missing_keys / issue_number_mismatch) でも .data を
    # 埋めたうえで exit 2 を返す。よって exit code ではなく stdout の有無で採否を決める
    # (exit code で捨てると当該ファイルの sync_revision が 1 へ巻き戻り、版が逆行する)。
    # `|| _parse_rc=$?` であって `|| parse_out=""` ではない: 代入は `||` の評価前に完了するので
    # stdout は保持され、非ゼロ exit だけを飲む。`|| parse_out=""` にすると corrupt 判定ファイルの
    # .data ごと捨てて sync_revision を巻き戻す。ガード自体が要るのは、`set -e` 下で本 helper を
    # source する呼び出し形に更新継続を依存させないため。
    # python3 と jq の stderr は共通の tempfile へ退避する。両方を捨てると下の読み戻し不能 WARNING が
    # 根因へ辿る唯一の経路になるため (post-tool-wm-sync.sh の同型 pipeline が
    # "masquerading as a successful-but-empty parse" を防ぐ目的で同じ退避を行っている)。
    # mktemp 失敗時は /dev/null へ倒し、WARNING に stderr_capture=disabled を付けて
    # 「stderr が無かった」と「stderr を失った」を区別できるようにする。
    local parse_out="" _parse_rc=0 _parse_err=""
    _parse_err=$(mktemp 2>/dev/null) || _parse_err=""
    parse_out=$(python3 "$parse_script" "$local_wm" 2>"${_parse_err:-/dev/null}") || _parse_rc=$?
    # `_jq_rc` の初期値は「未起動」を表す非数値 sentinel。`0` で初期化すると、parse_out が空で jq が
    # 一度も起動しない経路でも WARNING が `jq rc=0` を出し、未起動の段を「起動して成功した」と断定する
    # (下の分離コメントが避けようとしている誤誘導の鏡像)。
    local parsed="" _jq_rc="n/a"
    if [ -n "$parse_out" ]; then
      # 4 field を 1 回の jq で取り出し、python3 プロセスの追加起動を避ける。末尾の `.data` 要素数が
      # 「carry-forward の材料が実際にあるか」の判定値 — 前 3 field は `//` 既定値を持つため、
      # .data が空でも非空文字列になり判定には使えない。
      # jq の rc は python3 の rc と別変数で捕捉する。同一変数に畳むと、jq が失敗した経路で
      # WARNING が `parse rc=0` を表示し「前段は成功した」と能動的に否定して triage を誤誘導する
      # (parse 失敗と jq 失敗は別条件なので診断も分離する)。
      # 区切りは `@tsv` ではなく `join("\u001f")` — tab は IFS whitespace として畳まれるため、
      # 空 field が出た瞬間に後続の列が左へずれる (peer hook 3 本が同じ理由で 0x1f を使う。
      # post-compact.sh は「空 next_action が PR field をブランチ名で汚染した」実害を記録している)。
      # `.errors` を同じ read に載せるのは、corrupt の**種別**が carry-forward の可否を決める入力
      # だから (下の `_carry_block`)。clamp も jq 側の `.[0:200]` で行う — pipeline 末尾の
      # `head -c` は上流 jq を SIGPIPE で殺し、pipefail を張る caller (pre-compact.sh /
      # post-tool-wm-sync.sh) では巨大 errors のときだけ種別が丸ごと失われる。改行は read が
      # 1 行しか読まないため jq 側で潰す。
      parsed=$(printf '%s' "$parse_out" \
        | jq -r '[(.data.sync_revision // 0), (.data.pr_number // "null"), (.data.loop_count // 0), (.data | length), ((.errors // []) | join("; ") | gsub("[\n\r]"; " ") | .[0:200])] | join("\u001f")' 2>>"${_parse_err:-/dev/null}") && _jq_rc=0 || { _jq_rc=$?; parsed=""; }
    fi
    local existing_rev=0 existing_pr="" existing_loop="" existing_keys=0 existing_errors=""
    if [ -n "$parsed" ]; then
      IFS=$'\x1f' read -r existing_rev existing_pr existing_loop existing_keys existing_errors <<< "$parsed"
    fi
    # 縮退を silent に飲むと、sync_revision が 1 へ巻き戻ったことが「もともと版が無かった」と
    # 区別できない。non-blocking は維持しつつ WARNING で観測性を確保する (下段 detail_extra awk と
    # 同形)。**この読み戻し不能 WARNING の射程は .data 全体が空の場合に限る** — 判定が .data の
    # 要素数 1 本なので、非必須 key だけの欠落 (例: pr_number 行だけが読めない) は parse が rc=0 を
    # 返し .data も非空になるため、無警告で既定値へ倒れる。必須 key (schema_version / issue_number /
    # sync_revision) の欠落は parse が corrupt を返すので、下の corrupt WARNING 側が拾う。
    # **本 WARNING の条件には** parse の rc を使わない (rc を条件にすると、carry-forward が成功する
    # corrupt 系統でも発火して誤報になる)。rc を条件に使うのは下の corrupt WARNING 側。
    # 文面が断定するのは sync_revision だけに留める — pr_number / loop_count は本ブロックより後段の
    # env override / flow-state 読み取りが最終値を決めるため、ここでは既定値化を断定できない。
    if [ "$existing_keys" -eq 0 ]; then
      local _rb_tag=""
      [ -z "$_parse_err" ] && _rb_tag=" stderr_capture=disabled"
      echo "WARNING: 既存 WM から値を読み戻せませんでした ($local_wm, parse rc=$_parse_rc, jq rc=$_jq_rc${_rb_tag}) — sync_revision を 1 から採番し直します (pr_number / loop_count は env override も flow-state 読み取りも無い場合のみ既定値へ倒れます)" >&2
      # 先頭ではなく末尾を出す。python3 の未捕捉例外は traceback の**最終行**に例外メッセージを
      # 載せるため、`head -3` だと根因が構造的に落ちて `Traceback (most recent call last):` と
      # フレームだけが残る。1 行 stderr の site では tail でも同じ 1 行が出る。
      [ -n "$_parse_err" ] && [ -s "$_parse_err" ] && tail -3 "$_parse_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    else
      # corrupt 判定 (rc 非ゼロ) でも .data が埋まっていればここへ来る。verdict を握り潰すと
      # 「corrupt と判定されたファイルを材料に処理を続けた」ことがどこにも残らない。上の読み戻し
      # 不能 WARNING とは別文面にして、両者を混同せず切り分けられるようにする。
      # 文面は発火条件が保証している事実だけに留める — 実際に carry-forward されるかは後段の
      # env override / flow-state 読み取り次第で、この時点では断定できない。
      # corrupt verdict は種別を問わず exit 2 に畳まれるため、rc だけでは missing_keys (carry-forward が
      # 正当な系統) と issue_number_mismatch (.data が別 Issue のもので、carry-forward が他 Issue の
      # pr_number を転写する系統) を切り分けられない。種別で carry-forward の可否を分ける。
      # 種別が読めないときも止める (fail-closed) — 判別できない材料を採ると、転写が起きたかどうかを
      # 後から知る手段が無い。同じ書き込みが issue_number をファイル名側の値へ直すため、次回の
      # parse は valid 判定になり痕跡も消える。
      local _carry_block=0
      if [ "$_parse_rc" -ne 0 ]; then
        case "$existing_errors" in
          *issue_number_mismatch*|"") _carry_block=1 ;;
        esac
        # corrupt ファイル由来の文字列を stderr へ出すため中和する (生 echo は _sanitize_yaml_value が
        # 塞いでいる制御文字経路を再び開く)。長さの clamp は上の jq が済ませている。
        local _corrupt_reasons
        _corrupt_reasons=$(printf '%s' "$existing_errors" | neutralize_ctrl --c0-only) || _corrupt_reasons=""
        [ -n "$_corrupt_reasons" ] || _corrupt_reasons="(種別不明)"
        local _block_tag=""
        [ "$_carry_block" -eq 1 ] && _block_tag=" — 種別が issue_number_mismatch または判別不能のため carry-forward は行いません (既定値へ倒します)"
        echo "WARNING: 既存 WM は corrupt 判定 (parse rc=$_parse_rc, errors: $_corrupt_reasons) ですが .data が読めたため処理を継続しました ($local_wm)${_block_tag}" >&2
      fi
      if [[ "$existing_rev" =~ ^[0-9]+$ ]]; then sync_rev=$((existing_rev + 1)); fi
      # carry-forward は env override が無いときだけ発火させる。未設定判定に `-z` を使うのは
      # 上の初期化が `${WM_PR_NUMBER:-null}` 形式で「空文字 = 未設定」と扱っているため
      # (`${VAR+set}` では空文字セットの扱いが初期化側と食い違う)。
      # `0` は flow-state が「PR 未作成」を表すのに使う sentinel で、skill 側が `--pr 0` を書き
      # (全数は `grep -rn -- "--pr 0" plugins/rite/skills/`)、`WM_READ_FROM_FLOW_STATE` 経路が
      # それを WM へ運ぶ。carry-forward がこれを実値として拾うと、work-memory-format.md が
      # `null if not created` と定義する状態を表現できないまま `pr_number: 0` が恒久化する
      # (carry-forward 導入前は次の通常更新で `null` へ戻っていた)。実 PR 番号が 0 になることは
      # ないので AC-1 の保持対象は失わない。
      # loop_count 側に同じ除外を置かないのは、そちらの `0` が「まだ 1 周もしていない」という実値だから。
      if [ "$_carry_block" -eq 0 ] && [ -z "${WM_PR_NUMBER:-}" ] && [ -n "$existing_pr" ] && [ "$existing_pr" != "0" ]; then
        pr_num="$existing_pr"
      fi
      if [ "$_carry_block" -eq 0 ] && [ -z "${WM_LOOP_COUNT:-}" ] && [ -n "$existing_loop" ]; then
        loop_cnt="$existing_loop"
      fi
    fi
    [ -n "$_parse_err" ] && rm -f "$_parse_err"
  fi

  # Read flow-state fields if requested (lint pattern).
  # legacy `.rite-flow-state` 直接読みを
  # flow-state.sh 経由に変更。schema_version=2 環境では flow-state.sh が per-session file を解決
  # するため、別 session の stale residue を読まなくなる。flow-state.sh は per-session/legacy
  # 両方を transparent に解決し、両方不在時は default を返すので、外側の `[ -f ]` check は不要。
  #
  # verified-review cycle 33 fix (F-01 HIGH): WM_REQUIRE_FLOW_STATE 経路と対称化。helper 存在性 +
  # exit code を独立 capture して silent skip を防ぐ (Fail-Fast First 原則)。`|| pr_num="null"` と
  # `|| loop_cnt="0"` の旧 fallback パターンは「両 file 不在 → DEFAULT 返却」と「helper 起動失敗」を
  # 区別不能で silent fallback していたため fail-fast に変更。
  if [ "${WM_READ_FROM_FLOW_STATE:-false}" = "true" ]; then
    _wm_state_read_field pr_num pr_number "null" || return $?
    _wm_state_read_field loop_cnt loop_count 0 || return $?
  fi

  local last_commit tmp_wm
  local branch="$current_branch"
  last_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  # anchor: tmp_wm_mktemp (referenced by lock-skip path comment above)
  tmp_wm=$(mktemp "${local_wm}.tmp.XXXXXX") || { echo "rite: ${WM_SOURCE}: mktemp failed" >&2; return 2; }
  # Extend RETURN trap to also clean up temp file (rm -f is safe even after successful mv)
  if [ "${WM_SKIP_LOCK:-false}" = "true" ]; then
    trap 'rm -f "$tmp_wm"' RETURN
  else
    trap 'rm -f "$tmp_wm"; release_wm_lock "$lockdir"' RETURN
  fi

  # YAML frontmatter 値の defense-in-depth sanitization。改行除去 + backslash escape + `"` を `\"` に escape して
  # frontmatter 破損 / 子 key injection を防ぐ (caller 責務に加えた二段目の防御層)。
  # WM_BODY_TEXT は frontmatter 外なので除外 (markdown body は改行を保持する必要がある)。
  #
  # verified-review cycle 44 F-12 MEDIUM (security Hypothetical exception):
  # backslash escape を追加。値が `\` で終わる場合、YAML double-quoted string では
  # closing `"` が `\"` の escape sequence と解釈されて閉じクォート消失 → 後続の
  # `phase_detail: "..."` 行を value continuation として誤 parse する経路があった。
  # 例: WM_PHASE='foo\' → `phase: "foo\"` → escaped quote → continuation。
  # まず backslash を `\\` に escape してから `"` → `\"` の順で sed を実行する
  # (順序逆転すると新たに作った escape sequence の `\` が更に escape されてしまう)。
  # tr -d '[:cntrl:]' に拡張し、tab / BEL (0x07) / DEL (0x7F) 等の他制御文字も strip する。
  # _resolve-session-id-from-file.sh の superset cntrl char strip 規範と対称化
  # (tab / BEL を含む caller-supplied 値が frontmatter の
  # double-quoted string に literal で混入する経路を遮断する)。
  _sanitize_yaml_value() {
    printf '%s' "$1" | tr -d '[:cntrl:]' | sed 's/\\/\\\\/g; s/"/\\"/g'
  }
  # 数値フィールド (pr_num / loop_cnt) の YAML literal 化 helper。flow-state.sh 経由で取得される
  # 値に改行 / 制御文字 / その他非数値が混入していた場合 (tampered/corrupt な flow-state file の防御)、
  # `null` (YAML literal) に降格して frontmatter parse の破壊を防ぐ。
  # 引数: $1 = 値, $2 = フィールド名 (WARNING に出力)。stdout に YAML literal を出力。
  _validate_numeric_yaml_value() {
    local _v="$1" _name="$2"
    case "$_v" in
      ''|null) printf 'null'; return 0 ;;
    esac
    case "$_v" in
      *[!0-9]*)
        echo "WARNING: $_name contains non-numeric character (probable YAML injection attempt or state corruption), forcing 'null'" >&2
        printf 'null'
        return 0
        ;;
    esac
    printf '%s' "$_v"
  }
  local _wm_phase_san _wm_phase_detail_san _wm_next_san _wm_source_san _branch_san _last_commit_san
  _wm_phase_san=$(_sanitize_yaml_value "$WM_PHASE")
  _wm_phase_detail_san=$(_sanitize_yaml_value "$WM_PHASE_DETAIL")
  _wm_next_san=$(_sanitize_yaml_value "$WM_NEXT_ACTION")
  _wm_source_san=$(_sanitize_yaml_value "$WM_SOURCE")
  _branch_san=$(_sanitize_yaml_value "$branch")
  _last_commit_san=$(_sanitize_yaml_value "$last_commit")

  # verified-review F-04 (MEDIUM) 対応 + post-review F-01 (MEDIUM) DRY 化:
  # pr_num / loop_cnt は flow-state.sh 経由で flow-state JSON から取得されるが、jq -r は raw string を
  # 返すため、tampered/corrupt な flow-state file (例: `{"pr_number": "123\nmalicious: injection"}`) で
  # 改行込みの値が返ると YAML frontmatter parse が破壊される。
  # 数値型 validation を _validate_numeric_yaml_value() helper に集約し、新規数値フィールド追加時の
  # 片肺更新リスクを構造的に解消した (本 PR review F-01)。
  local _pr_num_san _loop_cnt_san
  _pr_num_san=$(_validate_numeric_yaml_value "$pr_num" pr_num)
  _loop_cnt_san=$(_validate_numeric_yaml_value "$loop_cnt" loop_cnt)

  # 蓄積セクション保持: `## Detail` 以下は自由記述の置き場 (work-memory-format.md の local
  # File Structure 定義) のため、body 全置換するとフェーズ遷移のたびに追記内容が消える。
  # stock の先頭 `Phase:` / `Branch:` 行のみ最新値で再生成し、それ以外の自由記述内容を
  # verbatim で引き継ぐ (WM_BODY_TEXT はサマリー領域のみを対象とする契約)。
  local detail_extra="" _detail_awk_rc=0
  if [ -f "$local_wm" ]; then
    detail_extra=$(awk '
      /^## Detail$/ {found=1; next}
      found && !body && (/^Phase: / || /^Branch: / || /^[[:space:]]*$/) {next}
      found {body=1; print}
    ' "$local_wm" 2>/dev/null) || _detail_awk_rc=$?
    # awk 失敗 (I/O error / 読み取り権限剥奪等) を silent fallback にすると、蓄積 Detail の
    # 消失が「もともと空だった」と区別できない。non-blocking は維持しつつ WARNING で観測性を確保する。
    if [ "$_detail_awk_rc" -ne 0 ]; then
      echo "WARNING: detail_extra awk extraction failed (rc=$_detail_awk_rc) — accumulated Detail content will be dropped from the regenerated body" >&2
      detail_extra=""
    fi
  fi

  {
    printf '# 📜 rite 作業メモリ\n\n'
    printf '## Summary\n'
    printf -- '---\n'
    printf 'schema_version: 1\n'
    printf 'issue_number: %s\n' "$issue_number"
    printf 'sync_revision: %s\n' "$sync_rev"
    printf 'sync_status: pending\n'
    printf 'source: %s\n' "$_wm_source_san"
    printf 'last_modified_at: "%s"\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'phase: "%s"\n' "$_wm_phase_san"
    printf 'phase_detail: "%s"\n' "$_wm_phase_detail_san"
    printf 'next_action: "%s"\n' "$_wm_next_san"
    printf 'branch: "%s"\n' "$_branch_san"
    printf 'pr_number: %s\n' "$_pr_num_san"
    printf 'last_commit: "%s"\n' "$_last_commit_san"
    printf 'loop_count: %s\n' "$_loop_cnt_san"
    printf -- '---\n'
    printf '\n%s\n' "$WM_BODY_TEXT"
    printf '\n## Detail\nPhase: %s\nBranch: %s\n' "$_wm_phase_san" "$_branch_san"
    if [ -n "$detail_extra" ]; then
      printf '\n%s\n' "$detail_extra"
    fi
  } > "$tmp_wm"

  chmod 600 "$tmp_wm" 2>/dev/null || true
  # mv の exit code を明示的にチェックする (writer/reader 対称化 doctrine、cycle 49 M-1)。
  # flow-state.sh の create/patch/increment mode は同型 pattern (`if ! mv ...; then ...; rm -f; exit 1; fi`)
  # で mv 失敗を fail-fast 化しているが、本 work-memory-update.sh は `set -e` 不在 (sourced helper) のため
  # mv 失敗 (disk full / permission denied / EXDEV / 親 dir 削除済) が silent に成功扱いされ、caller が
  # work memory 書き込み成功と誤認する経路があった。return 2 (本 helper の lock failure と同 code) で
  # caller の WM 書き込み失敗を fail-fast にする。
  # if/else preserves the real mv rc (EXDEV=18, EACCES=13, ENOSPC=28). The
  # caller (orchestrator) uses rc=2 as a generic "write failed" signal, but
  # the rc shown in the WARNING lets triage distinguish disk-full from
  # permission-denied from cross-filesystem.
  local _mv_err
  _mv_err=$(mktemp 2>/dev/null) || _mv_err=""
  if mv "$tmp_wm" "$local_wm" 2>"${_mv_err:-/dev/null}"; then
    [ -n "$_mv_err" ] && rm -f "$_mv_err"
    return 0
  fi
  local _mv_rc=$?
  echo "rite: ${WM_SOURCE}: mv failed (rc=$_mv_rc): $tmp_wm -> $local_wm" >&2
  [ -n "$_mv_err" ] && [ -s "$_mv_err" ] && head -3 "$_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  [ -n "$_mv_err" ] && rm -f "$_mv_err"
  rm -f "$tmp_wm"
  return 2
}
