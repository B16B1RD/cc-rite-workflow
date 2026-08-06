#!/bin/bash
# rite workflow - Review Cycle Scope Determination (cycle 1 / cycle 2+ 差分スコープ)
#
# Responsibility: 当該 PR の永続レビュー JSON (skills/pr-review/SKILL.md ステップ 6.1.a の
# 保存先 `{state_root}/.rite/review-results/{pr}-*.json`) だけを入力に、今回のレビューを
# full scope (cycle 1) で回すか incremental scope (cycle 2+ 差分スコープ) で回すかを決める。
# あわせて差分の起点 commit と、前サイクルで blocking を出した reviewer_type を抽出する。
#
# 設計根拠の SoT: skills/pr-review/references/cycle-scope.md
#   - なぜ判定入力を PR コメントでなく永続 JSON にするか (既定 post_comment: false)
#   - なぜ二値であって cycle 数の段階判定ではないか (finding-cycling.md の degradation 禁止)
#   - なぜ情報欠落時に必ず full へ倒すか
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 1.2.4 (Review Scope Determination)
#
# Usage:
#   bash review-cycle-scope.sh --pr <n> [--results-dir <dir>] [--since <basename>]
#
#   --pr           PR 番号 (数値必須)。JSON ファイル名 `{pr}-{timestamp}.json` の照合に使う。
#   --results-dir  review-results ディレクトリ。省略時は hooks/state-path-resolve.sh で解決した
#                  state root 配下 `.rite/review-results` (書込側 hooks/review-result-save.sh と
#                  同一解決。セッション worktree / main checkout のどちらから実行しても同じ物理
#                  パスを読む)。解決失敗時は cwd 相対へフォールバックする。
#   --since        現 run の開始点となる JSON basename。これより LC_ALL=C 昇順で後ろのファイルだけを
#                  現 run のものとみなす。省略時は state root 配下
#                  `.rite/state/review-run-since-{pr}.txt` を読む (書き手は skills/iterate/SKILL.md
#                  ステップ 0.6。sibling hooks/scripts/review-trend-divergence.sh と同一 pin)。
#                  同ディレクトリは /rite:cleanup まで同一 PR の複数 run を同居させるため、pin を
#                  見ないとブレーカー発火後の再実行で cycle 1 が前 run の JSON を拾って
#                  incremental になる。pin 不在 / 空のときは全件を現 run とみなす (新規 PR の正常系)。
#
# git 操作は cwd のリポジトリに対して行う (caller はセッション worktree 内で実行する)。
#
# Output — stderr (observability contract。stdout は使わない):
#   [CONTEXT] REVIEW_CYCLE_SCOPE=incremental; base_sha=<sha>; prev_json=<path>; prev_finders=<csv>
#   [CONTEXT] REVIEW_CYCLE_SCOPE=full; reason=<reason>
#   [CONTEXT] REVIEW_CYCLE_SCOPE_FALLBACK=1; reason=<reason>   ← no_prev_json 以外で追加 emit
#   ⚠️ 差分スコープのフォールバック: ...                        ← 同上 (人間向け)
#
#   prev_finders は前サイクルの findings[] と non_blocking_findings[] の**和**のうち
#   **gated scope (current-pr / follow-up)** の finding だけを対象に reviewer を agent 名から
#   reviewer_type へ正規化 (`-reviewer` サフィックス除去) し unique + カンマ区切りにしたもの。
#   **findings[] 全体は blocking 集合ではない** — review-measured-gate.sh は scope == "nit-noted"
#   をゲート対象外として非実測でも findings[] に残すため、実体は blocking 集合と全 nit-noted 集合の
#   和である。逆に非実測の gated 指摘は non_blocking_findings[] へ *移送* されるため findings[] には
#   残らない。両方を読み gated scope で絞ることで、nit だけの reviewer を除きつつ未解消の
#   非実測指摘を出した reviewer は取りこぼさない。空になりうる (前サイクルの gated 指摘が
#   0 件だった場合)。統合済み旧 type
#   (api/frontend/performance/database/type-design) の読み替えは caller 側の責務
#   (skills/reviewers/SKILL.md の Legacy Reviewer Type Aliases 表が SoT)。
#
# Fallback reason 語彙 (SoT。skills/pr-review/SKILL.md ステップ 1.2.4 の reason 表と同期):
#   no_prev_json          — 当該 PR の review-results JSON が無い (cycle 1 の正常経路。WARNING なし)
#   prev_json_unreadable  — JSON が壊れている / jq で読めない / 探索中に IO エラー
#   commit_sha_missing    — .commit_sha が空 / null / キー欠落 (旧形式)
#   commit_sha_unreachable— 起点 commit が履歴から消失 (force-push / rebase)
#   diff_failed           — git diff {sha}..HEAD が失敗
#   empty_diff            — git diff {sha}..HEAD は成功したが差分ゼロ行 (前回起点から新規 commit なし。
#                           /rite:fix の accept-only cycle で base_sha == HEAD となり必ず成立する)
#   run_pin_unresolved    — state root を解決できず run 開始点 pin の在否を確認できない
#   run_pin_unreadable    — run 開始点 pin は存在するが読めない
#   jq_missing            — jq が PATH 上に無い
#
# Exit codes:
#   0 = スコープ決定完了 (incremental / full のいずれも正常終了)
#   2 = usage error (--pr 欠落 / 非数値)
#
# Why fail-safe instead of fail-loud on jq_missing:
#   sibling helper (review-measured-gate.sh 等) は jq 不在を exit 1 の fatal として扱う。それらは
#   レビュー結果 JSON を **書き換える** ため、環境が壊れた状態で先へ進ませてはならないからである。
#   本 script は状態を書き換えず「どちらのスコープで回すか」を選ぶだけで、情報が何も得られない
#   ときの安全な選択 (full = 従来どおりの徹底レビュー) が常に存在する。ここで exit 1 を返すと
#   caller の bash が失敗し、スコープ最適化の失敗がレビュー自体の失敗に昇格してしまう。
#   これは Issue #2118 AC-3 が要求する「取得不能なら WARNING を出してフルレビューへ倒れる」の
#   契約そのものでもある。silent fallback ではない — 全経路で reason 付き marker を emit する。
set -uo pipefail

_rcs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/scripts/lib/tempfile.sh
source "$_rcs_dir/../hooks/scripts/lib/tempfile.sh"

PR_NUMBER=""
RESULTS_DIR=""
RUN_SINCE=""
RUN_SINCE_SET=0

# `shift 2` は使わない。値なしフラグが argv 末尾に来ると n > $# で shift が $# を変えずに rc=1 を
# 返し、set -e 非設定 + ${2:-} で nounset も発火しない本 script では while を抜けられず hang する
# (無人ループの /rite:iterate / /rite:batch-run では診断ゼロの無期限停止になる)。1 回目の shift で
# $# を確実に 0 にし 2 回目を no-op にする house convention に従う
# (sibling: scripts/review-source-resolve.sh、機械検査: hooks/tests/shift2-loop-hardening.test.sh)。
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)          PR_NUMBER="${2:-}"; shift; shift ;;
    --results-dir) RESULTS_DIR="${2:-}"; shift; shift ;;
    --since)       RUN_SINCE="${2:-}"; RUN_SINCE_SET=1; shift; shift ;;
    *) echo "ERROR: review-cycle-scope: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-cycle-scope: --pr は数値必須です (received: '${PR_NUMBER}')" >&2
    exit 2 ;;
esac

# full へ倒して終了する共通経路。no_prev_json だけは cycle 1 の正常経路なので WARNING を出さない。
emit_full() {
  local reason="$1"
  echo "[CONTEXT] REVIEW_CYCLE_SCOPE=full; reason=$reason" >&2
  if [ "$reason" != "no_prev_json" ]; then
    echo "⚠️ 差分スコープのフォールバック: reason=${reason}。フルレビュー (全 reviewer・フル diff) で実行します。" >&2
    echo "[CONTEXT] REVIEW_CYCLE_SCOPE_FALLBACK=1; reason=$reason" >&2
  fi
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_full jq_missing

# state root は results dir と run 開始点 pin の両方が使う。resolver は内部で git を複数回叩くため
# 1 回だけ解決して共有し、失敗時の告知も単一経路にまとめる (house convention: hooks/ の 5 ファイルと同形)。
_rcs_root=""
if [ -z "$RESULTS_DIR" ] || [ "$RUN_SINCE_SET" -eq 0 ]; then
  _rcs_root=$(bash "$_rcs_dir/../hooks/state-path-resolve.sh" "$PWD" 2>/dev/null) || _rcs_root=""
  [ -n "$_rcs_root" ] || echo "WARNING: review-cycle-scope: state-path-resolve.sh の解決に失敗しました" >&2
fi

if [ -z "$RESULTS_DIR" ]; then
  if [ -n "$_rcs_root" ]; then
    RESULTS_DIR="$_rcs_root/.rite/review-results"
  else
    echo "  cwd 相対の .rite/review-results へフォールバックします" >&2
    RESULTS_DIR=".rite/review-results"
  fi
fi

# dir 不在は初回レビュー (cycle 1) の正常経路
[ -d "$RESULTS_DIR" ] || emit_full no_prev_json

# run 開始点 pin。`.rite/review-results/` は `/rite:cleanup` (マージ後) まで同一 PR の**複数 run**
# を同居させるため、pin を見ないと「サーキットブレーカー発火後に人間が再実行した run の cycle 1」が
# 前 run の最終 JSON を拾って incremental になる。§4.4 MUST NOT「cycle 1 の挙動を変えない」に
# 反し、失敗方向が禁じられている狭い側。同一ディレクトリの同じ問題を sibling
# `hooks/scripts/review-trend-divergence.sh` が `--since BASENAME` + pin ファイルで解決済みなので、
# 同じ pin を同じ読み方 (LC_ALL=C 昇順比較) で共有する。pin の書き手は
# `skills/iterate/SKILL.md` ステップ 0.6 で、fresh run ごとに「その時点の最新 basename」を記録する。
# pin 不在 / 空 = 新規 PR または pin を書けなかった run で、そのときは全件を現 run とみなす
# (書き手側が同じ縮退を WARNING で告知済み)。
# pin **不在**は「新規 PR / pin を書けなかった run」で、そのときは全件を現 run とみなす (書き手側が
# 同じ縮退を WARNING で告知済み)。pin が**存在するのに読めない**のは別物として扱う — 区別しないと
# 全 fail-safe のうちこの経路だけが狭い側 (incremental) へ倒れる。cycle-scope.md が「欠落時の安全側は
# 常に広い方」と定める以上、読めない pin も、pin の在否を確かめられない状態も広い側へ倒す。
if [ "$RUN_SINCE_SET" -eq 0 ]; then
  if [ -z "$_rcs_root" ]; then
    echo "  run 開始点 pin の在否を確認できないため、前 run の JSON を現 run と誤認しないよう full へ倒します" >&2
    emit_full run_pin_unresolved
  fi
  _rcs_pin="$_rcs_root/.rite/state/review-run-since-${PR_NUMBER}.txt"
  if [ -f "$_rcs_pin" ]; then
    rite_tempfile_init
    rite_tempfile_new pin_err "rcs-pin-err" || emit_full run_pin_unreadable
    if ! RUN_SINCE=$(head -1 "$_rcs_pin" 2>"$pin_err"); then
      echo "WARNING: review-cycle-scope: run 開始点 pin を読めません: $_rcs_pin" >&2
      head -3 "$pin_err" | sed 's/^/  /' >&2
      emit_full run_pin_unreadable
    fi
  fi
fi

rite_tempfile_init
rite_tempfile_new find_err "rcs-find-err" || emit_full prev_json_unreadable

# mapfile + process substitution で SIGPIPE 経路を断つ (scripts/review-source-resolve.sh Priority 2 と同形)。
# sort の stderr も同じファイルへ追記し、探索段の IO エラーを取りこぼさない。
cs_files=()
mapfile -t cs_files < <(find "$RESULTS_DIR" -maxdepth 1 -type f -name "${PR_NUMBER}-*.json" 2>"$find_err" | sort -r 2>>"$find_err")

# IO エラーを「JSON が無い (= cycle 1)」と誤認すると、探索に失敗しただけの状態が silent に
# cycle 1 扱いになる。loud な prev_json_unreadable として区別する。
if [ -s "$find_err" ]; then
  echo "WARNING: review-cycle-scope: $RESULTS_DIR/ の探索でエラーが発生しました:" >&2
  head -3 "$find_err" | sed 's/^/  /' >&2
  emit_full prev_json_unreadable
fi

# pin より新しい (LC_ALL=C 昇順で pin を超える) basename だけが現 run のもの。ソート順は
# 書き手側 (iterate ステップ 0.6) の `LC_ALL=C sort` と揃える。
if [ -n "$RUN_SINCE" ]; then
  _rcs_kept=()
  for _rcs_f in ${cs_files[@]+"${cs_files[@]}"}; do
    if [ "$(printf '%s\n%s\n' "$RUN_SINCE" "$(basename "$_rcs_f")" | LC_ALL=C sort | tail -1)" != "$RUN_SINCE" ]; then
      _rcs_kept+=("$_rcs_f")
    fi
  done
  cs_files=(${_rcs_kept[@]+"${_rcs_kept[@]}"})
fi

prev_json="${cs_files[0]:-}"
[ -n "$prev_json" ] || emit_full no_prev_json

# 失敗経路の診断は捨てない。`.rite/review-results/` は同一 PR の JSON を timestamp 付きで複数世代
# 持つため、reason だけでは「どのファイルが壊れていたか」を運用者が特定できない
# (canonical: 探索段の find/sort と同じ selective surface。1 ファイル内で診断を出す経路と
# 捨てる経路が同居する非対称を作らない)。
rite_tempfile_new probe_err "rcs-probe-err" || emit_full prev_json_unreadable

if ! jq empty "$prev_json" 2>"$probe_err"; then
  echo "WARNING: review-cycle-scope: 前回レビュー JSON を parse できません: $prev_json" >&2
  head -3 "$probe_err" | sed 's/^/  /' >&2
  emit_full prev_json_unreadable
fi

# 抽出失敗 (トップレベルが object でない等の rc!=0) と、キー欠落 (rc=0 で空) を分ける。
# 融合すると前者が commit_sha_missing = docstring 上「旧形式」= 良性 として報告され、
# 破損が旧形式互換の顔をして運用者に無視される。診断も他 4 経路と同じ形で surface する。
if ! base_sha=$(jq -r '.commit_sha // empty' "$prev_json" 2>"$probe_err"); then
  echo "WARNING: review-cycle-scope: commit_sha を抽出できません: $prev_json" >&2
  head -3 "$probe_err" | sed 's/^/  /' >&2
  emit_full prev_json_unreadable
fi
if [ -z "$base_sha" ]; then
  echo "WARNING: review-cycle-scope: commit_sha が空 / 欠落しています: $prev_json" >&2
  emit_full commit_sha_missing
fi

# `^{commit}` を付けて「commit として解決できる」ことまで確認する (blob/tree の SHA を誤って
# 起点に据えない)。起点 object が object DB に無ければここで落ちる。
# **到達性 (HEAD の祖先か) までは見ない** — ローカル rebase / reset 直後の旧 commit は gc されるまで
# object DB に残り本検査を通過する。その場合 `base_sha..HEAD` は tree 間差分として rebase 分を
# 巻き込むが、失敗方向は「差分が広くなる」= 安全側のため許容する。
if ! git cat-file -e "${base_sha}^{commit}" 2>"$probe_err"; then
  echo "WARNING: review-cycle-scope: 起点 commit を解決できません (base_sha=$base_sha)" >&2
  head -3 "$probe_err" | sed 's/^/  /' >&2
  emit_full commit_sha_unreachable
fi

diff_names=$(git diff --name-only "${base_sha}..HEAD" 2>"$probe_err") || {
  echo "WARNING: review-cycle-scope: 差分を取得できません (${base_sha}..HEAD)" >&2
  head -3 "$probe_err" | sed 's/^/  /' >&2
  emit_full diff_failed
}

# rc=0 かつ出力ゼロ行 = 前回レビュー起点から新規 commit が無い。`/rite:fix` の accept-only cycle
# (commit も push もせず fingerprint 永続化のみ) で `base_sha == HEAD` となり必ず成立する。
# このまま incremental を宣言すると caller の照合入力も reviewer prompt の diff も空になり、
# 「前回 blocking の解消検証すら実行できない prompt」で全 reviewer が起動して無音で mergeable へ
# 抜ける。rc だけを見ると成功に見えるので、出力の有無を独立した判定材料にする。
if [ -z "$diff_names" ]; then
  echo "WARNING: review-cycle-scope: 前回レビュー起点から新規 commit がありません (base_sha=$base_sha)" >&2
  emit_full empty_diff
fi

# 前サイクルで gated scope (current-pr / follow-up) の指摘を出した reviewer を、健全性検査と
# 同一の jq で抽出する。
#
# **母集団は `findings[]` と `non_blocking_findings[]` の和**。実測必須ゲートは非実測の gated
# 指摘を `findings[]` から `non_blocking_findings[]` へ *移送* する (`.findings = $kept`) ため、
# 当該 cycle の gated 指摘が全件非実測だった reviewer は `findings[]` に 1 件も残らない。
# `findings[]` だけを見ると、その reviewer は次 cycle の mandatory 合流から外れ、fix diff が
# パターンに一致しなければ一度も起動しない。非実測指摘の記録コメントは update-in-place で
# 毎 cycle 本文を置換するため、再導出されないと PR 上の記録からも消える
# (差分スコープ導入前は cycle 2+ も全 reviewer × フル diff だったので毎 cycle 再導出されていた)。
# **nit-noted は和に含めない** — nit は「修正不要」と決着済みで再検証の価値が無く、含めると
# cap 免除枠を占有する。非実測の current-pr / follow-up は「merge は止めないが未解消」であり、
# 再検証と再記録の価値がある。この区別が母集団を分ける根拠。
#
# **健全性検査と抽出は 1 本の jq に畳む**。別々に書くと (a) 検査述語と抽出条件がずれても気付けず、
# ずれた分の要素が検査を通って抽出側で無音 drop される、(b) 検査が真を返した後の抽出は構造的に
# 失敗しえないため 2 本目の fail-safe が到達不能コードになる、(c) 検査が「不正あり」で正常終了する
# 主経路では jq が stderr に何も書かないため `$probe_err` 経由の原因行が常にゼロ行になる。
# 1 本に畳めば抽出条件そのものが検査述語になり (a) が構造的に消え、fail-safe は 1 本になり (b) が
# 消え、違反 finding の id を同じ jq 内で列挙できるので (c) も消える。
#
# **reviewer と id は「値の形」まで検査する**。型と非空だけでは足りない — 下流の marker 行
# (`[CONTEXT] ... ; prev_finders=...`) と診断行 (`該当 finding: ...`) はどちらも `; ` 区切りの
# 単一行を前提とする消費者で、値に改行が入れば 2 本目の整形式 marker が column 0 に出て
# `base_sha` が偽値に解決され、`; ` が入れば同一行に重複フィールドが付く (本 repo の
# `marker_value_of` は最後の出現を採る)。`-reviewer` 単体は `sub` 後に空になり phantom 要素を生む。
# アンカーは `^` / `$` ではなく `\A` / `\z` を使う。jq (Oniguruma) の `$` は文字列末尾に加えて
# **末尾改行の直前**にも match するため、`$` では末尾改行 1 個を持つ値が allowlist を通り、
# まさに閉じたかった marker 行の分断が起きる。
# reviewer は `skills/reviewers/SKILL.md` の reviewer_type がすべて小文字ケバブ、id は書込側
# `hooks/review-result-save.sh` の canonical regex `^F-[0-9]{2,}$` が SoT なので、その形へ寄せる。
# 改行だけを潰す対症では `; ` 注入と phantom 要素が残るため、形の allowlist で一括して閉じる。
#
# 出力は `OK\t{csv}` か `BAD\t{違反 id 列}` のタブ区切り 1 行。reviewer は agent 名
# (`code-quality-reviewer`) で入るため reviewer_type へ正規化する。jq 自体の失敗 (トップレベルが
# object でない等) は握り潰さない — 空の `prev_finders=` は「gated 指摘 0 件」の正常系と
# バイト単位で同一で区別できないため、既存の loud な fail-safe へ合流させる。
scope_probe=$(jq -r '
  def valid:
    (((.scope // "") | . == "current-pr" or . == "follow-up" or . == "nit-noted"))
    and (((.reviewer? // null) | type) == "string")
    and ((.reviewer // "") | test("\\A[a-z][a-z0-9-]*[a-z0-9]\\z"));
  [(.findings[]?, .non_blocking_findings[]?)] as $all
  | ($all | map(select(valid | not))) as $bad
  | if ($bad | length) > 0 then
      "BAD\t" + ($bad | map(.id | if (type == "string" and test("\\AF-[0-9]{2,}\\z")) then . else "(不正 id)" end) | join(", "))
    else
      "OK\t" + ([$all[]
                  | select((.scope // "") == "current-pr" or (.scope // "") == "follow-up")
                  | .reviewer | sub("-reviewer$";"")] | unique | join(","))
    end
' "$prev_json" 2>"$probe_err") || {
  echo "WARNING: review-cycle-scope: 前回 finder を抽出できません: $prev_json" >&2
  head -3 "$probe_err" | sed 's/^/  /' >&2
  emit_full prev_json_unreadable
}

case "$scope_probe" in
  BAD*)
    echo "WARNING: review-cycle-scope: findings[] / non_blocking_findings[] に scope が enum 外 / 欠落、または reviewer が欠落・非文字列・空文字の finding があります: $prev_json" >&2
    echo "  該当 finding: ${scope_probe#BAD	}" >&2
    emit_full prev_json_unreadable
    ;;
  # 上の jq は rc=0 のとき必ず `BAD` / `OK` prefix で始まる 1 行を返す (if/else が網羅) ため、
  # 第 3 の arm は到達しない。到達不能な fail-safe を置かない方針は上の 1 本化の根拠 (b) と同じ。
  OK*) prev_finders="${scope_probe#OK	}" ;;
esac

echo "[CONTEXT] REVIEW_CYCLE_SCOPE=incremental; base_sha=$base_sha; prev_json=$prev_json; prev_finders=$prev_finders" >&2
exit 0
