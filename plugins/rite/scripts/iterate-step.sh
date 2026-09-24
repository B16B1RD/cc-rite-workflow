#!/bin/bash
# rite workflow - /rite:iterate step bodies
#
# Responsibility: hold the shell body of every multi-statement step in
# skills/iterate/SKILL.md so that the skill calls each step as one top-level
# `bash {plugin_root}/scripts/iterate-step.sh <subcommand> --arg value ...`.
# A session worktree entered natively isolates the host shell, and the host
# refuses blocks that source files or mix command substitution, loops and git
# with other statements. A single top-level `bash <file> <literal args>` passes
# (see references/git-worktree-patterns.md#host-worktree-execution).
#
# The skill keeps the routing tables for every marker emitted here. This file
# only moves where the shell text lives; marker names, values and exit codes
# are the contract the skill reads.
#
# Usage:
#   bash iterate-step.sh restore
#   bash iterate-step.sh ensure-worktree --issue N [--branch B]
#   bash iterate-step.sh init-cycle --pr N --issue N --branch B
#   bash iterate-step.sh cycle-gate --pr N --issue N --branch B
#   bash iterate-step.sh lost-repair --repair saved|rereview|failed --cycle N --lost N
#   bash iterate-step.sh stagnation-route
#   bash iterate-step.sh nb-sweep-collect --pr N
#   bash iterate-step.sh nb-sweep-record --pr N
#   bash iterate-step.sh purpose-unaligned --pr N --issue N --branch B
#   bash iterate-step.sh run-close --pr N --issue N --branch B --sweep-origin S
#   bash iterate-step.sh nb-remaining
#   bash iterate-step.sh breaker --pr N --issue N --branch B --cb-reason R
#
# Exit 2: unknown subcommand, unknown option, missing required argument, or an
# argument value still carrying an unsubstituted `{placeholder}`.

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage_error() {
  echo "ERROR: iterate-step.sh: $1" >&2
  exit 2
}

# --- restore -------------------------------------------------------------------
step_restore() {
# marker の emit / 照合は共有関数 marker_emit / marker_get が所有する。書式・行頭アンカー・
# 複数行耐性・branch スコープ・recency の契約は hooks/tests/context-marker.test.sh が SoT
# （本ファイルに散文で書き戻さないこと）。読み込めないときは縮退させない — marker が出なければ
# LLM の routing が成立せず、無言で進むと develop 上で誤ったループを回しうる。
# Bash tool 呼び出し間でシェル状態は引き継がれないため、marker を扱う各ブロックで独立に読み込む。
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }

iterate_issue=$(bash "$plugin_root"/hooks/flow-state.sh get --field issue_number --default "") || iterate_issue=""
iterate_branch=$(bash "$plugin_root"/hooks/flow-state.sh get --field branch --default "") || iterate_branch=""
marker_emit ITERATE_ISSUE "$iterate_issue" "ITERATE_BRANCH=$iterate_branch"
}

# --- ensure-worktree -----------------------------------------------------------
step_ensure_worktree() {
claim_state=$(bash "$plugin_root"/hooks/issue-claim.sh check --issue $issue_number) || exit $?
if [ "$claim_state" != own ]; then
  bash "$plugin_root"/hooks/issue-claim.sh claim --issue $issue_number || exit $?
fi
if [ -n "$branch_name" ]; then
  bash "$plugin_root"/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue $issue_number --branch $branch_name
else
  bash "$plugin_root"/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue $issue_number
fi
}

# --- init-cycle ----------------------------------------------------------------
step_init_cycle() {
# PR 番号は state ファイル名に直接入る。未置換のまま進むと字面どおりの名前のファイル同士で辻褄が
# 合ってしまうため、数値でなければファイルに触れる前に止める（ステップ 1 も同じ）。
pr_number="$pr_number"
case "$pr_number" in
  ''|*[!0-9]*) echo "ERROR: iterate ステップ 0.6: pr_number が数値に置換されていません (値: '$pr_number')。PR 番号を確認して再実行してください" >&2; exit 1 ;;
esac

# review-state-initialize
review_state_path=$(bash "$plugin_root"/hooks/flow-state.sh path) || exit 1
review_state='{}'
if [ -e "$review_state_path" ] || [ -L "$review_state_path" ]; then
  review_state=$(jq -e 'select(type == "object")' "$review_state_path") || {
    echo "ERROR: cannot read review state: $review_state_path" >&2
    exit 1
  }
fi
if ! printf '%s' "$review_state" | jq -e --argjson pr "$pr_number" --arg branch "$branch_name" '
  ((.pr_number // 0) == 0 or .pr_number == $pr) and
  ((.branch // "") == "" or .branch == $branch)' >/dev/null; then
  echo "ERROR: review state belongs to a different PR or branch" >&2
  exit 1
fi
if printf '%s' "$review_state" | jq -e '(.pr_number // 0) == 0 and (.review_cycle == null)' >/dev/null; then
  bash "$plugin_root"/hooks/flow-state.sh set --phase pr --pr "$pr_number" \
    --branch "$branch_name" --issue "$issue_number" --next "/rite:pr-review $pr_number" || exit 1
fi

# (0) 診断スニペット用 helper を読み込む。SoT は control-char-neutralize.sh の header
# （`head -N ... | neutralize_ctrl --keep-newline | sed ... >&2` が全 emission site の canonical idiom）。
# capture 側の helper 呼び出しには `LC_ALL=C` を付ける（本ブロック / ステップ 1 / ステップ 6 共有前段の
# 4 サイト共通）。neutralize_ctrl は 0x80-0x9f を**バイト単位**で `?` に潰すため、mktemp / mv / flock 等
# 外部コマンドがロケール依存の多バイト診断を返すと原因語ごと判読不能になる。flow-state.sh が rc だけを
# 返し外部コマンドの stderr が唯一の原因行になる経路（`_atomic_write` の mktemp / mv 失敗）では、
# capture を導入した目的そのもの——停止通知が原因を推測で埋めないこと——が失われる。
# 未定義のまま pipe すると診断本文ごと消えるため不在時は素通しへ縮退させるが、**縮退は必ず
# WARNING で告知する**（無言で縮退させると、この helper を通す目的である「制御文字の素通し」が
# 無通知で復活し、本ブロックが reset_out の stderr を捨てずに capture している理由と矛盾する）。
# source の stderr も抑止しない（抑止すると helper 不在の原因が消える）。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$plugin_root"/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi
# marker の emit / 照合は共有関数が所有する（ステップ 0 と同型。契約の SoT は
# hooks/tests/context-marker.test.sh）。neutralize_ctrl と違い縮退させない — 診断の読みやすさが
# 落ちるのと marker が消えるのとでは帰結が異なり、後者は LLM の routing 自体を壊す。
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }

# ⚠ 下行はテスト hooks/tests/max-review-cycles-default.test.sh が awk 抽出アンカーとして参照する。変更時はテスト側の awk パターンも同時更新すること
# (1) max_review_cycles を rite-config.yml から読取・検証。無効値（0 以下 / 非数値）は WARNING + 既定値 15
raw_max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+max_review_cycles:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*max_review_cycles:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
case "$raw_max" in
  '')            max_cycles=15 ;;                                  # キー欠落 = 既定（正常系、WARNING なし）
  0|*[!0-9]*)    max_cycles=15; echo "WARNING: safety.max_review_cycles='$raw_max' は無効（0 以下 / 非数値）。既定値 15 を使用します" >&2 ;;
  *)             max_cycles=$raw_max ;;
esac

# (2) fresh / resume 判定: iterate 起動時の phase が review/fix なら resume（counter 継続）、それ以外は fresh（0 リセット）。
#     run バッチで前 Issue の cycle_count が同一セッション flow-state に merge-preserve され次 Issue に漏れるのを防ぐ。
#     発火時はステップ 6 の共有前段が counter を 0 にリセットするため、発火後の再実行は本ステップで
#     何もしなくても cycle 1 から再開する（発火済みを覚えておく必要がない = override を持たない）。
cur_phase=$(bash "$plugin_root"/hooks/flow-state.sh get --field phase --default "") || cur_phase=""
cur_cc=$(bash "$plugin_root"/hooks/flow-state.sh get --field cycle_count --default 0) || cur_cc=0
case "$cur_cc" in ''|*[!0-9]*) cur_cc=0 ;; esac   # 読めない / 不正なら 0 から（安全側: 既定上限で必ず止まる）
case "$cur_phase" in
  review|fix) cb_mode_init=resume ;;
  *)          cb_mode_init=fresh ;;
esac
# **この起動でステップ 1 が review を回さずに fire するか**（上限以上なら fire）。ステップ 6.2 の
# 注意行 (a) の付加条件をこの述語が決める。ここでは reset 試行**前**の値で暫定的に立て、
# reset に成功したら下の分岐で 0 に落とす（実効 counter に合わせる）。
cb_will_refire=0
if [ "$cur_cc" -ge "$max_cycles" ] 2>/dev/null; then
  cb_will_refire=1
fi
resume_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
if printf '%s' "$resume_state" | jq -e '.review_run != null' >/dev/null; then
  cb_mode_init=resume
fi
if printf '%s' "$resume_state" | jq -e '.phase == "review" and (.cycle_count // 0) > 0 and
  (.review_cycle.status == "collecting" or .review_cycle.status == "completed")' >/dev/null; then
  cb_mode_init=resume
  cb_will_refire=0
fi
reset_status=none
if [ "$cb_mode_init" = fresh ] && [ "$cur_cc" -gt 0 ] 2>/dev/null; then
  # stale counter を除去（--cycle-count 0 は key 自体を削除。他フィールドは merge-preserve）。
  # reset 失敗を握り潰さず WARNING を surface する（stale counter が残るとブレーカーが早期発火し
  # うるため）。非ブロッキング（iterate は止めない）。ステップ 1 の fire / ok 分岐の set と対称。
  # stderr は捨てずに変数へ受ける。捨てると flow-state.sh が原因別に出す診断（flock timeout /
  # corrupt state / write failed 等）が消え、ステップ 6.2 の停止通知が原因を推測で埋めることになる。
  # tempfile ではなく `2>&1` capture を使うのは、tempfile 方式では mktemp 自体が失敗したときに
  # 診断の退避先を失って結局捨てることになるため（helper は成功時 stdout に何も出さないので
  # stdout の混入は無害）。
  if reset_out=$(LC_ALL=C bash "$plugin_root"/hooks/flow-state.sh set --phase "${cur_phase:-pr}" \
    --next "review⇄fix ループ開始（cycle counter reset）" --cycle-count 0 2>&1); then
    reset_status=ok
    # reset 成功 = 起動時の stale counter は消えた。ステップ 1 は即 fire しないので述語を落とし、
    # marker に載せる counter も実効値（0）へ揃える
    # （cb_will_refire は reset 試行**前**の cur_cc で立つため、ここで再評価しないと
    #   「counter は 0 に戻ったのに REFIRE=1」という自己矛盾した marker が出る）。
    cb_will_refire=0
    cur_cc=0
  else
    # 即再発火（cb_will_refire=1 = counter が上限以上のまま残る）と stale leak
    # （0 < cur_cc < max_cycles）を別値に分ける。**停止通知の注意行の条件は REFIRE であって
    # 本値ではない**（下の RESET 表を参照）。分割の目的は、reset 失敗時に残った counter が
    # 上限以上か未満か——すなわち即再発火するのか残 cycle が目減りするだけなのか——を、
    # 人間が診断値だけで切り分けられるようにすることにある。
    if [ "$cb_will_refire" = 1 ]; then reset_status=failed-refire; else reset_status=failed-stale; fi
    echo "WARNING: cycle counter reset に失敗（stale counter が残りブレーカー早期発火の恐れ）" >&2
    # ここでは cur_cc を 0 に落とさない。永続 counter は元の値のまま残っているため、marker の
    # ITERATE_CYCLE を 0 にすると `ITERATE_CYCLE=0; RESET=failed-refire; REFIRE=1` のように
    # 「counter は 0 なのに review を回さず発火する」という自己矛盾した観測値になる（成功側で
    # cb_will_refire を再評価しているのと同じ理由の鏡像）。本ブロック直後の散文が ITERATE_CYCLE を
    # 「ステップ 1 の上限チェックに渡す値」と規定している以上、実効 counter と一致させる。
  fi
  # 診断の表示は rc に紐付けない。flow-state.sh は破損 state をデフォルト値でマージ書き込みする等、
  # **rc=0 のまま WARNING を出す経路**を持つため、rc!=0 のときだけ表示すると capture 導入前
  # （無リダイレクト）より観測性が落ちる。成功時の capture は空なので下の -n guard が
  # ノイズを抑止する。neutralize_ctrl は hooks/ の canonical 診断スニペット idiom（SoT:
  # control-char-neutralize.sh header）。素の pipe だと helper stderr の制御文字が端末に素通しする。
  [ -n "$reset_out" ] && printf '%s\n' "$reset_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi

# (3) run 開始点 pin の記録。`cur_cc == 0` = この起動から新しい run が始まる（fresh entry /
#     発火後の再実行 / batch の次 Issue）。その時点で存在する最新の結果ファイル basename を
#     `.rite/state/review-run-since-{pr}.txt` に記録し、以降の cycle では helper がそれより
#     新しいファイルだけを現 run とみなす。同一 PR の過去 run の JSON は cleanup（マージ後）
#     まで残るため、pin が無いと前 run の件数を現 run の列の先頭として読む。
#     **cycle_count を run 境界に使わない理由**は helper header の「Why run 境界に run-start pin を
#     使うか」を SoT とする（保存失敗と review 中断で「現 run のファイル数 == cycle_count」の
#     前提が破れる）。pin は counter と独立なのでその 2 経路で破れない。
#     resume（`cb_mode_init=resume` かつ counter が残っている）では既存 pin をそのまま使う —
#     上書きすると resume のたびに run が切り直され、それまでの列が消える。
#     **判定は `cur_cc == 0` 単独ではなく `fresh || cur_cc == 0` の選言**。`cur_cc == 0` だけだと
#     「新しい run か」の proxy にしかならず、fresh entry で counter reset が失敗した経路
#     （上の `failed-stale` / `failed-refire`。marker 整合のため意図的に `cur_cc` を 0 に落とさない）
#     で proxy が壊れる。そこで pin を据え置くと、ステップ 1 は stale pin を `--since` に、残存
#     counter を `--cycle-count` に渡すため helper の stale pin guard の前提条件（`since` が空
#     または `cycle_count == 0`）が揃わず素通りし、**前 run の列を含む混合列で発火する**
#     （健全な run を誤って止める方向）。選言にすれば fresh 側で必ず pin を張り直すので、その経路自体が消える
#     （reset 失敗分岐に pin 削除を複製する必要はない）。`cur_cc == 0` 側の項は resume 経路の
#     ステップ 5.0.1 / ステップ 6 共有前段が counter を 0 にして run を閉じた直後の起動
#     （phase 維持のため resume 判定になる）を拾うために残す。
#     非ブロッキング: pin を書けなくても helper は pin 無し（全件を 1 本の列として読む）へ
#     縮退するだけで、ループは止まらない。ただし縮退は WARNING で告知する。
run_since_status=none
if [ "$cb_mode_init" = fresh ] || [ "$cur_cc" -eq 0 ] 2>/dev/null; then
  # `2>/dev/null` は付けない — resolver は git 内外どちらでも rc=0 / 非空を返す設計なので、
  # ここに落ちるのは **helper 自体を実行できない場合（プラグイン破損 / 版 skew、rc=127）だけ**。
  # その唯一の原因を示すのは bash の `No such file or directory` であり、抑止すると原因が消える
  # （ステップ 1 側と同じ論拠）。正常系の stderr は実測 0 バイトなのでノイズは増えない。
  pin_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || pin_root=""
  if [ -z "$pin_root" ]; then
    echo "WARNING: state-path-resolve.sh を実行できませんでした（プラグインの破損 / 版 skew）。run 開始点 pin を記録できないため、発散判定は前 run の JSON を含んだ列を読んで判定を降ろします" >&2
    run_since_status=unresolved-root
  else
    rm -f "$pin_root/.rite/state/nb-sweep-done-${pr_number}.txt"
    pin_file="$pin_root/.rite/state/review-run-since-${pr_number}.txt"
    # 現時点で最新の結果ファイル basename（1 件も無ければ空 = pin 無し = 全件が現 run）。
    # ソート順は helper 側の選別と揃える（LC_ALL=C 昇順 = 時系列昇順）。
    pin_value=$(find "$pin_root/.rite/review-results" -maxdepth 1 -type f -name "${pr_number}-*.json" 2>/dev/null \
      | LC_ALL=C sort | tail -1)
    [ -n "$pin_value" ] && pin_value=$(basename "$pin_value")
    if mkdir -p "$pin_root/.rite/state" 2>/dev/null && printf '%s\n' "$pin_value" > "$pin_file" 2>/dev/null; then
      # 空 pin（結果ファイルが 1 件も無い = 新規 PR）は「境界を張った」とは意味が違う。
      # ステップ 1 は空 pin を読むと `--since ""` を渡し helper は全件読みへ倒れるため、
      # `ok` と同じ値にすると「正常」と読めてしまう。別値にして観測側で切り分ける。
      if [ -n "$pin_value" ]; then run_since_status=ok; else run_since_status=ok-empty; fi
    else
      # 書けなかった pin をそのまま残さない。ステップ 1 は「ファイルが存在するか」しか見ないため、
      # 前 run の pin が残っていると現 run の 2 cycle 目以降でそれを `--since` に渡してしまう。残る pin は
      # **前 run の開始点**（前 run の 0.6 が書いた値。指しているのは前々 run の最終ファイル）なので、
      # 「pin より新しいファイル」は前 run と現 run の結果を連結した列になる。helper の stale pin guard は `[ -z "$since" ] || cycle_count == 0`
      # を前提条件に持つため、pin が非空かつ 2 cycle 目以降ではこの列がそのまま判定にかかり、前 run の
      # 最良水準が `prefix_min` に居座る（実測: `5,3,1,0,8,8` は cycle 6 で fire）— 健全な run を殺す方向
      # の縮退になる。pin を消せば ステップ 1 の `absent` 経路 → `--since ""` となり、
      # 前 run の結果が同居している限り `実在数 > cycle_count` が必ず成立して guard の連言が揃い、
      # 既存の fail-loud 経路 `run_boundary_unresolved` へ倒れる（同居が無ければ全件 = 現 run なので
      # そのまま読んで正しい）。新しい fallback ではなく、用意済みの loud 経路へ到達させる措置。
      # `2>/dev/null` は付けない (cycle 4 で helper の find から外したのと同じ論拠 — rm が
      # EROFS / EACCES / immutable のどれで失敗したかが消える)。**削除の成否で縮退の向きが
      # 逆になる**ため、marker と WARNING を rm の rc で分ける。
      if rm -f "$pin_file"; then
        echo "WARNING: run 開始点 pin を書き込めませんでした ($pin_file)。stale pin を削除したため、発散判定は run 境界を確定できず判定を降ろします (max_review_cycles の backstop に委ねられます)" >&2
        run_since_status=write-failed
      else
        echo "WARNING: run 開始点 pin を書き込めず、stale pin の削除にも失敗しました ($pin_file)。残った pin は前 run の開始点なので、発散判定は前 run と現 run を連結した列を読み誤発火しえます。手動で削除してください" >&2
        run_since_status=write-failed-pin-retained
      fi
    fi
  fi
fi
marker_emit ITERATE_CYCLE_MAX "$max_cycles" "ITERATE_CYCLE=$cur_cc" "ITERATE_CYCLE_MODE=$cb_mode_init" \
  "RESET=$reset_status" "REFIRE=$cb_will_refire" "RUN_SINCE=$run_since_status"
}

# --- cycle-gate ----------------------------------------------------------------
step_cycle_gate() {
# ステップ 0.6 と同じ pr_number guard（未置換のパスで pin を読まない）。
pr_number="$pr_number"
case "$pr_number" in
  ''|*[!0-9]*) echo "ERROR: iterate ステップ 1: pr_number が数値に置換されていません (値: '$pr_number')。PR 番号を確認して再実行してください" >&2; exit 1 ;;
esac

# 診断スニペット用 helper（ステップ 0.6 (0) と同型 — 縮退時の WARNING 告知まで含めて同じ。
# Bash tool 呼び出し間でシェル状態は引き継がれないため、fire_out を表示する本ブロックでも
# 独立に読み込む）。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$plugin_root"/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi
# marker の emit / 照合の共有関数（ステップ 0 / 0.6 と同型。本ブロックは emit と照合の両方で使う）。
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit・照合できないため中止します" >&2; exit 1; }

cc=$(bash "$plugin_root"/hooks/flow-state.sh get --field cycle_count --default 0) || cc=0
case "$cc" in ''|*[!0-9]*) cc=0 ;; esac
raw_max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+max_review_cycles:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*max_review_cycles:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
case "$raw_max" in ''|0|*[!0-9]*) max_cycles=15 ;; *) max_cycles=$raw_max ;; esac  # 検証済。ここは silent fallback

# review-cycle-resume-gate
review_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
iteration_phase=$(printf '%s' "$review_state" | jq -er ' .phase') || exit 1
if printf '%s' "$review_state" | jq -e '.phase == "review" and (.cycle_count // 0) > 0 and
  (.review_cycle.status == "collecting" or .review_cycle.status == "completed")' >/dev/null; then
  # 早期 exit は「同じ HEAD の同じ cycle を続ける」ときだけの縮退である。HEAD が動いていれば
  # その cycle はもう続けられない（review-start / review-finish が HEAD 一致を要求する）ため、
  # ここで exit すると後段の lost 修復ゲートが構造的に到達不能になる。
  # SHA 欠落・git 失敗は HEAD 変更と混同せず停止する（証跡の有無を判定できないまま進ませない）。
  cycle_status=$(printf '%s' "$review_state" | jq -er '.review_cycle.status') || exit 1
  frozen_head=$(printf '%s' "$review_state" | jq -er '.review_cycle.review_context.commit_sha') || {
    echo "ERROR: 凍結 context に commit_sha がありません（state 破損）。/rite:recover $issue_number で証跡を確認してください" >&2
    marker_emit ITERATE_RESUME_HEAD undecidable "cycle=$cc" "reason=frozen_sha_missing"
    exit 1
  }
  current_head=$(git rev-parse HEAD 2>/dev/null) || current_head=""
  if [ -z "$current_head" ]; then
    echo "ERROR: 現 HEAD を取得できませんでした。HEAD 変更と区別できないため停止します" >&2
    marker_emit ITERATE_RESUME_HEAD undecidable "cycle=$cc" "reason=git_head_failed"
    exit 1
  fi
  if [ "$current_head" = "$frozen_head" ]; then
    marker_emit ITERATE_RESUME_HEAD match "cycle=$cc" "status=$cycle_status" "head=$current_head"
    marker_emit ITERATE_LOST_GATE ok "cycle=$cc" "INC=held" "REVIEW_RESUME=1"
    marker_emit ITERATE_CB ok "cycle=$cc" "max=$max_cycles" "INC=held" "REVIEW_RESUME=1"
    exit 0
  fi
  marker_emit ITERATE_RESUME_HEAD changed "cycle=$cc" "status=$cycle_status" \
    "frozen=$frozen_head" "head=$current_head"
  # 証跡ゼロの collecting はここで放棄する。lost 修復ゲートの結果に依存させると、前 cycle の
  # JSON が残っている経路（lost_gate=ok）では放棄されず、後段のどの道も review-start の HEAD
  # 一致要求で止まる。証跡の有無は helper が判定するのでここで先取りしない。
  if [ "$cycle_status" = collecting ]; then
    if abandon_out=$(LC_ALL=C bash "$plugin_root"/hooks/flow-state.sh review-abandon \
      --reason "HEAD changed before any evidence was recorded" 2>&1); then
      abandon_state=done
      # 放棄は phase を pr へ戻す。後段の set が古い phase を書き戻さないよう読み直す。
      review_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
      iteration_phase=$(printf '%s' "$review_state" | jq -er ' .phase') || exit 1
    elif printf '%s' "$abandon_out" | grep -q 'ERROR: review-cycle:'; then
      abandon_state=refused
      # helper が判定して拒否した、までが分かること。prefix は require() 違反すべてに付くので
      # 理由は証跡の残存とは限らない。断定せず、直後に出す helper の stderr に説明を委ねる。
      echo "WARNING: 未完了 cycle の放棄が helper に拒否されました。下の理由を読み、回収が必要なら /rite:recover $issue_number を実行してください" >&2
    else
      abandon_state=unavailable
      echo "ERROR: 未完了 cycle の放棄を実行できませんでした（helper 不在 / プラグイン破損 / 版 skew の疑い）。プラグインを取得し直してから /rite:iterate $pr_number を再実行してください" >&2
    fi
    [ -n "$abandon_out" ] && printf '%s\n' "$abandon_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    if [ "$abandon_state" = unavailable ]; then
      # 停止する前に handoff を落とす。Stop hook の consume-handoff は jq とシェルだけで
      # 動くため、helper を実行できない版 skew でも handoff は消費され、/rite:pr-review が
      # 再注入されて未放棄の cycle のままゲートを迂回する。他 2 つの停止点と同型に揃える。
      handoff_clear=ok
      bash "$plugin_root"/hooks/flow-state.sh set --phase "$iteration_phase" --issue "$issue_number" --branch "$branch_name" --pr "$pr_number" --next "放棄を実行できずに停止。プラグインを取得し直して再実行する" || handoff_clear=failed
      [ "$handoff_clear" = failed ] && echo "WARNING: handoff を落とせませんでした。Stop hook が /rite:pr-review を再注入してゲートを迂回する恐れがあります" >&2
      marker_emit ITERATE_ABANDON "$abandon_state" "cycle=$cc" "status=$cycle_status" \
        "HANDOFF_CLEAR=$handoff_clear"
      exit 1
    fi
    marker_emit ITERATE_ABANDON "$abandon_state" "cycle=$cc" "status=$cycle_status"
  fi
fi


# 収束トレンド判定。永続レビュー JSON から現 run の per-cycle blocking 列を復元し、
# 発散していれば cycle 上限未到達でも発火させる。判定は helper に閉じており、LLM は verdict を
# 読むだけで数え上げを行わない。
# `--since` にはステップ 0.6 が記録した run 開始点 pin を渡す（run 境界の決定はこれが担う。
# cycle_count は helper 側で「結果が失われた」診断にしか使われない）。pin ファイルが無ければ
# 空文字を渡す = 全件を 1 本の列として読む（pin 導入前の run への後方互換）。
# stderr は捨てずに素通しする（helper の WARNING はデータ異常の原因を示す唯一の記録）。
# pin の解決失敗と pin ファイル不在は**別の縮退**なので別値で報告する。どちらも helper へ空文字を
# 渡す（= 全件を 1 本の列として読む）が、その帰結は「他 run の混入」であり、helper 側の
# `run_boundary_unresolved` guard が捕まえるまで境界が失われている状態にある。無音で倒れると
# ステップ 0.6 が同じ失敗に WARNING を出しているのに、実際に helper へ渡す値を決める側だけが
# 何も残さないという非対称になる。`2>/dev/null` も付けない（原因が消える）。
pin_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || pin_root=""
run_since=""
run_since_used=pin
if [ -z "$pin_root" ]; then
  run_since_used=unresolved-root
  echo "WARNING: state-path-resolve.sh を実行できませんでした（プラグインの破損 / 版 skew）。run 開始点 pin を読めないため、発散判定は run 境界を確定できず判定を降ろします（max_review_cycles の backstop のみが働きます）" >&2
elif [ ! -f "$pin_root/.rite/state/review-run-since-${pr_number}.txt" ]; then
  run_since_used=absent
  echo "WARNING: run 開始点 pin が未記録です（ステップ 0.6 の書き込み失敗、または pin 導入前から継続中の run）。前 run の結果が同居していれば発散判定は判定を降ろします" >&2
else
  run_since=$(head -1 "$pin_root/.rite/state/review-run-since-${pr_number}.txt" | tr -d '[:space:]')
  if [ -z "$run_since" ]; then
    # pin ファイルはあるが中身が空（結果 0 件の新規 PR で記録された pin）。helper へ渡る値は
    # 不在時と同一（全件読み）なので、marker も `absent` と同義にして「pin を使えている」と
    # 名乗らせない。新規 PR では前 run が存在しないため実害は無いが、観測値は実態に合わせる。
    run_since_used=absent
  fi
fi
trend_out=$(bash "$plugin_root"/hooks/scripts/review-trend-divergence.sh \
  --pr $pr_number --cycle-count "$cc" --since "$run_since"); trend_rc=$?
# helper の出力から marker を読む。値の切り出しは marker_get が所有する — 行頭アンカー
# （helper の WARNING が marker 文字列を引用しても拾わない）・複数行 stderr 混入への耐性・
# 同一 KEY の recency・field 名のトークン完全一致は関数側の契約で、その SoT は
# hooks/tests/context-marker.test.sh。`reason` の値域や `trend` の区切りをここで文字クラスとして
# 書き直さないこと — 呼び出し側が値域を写すと helper が値を増やすたびに切り詰めが起きる
# （例: `[a-z_]` は `need_3_cycles` を `need_` にする）。値域を知るのは helper だけでよい。
trend_verdict=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE)
trend_series=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE --field trend)
# helper が判定不能の理由を載せる `reason=` は stdout にしか出ない。抽出して marker に載せないと、
# 「発散検出が全面不作動」と「まだ 3 cycle 目に達していない正常系」が呼び出し側から区別できない。
trend_reason=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE --field reason)
# 失われた結果の件数。列に穴があることを停止通知まで運ぶ（欠落は verdict を反転させうるため、
# 合成された推移を実測として描画させない）。`lost=` を出さないのは `_undecidable` 経路だけで、
# `need_3_cycles` は部分列とともに出す（差し替えと併記が同時成立する — ステップ 6.2 参照）。
# ゲートは raw を見る。coerce は注記 (`LOST=`) 用で、空を 0 に潰すと本 Issue の主シナリオ
# （cc>=1 かつ JSON 0 件）が fire しない。
trend_lost_raw=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE --field lost)
trend_lost=$trend_lost_raw
case "$trend_lost" in ''|*[!0-9]*) trend_lost=0 ;; esac
if [ "$trend_rc" -ne 0 ] || [ -z "$trend_verdict" ]; then
  # rc=2（引数不正 / jq 不在）や helper 不在（marketplace 版とローカル版の skew 等）。
  # 判定できないまま黙って通すと「発散検出が働いていない」ことが観測不能になるため loud にする。
  # 帰結は max_review_cycles による従来判定への縮退で、ループが止まらなくなるわけではない。
  echo "WARNING: 収束トレンド判定を実行できませんでした（rc=${trend_rc}）。cycle 上限のみで判定します" >&2
  trend_verdict=unavailable
  trend_reason=helper_unavailable
  trend_lost=0
fi

# lost 修復ゲート。次 cycle の increment / review / CB 発火より先に評価する。
# `lost > 0` = 完了済み cycle に対して JSON が不足（増分）。helper の lost= をそのまま使う。
# `_undecidable` は lost= を出さないため、cc>=1 かつ raw 欠落かつデータ不在 reason でも fire。
# helper_unavailable は発火させない（判定不能を修復ゲートへ倒すと再レビュー空転する）。
lost_gate=ok
if [ "$trend_lost" -gt 0 ] 2>/dev/null; then
  lost_gate=fire
elif [ "$cc" -ge 1 ] 2>/dev/null && [ -z "$trend_lost_raw" ] && [ "$trend_reason" != "helper_unavailable" ]; then
  case "$trend_reason" in
    no_results_file|results_dir_missing|no_file_after_pin) lost_gate=fire ;;
  esac
fi

# 発火理由を決める。**cycle 上限を先に評価する** — 両方成立しているとき、上限到達は
# 従来からの契約（収束トレンド判定の backstop）であり、そちらを理由として報告するほうが挙動の説明として正確。
# lost ゲートが fire のときは下の分岐で CB を保留する（本算出は行わないわけではない）。
cb_reason=""
if [ "$cc" -ge "$max_cycles" ] 2>/dev/null; then
  cb_reason=max-cycles
elif [ "$trend_verdict" = fire ]; then
  cb_reason=divergence
fi

if [ "$lost_gate" = fire ]; then
  # increment しない（marker の cycle は永続 counter と一致 = INC=held）。
  # ITERATE_CB=ok を載せるのは既存 CB 表の fire 分岐に落とさないため。
  # review invoke は ITERATE_LOST_GATE 表が決める（本 marker の ok を「次 cycle 開始」と読まない）。
  # `--handoff` なしの set で直前 [fix:pushed] の継続 handoff を default-clear する。
  # `--cycle-count` は付けない（INC=held）。CB fire 分岐と同型。
  if fire_out=$(LC_ALL=C bash "$plugin_root"/hooks/flow-state.sh set \
    --phase "$iteration_phase" --issue $issue_number --branch $branch_name --pr $pr_number \
    --next "lost 修復ゲート発火 (JSON 欠落 lost=$trend_lost)" 2>&1); then
    handoff_clear=ok
  else
    handoff_clear=failed
    echo "WARNING: lost 修復ゲート発火時の handoff クリアに失敗（handoff が残り Stop hook が /rite:pr-review を再注入してゲートを迂回する恐れ）" >&2
  fi
  [ -n "$fire_out" ] && printf '%s\n' "$fire_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  marker_emit ITERATE_LOST_GATE fire "lost=$trend_lost" "cycle=$cc" "max=$max_cycles" \
    "TREND=$trend_series" "TREND_VERDICT=$trend_verdict" "TREND_REASON=$trend_reason" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=held" "HANDOFF_CLEAR=$handoff_clear"
  marker_emit ITERATE_CB ok "cycle=$cc" "max=$max_cycles" \
    "TREND=$trend_series" "TREND_VERDICT=$trend_verdict" "TREND_REASON=$trend_reason" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=held"
elif [ -n "$cb_reason" ]; then
  # 直前の [fix:pushed] が fix.md ステップ5.1 で set した継続 handoff (`/rite:pr-review {pr}`) を
  # default-clear する（`--handoff` を伴わない set は handoff を消す）。これをしないと、fire 後に
  # turn が終わったとき stop-loop-continuation.sh が残存 handoff を consume して `/rite:pr-review` を
  # 再注入し、サーキットブレーカーを無視してループが継続する。`[fix:error]` が set で handoff を
  # クリアして clean terminal になるのと同じ役割。
  # **counter はここではリセットしない**。リセットは発火が sentinel として記録される直前
  # （ステップ 6 の共有前段）まで遅らせる。ここで 0 に戻すと、6.1 / 6.2 が sentinel を emit する
  # 前に turn が終わった場合、発火の記録がどこにも残らないまま counter だけが 0 になり、同じ set が
  # handoff も消しているので Stop hook は停止を許可する。その後 /rite:recover は保持した review/fix phase を
  # そのまま iterate へ routing するため、発火が 1 度も報告されないまま満額 max_review_cycles で
  # ループが再開する（＝ブレーカーの無効化）。counter を上限のまま残せば、その窓で中断しても
  # 次回ループ頭で必ず再発火する — 縮退が「停止側」に倒れる。
  # set の成否は HANDOFF_CLEAR marker に載せる（counter reset の成否は別軸で、ステップ 6 の
  # 共有前段が WARNING として表示する）。stderr は捨てずに変数へ受けて表示する。
  case "$cb_reason" in
    divergence) fire_desc="収束トレンドの発散を検出 (推移 $trend_series)" ;;
    *)          fire_desc="cycle 上限 $max_cycles 到達" ;;
  esac
  if fire_out=$(LC_ALL=C bash "$plugin_root"/hooks/flow-state.sh set \
    --phase "$iteration_phase" --issue $issue_number --branch $branch_name --pr $pr_number \
    --next "サーキットブレーカー発火 ($fire_desc)" 2>&1); then
    handoff_clear=ok
  else
    handoff_clear=failed
    echo "WARNING: サーキットブレーカー発火時の handoff クリアに失敗（handoff が残り Stop hook が /rite:pr-review を再注入してブレーカーを迂回する恐れ）" >&2
  fi
  # 診断の表示は rc に紐付けない（ステップ 0.6 の reset と同型）。flow-state.sh は rc=0 のまま
  # WARNING を出す経路を持つため、rc!=0 のときだけ表示するとブレーカー発火という最後の安全網の
  # 経路で診断が消える。neutralize_ctrl も同型（本ブロック冒頭で読み込み済み）。
  [ -n "$fire_out" ] && printf '%s\n' "$fire_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  # CB_REASON / TREND はステップ 6.2 の停止通知が「理由」行とトレンド推移の表示に使う。
  # ステップ 6 は別の Bash 呼び出しでシェル変数を引き継げないため marker で渡す。
  marker_emit ITERATE_LOST_GATE ok "lost=$trend_lost" "cycle=$cc" "max=$max_cycles" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=none"
  marker_emit ITERATE_CB fire "cycle=$cc" "max=$max_cycles" "CB_REASON=$cb_reason" \
    "TREND=$trend_series" "TREND_VERDICT=$trend_verdict" "TREND_REASON=$trend_reason" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "HANDOFF_CLEAR=$handoff_clear"
else
  # 名簿を確定してから review-start が一度だけ counter を進める。
  new_cc=$cc
  inc_status=deferred
  marker_emit ITERATE_LOST_GATE ok "lost=$trend_lost" "cycle=$new_cc" "max=$max_cycles" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=$inc_status"
  marker_emit ITERATE_CB ok "cycle=$new_cc" "max=$max_cycles" \
    "TREND=$trend_series" "TREND_VERDICT=$trend_verdict" "TREND_REASON=$trend_reason" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=$inc_status"
fi
}

# --- lost-repair ---------------------------------------------------------------
step_lost_repair() {
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }
marker_emit ITERATE_LOST_REPAIR "$repair" "cycle=$cycle" "lost=$lost"
}

# --- stagnation-route ----------------------------------------------------------
step_stagnation_route() {
# iterate-stagnation-route
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || exit 1
stagnation_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
if printf '%s' "$stagnation_state" | jq -e '.review_run != null' >/dev/null; then
  stagnation_action=$(printf '%s' "$stagnation_state" | jq -er '.review_run.current_decision.action') || exit 1
  case "$stagnation_action" in
    continue|replan|stop) marker_emit ITERATE_STAGNATION "$stagnation_action" ;;
    *) echo 'ERROR: invalid stagnation decision' >&2; exit 1 ;;
  esac
else
  marker_emit ITERATE_STAGNATION legacy
fi
}

# --- nb-sweep-collect ----------------------------------------------------------
step_nb_sweep_collect() {
# 診断出力の制御文字を潰す（ステップ 0.6 (0) と同型 — 縮退時の WARNING 告知まで含めて同じ）。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$plugin_root"/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; echo "[iterate:nb-sweep-error]"; exit 1; }
nb_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || nb_root=""
if [ -z "$nb_root" ]; then
  echo "ERROR: state-path-resolve が空を返した。NB sweep 対象を取得できない" >&2
  marker_emit ITERATE_NB_SWEEP failed "reason=state_root_unresolved"
  echo "[iterate:nb-sweep-error]"
  exit 1
fi
nb_done_file="$nb_root/.rite/state/nb-sweep-done-$pr_number.txt"
nb_latest=$(find "$nb_root/.rite/review-results" -maxdepth 1 -type f -name "$pr_number-*.json" 2>/dev/null | LC_ALL=C sort | tail -1)
nb_latest_base=""
[ -n "$nb_latest" ] && nb_latest_base=$(basename "$nb_latest")
nb_range=""
if [ -f "$nb_done_file" ]; then
  nb_range=$(awk 'NR==1 { print $2 }' "$nb_done_file")
fi
if [ -n "$nb_range" ] && [ "$nb_range" = "$nb_latest_base" ]; then
  skipped_kind=$(awk 'NR==1 { print $1 }' "$nb_done_file")
  case "$skipped_kind" in
    done|noop) ;;
    *) skipped_kind=done ;;
  esac
  marker_emit ITERATE_NB_SWEEP skipped "reason=already_done" "kind=$skipped_kind" "record=$nb_range"
else
collect_err=$(mktemp "${TMPDIR:-/tmp}/rite-nb-sweep-collect-XXXXXX") || { echo "ERROR: mktemp failed" >&2; echo "[iterate:nb-sweep-error]"; exit 1; }
collect_out=$(bash "$plugin_root"/hooks/scripts/nb-sweep-collect.sh --pr $pr_number --state-root "$nb_root" 2>"$collect_err") || collect_rc=$?
collect_rc=${collect_rc:-0}
neutralize_ctrl --keep-newline < "$collect_err" >&2
rm -f -- "$collect_err"
status=$(printf '%s' "$collect_out" | jq -r '.status // empty' 2>/dev/null) || status=""
count=$(printf '%s' "$collect_out" | jq -r '.count // empty' 2>/dev/null) || count=""
case "$collect_rc:$status" in
  0:empty)
    mkdir -p "$nb_root/.rite/state" || true
    # shellcheck source=../hooks/gitignore-ensure.sh
    source "$plugin_root"/hooks/gitignore-ensure.sh
    if ! _ensure_dir_gitignore "$nb_root/.rite/state"; then
      echo "WARNING: $nb_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
      [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
    fi
    nb_record=$(printf '%s' "$collect_out" | jq -r '.record // empty')
    nb_record_base=""
    [ -n "$nb_record" ] && nb_record_base=$(basename "$nb_record")
    nb_keep=""
    if [ -f "$nb_done_file" ]; then
      nb_keep=$(sed -n '2p' "$nb_done_file" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
      case "$nb_keep" in ''|*[!0-9a-f]*) nb_keep="" ;; esac
      [ "${#nb_keep}" -ge 7 ] || nb_keep=""
    fi
    if [ -z "$nb_record_base" ]; then
      echo "WARNING: nb-sweep-done marker を書けませんでした ($nb_done_file)。次回 5.S は再実行されます" >&2
      rm -f "$nb_done_file"
    elif [ -n "$nb_keep" ]; then
      if ! printf 'noop %s\n%s\n' "$nb_record_base" "$nb_keep" > "$nb_done_file"; then
        echo "WARNING: nb-sweep-done marker を書けませんでした ($nb_done_file)。次回 5.S は再実行されます" >&2
        rm -f "$nb_done_file"
      fi
    elif ! printf 'noop %s\n' "$nb_record_base" > "$nb_done_file"; then
      echo "WARNING: nb-sweep-done marker を書けませんでした ($nb_done_file)。次回 5.S は再実行されます" >&2
      rm -f "$nb_done_file"
    fi
    marker_emit ITERATE_NB_SWEEP noop "count=0"
    ;;
  0:ok)
    marker_emit ITERATE_NB_SWEEP pending "count=${count:-}"
    ;;
  *)
    echo "ERROR: NB sweep collect failed (rc=$collect_rc status=${status:-})" >&2
    marker_emit ITERATE_NB_SWEEP failed "rc=$collect_rc" "status=${status:-}"
    echo "[iterate:nb-sweep-error]"
    exit 1
    ;;
esac
fi
}

# --- nb-sweep-record -----------------------------------------------------------
step_nb_sweep_record() {
nb_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || nb_root=""
nb_done_file="$nb_root/.rite/state/nb-sweep-done-$pr_number.txt"
nb_latest=""
nb_latest_base=""
nb_have=""
if [ -n "$nb_root" ]; then
  nb_latest=$(find "$nb_root/.rite/review-results" -maxdepth 1 -type f -name "$pr_number-*.json" 2>/dev/null | LC_ALL=C sort | tail -1)
  [ -n "$nb_latest" ] && nb_latest_base=$(basename "$nb_latest")
  [ -f "$nb_done_file" ] && nb_have=$(awk 'NR==1 { print $2 }' "$nb_done_file")
fi
if [ -n "$nb_root" ] && [ -n "$nb_latest_base" ] && [ "$nb_have" != "$nb_latest_base" ]; then
  mkdir -p "$nb_root/.rite/state" || true
  # shellcheck source=../hooks/gitignore-ensure.sh
  source "$plugin_root"/hooks/gitignore-ensure.sh
  if ! _ensure_dir_gitignore "$nb_root/.rite/state"; then
    echo "WARNING: $nb_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
    [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
  fi
  nb_keep=""
  if [ -f "$nb_done_file" ]; then
    nb_keep=$(sed -n '2p' "$nb_done_file" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$nb_keep" in ''|*[!0-9a-f]*) nb_keep="" ;; esac
    [ "${#nb_keep}" -ge 7 ] || nb_keep=""
  fi
  if [ -n "$nb_keep" ]; then
    nb_write_ok=$(printf 'done %s\n%s\n' "$nb_latest_base" "$nb_keep" > "$nb_done_file" && echo ok || true)
  else
    nb_write_ok=$(printf 'done %s\n' "$nb_latest_base" > "$nb_done_file" && echo ok || true)
  fi
  if [ "$nb_write_ok" != ok ]; then
    echo "WARNING: nb-sweep-done marker を書けませんでした ($nb_done_file)" >&2
    rm -f "$nb_done_file"
  fi
elif [ -n "$nb_root" ] && [ -z "$nb_latest_base" ] && [ -f "$nb_done_file" ] && [ -z "$nb_have" ]; then
  rm -f "$nb_done_file"
fi
}

# --- purpose-unaligned ---------------------------------------------------------
step_purpose_unaligned() {
# 診断出力の制御文字を潰す（ステップ 0.6 (0) と同型 — 縮退時の WARNING 告知まで含めて同じ）。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$plugin_root"/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi
# purpose-unaligned: `--handoff` なしの set で FINALIZE を default-clear する（CB fire / 受入条件未検証と同型）。
iteration_phase=$(bash "$plugin_root"/hooks/flow-state.sh get --field phase --default review) || iteration_phase=review
if fire_out=$(LC_ALL=C bash "$plugin_root"/hooks/flow-state.sh set \
  --phase "$iteration_phase" --issue $issue_number --branch $branch_name --pr $pr_number \
  --next "purpose_unaligned: 完了前確認で目的逸脱" 2>&1); then
  handoff_clear=ok
else
  handoff_clear=failed
  echo "WARNING: 目的逸脱停止時の handoff クリアに失敗（handoff が残り Stop hook が完了通知を再注入して逸脱を迂回する恐れ）" >&2
fi
if [ -n "$fire_out" ]; then
  printf '%s\n' "$fire_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi
}

# --- run-close -----------------------------------------------------------------
step_run_close() {
# 診断スニペット用 helper（ステップ 0.6 (0) / ステップ 1 と同型。Bash tool 呼び出し間でシェル状態は
# 引き継がれないため独立に読み込む）。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$plugin_root"/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi
# marker の emit / 照合の共有関数（ステップ 0 / 0.6 / 1 と同型）。
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }

close_phase=$(bash "$plugin_root"/hooks/flow-state.sh get --field phase --default review) || close_phase=review
close_handoff=$(bash "$plugin_root"/hooks/flow-state.sh get --field handoff --default "") || close_handoff=""
close_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
if printf '%s' "$close_state" | jq -e '.review_run != null' >/dev/null; then
  close_success=false
  case "$sweep_origin" in '[review:mergeable]'|'[fix:non-fatal-only]') close_success=true ;; esac
  if [ "$close_success" = true ]; then
    bash "$plugin_root"/hooks/flow-state.sh review-close || { echo '[review:error] reason=review_close_failed'; exit 1; }
    marker_emit ITERATE_RUN_CLOSE completed "phase=$close_phase"
    exit 0
  fi
  if [ "$sweep_origin" = '[fix:replied-only]' ]; then
    bash "$plugin_root"/hooks/flow-state.sh review-defer || { echo '[review:error] reason=review_defer_failed'; exit 1; }
    marker_emit ITERATE_RUN_CLOSE deferred "phase=$close_phase"
    exit 0
  fi
  marker_emit ITERATE_RUN_CLOSE retained "phase=$close_phase"
  exit 0
fi
if [ -n "$close_handoff" ]; then
  close_out=$(LC_ALL=C bash "$plugin_root"/hooks/flow-state.sh set \
    --phase "$close_phase" --issue $issue_number --branch "$branch_name" --pr $pr_number \
    --next "run 終了 (cycle counter reset)" --cycle-count 0 --handoff "$close_handoff" 2>&1); close_rc=$?
else
  close_out=$(LC_ALL=C bash "$plugin_root"/hooks/flow-state.sh set \
    --phase "$close_phase" --issue $issue_number --branch "$branch_name" --pr $pr_number \
    --next "run 終了 (cycle counter reset)" --cycle-count 0 2>&1); close_rc=$?
fi
if [ "$close_rc" -eq 0 ]; then
  run_close=ok
else
  run_close=failed
  echo "WARNING: 完了時の cycle counter リセットに失敗しました。次回 /rite:iterate が resume と判定され、run 開始点 pin が更新されないまま前 run の結果を読みます。残存 counter が上限以上なら次回起動は review を 1 度も回さずに発火します" >&2
fi
[ -n "$close_out" ] && printf '%s\n' "$close_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
marker_emit ITERATE_RUN_CLOSE "$run_close" "phase=$close_phase"
}

# --- nb-remaining --------------------------------------------------------------
step_nb_remaining() {
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }
marker_emit ITERATE_NB_REMAINING 0 "status=ok" "record=" "by_severity=" "overlay=sweep"
}

# --- breaker -------------------------------------------------------------------
step_breaker() {
# 診断スニペット用 helper（ステップ 0.6 (0) と同型 — 縮退時の WARNING 告知まで含めて同じ）。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$plugin_root"/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi
# marker の emit / 照合の共有関数（ステップ 0 / 0.6 / 1 / 5.0.1 と同型）。
# shellcheck source=../hooks/scripts/lib/context-marker.sh
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }

state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh)
# 空値を sentinel に置き換える。rc 検査では救えない（resolver は cwd 削除時にも rc=0 で空文字を返す）。
# 空のまま marker に載せると、ステップ 6.2 の (b) が提示する `RITE_STATE_ROOT=` が flow-state.sh の
# `[ -n "${RITE_STATE_ROOT:-}" ]` 判定で「未設定」と**完全に同義**へ縮退し、(b) 自身が「省くと空振りする」
# と警告している当の空振りを、省いていないのに無言で起こす。しかも `flow-state.sh path` は state_root が
# 空でも rc=0 を返すため session_id は非空のまま残る（2 軸は独立）。sentinel にしておけば 6.2 の
# pre-fill 表が ROOT 側だけを解決手順へ置き換え、判明している session_id は保ったまま渡せる。
if [ -z "$state_root" ]; then
  echo "WARNING: state root を解決できませんでした（手動リセット手順が別ディレクトリを rc=0 のまま対象にする恐れがあるため、ステップ 6.2 は state root を埋め込んだコマンドではなく、人間が自分で state root を解決する代替手順に切り替えます）" >&2
  state_root=unresolved
fi
fs_path=$(bash "$plugin_root"/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
cb_mode=interactive
# session_id 解決不可（空）→ 自セッションのキューを特定できないため安全側 interactive のまま
# （read-only なので fail-loud はせず、batch と誤判定しない安全側に倒す）
if [ -n "$session_id" ] && [ -f "$queue_file" ]; then
  q_active=$(jq -r '.active // false' "$queue_file" 2>/dev/null)   # active 欠落の旧形式は false（安全側 = interactive）
  q_cursor=$(jq -r '.cursor // 0' "$queue_file" 2>/dev/null)
  q_total=$(jq -r '.issues | length' "$queue_file" 2>/dev/null)
  q_issue=$(jq -r ".issues[$q_cursor] // empty" "$queue_file" 2>/dev/null)
  if [ "$q_active" = "true" ] && [ "$q_cursor" -lt "${q_total:-0}" ] 2>/dev/null && [ "$q_issue" = "$issue_number" ]; then
    cb_mode=batch
  fi
fi
# cycle counter のリセット。**ステップ 1 の fire 分岐ではなくここで行う** — 直後の 6.1 / 6.2 が
# sentinel を emit するため、ここまで到達していれば発火は記録される。ここより手前で turn が
# 終わった場合は counter が上限のまま残り、次回ループ頭で再発火する（縮退が「停止側」に倒れる）。
# リセットしないと再実行が即再発火してループを再開する術が無くなる。発火済みを `cycle_count` の
# 相対値（例: max + 1）で符号化する設計は採らない — max_review_cycles が invocation 間で変わると
# 符号化が両方向に破綻するため、上限値から独立した文字列の `stop_reason` を下の同一 set で記録する。
# `--handoff` を伴わないため、ステップ 1 fire 分岐が消した handoff はクリアされたまま維持される。
# 失敗は共有前段の WARNING に載せる。失敗すると counter が上限のまま残り再実行が即再発火する
# （= 停止通知が約束する「再実行すれば新しい run として cycle 1 から回る」が偽になる）ため、
# ステップ 6.2 がこれを読んで注意行 (b) を出し分ける。
# `--stop-reason`は「発火した」という事実の durable な記録で、次セッションの
# `session-start.sh` がブレーカー失敗停止と Ctrl+C 中断を区別するために読む。**counter reset と同じ
# set に載せる**のが要点で、ステップ 1 の fire 分岐に書いても本 set（`--stop-reason` なし）が
# default-clear で消してしまう。ここに置くことで、上のコメントが言う「前段〜sentinel 間で turn が
# 終わる窓」でも発火の記録だけは残る（従来はこの窓で counter が 0 に戻り発火が無記録だった）。
# `$cb_reason` はステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=`（`max-cycles` / `divergence`）を
# リテラル置換する。**上限値そのものは埋めない** — `max_review_cycles` は invocation ごとに config から
# 読み直されるため、state に焼くと設定変更で符号化が破綻する（counter reset を選んだのと同じ理由）。
# review-cycle-breaker-reset
iteration_phase=$(bash "$plugin_root"/hooks/flow-state.sh get --field phase --default pr) || exit 1
breaker_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
if printf '%s' "$breaker_state" | jq -e '.review_run != null' >/dev/null; then
  bash "$plugin_root"/hooks/flow-state.sh set \
    --phase "$iteration_phase" --issue $issue_number --branch $branch_name --pr $pr_number \
    --next "停止理由と成果を保持して復旧情報を報告する" \
    --active false --stop-reason "circuit-breaker:$cb_reason" || exit 1
  marker_emit ITERATE_CB_MODE "$cb_mode" "issue=$issue_number" "pr=$pr_number" \
    "SESSION_ID=$session_id" "STATE_ROOT=$state_root"
  exit 0
fi
if cb_reset_out=$(LC_ALL=C bash "$plugin_root"/hooks/flow-state.sh set \
  --phase "$iteration_phase" --issue $issue_number --branch $branch_name --pr $pr_number \
  --next "サーキットブレーカー発火: 停止通知を出し、明示的な /rite:iterate 再実行を待つ" --cycle-count 0 \
  --stop-reason "circuit-breaker:$cb_reason" 2>&1); then
  :
else
  echo "WARNING: サーキットブレーカー発火時の cycle counter リセットと stop_reason 永続化に失敗（counter が上限のまま残り、次セッションでは通常の中断と区別できない）" >&2
fi
# 診断の表示は rc に紐付けない（ステップ 0.6 / ステップ 1 の capture と同型）。
[ -n "$cb_reset_out" ] && printf '%s\n' "$cb_reset_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
# session_id を marker に載せる。ステップ 6.2 の注意行 (b) が人間へ提示する手動リセットコマンドは
# **`--session` を明示しないと別セッションの state を対象にしうる** — flow-state.sh の解決順は
# override → CLAUDE_CODE_SESSION_ID → CLAUDE_SESSION_ID → `.rite-session-id` で、agent の Bash tool は
# env var 経路、人間の端末は env 不在で `.rite-session-id` 経路になる。さらに session-start.sh は
# CLAUDE_CODE_SESSION_ID がある間 `.rite-session-id` を書かないため、Claude Code 配下では両者の
# 不一致が定常状態である。--session 無しのコマンドは rc=0 で「成功」しながら別 sid の state を
# 新規作成し、上限のまま止まっている当の counter は手つかずで残る。
# state_root も同じ理由で marker に載せる。sid を --session で固定しても、state root は
# `resolve_state_root` が cwd へフォールバックするため、人間が repo 外の cwd（marketplace install では
# コマンド文字列にプロジェクト参照が無く、新規端末の既定 cwd は $HOME = 非 git）で実行すると
# rc=0 のまま $cwd/.rite/sessions/ に別ファイルを作り、当の counter はやはり手つかずで残る。
# 2 軸のうち片方だけを塞いでも空振りは塞げない。
marker_emit ITERATE_CB_MODE "$cb_mode" "issue=$issue_number" "pr=$pr_number" \
  "SESSION_ID=$session_id" "STATE_ROOT=$state_root"
}

# --- dispatch ----------------------------------------------------------------
[ "$#" -ge 1 ] || usage_error "subcommand is required"
subcommand=$1
shift

pr_number=""
issue_number=""
branch_name=""
cb_reason=""
sweep_origin=""
repair=""
cycle=""
lost=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage_error "$1 requires a value"
  case "$2" in
    '{'*'}') usage_error "$1 received an unsubstituted placeholder: $2" ;;
  esac
  case "$1" in
    --pr) pr_number=$2 ;;
    --issue) issue_number=$2 ;;
    --branch) branch_name=$2 ;;
    --cb-reason) cb_reason=$2 ;;
    --sweep-origin) sweep_origin=$2 ;;
    --repair) repair=$2 ;;
    --cycle) cycle=$2 ;;
    --lost) lost=$2 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift 2
done
for numeric in pr_number issue_number cycle lost; do
  case "${!numeric}" in
    ''|*[!0-9]*) [ -z "${!numeric}" ] || usage_error "--${numeric%_number} must be a number: ${!numeric}" ;;
  esac
done

require() {
  local name opt
  for name in "$@"; do
    case "$name" in
      pr_number) opt="pr" ;;
      issue_number) opt=issue ;;
      branch_name) opt=branch ;;
      *) opt=${name//_/-} ;;
    esac
    [ -n "${!name}" ] || usage_error "$subcommand requires --$opt"
  done
}

case "$subcommand" in
  restore) step_restore ;;
  ensure-worktree) require issue_number; step_ensure_worktree ;;
  init-cycle) require pr_number issue_number branch_name; step_init_cycle ;;
  cycle-gate) require pr_number issue_number branch_name; step_cycle_gate ;;
  lost-repair) require repair cycle lost; step_lost_repair ;;
  stagnation-route) step_stagnation_route ;;
  nb-sweep-collect) require pr_number; step_nb_sweep_collect ;;
  nb-sweep-record) require pr_number; step_nb_sweep_record ;;
  purpose-unaligned) require pr_number issue_number branch_name; step_purpose_unaligned ;;
  run-close) require pr_number issue_number branch_name sweep_origin; step_run_close ;;
  nb-remaining) step_nb_remaining ;;
  breaker) require pr_number issue_number branch_name cb_reason; step_breaker ;;
  *) usage_error "unknown subcommand: $subcommand" ;;
esac
