#!/bin/bash
# rite workflow - Issue Complexity Lane Determination (XS/S 軽量レーン)
#
# Responsibility: 対象 Issue の**宣言 Complexity** だけを入力に、後続工程を軽量レーン (light)
# で回すかフル装備 (full) で回すかを決める。判定器は作らない — 宣言値をそのまま読む
# (判定器は speculative であり、宣言 + Cross-File Impact Check の安全網で足りるため)。
#
# 設計根拠の SoT: skills/pr-review/references/complexity-lane.md
#   - なぜレーン境界を {XS, S} / {M, L, XL} の二値にするか
#   - なぜ reviewer 上限を reviewers/SKILL.md Phase 5 に置くか (cap の SoT は 1 つ)
#   - 何を軽量化し、何を軽量化しないか (採否基準・Cross-File Impact Check は不変)
#   - なぜ情報欠落時に必ず full へ倒すか
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 1.3.2 (Complexity Lane Determination)
#   - skills/issue-implement/SKILL.md 5.0.C (Complexity Lane Determination。emit した marker を
#     5.1.0.1 の並列実装ゲートと 5.1.0.8 の生産量制約の両方へ供給する)
#
# Usage:
#   bash issue-complexity-lane.sh --issue <n> --repo <owner/repo> [--cwd <absolute-path>]
#
#   --issue  Issue 番号 (数値必須)。
#   --repo   入口で解決した owner/repo (必須)。cwd の origin と一致すること。
#            `gh` には常に -R を明示する。
#            (省略すると SSH host alias 環境で別リポジトリを引く — references/gh-cli-patterns.md)。
#
#   --cwd    実行場所を絶対パスで固定する。省略時は現在の cwd を照合する。
#            skill は入口で保持した execution_cwd を明示する。
#
# Complexity の入力源は Issue body の宣言と、GitHub Projects の Complexity フィールドの 2 つ
# (flow-state は complexity フィールドを持たない)。body に宣言があればそれを使い、宣言らしき行が
# 無ければ Projects の値を使う (宣言らしき行があるのに値を取り出せない body は Projects で補わない)。Projects は rite-config.yml の github.projects.enabled: true のときだけ読み、
# body に宣言があっても読む — 両方に値があって食い違えば complexity_mismatch で停止する。
# フィールド名は github.projects.fields.complexity.name → 複雑度 → Complexity の順で探す
# (Issue 作成 helper と同じ候補順)。fields.complexity.enabled: false は連携無効と同じ扱い。
# body の宣言について、リポジトリ内に 3 つの記法が併存するため**すべて**を受理する — 一部だけ読むと、他の記法で
# 書かれた Issue が全て complexity_absent で full へ倒れ、レーンが一度も発動しない:
#   1. `**Complexity**: X`      — templates/issue/template-structure.md Section 0 Meta (現行 rite 形式)
#   2. `## 複雑度` セクション    — skills/rite-workflow/references/common-principles.md の記載形式
#   3. `| **Complexity** | X |` — Section 0 Meta を表で書いた形 (テンプレートを経ず LLM / 人間が
#                                 書いた実運用 Issue に定常的に現れる。生成する code path は無い)
# 探索順は 1 → 2 → 3 で、先に見つかった方を採る。**明示宣言を先に読み、表行を最後に読む**のが
# 順序の規律 — 本 helper は code fence を剥がさないため、表記法そのものを**説明している** Issue が
# 本文中の例から値を解決してしまう。記法 1 の Meta 行と記法 2 の `## 複雑度` 節は「そこが宣言で
# ある」ことを形で示すが、表行は body のどこにでも現れうるので最後に回す。
# 値は大小文字を問わず XS/S/M/L/XL に正規化する。
#
# Output — stderr (observability contract。stdout は使わない):
#   [CONTEXT] COMPLEXITY_LANE=light; complexity=<XS|S>; source=<body_meta|body_table|body_section|projects_field>
#   [CONTEXT] COMPLEXITY_LANE=full; complexity=<M|L|XL>; source=<body_meta|body_table|body_section|projects_field>
#   [CONTEXT] COMPLEXITY_LANE=full; reason=<reason>                 ← fail-safe 経路
#   [CONTEXT] COMPLEXITY_LANE_FALLBACK=1; reason=<reason>           ← fail-safe 経路で追加 emit
#   ⚠️ Complexity レーン判定のフォールバック: ...                    ← 同上 (人間向け)
#
# Fallback reason 語彙 (SoT。skills/pr-review/SKILL.md ステップ 1.3.2 /
# skills/pr-review/references/complexity-lane.md の reason 表と同期):
#   gh_missing            — gh が PATH 上に無い
#   repo_unresolved       — 明示 repo / cwd の origin を解決できない (停止、fallback しない)
#   repo_mismatch         — 明示 repo と cwd の origin が異なる (停止、fallback しない)
#   issue_fetch_failed    — gh issue view が失敗した (認証切れ / rate limit / Issue 不在)、
#                           **および** その stderr 捕捉用 tempfile を確保できなかった
#                           (取得に必要な資源が揃わない点で同じ帰結。sibling の
#                            review-cycle-scope.sh が mktemp 失敗を run_pin_unreadable へ
#                            帰属させるのと同型)
#   complexity_absent     — body に上記 3 記法のいずれも「値を取り出せる形で」現れない
#                           (rite 外で作られた Issue、崩れた記法 = lowercase key / 全角コロン /
#                            リスト項目化 / 太字なしの表セル、`{complexity}` のような未展開
#                            placeholder と `<!-- ... -->`、**および値行を持たない `## 複雑度` 節**。
#                            記法 1 と 3 は値の先頭に英字を要求し、記法 2 は `{` `<` を値の開始と
#                            認めず節探索を次見出しで止めるため、これらはすべて「無い」側に合流する
#                            — 記法や見出し語の言語で reason が分裂しない)
#                           次の 2 つの場合がある:
#                           (1) 宣言らしき行が無く、Projects にも値が無い (連携無効 / Project 未登録 /
#                               フィールド値なし)。探した場所と追記する 1 行の書式を stderr に示す
#                           (2) 宣言らしき行はあるが値を取り出せない。Projects の状態 (有効値 / 不正値 /
#                               取得失敗) に関わらず Projects の値では補わず、行番号 WARNING と、
#                               Projects の値を使っていない旨と本文の宣言を直す案内を stderr に示す
#   complexity_invalid    — 英字トークンは取り出せたが XS/S/M/L/XL のいずれでもない
#                           (`Medium` / `Small` / `XSmall` / `ZZ` 等の綴り誤り・別語彙)。
#                           body に宣言らしき行が無く Projects の値が同様に不正な場合も含む
#   projects_fetch_failed — body に宣言らしき行が無く、Projects の値を取得できない (gh api graphql の失敗、
#                           応答に Issue が無い、rite-config.yml を読めない)。値なしとは区別する。
#                           body に宣言があれば fallback せず、一致を確かめられなかった旨の
#                           WARNING を出して body の値で判定する
#   complexity_mismatch   — body と Projects の両方に有効な値があり食い違う (停止、fallback しない)
#   projects_config_invalid — github.projects.enabled: true なのに project_number が数値でない
#                           (null / 空 / キー無しは未設定として Projects を参照しない)
#                           (停止、fallback しない。連携無効と見なすと設定の誤りが値なしに化ける)
#
# 上記に加え、**本 script では表現できない** consumer 側の reason が 2 つある。いずれも本 script を
# 呼べない / 呼んだが marker が得られない状況そのものを指すため、caller 側 (SKILL.md) に置く:
#   issue_number_missing  — 関連 Issue を特定できず --issue を渡せない (本 script は未起動)
#   helper_failed         — 本 script が正常終了したが marker を出さない (consumer 側)
#
# repo_unresolved / repo_mismatch / complexity_mismatch / projects_config_invalid は停止する。それ以外の全 fallback reason は **full へ倒れる** (reason は分岐を変えない)。欠落時の安全側は常に
# 「儀式を減らさない方」= full である。詳細: complexity-lane.md「fail-safe は必ず full へ倒す」。
#
# Exit codes:
#   0 = レーン決定完了 (light / full のいずれも正常終了)
#   1 = 停止 (レーンを出さない): repository context error / complexity_mismatch / projects_config_invalid
#   2 = usage error (--issue 欠落 / 非数値 / 未知フラグ)
#
# Why fail-safe instead of fail-loud:
#   本 script は状態を書き換えず「どちらのレーンで回すか」を選ぶだけで、情報が何も得られない
#   ときの安全な選択 (full = 現行フル装備) が常に存在する。ここで exit 1 を返すと caller の
#   bash が失敗し、儀式コスト最適化の失敗がレビュー / 実装そのものの失敗に昇格してしまう。
#   sibling の scripts/review-cycle-scope.sh と同じ判断で、同じく silent fallback ではない
#   (全経路で reason 付き marker を emit する)。
#   例外は complexity_mismatch と projects_config_invalid で、これらは情報の欠落ではなく
#   入力の矛盾である。どちらかを黙って採ると誤った Complexity が工程全体に流れるため停止する。
set -uo pipefail

_icl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tempfile は lib 経由で確保する (coding-principles.md の Rule)。手書き mktemp は
# (a) 失敗が空パスへ落ちて gh の stderr 診断が無音で消える、(b) signal 中断で残留する、の
# 2 defect を再生産する。lib は fail-loud + EXIT/INT/TERM/HUP 回収を持つ
# (sibling: scripts/review-cycle-scope.sh と同形)。
# shellcheck source=../hooks/scripts/lib/tempfile.sh
source "$_icl_dir/../hooks/scripts/lib/tempfile.sh"
# gh の stderr スニペット (外部由来) を診断へ出す経路があるため中和 helper を読む。
# Issue body 由来の文字列は診断へ出さない (下の complexity_absent 経路を参照)。
# canonical idiom の SoT は control-char-neutralize.sh の header。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$_icl_dir/../hooks/control-char-neutralize.sh"

ISSUE_NUMBER=""
OWNER_REPO=""
EXECUTION_CWD=""
CWD_GIVEN=0

# `shift 2` は使わない。値なしフラグが argv 末尾に来ると n > $# で shift が $# を変えずに rc=1 を
# 返し、set -e 非設定 + ${2:-} で nounset も発火しない本 script では while を抜けられず hang する
# (無人ループの /rite:iterate / /rite:batch-run では診断ゼロの無期限停止になる)。1 回目の shift で
# $# を確実に 0 にし 2 回目を no-op にする house convention に従う
# (sibling: scripts/review-cycle-scope.sh、機械検査: hooks/tests/shift2-loop-hardening.test.sh)。
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_NUMBER="${2:-}"; shift; shift ;;
    --repo)  OWNER_REPO="${2:-}"; shift; shift ;;
    --cwd)   EXECUTION_CWD="${2:-}"; CWD_GIVEN=1; shift; shift ;;
    *) echo "ERROR: issue-complexity-lane: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$ISSUE_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: issue-complexity-lane: --issue は数値必須です (received: '${ISSUE_NUMBER}')" >&2
    exit 2 ;;
esac

# full へ倒して終了する共通経路。reason は分岐を変えず、全経路が WARNING を伴う。
# sibling の review-cycle-scope.sh は cycle 1 正常経路の no_prev_json だけを無警告にするが、
# 本 script は全 reason を loud にする — ただし根拠は「宣言が必ずある」ことではない
# (本リポジトリの実測では Issue 60 件中 23 件が宣言を持たない)。full へ倒れた事実は
# 「この PR ではレーンが働かなかった」という**観測値そのもの**であり、レーン効果の計測が
# 分母を数えるために要る。定常的に出うる complexity_absent は、宣言らしき行を解釈できなかった
# 場合に限り下の追加 WARNING で対象行の**行番号**を報告し、真の異常と routine を切り分ける。
emit_full_fallback() {
  local reason="$1"
  echo "[CONTEXT] COMPLEXITY_LANE=full; reason=$reason" >&2
  echo "⚠️ Complexity レーン判定のフォールバック: reason=${reason}。フル装備 (M+ 相当) で実行します。" >&2
  echo "[CONTEXT] COMPLEXITY_LANE_FALLBACK=1; reason=$reason" >&2
  exit 0
}

# API 対象だけを戻しても state / worktree は隣 repo のままになる。
# 入口の identity を cwd から置換せず、両方が一致してから取得する。
[ -n "$OWNER_REPO" ] || {
  echo "ERROR: issue-complexity-lane: repo_unresolved: --repo is required; cwd cannot select the target" >&2
  exit 1
}
if [ "$CWD_GIVEN" -eq 1 ]; then
  case "$EXECUTION_CWD" in
    /*) ;;
    *) echo "ERROR: issue-complexity-lane: repo_unresolved: --cwd must be an absolute path" >&2; exit 1 ;;
  esac
  cd "$EXECUTION_CWD" || {
    echo "ERROR: issue-complexity-lane: repo_unresolved: cannot enter --cwd" >&2
    exit 1
  }
fi
_or_line=$(bash "$_icl_dir/../hooks/scripts/lib/git-remote.sh" resolve-owner-repo) || {
  echo "ERROR: issue-complexity-lane: repo_unresolved: cannot resolve cwd repository" >&2
  exit 1
}
IFS=$'\t' read -r _or_owner _or_repo <<< "$_or_line"
_cwd_repo="$_or_owner/$_or_repo"
if [ "$(printf '%s' "$OWNER_REPO" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$_cwd_repo" | tr '[:upper:]' '[:lower:]')" ]; then
  printf 'ERROR: issue-complexity-lane: repo_mismatch: repository context mismatch: expected=%s; cwd_repo=%s; cwd=%s\n' "$OWNER_REPO" "$_cwd_repo" "$PWD" | neutralize_ctrl --keep-newline >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || emit_full_fallback gh_missing

# 取得失敗と「body が空の Issue」を区別する。gh の rc を捨てて本文の空判定だけで倒すと、
# 認証切れ (fetch 失敗) が complexity_absent として報告され、原因の切り分けができなくなる。
rite_tempfile_init
rite_tempfile_new _icl_err "complexity-lane-err" || emit_full_fallback issue_fetch_failed
if ! _body=$(gh issue view "$ISSUE_NUMBER" -R "$OWNER_REPO" --json body --jq '.body' 2>"$_icl_err"); then
  if [ -s "$_icl_err" ]; then
    echo "WARNING: issue-complexity-lane: gh issue view が失敗しました (issue=#${ISSUE_NUMBER}, repo=${OWNER_REPO}):" >&2
    # gh の stderr も外部由来なので canonical idiom を通す
    # (SoT: control-char-neutralize.sh の header)。
    head -3 "$_icl_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  emit_full_fallback issue_fetch_failed
fi

# CR を 1 度だけ落とす。awk の既定 FS は `\r` を含まないため、CRLF の body では CR だけの行が
# NF=1 = 非空行と数えられ、記法 2 の「見出し直後の最初の非空行」が値行ではなく空行を指す
# (GitHub Web UI 由来の body は CRLF になりうる)。抽出と診断の両方が同じ述語を持つので、
# 述語ごとに直すのではなく入力側で 1 度落として対称に閉じる。記法 1 の sed は `.*$` が既に
# CR を吸収するため影響を受けない。
_body=${_body//$'\r'/}

# 記法 1: `**Complexity**: X` (Section 0 Meta)。装飾の揺れ (太字なし / 全角コロン) は受理しない —
# テンプレート由来の 1 形式だけを pin し、崩れた記法は complexity_absent として可視化する。
# **英字トークン全体を貪欲に切り出し、値の妥当性判定は下の `case` に委ねる**。長さを 1-2 文字に
# 制限すると `XSmall` が `XS` へ切り詰められ、宣言していない light レーンへ落ちる。境界指定に
# GNU 拡張の `\b` を使ってはならない — POSIX BRE は `\b` を定義せず、BSD/macOS sed は
# リテラル `b` として扱って**無警告で不一致になる**ため、当該環境で全 Issue が
# complexity_absent へ倒れレーンが一度も発動しない (CI の macos leg が本経路を踏む)。
_raw=$(printf '%s\n' "$_body" | sed -n 's/^[[:space:]]*\*\*Complexity\*\*:[[:space:]]*\([A-Za-z][A-Za-z]*\).*$/\1/p' | head -1)
_source="body_meta"

# 記法 2: `## 複雑度` セクション。見出しの次に現れる最初の非空行から値を取る
# (`M` 単独行 / `- M` / `**M**` のいずれも許容する。common-principles.md は書式を固定していない)。
# **行頭側から最初のトークンだけを採る** — 記法 1 と同じ anchor 規律。greedy な `.*` を先頭に置くと
# 行内の**最後**のレーントークンを拾い、`M（S ではない）` のように宣言値の後ろへ根拠を書いた行で
# 宣言 M が S へ解決され、M+ が silent に light へ落ちる MUST NOT 違反になる。
# 記法 1 と同じく**英字トークン全体を切り出し、妥当性は `case` に委ねる**。BRE 交替 `\|` と
# 単語境界 `\b` はいずれも GNU 拡張で、BSD/macOS sed では無警告に不一致となるため使わない。
# 読み飛ばす先頭記号から `{` と `<` を除く — 含めると `{complexity}` の中身や
# `<!-- TODO -->` の `TODO` を値として捕捉し、記法 1 では complexity_absent になる
# 同じ記入漏れが記法 2 でだけ complexity_invalid へ分裂する (reason はレーン効果の計測が
# 「レーンが働かなかった理由」の分母として数える観測値なので、分裂すると集計の意味が壊れる)。
# 同じ理由で**節境界で探索を止める** — 止めないと空の複雑度節が次の見出しへ跨ぎ、英字見出し
# (`## Impact` 等) は読み飛ばしクラス `[^A-Za-z{<]*` が `## ` を食った後の英字を値として捕捉して
# complexity_invalid へ分裂する (日本語見出しでは分裂しないため、見出し語の言語で reason が変わる)。
if [ -z "$_raw" ]; then
  _raw=$(printf '%s\n' "$_body" \
    | awk '/^##[[:space:]]+複雑度[[:space:]]*$/{f=1; next} f && /^#/{exit} f && NF {print; exit}' \
    | sed -n 's/^[^A-Za-z{<]*\([A-Za-z][A-Za-z]*\).*/\1/p' | head -1)
  _source="body_section"
fi

# 記法 3: `| **Complexity** | X |` (Section 0 Meta を表で書いた形)。記法 1 と同じ装飾規律を敷く —
# **キーの太字を要求し、値セルの先頭に英字を要求する**。太字を落とすと、`| A | ... | Complexity M |`
# のように行の途中で Complexity に**言及するだけ**の表 (本リポジトリの散文に実在する) を宣言行と
# 誤認する。値セル直後に英字を要求すれば `{complexity}` / `<!-- ... -->` は記法 1 と同じく
# complexity_absent へ合流し、同じ記入漏れが記法によって別 reason へ分裂しない。
# 記法 1 と同じく英字トークン全体を切り出し、妥当性は下の `case` に委ねる。GNU 拡張は使わない。
# **最後に置く** — 表行は body のどこにでも現れうるのに対し、記法 1 の Meta 行と記法 2 の
# `## 複雑度` 節はいずれも「そこが宣言である」ことを形で示す。表行を先に読むと、明示宣言を
# 持つ Issue が本文中の説明用の表から値を解決する (実測: 記法 2 で M を宣言し別節に表の例を
# 置いた body が XS へ落ち、M+ が silent に light へ落ちる MUST NOT 違反になる。記法 2 宣言 + 文書用の
# 表ヘッダでは `complexity_invalid` へ落ちる)。`head -1` は同じ理由で必須 — 宣言の表行が
# 本文中の例より先にある形を保ち、複数行を連結して `complexity_invalid` にしない。
if [ -z "$_raw" ]; then
  _raw=$(printf '%s\n' "$_body" \
    | sed -n 's/^[[:space:]]*|[[:space:]]*\*\*Complexity\*\*[[:space:]]*|[[:space:]]*\([A-Za-z][A-Za-z]*\).*/\1/p' | head -1)
  _source="body_table"
fi

# Projects の Complexity フィールドは本文に次ぐ 2 番目の入力源。本文に宣言があっても読む —
# 両方に値があるときの食い違いを検出するため。読むのは github.projects.enabled: true の
# ときだけで、rite-config.yml が無い / 連携無効 / fields.complexity.enabled: false なら本文だけで
# 判定する (gh の追加呼び出しは 0 回)。project_number が null / 空 (配布テンプレートの既定) のときも
# 参照しない。連携を有効にしたまま project_number に数値でない値を書いた設定は
# 黙って無効扱いにせず停止する — 無効扱いにすると設定の誤りが「Projects に値が無い」に化ける。
_pj_state="disabled"   # disabled | query | value | none | invalid | failed
_pj_value=""
_pj_number=""
_pj_candidates=""
_pj_not_on_board=0
_pj_unset=0
if _pj_cfg=$(bash "$_icl_dir/../hooks/scripts/lib/rite-config-path.sh" 2>&1); then
  _pj_enabled=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$_pj_cfg")
  _pj_number=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$_pj_cfg")
  # YAML では引用符付きの数値 ("11" / '11') も正しい書き方なので、引用符を外してから判定する。
  _pj_number=${_pj_number#[\"\']}; _pj_number=${_pj_number%[\"\']}
  # null / 空 / キー無しは「未設定」で、配布テンプレートと setup が既定で書く形。矛盾ではないので
  # 止めずに Projects を参照しない (projects-status-gate.sh が skipped とするのと同じ扱い)。
  case "$_pj_number" in null|'~'|'#'*) _pj_number="" ;; esac
  if [ "$_pj_enabled" = "true" ] && [ -z "$_pj_number" ]; then
    _pj_unset=1
  elif [ "$_pj_enabled" = "true" ]; then
    case "$_pj_number" in
      *[!0-9]*)
        echo "ERROR: issue-complexity-lane: projects_config_invalid: rite-config.yml の github.projects.enabled が true ですが、github.projects.project_number が数値ではありません。github.projects.project_number に Project 番号を設定するか、github.projects.enabled を false にしてください" >&2
        exit 1 ;;
    esac
    # github.projects.fields.complexity の enabled / name をインデントで節を追って読む。
    _pj_cx_cfg=$(awk '
      BEGIN { q = sprintf("%c", 39) }
      /^[ ]*(#|$)/ { next }
      { match($0, /^ */); ind = RLENGTH }
      ind == 0 { g = ($0 ~ /^github:/); p = f = c = 0; next }
      g && ind == 2 { p = ($0 ~ /^  projects:/); f = c = 0; next }
      p && ind == 4 { f = ($0 ~ /^    fields:/); c = 0; next }
      f && ind == 6 { c = ($0 ~ /^      complexity:/); next }
      c && ind == 8 && /^        (enabled|name):/ {
        k = $0; v = $0
        sub(/^ */, "", k); sub(/:.*/, "", k)
        sub(/^ *[a-z]*:[ \t]*/, "", v)
        sub(/[ \t]+#.*$/, "", v)
        if (length(v) >= 2 && (substr(v, 1, 1) == "\"" || substr(v, 1, 1) == q) && substr(v, length(v), 1) == substr(v, 1, 1)) v = substr(v, 2, length(v) - 2)
        print k "=" v
      }
    ' "$_pj_cfg")
    if [ "$(printf '%s\n' "$_pj_cx_cfg" | sed -n 's/^enabled=//p' | head -1)" != "false" ]; then
      _pj_state="query"
      # 候補名の順序は Issue 作成 helper と同じ (設定の name → 日本語エイリアス → 英語正準名)。
      _pj_candidates=$(printf '%s\n' "$(printf '%s\n' "$_pj_cx_cfg" | sed -n 's/^name=//p' | head -1)" '複雑度' 'Complexity' \
        | awk 'NF && !seen[$0]++')
    fi
  fi
elif [ $? -ne 1 ]; then
  # rc=1 は「設定ファイルが無い」= 連携無効。それ以外 (読めない / main checkout を解決できない) は
  # Projects の値を確かめられない状態であり、無効扱いにしない。
  _pj_state="failed"
  echo "WARNING: issue-complexity-lane: rite-config.yml を読めないため Projects の Complexity を確認できません:" >&2
  printf '%s\n' "$_pj_cfg" | head -3 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi

_complexity=""
if [ -n "$_raw" ]; then
  _complexity=$(printf '%s' "$_raw" | tr '[:lower:]' '[:upper:]')
  # 本文の宣言が壊れているときは Projects の値で補わない (「宣言が無い」には当たらない)。
  case "$_complexity" in
    XS|S|M|L|XL) ;;
    *) emit_full_fallback complexity_invalid ;;
  esac
fi

if [ "$_pj_state" = "query" ]; then
  _pj_state="failed"
  # 照会結果は 1 行ずつ: NOISSUE / NOTONBOARD / ONBOARD に続けて「V<TAB>フィールド名<TAB>値」。
  # 値とフィールド名は外部入力なので区切り文字を潰して行構造を保つ。gh 内蔵の --jq を使い、
  # jq コマンドへの依存を足さない。
  _pj_jq='.data.repository.issue as $i
    | if $i == null then "NOISSUE"
      else ([$i.projectItems.nodes[]? | select(.project.number == '"$_pj_number"')][0]) as $it
      | if $it == null then "NOTONBOARD"
        else "ONBOARD", ($it.fieldValues.nodes[]? | select((.field.name // null) != null and (.name // null) != null)
          | "V\t" + (.field.name | gsub("[\t\n\r]"; " ")) + "\t" + (.name | gsub("[\t\n\r]"; " ")))
        end
      end'
  if rite_tempfile_new _icl_pj_err "complexity-lane-pj-err"; then
    if _pj_out=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          project { number }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                name
              }
            }
          }
        }
      }
    }
  }
}' -f owner="${OWNER_REPO%%/*}" -f repo="${OWNER_REPO#*/}" -F number="$ISSUE_NUMBER" --jq "$_pj_jq" 2>"$_icl_pj_err"); then
      case "$_pj_out" in
        NOTONBOARD) _pj_state="none"; _pj_not_on_board=1 ;;
        ONBOARD*)
          _pj_state="none"
          while IFS= read -r _pj_field; do
            _pj_raw=$(printf '%s\n' "$_pj_out" | _ICL_FIELD="$_pj_field" awk -F'\t' '$1 == "V" && $2 == ENVIRON["_ICL_FIELD"] { print $3; exit }')
            [ -n "$_pj_raw" ] || continue
            _pj_value=$(printf '%s' "$_pj_raw" | tr '[:lower:]' '[:upper:]')
            case "$_pj_value" in
              XS|S|M|L|XL) _pj_state="value" ;;
              *) _pj_state="invalid"; _pj_value="" ;;
            esac
            break
          done <<< "$_pj_candidates"
          ;;
      esac
    elif [ -s "$_icl_pj_err" ]; then
      echo "WARNING: issue-complexity-lane: Projects の Complexity の取得に失敗しました (issue=#${ISSUE_NUMBER}, project=${_pj_number}):" >&2
      head -3 "$_icl_pj_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
  fi
fi

_decl_line=""
if [ -z "$_complexity" ]; then
  # 宣言らしき行はあるのに値を取り出せなかった場合だけ対象行の行番号を報告する
  # (sibling の review-cycle-scope.sh は target の値そのものを名指しするが、本 helper は
  # 外部入力を診断へ通さないため位置だけを示す)。宣言が本当に無い Issue では出さない —
  # 出すと定常出力になり、この WARNING の目的である「lowercase key / 全角コロン /
  # リスト項目化などの崩れた記法」の可視化が noise に埋もれる。
  #
  # 述語は**宣言行の形**に固定する。裸のキーワード検索にすると両方向で外れる —
  # case-sensitive だと lowercase key を落とし (可視化対象の筆頭が無音になる)、行の形を問わないと
  # 散文や表セルの単なる言及を「宣言らしき行」と誤って断定する (定常出力化して目的が消える)。
  # コロン形式は 行頭 anchor + キー + 区切り記号 (`:` / `：`) を要求し、大小文字は文字クラスで吸収する。
  #
  # 表形式 (記法 3) の宣言行も同じ規律で拾う。抽出側は太字を要求するので `| Complexity | S |` は
  # complexity_absent へ落ちるが、述語をコロン形式だけに留めるとその棄却が**無音**になり、崩れた
  # 記法の可視化という本 WARNING の目的が記法 3 でだけ果たされない。キーが**先頭セル**であることを
  # 要求して、行の途中で Complexity に言及するだけの表 (下の TC が pin する散文形) と切り分ける。
  # `|` は ERE の交替演算子なので文字クラス `[|]` で literal 化する (`\|` は移植性がない)。
  #
  # **診断に出すのは行番号だけで、body の中身は出さない。** ${_body} は第三者が書ける外部入力で、
  # 切り分け (崩れた記法 か 宣言不在 か) という本 WARNING の目的は行番号だけで果たせる。
  #
  # 記法 2 では見出しではなく**値を取り出せなかった行**を指す (見出しは解釈できているので
  # 是正先にならない)。ただし節に値行が 1 行も無い形では見出し自身が唯一の是正先なので、
  # そこへ退避する。退避しないと、次の見出しが続く形では無関係な次節見出しを是正先として提示し、
  # body 末尾の形では沈黙して記入漏れの節が宣言不在と区別できなくなる。
  #
  # **print 点は END の 1 箇所だけにする。** awk の `exit` は END 規則を実行するため、
  # 本体規則でも print すると早期終了した経路で二重出力になり、下の `case` の数値検査が
  # 改行込みの値を非数値として飲み込んで WARNING ごと消える。本体規則は行番号を `n` へ
  # 記録するだけにすれば、その失敗モードが構造的に起こりえない。
  _decl_line=$(printf '%s\n' "$_body" | awk '
    /^[[:space:]]*([-*+][[:space:]]+)?\**[[:space:]]*([Cc][Oo][Mm][Pp][Ll][Ee][Xx][Ii][Tt][Yy]|複雑度)[[:space:]]*\**[[:space:]]*[:：]/ { n = NR; exit }
    /^[[:space:]]*[|][[:space:]]*\**[[:space:]]*([Cc][Oo][Mm][Pp][Ll][Ee][Xx][Ii][Tt][Yy]|複雑度)[[:space:]]*\**[[:space:]]*[|]/ { n = NR; exit }
    /^##[[:space:]]+複雑度[[:space:]]*$/ { f = 1; h = NR; next }
    f && /^#/ { n = h; exit }
    f && NF   { n = NR; exit }
    END { if (!n) n = h; if (n) print n }
  ')
  # 宣言らしき行があるのに値を取り出せなかった本文は「宣言が無い」には当たらない。Projects の値で
  # 補うと、崩れた宣言 (例: 本文 M) が Projects の値 (例: S) で黙って上書きされ、行番号 WARNING も
  # 食い違いの検査も働かない。英字を取り出せた不正綴りを補わないのと同じく、下の欠落経路 (complexity_absent) へ倒す。
fi

if [ -n "$_complexity" ]; then
  case "$_pj_state" in
    value)
      if [ "$_pj_value" != "$_complexity" ]; then
        echo "ERROR: issue-complexity-lane: complexity_mismatch: Issue 本文と Projects #${_pj_number} の Complexity が食い違っています (本文=${_complexity}; Projects=${_pj_value})。どちらかを正しい値に直してから再実行してください" >&2
        exit 1
      fi ;;
    invalid)
      echo "WARNING: issue-complexity-lane: Projects #${_pj_number} の Complexity フィールドの値が XS / S / M / L / XL のいずれでもないため、本文の宣言 (${_complexity}) だけで判定しました。診断に値は載せません — 第三者が書ける外部入力のため" >&2 ;;
    failed)
      echo "WARNING: issue-complexity-lane: Projects の Complexity を確認できなかったため、本文との一致を確かめずに本文の宣言 (${_complexity}) で判定しました" >&2 ;;
  esac
elif [ -z "$_decl_line" ]; then
  case "$_pj_state" in
    value) _complexity="$_pj_value"; _source="projects_field" ;;
    invalid) emit_full_fallback complexity_invalid ;;
    failed) emit_full_fallback projects_fetch_failed ;;
  esac
fi

if [ -z "$_complexity" ]; then
  # 原因の分類は列挙しない。退避先が増えるたびに列挙と実態がずれ (記入漏れの空節は
  # 「崩れた記法」のどれにも当たらない)、同じ列挙を持つ散文 site との同期義務も増える。
  # reason ごとの原因分類は本 script の docstring と complexity-lane.md の reason 表が持つ。
  case "$_decl_line" in
    ''|*[!0-9]*) : ;;
    *) echo "WARNING: issue-complexity-lane: Complexity 宣言らしき記述はありますが body の ${_decl_line} 行目から値を取り出せませんでした。診断に本文は載せません — 第三者が書ける外部入力のため" >&2 ;;
  esac
  # 探した場所は実際に参照したものだけを示す。連携が無効なのに「Projects を探した」と言うと、
  # 利用者は Projects 側の値を直しに行って空振りする。
  if [ "$_pj_unset" -eq 1 ]; then
    _pj_where="github.projects.project_number が未設定のため Projects は参照していません"
  elif [ "$_pj_state" = "disabled" ]; then
    _pj_where="Projects 連携は無効のため Projects は参照していません"
  elif [ -z "$_pj_number" ]; then
    # Project 番号が空のまま照会へ進む経路は無いので、ここは rite-config.yml を読めなかった場合。
    _pj_where="rite-config.yml を読めないため Projects は参照していません"
  elif [ -n "$_decl_line" ]; then
    # 崩れた宣言があるときは Projects の値を見つけても使っていない。「探して見つからなかった」と
    # 書くと、利用者は値の入った Projects 側を直しに行って空振りする。値は外部入力なので載せない。
    _pj_where="Projects #${_pj_number} の Complexity フィールドは、本文 ${_decl_line} 行目の宣言を読めないため使っていません (本文の宣言を直してください)"
  else
    _pj_where="Projects #${_pj_number} の Complexity フィールド (候補名: $(printf '%s' "$_pj_candidates" | tr '\n' ',' | sed 's/,/, /g' | neutralize_ctrl --keep-newline))"
    [ "$_pj_not_on_board" -eq 1 ] && _pj_where="${_pj_where} — Issue は Project に未登録"
  fi
  echo "Complexity が見つかりません。探した場所: Issue 本文の宣言 (\`**Complexity**: X\` / \`## 複雑度\` 節 / \`| **Complexity** | X |\` 表行)、${_pj_where}" >&2
  if [ -n "$_decl_line" ]; then
    echo "  本文 ${_decl_line} 行目の宣言を次の書式に直してください (値は XS / S / M / L / XL のいずれか): **Complexity**: M" >&2
  else
    echo "  本文に次の 1 行を追記してください (値は XS / S / M / L / XL のいずれか): **Complexity**: M" >&2
  fi
  emit_full_fallback complexity_absent
fi

case "$_complexity" in
  XS|S) _lane="light" ;;
  *) _lane="full" ;;
esac

echo "[CONTEXT] COMPLEXITY_LANE=$_lane; complexity=$_complexity; source=$_source" >&2
exit 0
