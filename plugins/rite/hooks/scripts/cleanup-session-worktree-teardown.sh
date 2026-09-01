#!/usr/bin/env bash
# cleanup-session-worktree-teardown.sh — session worktree の検出と削除。
# cleanup/SKILL.md ステップ 4-W から抽出した後片付けロジック。振る舞いは抽出前と同一。
# 引数はすべて名前付きオプションで受けるため、cleanup 以外の経路からも呼べる。
#
# なぜ 2 subcommand に分かれているか:
#   検出と削除の**間**に `ExitWorktree`（LLM ツール）が必ず入る。cwd が worktree 内のまま
#   `git worktree remove` すると自分の足元を消すため、呼び出し側は detect → ExitWorktree(keep)
#   → remove の順に進む。1 本の直列 helper には畳めない。
#   dirty 時の AskUserQuestion も同じ理由で呼び出し側に残る（本 helper は marker を出すのみ）。
#
# Usage:
#   cleanup-session-worktree-teardown.sh detect [--issue <N>] [--config <path>]
#   cleanup-session-worktree-teardown.sh remove --worktree <path> --pr-merged <true|false> \
#     --self-root <pid> [--dry-run]
#
# detect の `--issue` は空値・省略を許容する（関連 Issue 未識別は cleanup の正規経路で、ここで
# 落とすと marker が 1 本も出ず、呼び出し側が marker 不在を「削除成功」と読むため）。ただし空 issue
# では物理 cwd からの `in_worktree_unrecorded` 導出（cleanup-worktree-detect.sh の physical
# derivation。issue 番号でパス末尾を照合するため `[ -n "$issue" ]` を要求する）が働かず `none` に
# 落ちる — 空 issue で分類できるのは flow-state に worktree 記録がある経路だけ。
# remove の 3 引数は既定値を持たず未指定で exit 2。
#
# detect の出力 (stdout):
#   [CONTEXT] CLEANUP_WT=<none|in_main|in_worktree|in_worktree_unrecorded>; worktree=<path>; \
#     [dirty=<yes|no>; ]main_root=<path>
#   [CONTEXT] CLEANUP_DELEGATED=1; reason=exit_worktree_unavailable   (in_worktree_unrecorded のみ)
#   [CONTEXT] CLEANUP_WT=unknown; reason=detect_classify_failed; rc=<n>
#     (内側の分類 helper cleanup-worktree-detect.sh が起動できない / 失敗したとき)
#   in_worktree のとき dirty が非空なら `--- dirty files begin/end ---` で囲んだ生パス一覧を続けて出す。
#
#   `CLEANUP_WT=unknown` は **呼び出し側 (cleanup/SKILL.md 4-W) も emit する** —— 本 helper 自体が
#   起動できなかった場合に `reason=detect_helper_failed` で出す。helper 自身は emit しないが、
#   marker family が同一で consumer の判定表 (cleanup/SKILL.md ステップ 12 の
#   {session_worktree_check}) は両者を同じ「未確認」として扱うため、値を追う人がここで
#   行き止まらないよう併記しておく。
#
# remove の出力 (stderr。削除成功時は marker を出さない — 呼び出し側の
#   {session_worktree_check} は「marker family が無い = 削除成功」で判定する):
#   [CONTEXT] WORKTREE_REMOVE_SKIPPED_LIVE_CWD=1; path=<path>
#   [CONTEXT] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1; path=<path>
#   [CONTEXT] WORKTREE_REMOVE_FAILED=1; path=<path>
#   --dry-run では削除せず [CONTEXT] DRY_RUN_WORKTREE_REMOVE=1; path=<path>; action=<...> を
#   **stdout** に出す（対象の報告であって失敗診断ではないため）。marker 名を `DRY_RUN_` 前置に
#   するのは、呼び出し側 (cleanup/SKILL.md ステップ 12 の {session_worktree_check}) が
#   `WORKTREE_REMOVE_*` の glob で marker family を scope するため。family 内の名前にすると
#   判定表のどの行にも一致せず fallback にも落ちない未定義状態を作る。
#   detect は read-only なので --dry-run を受理して no-op にする。
#
# --self-root を呼び出し側から受け取る理由:
#   抽出前は SKILL.md の bash が Bash tool のシェルとして走り、`$PPID` が claude ハーネスを指した。
#   helper 化すると `$PPID` は呼び出し元シェルになりハーネスへ届かない。self-exclusion の意味を
#   保つため、呼び出し側で `$PPID` を評価して渡す（`--self-root "$PPID"`）。
#
# exit code: 全運用経路 0（非ブロッキング）。usage error のみ 2。
#
# `set -e` は使わない: 判定は rc の捕捉に依存しており、-e は分岐を黙って殺す。
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

usage() {
  echo "ERROR: $1" >&2
  echo "Usage: cleanup-session-worktree-teardown.sh detect [--issue <N>] [--config <path>]" >&2
  echo "       cleanup-session-worktree-teardown.sh remove --worktree <path> --pr-merged <true|false> --self-root <pid> [--dry-run]" >&2
  exit 2
}

require_value() {
  # $1 = option name, $2 = remaining arg count
  [ "$2" -gt 0 ] || usage "$1 requires a value"
}

cmd_detect() {
  local issue="" config="rite-config.yml"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # `--issue` は値の欠落も空値として受ける（SKILL.md が `--issue {issue_number}` を
      # literal substitute するため、Issue 未識別のときトークンごと消えて `detect --issue` になる。
      # ここで落とすと marker が 1 本も出ず、消費側が marker 不在を削除成功と読む）。
      --issue)
        shift
        # 引数が尽きた（`detect --issue` で終端）ならそのまま空 issue。
        # 残っていれば、別のフラグ（`--config` 等）でない限り値として消費する。
        # **空文字列も値として shift する** — `--issue ""` を消費せずに抜けると、次の周回で
        # 空トークンが `*)` に落ちて "unknown option" の usage error になり、marker を 1 本も
        # 出さないまま exit 2 する（本 helper が閉じたはずの経路がトークンの形を変えて再発する）。
        if [ "$#" -gt 0 ]; then
          case "$1" in
            --*) ;;
            *) issue=$1; shift ;;
          esac
        fi
        ;;
      --config) shift; require_value --config "$#"; config=$1; shift ;;
      # detect は read-only（分類と marker の出力だけで、削除も書き込みもしない）。
      # --dry-run は受理して no-op にする — 全 helper が --dry-run を受けるという契約を
      # 満たしつつ、read-only な subcommand に別経路を作らないため。
      --dry-run) shift ;;
      *) usage "unknown option: $1" ;;
    esac
  done
  # `--issue` の空値・省略は usage error にしない。呼び出し側は cleanup/SKILL.md 4-W で、その
  # cleanup/SKILL.md ステップ 3 が「関連 Issue が識別できなければステップ 4 へ進む」を正規経路と
  # して宣言している。抽出前の cleanup-worktree-detect.sh は空 issue でも rc=0 で分類を返していた。
  # ここで落とすと marker が 1 本も出ず、{session_worktree_check} が marker 不在を「削除成功」と
  # 読むため未削除の worktree が削除済みと報告される。
  # なお空 issue では physical derivation が働かず `none` に落ちる（docstring 冒頭を参照）。

  local ms_section ms_enabled ms_base flow_wt cur_top main_root detect cleanup_wt dirty
  ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' "$config" 2>/dev/null) || ms_section=""
  ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ {print; exit}' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
  case "$ms_enabled" in true|yes|1) ms_enabled=true ;; *) ms_enabled=false ;; esac
  # worktree_base も読む（物理 cwd 検出時に worktree dir の親 leaf を照合する）
  ms_base=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
  [ -n "$ms_base" ] || ms_base=".rite/worktrees"
  flow_wt=$(bash "$PLUGIN_ROOT/hooks/flow-state.sh" get --field worktree --default "") || flow_wt=""
  cur_top=$(git rev-parse --show-toplevel 2>/dev/null) || cur_top=""
  # main checkout の絶対パスを削除前に確保する（自己削除後も main checkout を参照できるようにするため）。
  # `git worktree list --porcelain` の先頭 worktree entry は常に main checkout（git の仕様上保証）
  # なので、削除がまだ起きていないこの時点で取得すれば cwd の状態に関わらず正しい値が取れる。
  main_root=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}') || main_root=""
  # 検出は既存 helper に委譲する。flow-state 未記録（flow_wt 空）でも、物理 cwd が当該 Issue の
  # rite セッション worktree なら in_worktree_unrecorded を返し worktree= に cur_top を導出する。
  # 分類 helper が起動できない / 失敗したときに `none` へ落とすと、消費側は `none` を
  # 「行ごと省略」に routing するため、live で dirty な worktree が報告から完全に消える。
  # 呼び出し側が helper 起動失敗に対して使うのと同じ `unknown` へ寄せて未確認扱いにする
  # （消費側の判定は値 unknown のみで一致し reason 非依存なので、判定表の追加は不要）。
  if ! detect=$(bash "$SCRIPT_DIR/cleanup-worktree-detect.sh" \
    --ms-enabled "$ms_enabled" --flow-wt "$flow_wt" --cur-top "$cur_top" \
    --issue "$issue" --worktree-base "$ms_base"); then
    _cwd_rc=$?
    echo "WARNING: 分類 helper (cleanup-worktree-detect.sh) が rc=${_cwd_rc} で失敗しました。作業ツリーの分類ができていません" >&2
    echo "  原因候補: helper 欠落 (rc=127) / helper 非可読 (rc=126) / 引数不正 (rc=2)" >&2
    echo "[CONTEXT] CLEANUP_WT=unknown; reason=detect_classify_failed; rc=${_cwd_rc}"
    return 0
  fi
  cleanup_wt=${detect#CLEANUP_WT=}; cleanup_wt=${cleanup_wt%%;*}
  flow_wt=${detect##*worktree=}
  case "$cleanup_wt" in
    in_worktree)
      dirty=$(bash "$SCRIPT_DIR/lib/git-status-filtered.sh") || dirty="?? (dirty-check failed — assume dirty for safety)"
      echo "[CONTEXT] CLEANUP_WT=$cleanup_wt; worktree=$flow_wt; dirty=$([ -n "$dirty" ] && echo yes || echo no); main_root=$main_root"
      # dirty 一覧は marker と区別できるようデリミタで囲んで表示する（ファイル名由来の偽 marker 混入防止）
      if [ -n "$dirty" ]; then
        echo "--- dirty files begin ---"
        printf '%s\n' "$dirty"
        echo "--- dirty files end ---"
      fi
      ;;
    in_worktree_unrecorded)
      # EnterWorktree を経由しない path 入場のため ExitWorktree が no-op。main checkout へ
      # 退出できないまま base 更新・worktree 削除・ブランチ削除・wiki ingest を試行すると、harness の
      # worktree 隔離ガードが拒否する（実測）。試行せず委譲する。
      # dirty チェックは worktree を削除しないため不要（未コミット変更は worktree に残り、失われない）。
      echo "[CONTEXT] CLEANUP_WT=$cleanup_wt; worktree=$flow_wt; main_root=$main_root"
      echo "[CONTEXT] CLEANUP_DELEGATED=1; reason=exit_worktree_unavailable"
      ;;
    *)
      echo "[CONTEXT] CLEANUP_WT=$cleanup_wt; worktree=$flow_wt; main_root=$main_root"
      ;;
  esac
  return 0
}

cmd_remove() {
  local flow_wt="" pr_merged="" self_root="" dry_run=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree)  shift; require_value --worktree "$#";  flow_wt=$1; shift ;;
      --pr-merged) shift; require_value --pr-merged "$#"; pr_merged=$1; shift ;;
      --self-root) shift; require_value --self-root "$#"; self_root=$1; shift ;;
      --dry-run)   dry_run=true; shift ;;
      *) usage "unknown option: $1" ;;
    esac
  done
  [ -n "$flow_wt" ] || usage "--worktree is required"
  # --pr-merged / --self-root にデフォルトを置かない。前者は PR の mergedAt に基づく呼び出し側の
  # 判断で bash からは導出できず、既定値を入れると未マージ作業を強制削除しうる。後者は
  # ハーネスの pid で、helper 内の $PPID では代用できない（上部コメント参照）。
  case "$pr_merged" in true|false) ;; *) usage "--pr-merged must be true or false" ;; esac
  case "$self_root" in ''|*[!0-9]*) usage "--self-root must be a pid" ;; esac

  # rc 0 = 別の live セッションが cwd を置く → 削除を遅延 / rc 1 = 自セッションだけ or 不在
  #        → 削除 / rc 2 = 判定不能（/proc 無し）→ 削除（従来 worktree-live-cwd.sh rc=2 と同じ後方互換）。
  # --self-root で呼び出し側ハーネスの process subtree を self として除外する。
  local _fc_rc=0
  bash "$SCRIPT_DIR/worktree-foreign-cwd.sh" "$flow_wt" --self-root "$self_root" >/dev/null 2>&1 || _fc_rc=$?
  # sandbox マスク検知: sandbox が admin dir の config.worktree に /dev/null マスクマウントを
  # 張っている（= character device に見える）状態で `git worktree remove`（--force 含む）を
  # 実行すると、working tree 削除失敗後の admin dir 再帰削除が HEAD を unlink した直後に
  # マスクの EBUSY で中断し、HEAD のみ欠けた半壊 admin dir（corpse）が残る。削除試行自体が
  # 半壊を作るため、busy 失敗後の対処では防げない — 検知したら remove を一切実行せず遅延 reap
  # （corpse 回収経路を持つ pr-cycle-cleanup.sh Step 5）へ委譲する。admin dir は worktree 側
  # .git ファイルの gitdir: 行から解決する（解決不能・マスク無しなら従来どおり remove を試行 =
  # 非 sandbox 環境で挙動不変の後方互換）。
  local _wt_admin
  _wt_admin=$(sed -n 's/^gitdir: //p' "$flow_wt/.git" 2>/dev/null | head -1) || _wt_admin=""
  if [ "$_fc_rc" -eq 0 ]; then
    # 多バイト文字に隣接する変数展開は必ず brace で閉じる。`$flow_wt）` と書くと bash が
    # `）` の先頭バイトを変数名に取り込み、非 UTF-8 ロケールで変数が未定義化する
    # （invariant: hooks/tests/flow-state.test.sh TC-8b-h）。
    echo "WARNING: 別のセッションがこの作業ツリー（${flow_wt}）を使用中のため、削除を見送りました。そのセッションが終了したあと、次回のセッション開始時に作業ツリーとローカルブランチが自動で回収されます。" >&2
    echo "[CONTEXT] WORKTREE_REMOVE_SKIPPED_LIVE_CWD=1; path=$flow_wt" >&2
  elif [ -n "$_wt_admin" ] && [ -c "$_wt_admin/config.worktree" ]; then
    echo "WARNING: sandbox が作業ツリーの管理ディレクトリ（$_wt_admin/config.worktree）にマスクマウントを張っているため、削除を見送りました。この状態で git worktree remove を実行すると管理ディレクトリが半壊するため、削除自体を試行しません。次回のセッション開始時（sandbox 外）に作業ツリーとローカルブランチが自動で回収されます。実行エージェントはこの場で sandbox を無効化して remove を再試行しないこと。" >&2
    echo "[CONTEXT] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1; path=$flow_wt" >&2
    # admin dir 半壊では、このマスク検知は次に control が渡る側（corpse）の直接の前兆であり、
    # corpse は checkout 中 branch を git で解決できないため pr-cycle-cleanup.sh Step 5 の
    # ブランチ名 manifest bypass が構造的に効かない。パス自体を事前に記録しておけば、corpse age
    # guard がこの記録を見て 24h 待ちをバイパスできる（{pr_merged}=true のときのみ — 未マージ PR の
    # 強制 cleanup では記録しない）。record 自体は non-blocking 契約（rite-tmp-artifact.sh）。
    # `--type session_worktree`（`worktree` ではない）: `worktree` type は Step 4.5 の ungated reap
    # （dirty チェックのみ、claim/self-exclusion/live-cwd ガード無し）が消費する EPHEMERAL tmp
    # artifact 専用の契約を持つ。session worktree のパスをそこに混ぜると、Step 4.5 が Step 5 の
    # 保護ゲートを経ずに生存中の worktree を reap しうる。
    if [ "$pr_merged" = "true" ]; then
      if [ "$dry_run" = "true" ]; then
        echo "[CONTEXT] DRY_RUN_WORKTREE_REMOVE=1; path=$flow_wt; action=record_session_worktree"
      else
        bash "$SCRIPT_DIR/rite-tmp-artifact.sh" record --type session_worktree --id "$flow_wt" 2>/dev/null || true
      fi
    fi
  elif [ "$dry_run" = "true" ]; then
    # 削除対象を報告するだけで remove / prune を実行しない。marker 名を `DRY_RUN_` 前置にして
    # 呼び出し側 ({session_worktree_check}) が scope する glob `WORKTREE_REMOVE_*` の外へ出す
    # （family 内だと「marker 不在 = 削除成功」の判定を dry-run の 1 行が壊す）。
    echo "[CONTEXT] DRY_RUN_WORKTREE_REMOVE=1; path=$flow_wt; action=remove_worktree"
  else
    # git 診断メッセージは locale 翻訳で揺れるため LC_ALL=C で固定し、busy 検出の substring
    # マッチを安定させる。stderr を一時ファイルに退避するのは、通常 fallback（remove →
    # remove --force）のどちらで失敗しても最後の失敗理由を busy 判定に使うため。
    local _wt_rm_err
    _wt_rm_err=$(mktemp 2>/dev/null) || _wt_rm_err=""
    if LC_ALL=C git worktree remove "$flow_wt" 2>"${_wt_rm_err:-/dev/null}" \
       || LC_ALL=C git worktree remove --force "$flow_wt" 2>"${_wt_rm_err:-/dev/null}"; then
      :
    else
      echo "[CONTEXT] WORKTREE_REMOVE_FAILED=1; path=$flow_wt" >&2
      if [ -n "$_wt_rm_err" ] && grep -qi "busy" "$_wt_rm_err" 2>/dev/null; then
        echo "WARNING: worktree 削除が「Device or resource busy」で失敗しました。Claude Code の sandbox が worktree の .git/worktrees/*/config.worktree・commondir に read-only bind mount を張っている環境では、sandbox 内からの git worktree remove（--force 含む）は構造的に失敗します。この失敗は意図的に non-blocking として遅延 reap（pr-cycle-cleanup.sh）へ委譲するため、実行エージェントはこの場で sandbox を無効化して同コマンドを再試行しないこと。復旧: ユーザーが sandbox 外のシェルで次を実行してください: git worktree remove --force '$flow_wt' && git worktree prune" >&2
      fi
      # remove --force 自体がこの busy 失敗の過程で admin dir を部分破壊し corpse 化した場合、
      # 上記マスク検知分岐と同じ理由でブランチ名 bypass が効かなくなる。パスを reap manifest に
      # 記録し、pr-cycle-cleanup.sh の corpse age guard バイパスに委ねる（{pr_merged}=true のときのみ）。
      if [ "$pr_merged" = "true" ]; then
        bash "$SCRIPT_DIR/rite-tmp-artifact.sh" record --type session_worktree --id "$flow_wt" 2>/dev/null || true
      fi
    fi
    [ -n "$_wt_rm_err" ] && rm -f "$_wt_rm_err"
    git worktree prune 2>/dev/null || true
  fi
  return 0
}

[ "$#" -gt 0 ] || usage "subcommand is required (detect|remove)"
subcommand=$1
shift
case "$subcommand" in
  detect) cmd_detect "$@" ;;
  remove) cmd_remove "$@" ;;
  *) usage "unknown subcommand: $subcommand" ;;
esac
exit 0
