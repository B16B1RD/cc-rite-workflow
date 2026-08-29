#!/bin/bash
# rite workflow - Non-measured Findings Issue Comment Record
# Deterministic helper for skills/pr-review/SKILL.md ステップ 6.1.d (非実測指摘の関連 Issue コメント記録)。
#
# 実測必須ゲート (severity-levels.md §実測必須ゲート) が non-blocking へ降格した非実測指摘を、
# 関連 Issue 上の単一コメント (update-in-place) に記録する。これは「非実測指摘は破棄せず
# 共有可能な永続チャネルへ記録する」という D-01 の要件を担保し、`pr_review.post_comment` 設定には**依存しない** (opt-out 対象外)。
# 関連 Issue は PR body の closing keyword を第一候補、branch 命名 (`issue-{N}`) を第二候補として解決する。
# どちらも無いときは記録投稿を失敗として表面化する (silent skip しない)。
#
# Usage:
#   bash review-nonblocking-record.sh \
#     --pr <number> \
#     --owner-repo <owner/repo> \
#     --count <N> \
#     --iteration-id <id> \
#     --content-file <path>
#
#   caller (pr-review.md ステップ 6.1.d) は以下を行う:
#     1. 件数 (`non_blocking_findings` の件数) に応じた本文 (variant A / B) を生成し、
#        **Write tool** で tmpfile に保存する。1 行目は必ず MARKER 見出しにする。
#     2. ステップ 6.1.a step 0 の [CONTEXT] REVIEW_CYCLE_ID= を --iteration-id に渡す。
#     3. 本 helper を 1 回だけ実行する。
#
# 契約 (pr-review.md ステップ 6.1.d と verbatim 一致):
#   - **単一 invocation**: 既存コメント lookup → skip 判定 → PATCH / create を 1 プロセスに閉じる。
#     lookup だけ実行して記録を skip した状態が構造的に存在しえないため、terminal sentinel の
#     存在 = 「記録経路が終端まで走った」を意味する (動作前 marker を gate の入力にしてはならない)。
#     caller は existing_comment_id を受け渡さない。
#   - **terminal sentinel は 1 種のみ**: EXIT trap が
#       [CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=N; outcome=<...>; count=K; iteration_id=ID; comment_id=<id|空>; degraded=<0|1>
#     を stderr に emit する。outcome は created / updated / skipped / failed / aborted。
#     `aborted` は trap の初期値で、判定に到達する前に落ちた場合にのみ残る (早期 exit が
#     success を騙れない構造)。個別の RECORDED / CLEAR_SKIPPED marker は持たない (consumer が
#     いない marker を作らないため)。
#   - **非ブロッキング (AC-3)**: gh / jq / IO の失敗は WARNING + `[CONTEXT] NONBLOCKING_RECORD_FAILED=1;
#     reason=...` を emit して **exit 0**。overall_assessment / result pattern に一切影響しない。
#     例外は placeholder residue 系 gate (skill 定義のバグ) で、loud に exit 1 する。
#     reason 語彙: pr_number_placeholder_residue / owner_repo_placeholder_residue /
#       non_blocking_count_placeholder_residue / iteration_id_placeholder_residue /
#       content_file_placeholder_residue / content_file_missing / unknown_option /
#       body_file_empty / body_marker_missing / body_sentinel_missing / count_body_mismatch /
#       body_check_unavailable / patch_failed / create_failed / signal_aborted /
#       related_issue_unresolved
#   - **8.0.3 機械強制 (pending marker) の差し戻し境界は「原因」で引く**: caller (LLM) 契約違反は
#     marker を残して 8.0.3 に差し戻させる。対象は 2 群 (計 11 reason):
#       (i)  trap 設置**前**の exit 1 (構造的に marker が残る) — unknown_option /
#            pr_number_placeholder_residue / owner_repo_placeholder_residue /
#            non_blocking_count_placeholder_residue / iteration_id_placeholder_residue /
#            content_file_placeholder_residue / content_file_missing の 7 種
#       (ii) trap 設置**後**の exit 0 + retain_pending_marker=1 (本文検査 4 段) —
#            body_file_empty / body_marker_missing / body_sentinel_missing / count_body_mismatch
#     第 3 群: trap 設置後の related_issue_unresolved は exit 1 で表面化するが pending marker は残さない
#     (同 cycle 内で PR body / branch を直せないため差し戻しても収束しない)。
#     gh / network / rate-limit / IO 起因 (patch_failed / create_failed / lookup degraded /
#     body_check_unavailable) と signal 中断 (signal_aborted) は従来どおり無条件削除する (差し戻しても
#     同 cycle 内で収束しないため)。`body_check_unavailable` は本文検査と同じ位置で起きるが、
#     **述語を評価できなかった**環境起因の失敗であり、caller が本文を作り直しても解消しないため
#     (ii) ではなく本群に属する。exit code (trap 設置の前後) で境界を引くと (ii) だけが検出位置の違いで機械強制から
#     外れる。marker 保持は overall_assessment を変えず「result pattern を emit してよいか」だけを
#     止めるため AC-3 と両立する。
#   - **既存コメントの特定は 2 段解決**: (1) 関連 Issue body に永続化した comment id (durable、第一候補)、
#     (2) 本文照合による fallback。本文照合だけを同定手段にすると「記録コメントの raw markdown を
#     複製した同一 author の人間コメント」を構造的に除外できない (述語を 4 度強化してもこの残余は
#     消えなかった) ため、第一候補を本文に依存しない id へ移した。id は marker 行の形で **関連 Issue body**
#     に置く (形状の SoT は下の ID_MARKER_* 定数。marker は **行全体** を占める) — 記録コメント本文に
#     置くと copy-paste で複製され、本文照合と同じ誤認経路が再生する。id で解決できないときの観測 marker は
#       [CONTEXT] NONBLOCKING_ID_UNRESOLVED=1; pr=N; reason=<...>; action=fallback
#     reason 語彙 (8 種): id_read_failed / id_malformed / id_fetch_failed / id_fetch_unparseable /
#       id_author_mismatch / id_pr_mismatch / id_target_not_record / id_comment_deleted。
#     **帰結は理由に依らず fallback の
#     1 種**で、`action=` は常に `fallback` (理由ごとに帰結を分けると周辺状態との交差ごとにガードが
#     要り、そのガード自体が次の欠陥面になる)。id で解決するには author 一致に加え **所属 Issue の
#     一致** と **対象が記録コメントであること** (1 行目 marker ∧ 最終非空行 sentinel) も要る —
#     `issues/comments/{id}` は repo スコープで issue 非依存なので author だけでは別 PR / 別 Issue の
#     自コメントを掴め、所属 Issue まで縛っても同一 Issue の別種コメント (作業メモリ replica 等) が残る。
#     関連 Issue body は書き込み権限があれば編集できるため、この 3 つ目が最後の防壁になる。
#     なお `gh api user` が失敗した cycle は段 1 自体が呼ばれず、本 marker は 1 つも出ないまま
#     degraded=1 で縮退する (id 側が外れる = 本 marker が出る、ではない)。id が関連 Issue body に無い初回 cycle は
#     正常系のため marker を出さない (fallback がそのまま canonical を見つけ、投稿後に永続化されて
#     次 cycle から id 経路に乗る)。投稿後の永続化に失敗したときは
#       [CONTEXT] NONBLOCKING_ID_PERSIST_FAILED=1; pr=N; reason=<...>
#     reason 語彙: comment_id_unresolved / body_read_failed / body_write_failed / body_edit_failed。
#     **どちらも純粋な observability marker**で gate の入力ではなく、記録の成否 (outcome) も
#     `overall_assessment` も変えない。永続化失敗は環境/IO 起因のため pending marker は残さない
#     (本文を作り直しても解消しないため、`body_check_unavailable` と同じ削除バケットに属する)。
#     terminal sentinel の `degraded=1` は **PATCH 先を特定できなかった**ことを表す。本文照合の
#     lookup が失敗しても durable id で PATCH 先が確定していれば update-in-place は成立するため
#     degraded ではない (この 1 点が「degraded 縮退が重複記録コメントを生む」経路を塞ぐ本 helper の
#     中核)。自 login の取得失敗だけは id 経路の author 検証も不能にするため従来どおり degraded=1。
#     rationale: ../skills/pr-review/references/measured-gate-record.md#durable-id
#   - **fallback の述語は「自分が投稿した」∧「1 行目 marker への前方一致 (startswith)」∧
#     「**最終非空行が**機械専用 sentinel **と等しい**」の連言**。author 条件を欠くと、marker で始まる
#     コメントを第三者が 1 件投稿するだけで PATCH 先を奪える。`contains($MARKER)` (人間可視 marker を
#     本文全体で探す) も別コメントを掴む。ただし author + startswith だけでは **同一 author が書いた、
#     引用接頭辞を持たない、marker 前方一致の人間コメント** (例: 記録コメントを追跡するための
#     「## 📜 rite 非実測指摘の記録 の対応状況」という見出し) を除外できず、PATCH がその本文を
#     丸ごと上書き破壊する。第 3 条件の sentinel は **位置まで固定する** — `contains` だと人間が
#     記録の raw markdown を一部貼り込んだメモも拾ってしまい、同じ破壊が残る。
#     lookup で「author ∧ marker 前方一致は満たすが最終非空行 sentinel に落ちた件数」を数え、
#     0 件でなければ WARNING + `[CONTEXT] NONBLOCKING_LEGACY_ORPHAN=1` を emit する
#     (sentinel 導入前の記録コメントの孤児化を silent にしない)。
#     **本文照合の走査は id 解決の成否に依らず常に実行する** — id で PATCH 先が確定した cycle でも、
#     孤児 / 重複 (`NONBLOCKING_LEGACY_ORPHAN` / `NONBLOCKING_DUPLICATE_RECORD`) の観測を落とすと
#     関連 Issue 上の残骸が silent になる。
#     rationale: ../skills/pr-review/references/measured-gate-record.md#startswith
#   - **投稿する本文は「非空」→「1 行目が MARKER で始まる」→「最終非空行が機械専用 sentinel」→
#     「`📎 non_blocking_count:` 行が --count と一致する」の 4 段で投稿前に検査する**。前 3 段の
#     契約違反はいずれも lookup の条件を満たさないコメントを投稿し、以降の lookup を恒久的に
#     miss させる (記録コメントが cycle ごとに増殖する)。3 段目は read 側と**完全に同じ述語**
#     (最終非空行の等値) にする — 片側だけ緩いと人間のコメントを掴んで破壊し、片側だけ厳しいと増殖する。4 段目は step 1 の本文 variant 選択と
#     step 2 の --count 置換のずれ（無音喪失 / 虚偽記録）を捕捉する。
#     rationale: ../skills/pr-review/references/measured-gate-record.md#startswith
#   - **create は count > 0 でガード**: 0 件 ∧ 既存なしで「0 件です」という事実と異なるコメントを
#     新規作成しない (AC-4 非退行)。
#   - [CONTEXT] / WARNING は stderr (6.1.a/b/c の 3 兄弟 helper と同一)。
#
# Exit codes:
#   0: 記録成功 / 正当な skip / 非ブロッキングな失敗 (gh・IO)。
#   1: placeholder residue / content_file 不在 等の caller 契約違反 (skill 定義のバグ)。
#      加えて related_issue_unresolved (trap 設置後。terminal sentinel は outcome=failed。
#      pending marker は残さない — 差し戻しても収束しない。caller は rc=1 を skill 全体の
#      hard fail と読まず sentinel を読んで 6.1.d step 3 / 8.0.3 へ進む)。
set -uo pipefail
# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

# 記録コメントの 1 行目見出し。lookup の前方一致 needle であり、caller が生成する本文の
# 1 行目が本値で **始まる** こと (前方一致) が write 側契約 (SKILL.md ステップ 6.1.d step 1)。
# variant A / B の 1 行目は末尾に ` (non-blocking)` が付くため完全一致ではない。
MARKER='## 📜 rite 非実測指摘の記録'

# 機械専用 sentinel。lookup の第 3 条件であり、caller が生成する本文の **最終非空行が本値と等しい**
# ことが write 側契約 (SKILL.md ステップ 6.1.d step 1 の variant A / B は最終行に本行を置く)。
# HTML コメントなので GitHub の rendered view には現れないが、**raw markdown の copy-paste では
# 同伴する** (Edit view / `gh api` / `gh issue view --comments` 経由)。したがって「人間が書き写す経路が
# 存在しない」とは言えず、位置非依存の `contains` では、人間が記録コメントの raw を一部貼り込んだ
# メモを PATCH で丸ごと破壊する経路が残る。**最終非空行が本値と等しい**ことを条件にすることで、
# 本文中に引用として現れた sentinel も、末尾に `> ` 付きで引用された sentinel も構造的に除外する
# (本文全体への `endswith` は行頭の `> ` を吸収してしまうため不十分)。write 側の本文検査も
# **完全に同じ述語** (CR を落とし、空白のみの行を除いた最終行の等値) にし read == write を保つ
# — 片側だけ緩いと人間のコメントを掴んで破壊し、片側だけ厳しいと次 cycle の lookup が自分の
# 投稿を miss して記録コメントが増殖する。
RECORD_SENTINEL='<!-- rite:nbr:v1 -->'

# 記録コメント id を **関連 Issue body** に永続化するときの marker。lookup の第一候補の情報源。
# **記録コメント本文には置かない** — 本文に置くと raw markdown の copy-paste で marker ごと複製され、
# 本文照合と同じ「人間コメントを canonical と誤認する」経路が再生する。Issue body はコメント本文の
# 複製経路から構造的に隔離されており、かつ Issue に紐づく永続領域なので abandoned PR でも残り、
# cross-machine でも効く (`.rite/` は machine-local であり、かつ `/rite:setup` が生成する
# nested `.rite/.gitignore` (`*`) で追跡対象外のため、別マシンからは読めない)。
ID_MARKER_PREFIX='<!-- rite:nbr:comment-id:'
ID_MARKER_SUFFIX=' -->'
# 関連 Issue body から marker の値部分を取り出す sed 式と、marker 行を除去する sed 式。read/write で
# **同一の形状定義**を使う (片方だけ形が違うと、書いた marker を次 cycle が読めない / 除去できずに
# 重複する)。値は緩く取って shell 側の numeric guard に委ねる — 厳格な regex で抽出すると
# 「壊れた marker」が「marker 不在」と区別できず、関連 Issue body 側の破損が無音になる。
# **行全体を占めることを両式で要求する** (`^` / `$` アンカー)。helper は常に marker を独立行として
# 書くためこれで取り逃さず、散文中に同形の文字列が現れても (この機構を説明する Issue 本文がまさにそう)
# 抽出で偽の id を拾わず、除去でその一節を無音で消さない。strip は `s///` ではなく行の `d` にして、
# marker 行の跡に空行が積もるのも同時に断つ。
# 行頭・行末の `[[:space:]]*` は**必須**で、両式に対称に置く。GitHub の web UI で Issue 本文を編集すると
# 本文が CRLF で返り、人間が marker 行を字下げすることもある。素の `^`/`$` だとその形で抽出も除去も
# 同時に外れ、(a) 抽出結果が空になって「marker 不在」と区別できなくなり (下の probe が無ければ無音)、
# (b) 除去も外れて marker 行が cycle ごとに積む。同 helper がコメント本文側で CR を既知ハザードとして
# `LAST_CONTENT_LINE_JQ` の `sub("\r$"; "")` で正規化しているのと同じ規律を、関連 Issue body 側にも適用する。
# `[[:space:]]` は CR を含み、散文中の同形文字列は marker 前に非空白があるため引き続き除外される。
ID_MARKER_EXTRACT_SED='s/^[[:space:]]*<!-- rite:nbr:comment-id:\([^ ]*\) -->[[:space:]]*$/\1/p'
# 「行全体が marker 行の形をしている」の定義。**除去 (strip) と破損検出 (probe) はこの 1 本から
# 導出する** — 別々の literal として並べると、片方だけ触った編集で受理集合の関係が崩れ、
# 「破損と判定したのに除去できない (= 壊れた行が関連 Issue body に恒久残留し、hint の『張り直します』が
# 偽になる)」状態が生まれる。値部を `.*` にして抽出式 (`[^ ]*` + 区切りの空白を要求) より緩くするのは
# 意図的で、受理集合の包含関係を **抽出 ⊆ 除去 = 破損検出** に固定する: 読めた marker は必ず消せ、
# 読めないが marker 行の形をしているものは「破損」として loud に落としたうえで同時に消える。
# 行頭・行末の `[[:space:]]*` は**必須**で、抽出式と対称に置く (上のコメント参照)。行全体を要求する
# ことで、散文の途中や行末に同形の文字列が現れても破損と誤検出せず、その一節を無音で消しもしない。
ID_MARKER_LINE_RE='^[[:space:]]*<!-- rite:nbr:comment-id:.*-->[[:space:]]*$'
ID_MARKER_STRIP_SED="/$ID_MARKER_LINE_RE/d"
ID_MARKER_LINE_PROBE_SED="/$ID_MARKER_LINE_RE/p"

# read (durable id の対象検証 / 本文照合 lookup) と write (投稿前の本文検査) が共有する述語定義。
# **消費者は 3 箇所**で、どれか 1 つのために弱めると他の 2 つも同時に緩む。**2 言語で並行実装してはならない** —
# shell の `grep -E '[^[:space:]]'` は glibc の空白クラス (locale 依存、grep 実装依存) を使い、
# jq は Oniguruma (locale 非依存) を使うため受理集合が環境で割れる。`tr -d '\r'` と
# `sub("\r$"; "")` も CR の除去範囲が違う (全 CR ⇄ 行末 1 個)。片側だけ緩いと人間のコメントを
# 掴んで PATCH 破壊し、片側だけ厳しいと次 cycle の lookup が自分の投稿を miss して記録コメントが
# 増殖する。定義を 1 本にして「同値であること」を構造的に保証する
# (同じ hooks/ の control-char-neutralize.sh が grep 実装差を理由に grep を避けているのと同根)。
LAST_CONTENT_LINE_JQ='def last_content_line:
  (. // "") | split("\n") | map(sub("\r$"; "")) | map(select(test("[^[:space:]]"))) | last // "";'

# --- Argument parsing ---
PR_NUMBER=""
OWNER_REPO=""
NB_COUNT=""
ITERATION_ID=""
CONTENT_FILE=""
ISSUE_NUMBER=""

# 各値付きフラグは `shift; shift` で消費する (値なしフラグが末尾に来た場合の無限ループ回避。
# review-comment-post.sh と同一 idiom)。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)           PR_NUMBER="${2:-}"; shift; shift ;;
    --owner-repo)   OWNER_REPO="${2:-}"; shift; shift ;;
    --count)        NB_COUNT="${2:-}"; shift; shift ;;
    --iteration-id) ITERATION_ID="${2:-}"; shift; shift ;;
    --content-file) CONTENT_FILE="${2:-}"; shift; shift ;;
    # 値の verbatim echo は禁止 (下記 iteration_id gate と同根)。本分岐は trap 設置**前**のため
    # real sentinel が 1 本も出ず、偽 sentinel が唯一の sentinel になりうる。
    *) echo "ERROR: review-nonblocking-record: unknown option: $(printf '%s' "$1" | neutralize_ctrl)" >&2
       echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=unknown_option" >&2
       exit 1 ;;
  esac
done

# --- placeholder residue gates ---
# いずれも「caller が {placeholder} をリテラル置換し忘れた」= skill 定義のバグであり、記録の失敗
# ではない。正常系と同じ marker で silent に skip させず loud に落とす (D-01 の無音喪失を防ぐ)。
# 本 gate 群は terminal sentinel の trap 設置より **前** に置く: ここで落ちた場合は記録経路が
# 一度も走っていないため、outcome=failed を名乗らせずに exit 1 の非ゼロ rc で caller に返す。
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-nonblocking-record: pr_number が数値ではありません (値: '$(printf '%s' "$PR_NUMBER" | neutralize_ctrl)', 期待: 数値のみ非空)" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 1
    ;;
esac
# owner_repo は `gh issue comment -R` に渡る。gh は `[HOST/]OWNER/REPO` を受けるため、3 セグメント値は
# 先頭がホスト名として解釈され、記録が別 GitHub インスタンスへ送られる。producer 側
# (hooks/scripts/lib/git-remote.sh) が同じ理由で持つ allowlist をここでも継承する。
case "$OWNER_REPO" in
  */*/*|*[!A-Za-z0-9._/-]*|*/|/*|""|*..*)
    echo "ERROR: review-nonblocking-record: owner_repo が owner/repo 形式ではありません (値: '$(printf '%s' "$OWNER_REPO" | neutralize_ctrl)')" >&2
    echo "  期待: 英数字 / '.' / '_' / '-' からなる 2 セグメント (例: owner/repo)。HOST/OWNER/REPO の 3 セグメント形は別ホストへの送出になるため拒否する" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=owner_repo_placeholder_residue" >&2
    exit 1
    ;;
  */*) ;;
  *)
    echo "ERROR: review-nonblocking-record: owner_repo が owner/repo 形式ではありません (値: '$(printf '%s' "$OWNER_REPO" | neutralize_ctrl)')" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=owner_repo_placeholder_residue" >&2
    exit 1
    ;;
esac
case "$NB_COUNT" in
  ''|*[!0-9]*)
    echo "ERROR: review-nonblocking-record: count が数値ではありません (値: '$(printf '%s' "$NB_COUNT" | neutralize_ctrl)')" >&2
    echo "  0 件のときも明示的に --count 0 を渡してください (空文字は substitute 漏れと区別できません)" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=non_blocking_count_placeholder_residue" >&2
    exit 1
    ;;
esac
# iteration_id は terminal sentinel に無加工で埋め込まれ、その sentinel は 6.1.d step 3 / 8.0.3 の
# 2 gate が唯一の pass 条件として読む機械可読 control line である。denylist だけでは改行入りの値を
# 通してしまい、完全な形の 2 本目の sentinel 行 (= gate 入力の偽装) を生成できる。形状 allowlist で
# 弾く (REVIEW_CYCLE_ID の実値は `{pr}-{epoch}` 形式でこの範囲に収まる)。
case "$ITERATION_ID" in
  ''|*'{'*|*'}'*|*[!A-Za-z0-9._-]*)
    # 値の verbatim echo は禁止 — 改行入りの値をそのまま出すと、診断行の中に完全な形の
    # `[CONTEXT] NONBLOCKING_RECORD_DONE=1; ...` を再現でき、gate を読む LLM を欺ける。
    # neutralize_ctrl で改行ごと `?` 化してから 1 行に収める。
    echo "ERROR: review-nonblocking-record: iteration_id が literal substitute されていないか不正な文字を含みます (値: '$(printf '%s' "$ITERATION_ID" | neutralize_ctrl)')" >&2
    echo "  期待: 英数字 / '.' / '_' / '-' のみからなる非空文字列 (例: 2038-1799999999)" >&2
    echo "  caller は ステップ 6.1.a step 0 の [CONTEXT] REVIEW_CYCLE_ID= emit 値を --iteration-id に渡す必要があります" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=iteration_id_placeholder_residue" >&2
    exit 1
    ;;
esac
# content-file のブレース残留は content_file_missing (Write 呼び出し漏れ) と別 reason にする。
# 未置換パスは存在しないパスなので、専用 gate が無ければ後続の存在検査に潰れる。どちらも caller
# 契約違反だが、前者は skill テンプレートの substitution 漏れ、後者は step 1 の Write 呼び出し漏れで
# 復旧手順が異なるため独立の reason を持たせる。
case "$CONTENT_FILE" in
  ''|*'{'*|*'}'*)
    echo "ERROR: review-nonblocking-record: content_file のパスが literal substitute されていません (値: '$(printf '%s' "$CONTENT_FILE" | neutralize_ctrl)')" >&2
    echo "  caller は ステップ 6.1.a step 0 の [CONTEXT] REVIEW_TMP_DIR= emit 値でパスを解決する必要があります" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=content_file_placeholder_residue" >&2
    exit 1
    ;;
esac
# ファイル**不在**は caller 契約違反 (step 1 の Write tool 呼び出し漏れ) であり IO 失敗ではない。
# 後段の非空検査 (`[ ! -s ]`) に潰すと、記録が一度も行われないまま outcome=failed で exit 0 し、
# 8.0.3 gate は「評価された」として pass する — D-01 の記録が無音で失われる。placeholder residue
# 5 gate と同じ loud fail に揃える (兄弟 review-comment-post.sh の --content-file 不在 reject と対称)。
# 「存在するが空」は本 gate を通過し、後段で非ブロッキング body_file_empty として扱う。
if [ ! -f "$CONTENT_FILE" ]; then
  echo "ERROR: review-nonblocking-record: content_file が存在しません (値: '$(printf '%s' "$CONTENT_FILE" | neutralize_ctrl)')" >&2
  echo "  caller は ステップ 6.1.d step 1 の Write tool による本文保存を先に実行する必要があります" >&2
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=content_file_missing" >&2
  exit 1
fi

# --- terminal sentinel (EXIT trap) ---
# outcome の初期値は `aborted`。success 値 (created / updated / skipped) は該当分岐に到達して
# はじめて代入されるため、途中終了が success を騙ることは構造的に起きない。
outcome="aborted"
existing_id=""
lookup_degraded=0
legacy_orphan_count=0
canonical_hit_count=0
gh_err=""
# 2 段解決の中間状態。`fallback_id` は本文照合 lookup が選んだ候補、`id_resolved` は関連 Issue body の
# durable id が指す確定値。`existing_id` は両者から決まる最終的な PATCH 先 (段 3)。
fallback_id=""
persisted_id=""
id_resolved=""
id_reason=""
id_action=""
# 本文照合 lookup (gh/jq) が失敗したか。degraded の判定は `existing_id` が確定したかを見てから
# 行うため (durable id で確定していれば degraded ではない)、失敗の事実だけを先に持つ。
list_failed=0
# `_persist_comment_id` が使う tempfile。**グローバルに持って EXIT trap の回収対象に載せる** —
# 関数ローカルに閉じると、gh 実行中に INT/TERM/HUP を受けたとき 2 本とも TMPDIR に残る
# (同ファイルが `_body_jq_err` について「代入が jq 実行の後だと本ファイルだけが残る」として
# 代入位置を前倒ししているのと同じ規律)。
id_persist_tmp=""
id_persist_err=""
# `_persist_comment_id` が `gh_err` を自分用に差し替えている間、呼び出し元の tempfile を退避する枠。
# **これもグローバルに持つ** — 関数ローカルに退避すると、差し替え中 (gh issue view + gh issue edit の
# 2 往復) に signal を受けたとき退避先が trap から見えず、上の 2 本と同じ窓が 1 本ぶん開いたままになる。
id_persist_prev_err=""
# ステップ 8.0.3 の機械強制 marker。パスは SKILL.md ステップ 6.1.a step 0 が作る側と同じ規則
# (`${TMPDIR:-/tmp}/rite-nbr-pending-<iteration_id>`) で導出する。引数として受け取らないのは、
# placeholder を 1 つ増やすと residue gate も 1 本増えるため — 導出が外れた場合は marker が
# 消えず gate が loud に落ちる方向 (誤 pass ではない) なので、安全側に倒れる。
PENDING_MARKER="${TMPDIR:-/tmp}/rite-nbr-pending-${ITERATION_ID}"
# signal trap は emit 後に exit するため EXIT trap が再入する。兄弟 review-result-save.sh と同じ
# 冪等ガードを置き、terminal sentinel が 1 回だけ出ることを保証する。
_terminal_emitted="false"
# 機械強制 (8.0.3) へ差し戻す = marker を残す、の可否フラグ。境界は **原因** で引く:
#   - caller (LLM) 契約違反で、caller が本文/--count を作り直せば 1 iteration で収束するもの
#     → marker を残して 8.0.3 に差し戻させる (retain_pending_marker=1)
#   - gh / network / rate-limit / IO 起因で、差し戻しても同じ cycle 内では収束しないもの
#     → 従来どおり無条件削除 (非ブロッキング契約 AC-3 をそのまま維持)
# 引数 gate 群 (unknown_option / placeholder residue 5 種 / content_file_missing = 7 種) は本 trap 設置**前**に exit 1 するため
# 自動的に marker が残る。本フラグは trap 設置**後**に検出される caller 契約違反 (本文検査 4 段) を
# 同じ扱いに揃えるためのもの — 境界を exit code (trap 前/後) で引くと、同種の契約違反が検出位置の
# 違いだけで機械強制の対象から外れる。
retain_pending_marker=0
_rite_p61d_cleanup() {
  rm -f "${gh_err:-}" "${id_persist_tmp:-}" "${id_persist_err:-}" "${id_persist_prev_err:-}"
  # 既定は「記録の成否 (created / updated / skipped / failed / aborted) に関わらず削除」。8.0.3 へ
  # 伝えるのは「6.1.d が完走した」ことだけで、成否は terminal sentinel の outcome= が担う
  # (非ブロッキング契約 AC-3 を gate 側へ持ち込まない)。例外は retain_pending_marker=1 の
  # caller 契約違反のみで、これは overall_assessment を変えず「result pattern を emit してよいか」
  # だけを止める (= 引数 gate 群が既に行っている挙動と構造的に同一)。
  [ "$retain_pending_marker" = "1" ] && return 0
  if [ -n "${PENDING_MARKER:-}" ] && { [ -e "$PENDING_MARKER" ] || [ -L "$PENDING_MARKER" ]; }; then
    if ! LC_ALL=C rm -f -- "$PENDING_MARKER"; then
      pending_marker_display=$(printf '%s' "$PENDING_MARKER" | neutralize_ctrl)
      printf -v pending_marker_shell_q '%q' "$PENDING_MARKER"
      echo "WARNING: non-blocking pending marker の削除に失敗しました ($pending_marker_display)。ステップ 8.0.3 は本 cycle の 6.1.d を未実行と誤判定します" >&2
      echo "  marker が残っている間は pending_marker_present により result pattern の emit が差し戻され続けます" >&2
      echo "  対処: 削除失敗は決定論的なため 6.1.d の再実行では収束しません" >&2
      echo "  marker を手動で削除してからステップ 8.0 を再評価してください: rm -f -- $pending_marker_shell_q" >&2
      echo "  6.1.d の terminal sentinel が成功を示していても、この cleanup 失敗は別途解消が必要です" >&2
    fi
  fi
}
# gh / jq の stderr 詳細を出す共通スニペット。行接頭辞に `gh:` を入れるのは、gh 側の stderr に
# terminal sentinel と同形の行が混じったとき、字下げだけでは gate の部分一致述語をすり抜けて
# 偽の完了報告として読まれうるため (テストの negative control は行頭 anchor 付きで検出できず、
# gate だけが騙される非対称が生まれる)。
_gh_err_detail() {
  [ -n "$gh_err" ] && [ -s "$gh_err" ] || return 0
  echo "  詳細 (gh/jq stderr 先頭 5 行):" >&2
  head -5 "$gh_err" | neutralize_ctrl --keep-newline | sed 's/^/  gh: /' >&2
}
# lookup が degraded したときの案内。**記録は続行されうる** ため、記録失敗用の
# _record_gh_io_failure_hint / _record_body_check_failure_hint とは文言を分ける。共用すると
# 「記録が失われた」と読める案内が成功経路で出て、operator を不要な
# レビュー再実行へ誘導する。ただし投稿されるかどうかは件数と既存コメントの有無で決まるため、
# **結末を断定せず** 「update-in-place を諦める」ことだけを述べる (結末は terminal sentinel の
# `outcome=` が担う)。
_record_degraded_hint() {
  echo "  対処: gh auth status を確認してください。既存コメントを特定できないため update-in-place を諦めます" >&2
  echo "  mergeable 判定には影響しません (非ブロッキング)。以降の結末は terminal sentinel の outcome= を参照してください" >&2
}
# durable id で PATCH 先を解決できなかったときの案内。**記録は続行される** (fallback へ倒すか、
# 削除済みなら新規作成する) ため、_record_degraded_hint と同じく結末を断定しない。reason ごとに
# 復旧手順が違うので 1 文に畳まず分岐する — 誤った復旧手順は operator を真因から遠ざける
# (_record_env_failure_hint / _record_body_check_failure_hint を分けたのと同じ規律)。
_record_id_unresolved_hint() {  # $1=reason
  case "$1" in
    id_read_failed)
      echo "  対処: gh auth status / Issue #${ISSUE_NUMBER} への read 権限を確認してください。本 cycle は本文照合の fallback で同定します" >&2 ;;
    id_malformed)
      echo "  対処: 追加操作は不要です。Issue #${ISSUE_NUMBER} の body にある '${ID_MARKER_PREFIX}' 行が壊れています (値が数値でない / 形が崩れている) が、本文照合の fallback で同定し直し、次に記録コメントを投稿する cycle で marker 行ごと張り直します" >&2 ;;
    id_fetch_failed|id_fetch_unparseable)
      # 本分岐は gh 側の失敗だけでなく **jq 側の失敗** (jq 不在 / filter 非互換) からも到達する
      # (GET は `gh api ... | jq` のパイプで、jq 単独失敗は pipefail で非ゼロ rc になり 404 判定を
      # 素通りする)。原因を片側に断定すると operator を真因から遠ざけるため両方を挙げる。
      echo "  対処: gh auth status / network 接続、または jq の実行環境 (jq --version) を確認してください。直前の詳細行 (gh/jq stderr) で切り分けられます。本 cycle は本文照合の fallback で同定します" >&2 ;;
    id_author_mismatch)
      echo "  対処: 永続化 id が別 identity のコメントを指しています。本文照合の fallback へ倒すため、そのコメントには一切触れません" >&2 ;;
    id_pr_mismatch)
      echo "  対処: 追加操作は不要です。永続化 id が **別の PR / Issue** のコメントを指していますが、本文照合の fallback で同定し直し、次に記録コメントを投稿する cycle で正しい id を張り直します。そのコメントには一切触れません" >&2 ;;
    id_target_not_record)
      echo "  対処: 追加操作は不要です。永続化 id が **同一関連 Issue の記録コメント以外** を指していますが、本文照合の fallback で同定し直し、次に記録コメントを投稿する cycle で正しい id を張り直します。そのコメントには一切触れません" >&2 ;;
    id_comment_deleted)
      echo "  対処: 追加操作は不要です。id が指すコメントは削除済みのため、本文照合の fallback で同定し直します" >&2 ;;
  esac
  echo "  mergeable 判定には影響しません (非ブロッキング)" >&2
}
# 投稿後の id 永続化に失敗したときの案内。**記録そのものは成功している**ため、記録失敗用の
# 案内 (_record_gh_io_failure_hint) とは文言を分ける — 共用すると成功経路で「記録が失われた」と
# 読める案内が出て、operator を不要なレビュー再実行へ誘導する。
_record_id_persist_failure_hint() {  # $1=reason
  echo "  影響: 次 cycle の lookup は本文照合の fallback に倒れます (本 cycle の記録自体は成功しています)" >&2
  case "$1" in
    comment_id_unresolved)
      echo "  対処: gh の出力形式が想定と異なる可能性があります (gh --version を確認してください)" >&2 ;;
    body_read_failed|body_edit_failed)
      echo "  対処: gh auth status / Issue #${ISSUE_NUMBER} への write 権限を確認してください" >&2 ;;
    body_write_failed)
      echo "  対処: \${TMPDIR} の書き込み権限を確認してください" >&2 ;;
  esac
  echo "  mergeable 判定には影響しません (非ブロッキング)" >&2
}
# 関連 Issue を解決する。第一候補 = PR body の GitHub closing keyword (`Closes #N` 等)、
# 第二候補 = head branch 名に含まれる `issue-{N}`。どちらも無ければ fail-loud
# (`related_issue_unresolved`)。抽出パターンは scripts/watchdog-status-mismatch.sh と同型。
_resolve_related_issue() {
  local _pr_body="" _head_ref="" _n=""
  if ! _pr_body=$(gh pr view "$PR_NUMBER" -R "$OWNER_REPO" --json body --jq '.body' 2>"${gh_err:-/dev/null}"); then
    echo "ERROR: review-nonblocking-record: 関連 Issue を解決できません (PR #${PR_NUMBER} の body を読めません)" >&2
    _gh_err_detail
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=related_issue_unresolved" >&2
    return 1
  fi
  _n=$(printf '%s' "$_pr_body" | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+$' || true)
  if [ -z "$_n" ]; then
    if ! _head_ref=$(gh pr view "$PR_NUMBER" -R "$OWNER_REPO" --json headRefName --jq '.headRefName' 2>"${gh_err:-/dev/null}"); then
      echo "ERROR: review-nonblocking-record: 関連 Issue を解決できません (PR #${PR_NUMBER} の headRefName を読めません)" >&2
      _gh_err_detail
      echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=related_issue_unresolved" >&2
      return 1
    fi
    if [[ "$_head_ref" =~ issue-([0-9]+) ]]; then
      _n="${BASH_REMATCH[1]}"
    fi
  fi
  case "$_n" in
    ''|*[!0-9]*)
      echo "ERROR: review-nonblocking-record: 関連 Issue を解決できません (PR #${PR_NUMBER}: closing keyword も issue-N branch 命名もありません)" >&2
      echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=related_issue_unresolved" >&2
      return 1
      ;;
  esac
  ISSUE_NUMBER="$_n"
  return 0
}
# 段 1: 関連 Issue body に永続化された comment id を第一候補として解決する。**同定は id で 1 件に絞り込む**
# ため、同一 author が記録コメントの raw markdown を複製したコメントが Issue 上にあっても PATCH 先を
# 奪われない (AC-1)。本文述語 (下の GET) は絞り込んだ**後**の必要条件であって同定手段ではない。
# 結果は persisted_id / id_resolved / id_reason / id_action に置く。
_resolve_persisted_id() {
  local _issue_body="" _raw="" _id_probe="" _author="" _rest="" _issue_url="" _is_record=""
  if _issue_body=$(gh issue view "$ISSUE_NUMBER" -R "$OWNER_REPO" --json body --jq '.body' 2>"${gh_err:-/dev/null}"); then
    _raw=$(printf '%s\n' "$_issue_body" | sed -n "$ID_MARKER_EXTRACT_SED" | tail -1)
    # この値は最終的に `issues/comments/$existing_id` の PATCH へ補間される。本文照合側が持つ
    # numeric guard と **同一の述語** を通す (PATCH 先の供給元が 2 つになったのに片方だけ無検証、
    # という非対称を作らない)。空へ倒せば既存の「既存なし」経路にそのまま乗る。
    case "$_raw" in
      '')
        # 抽出が空になる原因は 2 通りある — 「marker 行が無い」(正常系) と「marker 行はあるが
        # 抽出述語を満たさない」(関連 Issue body 側の破損)。後者を前者に畳むと上の形状定義コメントが
        # 避けると宣言している無音の破損がそのまま成立する。probe で切り分け、破損側は既存の
        # `id_malformed` で loud に落とす (帰結は「値が使えない」で同じなので新 reason は要らない)。
        # 判定は「probe の出力が非空か」で行い、`grep -q` のような**早期 exit する consumer を
        # パイプ終端に置かない** — grep が最初の一致で exit すると上流の sed が SIGPIPE を受け、
        # グローバルの `set -o pipefail` がパイプライン rc を 141 にする。すると「一致があった」のに
        # else 側へ落ちて無音の破損が復活する (入力が小さいと sed が先に書き終わるため発火せず、
        # 出力が stdio バッファ境界を超えた地点で挙動が反転する)。出力を最後まで読む形なら
        # SIGPIPE 経路自体が存在しない。
        if [ -n "$(printf '%s\n' "$_issue_body" | sed -n "$ID_MARKER_LINE_PROBE_SED")" ]; then
          id_reason="id_malformed"; id_action="fallback"
        else
          return 0   # marker 不在 = 初回 cycle / 永続化前の正常系。marker は出さず fallback に委ねる
        fi
        ;;
      *[!0-9]*) id_reason="id_malformed"; id_action="fallback" ;;
      *)        persisted_id="$_raw" ;;
    esac
  else
    id_reason="id_read_failed"; id_action="fallback"
  fi

  if [ -n "$persisted_id" ]; then
    # author / **所属 Issue** / **記録コメントであること** を 1 回の GET で同時に取る。
    # `issues/comments/{id}` は repo スコープで issue 非依存のため、author 一致だけでは
    # 「同一 author の**別 PR / 別 Issue** のコメント」を PATCH 先にできてしまう。さらに所属 Issue まで
    # 縛っても「同一 Issue の**別種のコメント**」(作業メモリ replica 等) は素通りする — 関連 Issue body は
    # 書き込み権限があれば編集でき、抽出は `tail -1` を採るので marker を 1 行足すだけで
    # PATCH 先を任意に指し替えられるためである。置き換えた本文照合は author ∧ 1 行目 marker ∧
    # 最終非空行 sentinel の 3 述語で対象を絞っていた。read 経路の差し替えでそのどれも落とさない。
    # **これは同定手段を本文照合へ戻すものではない** — id で 1 件に絞り込んだ**後**の必要条件として
    # 本文を見るだけなので、記録コメントの raw markdown を複製した人間コメントが述語を満たしても
    # id が指す先は 1 件のままで誤認は起きない (AC-1 は保たれる)。
    # 述語は shell 側で再実装せず read/write 共有の `$LAST_CONTENT_LINE_JQ` をそのまま使う
    # (「2 言語で並行実装してはならない」の規律)。`--arg` が要るので `gh --jq` ではなく実 jq へ繋ぐ
    # (グローバルの `set -o pipefail` により jq 段の失敗も rc に伝播する)。
    if _id_probe=$( ( gh api "repos/$OWNER_REPO/issues/comments/$persisted_id" \
        | jq -r --arg marker "$MARKER" --arg sentinel "$RECORD_SENTINEL" \
            "$LAST_CONTENT_LINE_JQ"'
            [ (.user.login // ""),
              (.issue_url // ""),
              (((((.body // "") | startswith($marker))
                 and (((.body // "") | last_content_line) == $sentinel))) | tostring)
            ] | @tsv
          ' ) 2>"${gh_err:-/dev/null}" ); then
      # `@tsv` は 3 要素配列に対し常にちょうど 2 個の実タブを出し、値中の TAB は 2 文字へ
      # エスケープされる。したがってフィールド分割は構造的に壊れない。
      _author="${_id_probe%%$'\t'*}"
      _rest="${_id_probe#*$'\t'}"
      _issue_url="${_rest%%$'\t'*}"
      _is_record="${_rest##*$'\t'}"
      if [ -z "$_author" ]; then
        # rc=0 だが author が空 = レスポンス形状の drift。検証できない値を PATCH 先にしてはならない
        # (`gh api user` の rc=0 + 空文字を degraded に倒すのと同じ規律)。
        id_reason="id_fetch_unparseable"; id_action="fallback"
      elif [ "$_author" != "$gh_login" ]; then
        # AC-5: 他人のコメントは PATCH しない。identity 変更 / 関連 Issue body の手動編集が疑われる。
        id_reason="id_author_mismatch"; id_action="fallback"
      elif [ "${_issue_url%/issues/$ISSUE_NUMBER}" = "$_issue_url" ]; then
        # issue_url が `/issues/{ISSUE_NUMBER}` で終わらない = 当該関連 Issue に属さないコメント。
        # Issue body は書き込み権限があれば編集できるため、author 検証だけでは
        # repo 内の任意の自コメントを PATCH 先にされうる (AC-5 の author 検証は「誰の」しか縛らない)。
        id_reason="id_pr_mismatch"; id_action="fallback"
      elif [ "$_is_record" != "true" ]; then
        # 同一 Issue の自コメントではあるが記録コメントではない。ここを縛らないと、Issue body に marker を
        # 1 行足すだけで同 Issue の別種コメント等を PATCH 先に指定でき、本文が丸ごと破壊される。
        id_reason="id_target_not_record"; id_action="fallback"
      else
        id_resolved="$persisted_id"
      fi
    elif [ -n "${gh_err:-}" ] && [ -s "$gh_err" ] && grep -qE 'HTTP 404|Not Found' "$gh_err"; then
      # AC-4: 削除済みをエラーにしない。**fallback へ倒す** — 「id が使えない」他の reason と同じ扱い。
      # 当初は「かつて canonical だった記録が消えた以上、新規作成が意図に近い」として recreate 分岐を
      # 持っていたが、それは (a) 本文照合が実在の canonical を見つけていても無視して 2 通目を作り、
      # (b) 0 件 cycle では収束クリア (AC-2) が成立せず、(c) list 失敗と重なると degraded 判定が
      # 非対称になる、という 3 つの実害を生んだ。fallback は「author ∧ 1 行目 marker ∧ 最終非空行
      # sentinel」を満たすコメントしか掴まないので、削除済み id の代わりに採っても安全であり、
      # 見つからなければ既存の「既存なし」経路がそのまま新規作成へ倒す (AC-4 の帰結は保たれる)。
      id_reason="id_comment_deleted"; id_action="fallback"
    else
      id_reason="id_fetch_failed"; id_action="fallback"
    fi
  fi

  [ -n "$id_reason" ] || return 0
  echo "WARNING: 永続化された記録コメント id を解決できませんでした (reason=$id_reason)" >&2
  _gh_err_detail
  _record_id_unresolved_hint "$id_reason"
  echo "[CONTEXT] NONBLOCKING_ID_UNRESOLVED=1; pr=$PR_NUMBER; reason=$id_reason; action=$id_action" >&2
}
# 段 3: PATCH 先を決める。durable id > 本文照合 fallback の 2 段だけで、id が使えない理由
# (不在 / 破損 / 取得失敗 / author 不一致 / PR 不一致 / 記録コメントでない / 削除済み) は帰結を分けない — どれも
# 「fallback へ倒す」に畳む。理由ごとに帰結を分けると、周辺状態 (list_failed / canonical 実在 /
# NB_COUNT) との交差ごとにガードが要り、そのガード自体が次の欠陥面になる。
_decide_existing_id() {
  if [ -n "$id_resolved" ]; then
    existing_id="$id_resolved"
  else
    existing_id="$fallback_id"
  fi
  [ "$list_failed" = "1" ] || return 0
  # 本文照合が失敗しても durable id で PATCH 先が確定していれば update-in-place は成立する。
  # ここで degraded を立てると「既存コメントを特定できない」という事実と異なる案内が出るうえ、
  # 本 helper が消そうとしている「degraded 縮退による重複作成」を自分で再導入することになる。
  if [ -n "$existing_id" ]; then
    echo "  注意: 記録コメント id で PATCH 先を確定したため update-in-place は継続します (本 cycle は孤児 / 重複の走査を行えていません)" >&2
    return 0
  fi
  _record_degraded_hint
  lookup_degraded=1
}
# degraded skip (既存コメントを特定できず、かつ本 cycle の非実測指摘が 0 件) 専用の案内。
# 実在する既存コメントを検出できないまま skip するため、前 cycle の「N 件」記録が関連 Issue 上に
# stale で残りうる。この 1 経路だけは「投稿されなかった」ことを明示する必要がある。
_record_degraded_skip_hint() {
  echo "  注意: 既存の記録コメントを特定できないまま 0 件 skip したため、前 cycle の記録コメントが Issue 上に残っている可能性があります" >&2
  echo "  対処: Issue #${ISSUE_NUMBER} の '$MARKER' コメントを目視で確認してください (mergeable 判定には影響しません)" >&2
}
# degraded create (既存コメントを特定できず、かつ本 cycle の非実測指摘が 1 件以上あり新規作成へ
# 縮退) 専用の案内。_record_degraded_skip_hint と対称: こちらは「投稿されなかった」ではなく
# 「既存を検出できないまま重複して新規作成した」ことを明示する。実在する記録コメントを検出できない
# まま新規作成するため、前 cycle の記録コメントは関連 Issue 上に孤児として残り、以後の lookup は
# `last` (新しい方) だけを PATCH するので古い方は恒久的に stale で残る (skip 経路と同じ結末)。
_record_degraded_create_hint() {
  echo "  注意: 既存の記録コメントを特定できないまま新規作成したため、前 cycle の記録コメントが Issue 上に重複して残っている可能性があります" >&2
  echo "  対処: Issue #${ISSUE_NUMBER} の '$MARKER' コメントを目視で確認し、古い方を手動で削除するか無視してください (mergeable 判定には影響しません)" >&2
}
# 記録できなかったときの gh/IO 起因の案内。caller (LLM) の本文生成起因ではなく gh 認証 / network /
# 書込権限に起因する失敗 (patch_failed / create_failed) から呼ぶ。
_record_gh_io_failure_hint() {
  echo "  対処: gh auth status / network 接続 / Issue #${ISSUE_NUMBER} への write 権限を確認し、レビューをやり直してください" >&2
  echo "  mergeable 判定には影響しません (非ブロッキング)。記録内容は ステップ 5.4 統合レポートの「実測なし指摘」section と ステップ 6.1.a のローカル JSON (non_blocking_findings[]) から参照できます (後者は gitignore 対象のためレビュアーとは共有されません)" >&2
}
# 記録できなかったときの実行環境起因の案内。gh でも本文でもなく、本文述語を評価する jq の
# 実行環境 (jq 不在 / 実行不能) に起因する失敗 (body_check_unavailable) から呼ぶ。gh auth /
# network / 権限や本文の再生成を指す案内は原因と無関係なため出さない (下の
# _record_body_check_failure_hint と同じ規律 — 誤った復旧手順は operator を真因から遠ざける)。
_record_env_failure_hint() {
  echo "  対処: jq --version で jq の実行環境を確認してください (gh 認証 / network / 権限や本文生成の問題ではありません)" >&2
  echo "  mergeable 判定には影響しません (非ブロッキング)。記録内容は ステップ 5.4 統合レポートの「実測なし指摘」section と ステップ 6.1.a のローカル JSON (non_blocking_findings[]) から参照できます (後者は gitignore 対象のためレビュアーとは共有されません)" >&2
}
# 記録できなかったときの本文検査起因の案内。gh / IO の障害ではなく caller (LLM) が
# ステップ 6.1.d step 1 で生成した本文自体の不備 (body_file_empty / body_marker_missing /
# body_sentinel_missing / count_body_mismatch) から呼ぶ。gh auth / network / 権限を指す案内は原因と無関係なため出さない
# (この 4 reason はいずれも degraded=0 の健全な gh 環境でも発生しうる — 誤った復旧手順を示すと
# operator が無関係な確認に時間を使い、真因である本文/--count の再生成に辿り着けない)。
_record_body_check_failure_hint() {
  echo "  対処: ステップ 6.1.d step 1 の本文生成 (Write) と step 2 の --count 置換を確認し、step 1 から再実行してください (gh 認証 / network / 権限の問題ではありません)" >&2
  echo "  mergeable 判定には影響しません (非ブロッキング)。記録内容は ステップ 5.4 統合レポートの「実測なし指摘」section と ステップ 6.1.a のローカル JSON (non_blocking_findings[]) から参照できます (後者は gitignore 対象のためレビュアーとは共有されません)" >&2
}
_rite_p61d_emit_terminal() {
  [ "$_terminal_emitted" = "true" ] && return 0
  _terminal_emitted="true"
  echo "[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=$PR_NUMBER; outcome=$outcome; count=$NB_COUNT; iteration_id=$ITERATION_ID; comment_id=$existing_id; degraded=$lookup_degraded" >&2
}
# signal 中断は sentinel だけを出すと「記録が走ったのか」を読む側が判別できない。gate は
# outcome=aborted を「評価はされた」として通すため、記録が確実に未投稿である事実を loud に残す。
_rite_p61d_signal_abort() {  # $1=rc $2=signal
  # 「未投稿」と断定しない: signal が gh の POST 実行中に届いた場合、コメントは既に受理されて
  # いることがある。投稿完了状態を読む手段が無いため、確実に言えるのは「本 helper が完走せず
  # 結末を確定できなかった」ことだけ。次 cycle の lookup + PATCH が自己修復する。
  echo "ERROR: review-nonblocking-record: signal で中断されました (記録が投稿されたかは不明です)" >&2
  echo "  対処: 次 cycle の lookup + PATCH が update-in-place で自己修復するため、通常は追加操作は不要です" >&2
  echo "  中断が繰り返される場合のみ Issue #${ISSUE_NUMBER} の '$MARKER' コメントを目視で確認してください (mergeable 判定には影響しません)" >&2
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=signal_aborted; rc=$1; signal=$2" >&2
}
trap 'rc=$?; _rite_p61d_emit_terminal; _rite_p61d_cleanup; exit $rc' EXIT
trap '_rite_p61d_signal_abort 130 2; _rite_p61d_emit_terminal; _rite_p61d_cleanup; exit 130' INT
trap '_rite_p61d_signal_abort 143 15; _rite_p61d_emit_terminal; _rite_p61d_cleanup; exit 143' TERM
trap '_rite_p61d_signal_abort 129 1; _rite_p61d_emit_terminal; _rite_p61d_cleanup; exit 129' HUP

# --- 既存記録コメントの探索 ---
# `--paginate --slurp` + 外側 jq で全ページ走査する (非 paginate は既定 30 件・昇順のため
# コメント 30 件超の Issue で marker を miss し、update-in-place が silent に破綻する)。
# pipefail なしでは gh 失敗が末尾 jq の rc=0 に mask され degraded 分岐が dead code になる。
gh_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
  review-nonblocking-record p61d-lookup-err "lookup 失敗時の gh/jq 詳細が表示されません")

# 関連 Issue を先に確定する。lookup / persist / create はすべて ISSUE_NUMBER を使う。
# trap 設置後なので失敗時も terminal sentinel が出る。pending marker は残さない
# (PR body / branch を同 cycle 内で直せないため、差し戻しても収束しない)。
if ! _resolve_related_issue; then
  outcome="failed"
  exit 1
fi

# **author 条件は必須**: 前方一致だけでは、marker で始まるコメントを第三者が 1 件投稿するだけで
# `last` がそれを掴み PATCH 先を奪われる (書込権限があれば他人のコメントを破壊、無ければ 403 で
# 記録が恒久的に失われる)。自分の login と一致する投稿のみを対象にする。
# **機械専用 sentinel 条件も必須**: author + startswith だけでは、同一 author が marker で始まる
# 見出しの人間コメント (記録の対応状況メモ等) を書いた場合にそれを掴み、PATCH が人間の本文を
# 丸ごと上書き破壊する。sentinel を **最終非空行の等値** で見て残余を塞ぐ (`contains` は本文中に引用として
# 現れた sentinel も拾うため不可 — 上記 RECORD_SENTINEL の注記参照)。
#
# 述語は 2 段構えにする。`$near` (author ∧ marker 前方一致 = 「記録コメントの候補」) と `$hit`
# (さらに最終非空行が sentinel と等しい = 「本 helper が投稿したと確定できるもの」) を別々に数え、差分を
# **sentinel を持たない候補の件数**として可視化する。差分の正体は (a) sentinel 導入前に投稿された
# 記録コメント (migration)、または (b) 同一 author が書いた marker 前方一致の手書きコメント の
# いずれかで、どちらも update-in-place の対象にならず関連 Issue 上に孤児として残る。述語変更由来のこの
# 縮退だけを無音にすると観測手段が無くなるため (本 helper は他の全 degraded 経路で WARNING を出す)。
# rc も見る (F-01, cycle 4 review, error-handling-reviewer): `gh api` は HTTP エラー時に
# `--jq` フィルタを適用せずレスポンス body をそのまま stdout へ書いて rc!=0 で終了する
# (gh 2.96.0 で実測)。空文字判定だけに依存すると、この非空な JSON エラー body が
# `gh_login` として通過し degraded 検出が素通りする (existing_id="" のまま degraded=0 で
# 新規作成へ縮退し、WARNING も出ない)。
if ! gh_login=$(gh api user --jq '.login' 2>"${gh_err:-/dev/null}") || [ -z "$gh_login" ]; then
  echo "WARNING: gh api user による自 login の取得に失敗しました。既存コメントを特定できないため存在不明として扱います" >&2
  _gh_err_detail
  _record_degraded_hint
  existing_id=""
  lookup_degraded=1
  # 自 login が無いと durable id の author 検証 (AC-5) も本文照合の author 条件も評価できない。
  # 段 1-3 をまとめて skip し「存在不明」で確定させる (誤 PATCH より新規作成を選ぶ既存の縮退方針)。
  gh_login=""
fi

# 段 1: durable id (第一候補)
[ -n "$gh_login" ] && _resolve_persisted_id

# 段 2: 本文照合による fallback。**id 解決の成否に依らず常に走らせる** — id で PATCH 先が確定した
# cycle でも孤児 / 重複の観測 (NONBLOCKING_LEGACY_ORPHAN / NONBLOCKING_DUPLICATE_RECORD) を
# 落とすと、関連 Issue 上の残骸が silent になる。
if [ -z "$gh_login" ]; then
  :   # 自 login 不明。上の分岐で degraded 確定済み
elif lookup_out=$(gh api --paginate --slurp "repos/$OWNER_REPO/issues/$ISSUE_NUMBER/comments" 2>"${gh_err:-/dev/null}" \
     | jq -r --arg marker "$MARKER" --arg me "$gh_login" --arg sentinel "$RECORD_SENTINEL" \
         "$LAST_CONTENT_LINE_JQ"'
         (add // [])
         | [.[] | select(((.body // "") | startswith($marker)) and ((.user.login // "") == $me))] as $near
         | [$near[] | select((.body | last_content_line) == $sentinel)] as $hit
         | ((($hit | last | .id) // "") | tostring)
           + "\t" + ((($near | length) - ($hit | length)) | tostring)
           + "\t" + (($hit | length) | tostring)
       ' 2>>"${gh_err:-/dev/null}"); then
  # タブ 3 フィールド。フィールド数が想定と違うときは lookup 出力の形状 drift なので、
  # 既存の degraded 境界へ合流させる (silent な default 補填にしない — jq filter を壊す編集が
  # 入っても孤児検出が signal ゼロの dead code に変わるだけで誰も気づけなくなる)。
  # `IFS=$'\t' read` は使わない — タブは IFS の *空白* 扱いなので**先頭の空フィールドが食われ**、
  # 「既存なし」(第 1 フィールドが空) のとき件数が 1 つずつ前へずれて existing_id に件数が入る
  # (実測: `read -r a b c <<< $'\t0\t0'` は a=0 b=0 c=空)。パラメータ展開で位置を固定する。
  fallback_id="${lookup_out%%$'\t'*}"
  _lookup_rest="${lookup_out#*$'\t'}"
  legacy_orphan_count="${_lookup_rest%%$'\t'*}"
  canonical_hit_count="${_lookup_rest#*$'\t'}"
  if [ "$(printf '%s' "$lookup_out" | awk -F'\t' '{print NF}')" != "3" ]; then
    echo "WARNING: lookup の出力形状が想定 (タブ 3 フィールド) と異なります。存在不明として扱います" >&2
    fallback_id=""; legacy_orphan_count=0; canonical_hit_count=0
    list_failed=1
  fi
  # fallback_id は mutating な API path (`issues/comments/$existing_id` の PATCH) へ補間されうる。
  # 同じ jq 出力から取る件数側には数値 guard があるのに書き込み先だけ無検証、という非対称を作らない
  # (owner_repo / iteration_id が allowlist を持つのと同じ方針)。空へ倒せば既存の「既存なし」経路に乗る。
  # 段 1 の durable id も同一の述語を通す (_resolve_persisted_id 内)。
  case "$fallback_id" in *[!0-9]*) fallback_id="" ;; esac
  case "$legacy_orphan_count" in ''|*[!0-9]*) legacy_orphan_count=0 ;; esac
  case "$canonical_hit_count" in ''|*[!0-9]*) canonical_hit_count=0 ;; esac
  if [ "$legacy_orphan_count" -gt 0 ]; then
    echo "WARNING: marker 前方一致だが最終非空行が機械専用 sentinel でない自分のコメントが ${legacy_orphan_count} 件あります。update-in-place の対象外として扱います" >&2
    echo "  該当は (a) sentinel 導入前に投稿された記録コメント、または (b) marker で始まる見出しの手書きコメント のいずれかです" >&2
    echo "  (a) なら Issue #${ISSUE_NUMBER} 上で古い記録コメントを手動削除してください (次に指摘が 1 件以上ある cycle で新しい 1 件が作られ、以後 update-in-place で維持されます)" >&2
    echo "  (b) なら意図どおりの除外です (本 helper が人間のコメントを PATCH で上書きしないための条件)" >&2
    echo "[CONTEXT] NONBLOCKING_LEGACY_ORPHAN=1; pr=$PR_NUMBER; count=$legacy_orphan_count" >&2
  fi
  # canonical な記録コメントが 2 件以上 = 過去の degraded 縮退が生んだ重複。`last` を採るため
  # 古い方は恒久的に stale で残る。legacy_orphan とは原因も復旧手順も違う (あちらは sentinel を
  # 持たない別種のコメント) ので合算せず別 marker にする — 合算すると WARNING の文面が事実と
  # 異なり、operator を誤った削除対象へ誘導する。
  if [ "$canonical_hit_count" -gt 1 ]; then
    echo "WARNING: 機械専用 sentinel を持つ自分の記録コメントが ${canonical_hit_count} 件あります。最新の 1 件だけを update-in-place し、古い方は stale のまま残ります" >&2
    echo "  原因は (a) 過去の cycle で lookup が degraded し新規作成へ縮退した、または (b) 同一 author が" >&2
    echo "  marker 前方一致かつ最終非空行が sentinel のコメントを投稿し update-in-place の対象になった のいずれかです" >&2
    echo "  (b) の場合、直前の PATCH が当該コメントを上書きしている可能性があります。GitHub のコメント編集履歴を確認してください" >&2
    echo "  対処: Issue #${ISSUE_NUMBER} 上で古い方を手動削除してください (mergeable 判定には影響しません)" >&2
    echo "[CONTEXT] NONBLOCKING_DUPLICATE_RECORD=1; pr=$PR_NUMBER; count=$canonical_hit_count" >&2
  fi
else
  echo "WARNING: 既存の非実測記録コメントの検索に失敗しました (gh/jq)。存在不明として扱います" >&2
  _gh_err_detail
  fallback_id=""
  list_failed=1
fi

# 段 3: PATCH 先の決定 (durable id > 本文照合 fallback)
[ -n "$gh_login" ] && _decide_existing_id
[ -n "$gh_err" ] && { rm -f "$gh_err"; gh_err=""; }

# --- 本文検査 (非空 → 1 行目 marker → 最終非空行 sentinel → count/body 整合) ---
# F-01 (cycle 3 review): count/body 整合検査は必ず **skip 判定より前** に置く。skip 判定を先に
# 評価すると、F-01 が本来対象としていた「--count 0 の誤置換 + N 件を表示する本文 + 既存コメントなし」
# のシナリオが `existing_id 空 ∧ NB_COUNT==0` の skip 条件に一致し、本文を一切読まないまま
# `outcome=skipped` へ抜けてしまう (AC-4 の正当な no-op と観測上区別できず、D-01 の記録が無音で
# 消える経路が温存される)。本文検査を先に行えば、0 件 skip の対象になる run でも「本当に 0 件と
# 宣言された本文か」を確認してから skip するため、この経路も count_body_mismatch で捕捉できる。
if [ ! -s "$CONTENT_FILE" ]; then
  echo "WARNING: 非実測記録の本文ファイルが空です ($(printf '%s' "$CONTENT_FILE" | neutralize_ctrl))。投稿を中止します (既存コメントの marker 破壊を防ぐ)" >&2
  _record_body_check_failure_hint
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=body_file_empty" >&2
  outcome="failed"
  retain_pending_marker=1
  exit 0
fi

# 1 行目 marker 検査。空 body と同様に「marker を欠いた本文で PATCH する」と 1 行目 marker が消え、
# 以降の lookup が恒久的に miss する。空 body だけを塞いでも本文生成が失敗した非空ケースが素通りする。
# 診断分離のため body_file_empty とは別 reason にする (兄弟 issue-comment-wm-sync.sh の header 検査と同型)。
case "$(head -n 1 "$CONTENT_FILE")" in
  "$MARKER"*) ;;
  *)
    echo "WARNING: 非実測記録の本文 1 行目が marker 見出しで始まっていません ($(printf '%s' "$CONTENT_FILE" | neutralize_ctrl))。投稿を中止します" >&2
    echo "  期待: 1 行目が '$MARKER' で始まること (SKILL.md ステップ 6.1.d step 1 の variant A / B)" >&2
    _record_body_check_failure_hint
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=body_marker_missing" >&2
    outcome="failed"
    retain_pending_marker=1
    exit 0
    ;;
esac

# 機械専用 sentinel 検査。lookup の第 3 条件に使う以上、投稿する本文が sentinel を欠くと
# **次 cycle の lookup が自分の投稿を見つけられず** update-in-place が恒久破綻して記録コメントが
# cycle ごとに増殖する (1 行目 marker を欠いた場合と同じ結末)。
# **read 側と完全に同じ述語で検査する**: read が最終非空行の等値なのに write が位置非依存 (`grep -qF`)
# だと、sentinel を本文途中にだけ持つ本文が検査を通過して投稿され、次 cycle の lookup が
# その投稿を miss する (片側だけ強めた場合の増殖経路)。最終**非空**行と厳密一致を要求する
# (末尾の空行は GitHub 側の整形でも増減しうるため許容する)。
# read 側 lookup と **同一の jq 定義** を評価する (LAST_CONTENT_LINE_JQ)。shell 側で
# `grep -E '[^[:space:]]'` を使う実装は、空白クラスが locale / grep 実装に依存し、また
# `tr -d '\r'` の CR 除去範囲が jq の `sub("\r$"; "")` と違うため、read/write の受理集合が
# 環境で割れる。jq は lookup / PATCH で既に hard dependency なので実装コストは増えない。
# **jq の rc は捨てない** — 「述語を評価した結果 sentinel と違った」(caller 契約違反、本文を作り直せば
# 収束する) と「述語の評価自体ができなかった」(jq 不在 / 実行不能などの環境起因、本文を作り直しても
# 収束しない) は帰結が正反対で、後者を retain 側に落とすと 8.0.3 が毎 cycle 差し戻して result pattern
# を永久に emit できなくなる。境界は exit code ではなく **原因** で引く (docstring の retain/delete 参照)。
_body_jq_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
  review-nonblocking-record p61d-body-err "本文述語の評価失敗の詳細が表示されません") || _body_jq_err=""
# 生成直後に trap 保護下へ置く (EXIT trap は ${gh_err:-} を回収する。代入が jq 実行の後だと、
# jq 実行中に INT/TERM/HUP を受けた場合に本ファイルだけが TMPDIR に残る)
gh_err="$_body_jq_err"
if ! _body_last_line=$(jq -Rrs "$LAST_CONTENT_LINE_JQ"' last_content_line' < "$CONTENT_FILE" 2>"${_body_jq_err:-/dev/null}"); then
  echo "WARNING: 非実測記録の本文述語 (最終非空行の算出) を評価できませんでした。投稿を中止します" >&2
  _gh_err_detail
  _record_env_failure_hint
  echo "  本文の作り直しでは解消しません (jq の実行環境側の問題です)。pending marker は削除するため 8.0.3 は差し戻しません" >&2
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=body_check_unavailable" >&2
  outcome="failed"
  exit 0
fi
[ -n "$_body_jq_err" ] && rm -f "$_body_jq_err"
gh_err=""
if [ "$_body_last_line" != "$RECORD_SENTINEL" ]; then
  echo "WARNING: 非実測記録の本文の最終非空行が機械専用 sentinel ではありません ($(printf '%s' "$CONTENT_FILE" | neutralize_ctrl))。投稿を中止します" >&2
  echo "  期待: 最終非空行が '$RECORD_SENTINEL' と厳密一致すること (SKILL.md ステップ 6.1.d step 1 の variant A / B は最終行に本行を置く)" >&2
  # `--c0-only`: 既定モードは C1 帯 (0x80-0x9f) をバイト単位で ? 化するため、日本語 UTF-8 の
  # 第 2/第 3 バイトを巻き込んで診断が読めなくなる。本行は LLM 生成の自由文が渡る唯一の call site。
  # C0 + DEL は引き続き ? 化されるので偽 [CONTEXT] 行の注入防止は損なわない。
  echo "  実際の最終非空行: '$(printf '%s' "$_body_last_line" | neutralize_ctrl --c0-only | head -c 200)'" >&2
  echo "  最終非空行が sentinel でない本文を投稿すると、次 cycle の lookup (最終非空行の等値) が自分の投稿を検出できず記録コメントが増殖します" >&2
  _record_body_check_failure_hint
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=body_sentinel_missing" >&2
  outcome="failed"
  retain_pending_marker=1
  exit 0
fi

# `--count` (SKILL.md ステップ 6.1.d step 2 の LLM 置換) と本文の `📎 non_blocking_count: {n}` 行
# (同 step 1 の LLM 置換) は独立した 2 箇所の置換であり、片方だけずれると事実と異なる記録が投稿
# される (count=0 + variant A 本文 で 0 件のはずが記録が無音で消える、または count>0 + variant B
# 「0 件」本文 で虚偽の記録が残る)。投稿前に本文中の該当行を抽出し --count と一致することを検査する。
# コロン直後・行末の空白量は固定しない (F-1, cycle 4 review: 本文は毎 cycle LLM が生成する自由文
# であり、`non_blocking_count:2` や行末 trailing space のような意味を変えない整形のブレで
# no-match になり記録が丸ごと投稿されなくなるのを防ぐ)。`-m1` (先頭一致) ではなく `tail -1`
# (末尾一致) で採る (F-2, cycle 4 review: SKILL.md の variant A/B は本行を `📎 reviewed_commit:`
# 行の直前に置く契約であり本文の最終行ではないため、コードフェンス等で本文中に同形の行が先に
# 現れても末尾の canonical な行を読む)。
body_count=$(grep -E '^📎 non_blocking_count:[[:space:]]*[0-9]+[[:space:]]*$' "$CONTENT_FILE" | tail -1 | grep -oE '[0-9]+')
if [ -z "$body_count" ] || [ "$body_count" != "$NB_COUNT" ]; then
  # `body_count` は直前の `grep -oE '[0-9]+'` により数字列か空文字のみを取り、制御バイトも
  # マルチバイト文字も含みえない — neutralize_ctrl の出番はない (F-8, cycle 4 review: 数字列に
  # 対する neutralize_ctrl は恒等写像であり、以前の呼び出しは自身が不要と論証する死んだコード
  # だった。空のときのハードコードされた日本語リテラル `<欠落>` はそのまま出す)。
  _body_count_disp="${body_count:-<欠落>}"
  echo "WARNING: 非実測記録の本文中の '📎 non_blocking_count:' 行 (値: '$_body_count_disp') が --count ($NB_COUNT) と一致しません。投稿を中止します" >&2
  echo "  期待: 本文中に '📎 non_blocking_count: $NB_COUNT' 行が存在すること (SKILL.md ステップ 6.1.d step 1 の variant A / B。variant A/B のテンプレートでは 📎 reviewed_commit: 行の直前)" >&2
  _record_body_check_failure_hint
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=count_body_mismatch" >&2
  outcome="failed"
  retain_pending_marker=1
  exit 0
fi

# --- 記録 / skip の分岐 ---
# 検索 degraded 時は `0 件 → skip` / `>0 件 → 新規作成に縮退` (WARNING と degraded=1 は emit 済で
# silent 縮退にはならない)。ここに到達した時点で本文は count/body 整合検査を通過済み。
if [ -z "$existing_id" ] && [ "$NB_COUNT" -eq 0 ]; then
  # 0 件 ∧ 既存なし: 投稿しない (AC-4 非退行)。事実と異なる「0 件」コメントを新規作成しない。
  # ただし degraded 由来の「既存なし」は **既存コメントが実在しても検出できなかった** 可能性が
  # あるため、収束 cycle のクリア (AC-2) が成立していないことを明示する。
  [ "$lookup_degraded" = "1" ] && _record_degraded_skip_hint
  outcome="skipped"
  exit 0
fi

gh_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
  review-nonblocking-record p61d-post-err "投稿失敗時の gh stderr 詳細が表示されません")

# PATCH / create の失敗診断は差分が label と reason の 2 語だけなので 1 関数に寄せる
# (片側にだけ診断を足す drift を構造的に防ぐ)。2 つの呼び出し元の直前に置く。
_record_gh_failure() {  # $1=label $2=reason $3=rc
  echo "WARNING: 非実測指摘の Issue コメント$1 に失敗しました (gh rc=$3)" >&2
  _gh_err_detail
  _record_gh_io_failure_hint
  # signal 終了 (rc>=128) を retained flag に併記する (兄弟 review-comment-post.sh と対称)
  if [ "$3" -ge 128 ]; then
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=$2; rc=$3; signal=$(($3 - 128))" >&2
  else
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=$2; rc=$3" >&2
  fi
  outcome="failed"
}

# 投稿した記録コメントの id を関連 Issue body へ永続化する。次 cycle の lookup が本文照合を経ずに
# canonical を特定できるようにするための唯一の書き込み経路であり、本経路の write 側の要。
# **失敗しても記録は成功扱いのまま**で pending marker も残さない (AC-3 / MUST NOT) — 環境 / IO 起因で
# caller が本文を作り直しても解消しないため、`body_check_unavailable` と同じ削除バケットに属する。
_persist_comment_id() {  # $1=comment_id
  # 呼び出し時点の gh_err (投稿失敗診断用) をグローバルの退避枠へ移す。本関数は _gh_err_detail に
  # 自分の stderr を見せるため gh_err を一時的に差し替えるので、復元しないと呼び出し元の tempfile が
  # EXIT trap の回収対象から外れて leak する。**退避先も trap の回収対象に載せる** — 関数ローカルに
  # 置くと差し替え中の signal で同じ leak が起きる (id_persist_tmp / id_persist_err と同じ理由)。
  local _cid="${1:-}" _cur="" _stripped="" _reason=""
  id_persist_prev_err="${gh_err:-}"
  case "$_cid" in ''|*[!0-9]*) _reason="comment_id_unresolved" ;; esac

  if [ -z "$_reason" ]; then
    id_persist_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
      review-nonblocking-record p61d-idpersist-err "id 永続化の失敗詳細が表示されません") || id_persist_err=""
    # 生成直後に trap 保護下へ置く (EXIT trap は ${gh_err:-} と ${id_persist_err:-} を回収する)
    gh_err="$id_persist_err"
    if ! _cur=$(gh issue view "$ISSUE_NUMBER" -R "$OWNER_REPO" --json body --jq '.body' 2>"${id_persist_err:-/dev/null}"); then
      _reason="body_read_failed"
    fi
  fi

  if [ -z "$_reason" ]; then
    # 既存 marker は **行ごと** 除去する (`$ID_MARKER_STRIP_SED` は `d` コマンド)。marker は必ず
    # 独立行として書かれるため取り逃さず、散文中の同形文字列は行アンカーで対象外になる。
    # コマンド置換が末尾改行を落とすため、marker を付け直しても空行は cycle ごとに累積しない。
    _stripped=$(printf '%s\n' "$_cur" | sed "$ID_MARKER_STRIP_SED")
    id_persist_tmp=$(mktemp "${TMPDIR:-/tmp}/rite-nbr-issuebody-XXXXXX") || id_persist_tmp=""
    if [ -z "$id_persist_tmp" ] || ! printf '%s\n\n%s%s%s\n' "$_stripped" "$ID_MARKER_PREFIX" "$_cid" "$ID_MARKER_SUFFIX" > "$id_persist_tmp"; then
      _reason="body_write_failed"
    elif ! gh issue edit "$ISSUE_NUMBER" -R "$OWNER_REPO" --body-file "$id_persist_tmp" >/dev/null 2>"${id_persist_err:-/dev/null}"; then
      _reason="body_edit_failed"
    fi
    [ -n "$id_persist_tmp" ] && { rm -f "$id_persist_tmp"; id_persist_tmp=""; }
  fi

  if [ -n "$_reason" ]; then
    echo "WARNING: 記録コメント id (${_cid:-<不明>}) を Issue body へ永続化できませんでした (reason=$_reason)" >&2
    _gh_err_detail
    _record_id_persist_failure_hint "$_reason"
    echo "[CONTEXT] NONBLOCKING_ID_PERSIST_FAILED=1; pr=$PR_NUMBER; reason=$_reason" >&2
  fi
  [ -n "$id_persist_err" ] && { rm -f "$id_persist_err"; id_persist_err=""; }
  gh_err="$id_persist_prev_err"
  # 復元したら退避枠は空へ戻す (trap の二重 rm / stale パス参照を作らない)
  id_persist_prev_err=""
  return 0
}

if [ -n "$existing_id" ]; then
  # 本文の受け渡しは gh-cli-patterns.md §"For comment update (gh api PATCH)" の正規形に従う
  # (jq --rawfile で JSON を組み --input - へ渡す)。pipefail は冒頭の `set -uo pipefail`
  # (グローバル) を subshell がそのまま継承するため、jq 段の失敗は継承された pipefail によって
  # rc に伝播する (issue-comment-wm-sync.sh と同型)。subshell 内の `set -o pipefail` は
  # その継承を前提にした冗長な再宣言であり (F-7, cycle 4 review: 削除しても本 subshell の
  # 伝播は保たれる)、本 block だけを抜き出して他所へ移植する場合の防御として残す。
  if ( set -o pipefail
       jq -n --rawfile body "$CONTENT_FILE" '{"body": $body}' \
         | gh api "repos/$OWNER_REPO/issues/comments/$existing_id" -X PATCH --input - >/dev/null ) 2>"${gh_err:-/dev/null}"; then
    outcome="updated"
    # 本文照合で見つけた canonical は、次 cycle から id 経路に乗せるためここで永続化する
    # (durable id を持たない既存 Issue の migration 経路)。id 経路で解決済みの場合は Issue body に
    # 同じ値が既にあるため書き直さない (毎 cycle の無意味な Issue body 更新を避ける)。
    [ -z "$id_resolved" ] && _persist_comment_id "$existing_id"
  else
    _record_gh_failure "更新 (PATCH)" patch_failed "$?"
  fi
else
  # ここに来るのは count > 0 のときのみ (0 件 ∧ 既存なしは上で skip 済)。
  # F-01 (cycle 3 review, application-reviewer + error-handling-reviewer が独立検出):
  # _record_degraded_create_hint は create の**成否が確定してから** (outcome="created" の直後)
  # 呼ぶこと。gh issue comment の実行前に呼ぶと、create 自体が失敗した run でも「重複して新規作成した」
  # という未確定の結末を断定する案内が出てしまう (degraded の主因である gh 認証/network 障害は
  # create 失敗の主因でもあるため、この誤案内は稀な角ケースではなく支配的な組み合わせで発火する)。
  # skip 経路の _record_degraded_skip_hint (結末確定後に emit) と同じ規律に揃える。
  # stdout は捨てない — `gh issue comment` が返す URL (`...#issuecomment-{id}`) が、作成したコメントの
  # id を知る唯一の手段であり、その id が次 cycle の durable な同定手段になる。
  if _post_out=$(gh issue comment "$ISSUE_NUMBER" -R "$OWNER_REPO" --body-file "$CONTENT_FILE" 2>"${gh_err:-/dev/null}"); then
    outcome="created"
    [ "$lookup_degraded" = "1" ] && _record_degraded_create_hint
    _persist_comment_id "$(printf '%s' "$_post_out" | sed -n 's|.*#issuecomment-\([0-9][0-9]*\).*|\1|p' | tail -1)"
  else
    _record_gh_failure "記録 (新規作成)" create_failed "$?"
  fi
fi

exit 0
