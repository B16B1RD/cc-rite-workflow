#!/bin/bash
# review-helpers-gate-behavior.test.sh
#
# Gate-behavior self-tests for the 4 review helpers:
#   - hooks/review-skip-notification.sh   (pr-review.md ステップ 6.1.c)
#   - hooks/review-comment-post.sh        (pr-review.md ステップ 6.1.b)
#   - hooks/review-result-save.sh         (pr-review.md ステップ 6.1.a)
#   - hooks/review-nonblocking-record.sh  (pr-review.md ステップ 6.1.d)
#
# shift2-loop-hardening.test.sh は shift-loop no-hang の 1 軸のみをカバーし、これらの helper の
# 中核 invariant である gate 分岐 (reason 語彙 / exit code / [CONTEXT] emit) には届かない。
# 本テストは各 gate を通過 / 遮断の両方向から検証してその invariant を guard する。
#
# Coverage:
#   TC-1 review-skip-notification.sh — post_comment_mode 3 分岐 / pr_number numeric gate /
#        file_timestamp 整合性 (unknown ∧ local_save_failed≠1 遮断) / local_save_failed 値検証 /
#        ケース 1 (INFO, exit 0) vs ケース 2 (p61c_persistence_unrecoverable, exit 2 hard-fail)
#   TC-2 review-comment-post.sh — post_comment_mode gate (false silent skip は gh 不実行まで検証) /
#        pr_number / json_saved / content-file / iso_timestamp の各 gate
#        (iso_timestamp は ISO 8601 allowlist — 非 ISO 形状 / awk metachar 注入形も reject) /
#        stub gh での happy path (Raw JSON 内 sentinel 置換 + Markdown 本文 sentinel 保存) /
#        gh 失敗時の gh_comment_post_failure emit
#   TC-3 review-result-save.sh — D-04 非ブロッキング契約 (gate 失敗でも exit 0 + EXIT trap が
#        FILE_TIMESTAMP / ISO_TIMESTAMP / JSON_SAVED を必ず emit) / --content-file 欠落 (exit 1) /
#        validation chain (required fields / findings id / scope enum / CRITICAL×nit-noted) /
#        happy path (JSON_SAVED=true + sentinel → ISO timestamp 置換)
#   TC-4 review-nonblocking-record.sh — 引数 gate (placeholder residue 5 種 + content_file 不在 +
#        iteration_id 形状 allowlist、いずれも exit 1) / lookup の「自 login ∧ 1 行目 marker 前方一致 ∧ 最終非空行 == 機械専用 sentinel」の 3 条件
#        (引用返信も第三者 author も掴まない、gh api user が rc!=0 かつ body を stdout に出す経路も
#        含む) / 本文検査 4 段 (非空 / 1 行目 marker / 最終非空行が機械専用 sentinel / count 整合) / 分岐 4 種
#        (created / updated / skipped / failed) / 非ブロッキング契約 (gh 失敗でも exit 0) /
#        本文検査起因の失敗 (body_file_empty / body_marker_missing / body_sentinel_missing / count_body_mismatch) と
#        gh/IO 起因の失敗 (patch_failed / create_failed) で復旧案内を分ける契約 /
#        **terminal sentinel が動作完了を表すことの実測** (outcome が created|updated を名乗るときは
#        gh stub log に投稿呼び出しが実在し、skipped のときは投稿呼び出しが 1 件も無い) /
#        iteration_id の echo back
#   TC-5 skills/pr-review/SKILL.md 静的 pin — markdown 埋め込みの prose gate は実行テストできない
#        ため、silent failure に直結する契約を静的に固定する: (a) 6.1.d の helper 呼び出しが
#        live な bash block にある (行頭 anchor + fence 検査で `# bash ...` コメントアウトを検出) /
#        (b) 両 gate の **Check 行そのもの** が terminal sentinel を参照する (出現数の等値ではなく
#        live な述語を pin する — 数の等値は散文追加で相殺され双方向に誤る)。加えて同じ Check 行が
#        `iteration_id` / `REVIEW_CYCLE_ID` の**一致判定 (「一致」の語を伴う比較)** にも言及して
#        いることを要求する (AC-7/T-06 — 両語の共起だけを pin すると、比較セマンティクスを削って
#        「存在するか」に弱めても REVIEW_CYCLE_ID の定義節に語が残るだけで素通りする。mutation 実測
#        済み: 比較動詞のみ削除で 249/249 のまま検出漏れだったため「一致」を必須トークンに追加した)。
#        さらに該当 Check 行が区間内に 1 本だけであることも固定する (区間内マッチ数のみの assertion
#        は同一トークン列を含む別行を足すだけで素通りするため) /
#        (c) helper の MARKER 値と SKILL.md の variant 見出しの前方一致 coupling / (d) 8.0 の
#        gate 評価順序規定 / (e) 8.0.x の表の行が終端 (`8.1`、「ステップ」接頭辞の有無を問わない) を
#        名指しせず、全データ行が
#        「次の gate へ」/ `**ERROR**` / `legitimately skipped` のいずれかの規約文言を持つ / (g) helper
#        が count/body 整合検査で grep する `📎 non_blocking_count:` needle と SKILL.md の variant
#        A/B テンプレートの coupling (TC-5c の MARKER coupling と同型)。前方一致だけでなく行全体の
#        形状 (g') と variant A/B への位置 (g'') も別途固定する (いずれも前方一致 count だけでは
#        素通りする drift クラス)。
#        各 pin は追加時に mutation を当てて落ちることを実測する (手順: measured-gate-record.md#static-pin)
#
# Network 非依存: gh は PATH 先頭の stub に差し替え、review-result-save は --results-dir で
# sandbox に隔離する (repo の .rite/ を汚さない)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

SENTINEL='__RITE_TS_PLACEHOLDER_7f3a9b2c__'

TMP_ROOT=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
# helper は marker path を自プロセスの ${TMPDIR} から導出する。TMPDIR を隔離ディレクトリへ向けると
# (a) fixture 側の "${TMPDIR:-/tmp}/rite-p61a-pending-..." 式がそのまま helper の導出先と一致し、
# (b) 固定名ファイルを共有 /tmp へ作らずに済む (素の `: >` は symlink を追随して任意ファイルを
#     0 バイトへ truncate しうる。production 側は同じ危険を set -C で塞いでいるがテストは持たない)、
# (c) helper が削除しない marker (trap 前 exit 1 の検証ケース) も EXIT trap で回収される。
export TMPDIR="$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

# --- 前提: 4 helper の存在 (rename / 削除 drift は環境エラーではなくテスト失敗として扱う) ---
for helper in \
  "hooks/review-skip-notification.sh" \
  "hooks/review-comment-post.sh" \
  "hooks/review-result-save.sh" \
  "hooks/review-nonblocking-record.sh"; do
  if [ ! -f "$PLUGIN_ROOT/$helper" ]; then
    fail "precondition: $helper が存在しません (rename / 削除 drift)"
  fi
done
if [ "$FAIL" -ne 0 ]; then
  print_summary "$(basename "$0")"
  exit 1
fi

# _dump_precondition_stderr <errfile> — 「前提未成立」で fail したケースの診断出力。
#   signal 窓を開く shim 系 (TC-3.11h/i/l/m) は、窓を作れなかった事実だけを報告しても
#   原因 (shim 不発 / helper が別経路で早期 return / 環境差) が判別できない。これらは
#   author の Linux では再現せず CI でしか観測できないため、1 往復あたりのコストが高い。
#   fail 行の直後に helper の stderr 先頭を添えて、次の CI 実行が自己診断になるようにする。
_dump_precondition_stderr() {
  local _f="${1:-}"
  if [ -n "$_f" ] && [ -s "$_f" ]; then
    echo "     ↳ helper stderr (先頭 20 行):"
    head -20 "$_f" | sed 's/^/       /'
  else
    echo "     ↳ helper stderr: (空 — helper が何も出力せずに終了した)"
  fi
}

# --- stub gh (network 遮断 + 呼び出し観測) ---
# GH_STUB_LOG   : 呼び出し有無の観測 (silent skip 契約「gh pr comment を絶対に実行しない」の検証、
#                 および TC-4 の「outcome=created|updated ⇒ 投稿呼び出しが実在する」検証)
# GH_STUB_BODY  : --body-file の内容 capture (sentinel 置換 post-condition の検証)
# GH_STUB_RC    : stub の exit code (gh_comment_post_failure / patch_failed / create_failed 経路の再現)
# GH_LOOKUP_JSON: `gh api --paginate --slurp .../comments` が返す JSON のパス (6.1.d の既存コメント探索)
# GH_LOOKUP_RC  : 同 lookup の exit code (degraded 縮退経路の再現)。投稿側 rc とは独立に制御する
STUB_DIR="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_STUB_LOG"
# lookup 経路は投稿経路と別 rc / 別出力で制御する (6.1.d は 1 プロセスで両方を呼ぶため)
# 自 login の解決 (lookup の author 条件が使う)。GH_ME_RC で失敗経路も再現できる
if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  if [ "${GH_ME_RC:-0}" != "0" ]; then
    echo "stub: gh api user failure" >&2
    # F-01 (error-handling-reviewer, cycle 4): 実 gh は HTTP エラー時に --jq フィルタを適用せず
    # レスポンス body をそのまま stdout へ出す (rc!=0 と非空 stdout が同時に成立する)。旧来の
    # 「rc≠0 かつ stdout 空」だけをモデル化したスタブでは、rc を見ずに空文字判定だけに依存する
    # 実装バグを検出できなかった (3 cycle 生き延びた理由)。この軸を再現する。
    [ -n "${GH_ME_STDOUT_ON_ERROR:-}" ] && printf '%s' "$GH_ME_STDOUT_ON_ERROR"
    exit "${GH_ME_RC}"
  fi
  # F-01 (test-reviewer, cycle 5): rc=0 かつ空 stdout (login フィールド欠落等) の軸。
  # cycle 4 の rc チェック追加は選言 (`rc!=0 || -z`) の rc 側だけを検証しており、`-z` 側
  # (rc=0 だが空文字) を再現するスイッチが無く、この分岐を削除しても suite が green のままだった。
  if [ -n "${GH_ME_EMPTY:-}" ]; then
    exit 0
  fi
  printf '%s' "${GH_ME:-rite-bot}"
  exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "--paginate" ]; then
  if [ "${GH_LOOKUP_RC:-0}" != "0" ]; then
    echo "stub: lookup failure" >&2
    exit "${GH_LOOKUP_RC}"
  fi
  # abort 経路テスト用の hang スイッチ (判定分岐に到達する前に signal を受けさせる)。
  # **自 PID を GH_HANG_PID_FILE に書く**: helper は本 stub の stderr を tempfile へ退避するため
  # 「hang に入った」ことを親の stderr では観測できない。加えて bash は foreground コマンドの
  # 完了まで signal trap を遅延させるので、test 側が helper に TERM を送っても本 stub を
  # 落とさない限り trap は走らない。PID を渡して test が両方を落とせるようにする。
  if [ -n "${GH_LOOKUP_HANG:-}" ]; then
    [ -n "${GH_HANG_PID_FILE:-}" ] && printf '%s' "$$" > "$GH_HANG_PID_FILE"
    echo "stub: lookup hang" >&2
    # `exec` で sleep に自 PID を引き継がせる。子プロセスのまま sleep すると、記録した PID を
    # 落としても sleep がパイプの書き込み端を握り続け、helper 側のコマンド置換が sleep 満了まで
    # 戻らない (実行時間が 30 秒に膨らむ)。
    exec sleep 30
  fi
  # jq 側を壊す switch (helper の lookup パイプで jq の stderr も capture されることを検証する)。
  # gh は rc=0 で返るため、jq のエラーだけが degraded 経路を発火させる。
  if [ -n "${GH_LOOKUP_MALFORMED:-}" ]; then
    printf '%s' '{"message":"Not Found"}'
    exit 0
  fi
  # F-9 (application-reviewer, cycle 4): `--paginate --slurp` が 0 ページ (真の空配列 `[]`、
  # zero-byte 出力とは異なる — jq は空 stdin では filter 自体を評価せず rc=0 で無害だが、
  # リテラル `[]` は 1 個の JSON 値として評価され `add` が `null` を返す) を返す稀な経路を再現する。
  if [ -n "${GH_LOOKUP_ZERO_PAGES:-}" ]; then
    printf '%s' '[]'
    exit 0
  fi
  # fixture は「ページの配列」。実 gh のフラグ意味論を再現する:
  #   --slurp あり -> 全ページを 1 つの配列にまとめて出す (helper の `add` が平坦化する形)
  #   --slurp なし -> ページごとに独立した JSON を stream 出力する (`add` が壊れる形)
  # これを stub 側で再現しないと --slurp の脱落が観測上まったく差を生まず検出できない。
  if [ -n "${GH_LOOKUP_JSON:-}" ]; then
    case " $* " in
      *" --slurp "*) cat "$GH_LOOKUP_JSON" ;;
      *)             jq -c '.[]' "$GH_LOOKUP_JSON" ;;
    esac
  fi
  exit 0
fi
# PR body の read (durable comment id の永続化先)。GH_PR_BODY 未設定なら空 body を返す
# — id marker 不在 = 初回 cycle の正常系であり、既存 TC はこの経路にそのまま乗る。
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ "${GH_PR_VIEW_RC:-0}" != "0" ]; then
    echo "stub: pr view failure" >&2
    exit "${GH_PR_VIEW_RC}"
  fi
  [ -n "${GH_PR_BODY:-}" ] && [ -f "$GH_PR_BODY" ] && cat "$GH_PR_BODY"
  exit 0
fi
# PR body の write (id 永続化)。--body-file の中身は投稿本文用の GH_STUB_BODY とは **別ファイル**
# へ capture する — 同じ変数に混ぜると create 経路 (pr comment → pr edit の順) で後者が前者を
# 上書きし、どちらを検査しているのか区別できなくなる。
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "edit" ]; then
  if [ -n "${GH_PR_EDIT_BODY:-}" ]; then
    _e_args=("$@"); _e_i=0
    while [ "$_e_i" -lt "${#_e_args[@]}" ]; do
      if [ "${_e_args[$_e_i]}" = "--body-file" ]; then
        _e_next=$((_e_i + 1))
        [ "$_e_next" -lt "${#_e_args[@]}" ] && cp "${_e_args[$_e_next]}" "$GH_PR_EDIT_BODY"
      fi
      _e_i=$((_e_i + 1))
    done
  fi
  if [ "${GH_PR_EDIT_RC:-0}" != "0" ]; then
    echo "stub: pr edit failure" >&2
    exit "${GH_PR_EDIT_RC}"
  fi
  exit 0
fi
# 単一コメントの GET (durable id の解決)。PATCH は `-X PATCH` を伴うため下の汎用経路へ落ちる。
# lookup の `repos/o/r/issues/9/comments` とはパス形状が異なる (`/issues/comments/{id}`) ため
# 誤って捕まえない。
if [ "${1:-}" = "api" ]; then
  case " $* " in
    *" -X PATCH "*) : ;;
    *"/issues/comments/"*)
      if [ "${GH_COMMENT_GET_RC:-0}" != "0" ]; then
        # 実 gh は 404 を `gh: Not Found (HTTP 404)` の形で stderr に出す。helper はこの文字列で
        # 「削除済み」と「一時障害」を reason 上で分けるため (帰結はどちらも fallback)、形を実物に合わせる。
        echo "${GH_COMMENT_GET_STDERR:-gh: Not Found (HTTP 404)}" >&2
        # 実 gh は HTTP エラー時に --jq を適用せずレスポンス body を stdout へ出す (rc!=0 と
        # 非空 stdout が同時に成立する)。`gh api user` stub が GH_ME_STDOUT_ON_ERROR で
        # モデル化しているのと同じ軸 — 再現しないと「rc ではなく stdout 非空を成功条件にする」
        # 実装バグ (404 が id_author_mismatch に化けて AC-4 が反転する) を検出できない。
        [ -n "${GH_COMMENT_GET_STDOUT_ON_ERROR:-}" ] && printf '%s' "$GH_COMMENT_GET_STDOUT_ON_ERROR"
        exit "${GH_COMMENT_GET_RC}"
      fi
      # helper は `gh api ... | jq --arg ...` で author / 所属 PR / 記録コメント述語の 3 つを
      # 同時に取る (`--jq` では `--arg` を渡せないため実 jq へ繋いでいる)。したがって stub は
      # **生 JSON** を返す — TSV を返すと述語の評価が stub 側に漏れ、jq filter を壊す編集を
      # テストが検出できなくなる。issue_url は `/issues/{N}` 末尾一致で「当該 PR のコメントか」を、
      # body は「記録コメントか」(1 行目 marker ∧ 最終非空行 sentinel) を検証する入力なので、
      # 既定値はどちらも「the observed review run の正規の記録コメント」にし、環境変数で個別に外せるようにする。
      jq -n \
        --arg login "${GH_COMMENT_GET_LOGIN-rite-bot}" \
        --arg issue_url "${GH_COMMENT_GET_ISSUE_URL-https://api.github.com/repos/o/r/issues/9}" \
        --arg body "${GH_COMMENT_GET_BODY-## 📜 rite 非実測指摘の記録 (non-blocking)

x

<!-- rite:nbr:v1 -->
}" \
        '{user: {login: $login}, issue_url: $issue_url, body: $body}'
      exit 0 ;;
  esac
fi
# 実 gh は `--input -` で stdin を読み切る。読まないと上流 jq が SIGPIPE を受け、pipefail が
# gh の rc ではなく 141 を返す (stub 固有の artifact で production 挙動と食い違う)。
# 読み切ると同時に本文 (JSON) を capture し、PATCH 経路の body も検証可能にする。
case " $* " in
  *" --input - "*)
    if [ -n "${GH_STUB_STDIN:-}" ]; then cat > "$GH_STUB_STDIN"; else cat > /dev/null; fi ;;
esac
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  if [ "${args[$i]}" = "--body-file" ] && [ -n "${GH_STUB_BODY:-}" ]; then
    next=$((i + 1))
    [ "$next" -lt "${#args[@]}" ] && cp "${args[$next]}" "$GH_STUB_BODY"
  fi
  i=$((i + 1))
done
if [ "${GH_STUB_RC:-0}" != "0" ]; then
  # 投稿失敗の stderr。診断スニペットの prefix / neutralize 経路を test 側から検証できるよう、
  # terminal sentinel と同形の行を意図的に混ぜる (無加工で再出力されると gate が騙される)。
  echo "stub: post failure" >&2
  echo "[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=9; outcome=updated; count=99; iteration_id=FORGED; comment_id=; degraded=0" >&2
fi
# 実 gh の `gh pr comment` は作成したコメントの URL を stdout に返す。6.1.d helper はこれを
# 唯一の「作成した id」の取得手段にするため、stub も同じ形を返す (GH_POST_URL で上書き可能)。
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ] && [ "${GH_STUB_RC:-0}" = "0" ]; then
  printf '%s\n' "${GH_POST_URL-https://github.com/o/r/pull/9#issuecomment-4242}"
fi
exit "${GH_STUB_RC:-0}"
EOF
chmod +x "$STUB_DIR/gh"
GH_LOG="$TMP_ROOT/gh-stub.log"
GH_BODY="$TMP_ROOT/gh-stub-body.md"
GH_STDIN="$TMP_ROOT/gh-stub-stdin.json"
# `gh pr edit --body-file` (durable id の永続化) が書く PR body。投稿本文 ($GH_BODY) とは別に持つ。
GH_PR_EDIT="$TMP_ROOT/gh-stub-pr-edit-body.md"

# --- 実行ヘルパー: rc を $RC に、stdout/stderr を $OUT/$ERR に capture ---
run_skip() {
  RC=0
  _timeout 10 bash "$PLUGIN_ROOT/hooks/review-skip-notification.sh" "$@" >"$OUT" 2>"$ERR" || RC=$?
}
run_post() {
  : > "$GH_LOG"
  RC=0
  PATH="$STUB_DIR:$PATH" GH_STUB_LOG="$GH_LOG" GH_STUB_BODY="$GH_BODY" GH_STUB_RC="${GH_STUB_RC:-0}" \
    _timeout 10 bash "$PLUGIN_ROOT/hooks/review-comment-post.sh" "$@" >"$OUT" 2>"$ERR" || RC=$?
}
run_save() {
  RC=0
  _timeout 10 bash "$PLUGIN_ROOT/hooks/review-result-save.sh" "$@" >"$OUT" 2>"$ERR" || RC=$?
}
run_nbr() {
  : > "$GH_LOG"
  # 前 run の残骸を検査してしまう罠を避けるため body capture も毎回初期化する
  rm -f "$GH_BODY" "$GH_STDIN" "$GH_PR_EDIT"
  RC=0
  PATH="$STUB_DIR:$PATH" GH_STUB_LOG="$GH_LOG" GH_STUB_BODY="$GH_BODY" GH_STUB_STDIN="$GH_STDIN" \
    GH_LOOKUP_JSON="${GH_LOOKUP_JSON:-}" GH_LOOKUP_RC="${GH_LOOKUP_RC:-0}" GH_STUB_RC="${GH_STUB_RC:-0}" \
    GH_LOOKUP_ZERO_PAGES="${GH_LOOKUP_ZERO_PAGES:-}" \
    GH_ME="${GH_ME:-rite-bot}" GH_ME_RC="${GH_ME_RC:-0}" GH_ME_STDOUT_ON_ERROR="${GH_ME_STDOUT_ON_ERROR:-}" \
    GH_ME_EMPTY="${GH_ME_EMPTY:-}" \
    GH_PR_BODY="${GH_PR_BODY:-}" GH_PR_VIEW_RC="${GH_PR_VIEW_RC:-0}" \
    GH_PR_EDIT_BODY="$GH_PR_EDIT" GH_PR_EDIT_RC="${GH_PR_EDIT_RC:-0}" \
    GH_COMMENT_GET_RC="${GH_COMMENT_GET_RC:-0}" GH_COMMENT_GET_LOGIN="${GH_COMMENT_GET_LOGIN-rite-bot}" \
    GH_COMMENT_GET_ISSUE_URL="${GH_COMMENT_GET_ISSUE_URL-https://api.github.com/repos/o/r/issues/9}" \
    GH_COMMENT_GET_BODY="${GH_COMMENT_GET_BODY-## 📜 rite 非実測指摘の記録 (non-blocking)

x

<!-- rite:nbr:v1 -->
}" \
    GH_COMMENT_GET_STDOUT_ON_ERROR="${GH_COMMENT_GET_STDOUT_ON_ERROR:-}" \
    GH_COMMENT_GET_STDERR="${GH_COMMENT_GET_STDERR:-}" GH_POST_URL="${GH_POST_URL-https://github.com/o/r/pull/9#issuecomment-4242}" \
    _timeout 10 bash "$PLUGIN_ROOT/hooks/review-nonblocking-record.sh" "$@" >"$OUT" 2>"$ERR" || RC=$?
}

# =====================================================================
echo "=== TC-1: review-skip-notification.sh (6.1.c) ==="
# =====================================================================

# TC-1.1 post_comment_mode=true は 6.1.b で完結すべき経路 → fail-fast
run_skip --post-comment-mode true --pr 123 --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.1 post_comment_mode=true: exit 1" "1" "$RC"
assert_grep "TC-1.1 reason=p61c_post_comment_mode_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_post_comment_mode_invalid'
assert_grep "TC-1.1 [review:error] を stdout に emit" "$OUT" '\[review:error\]'

# TC-1.2 post_comment_mode 不正値 (substitute 漏れ相当)
run_skip --post-comment-mode maybe --pr 123 --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.2 post_comment_mode 不正値: exit 1" "1" "$RC"
assert_grep "TC-1.2 reason=p61c_post_comment_mode_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_post_comment_mode_invalid'

# TC-1.3 pr_number gate: 空文字 / placeholder 残留 / 非数値
run_skip --post-comment-mode false --pr "" --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.3a pr_number 空文字: exit 1" "1" "$RC"
assert_grep "TC-1.3a reason=p61c_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_pr_number_invalid'
run_skip --post-comment-mode false --pr "{pr_number}" --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.3b pr_number placeholder 残留: exit 1" "1" "$RC"
assert_grep "TC-1.3b reason=p61c_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_pr_number_invalid'
run_skip --post-comment-mode false --pr "12a3" --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.3c pr_number 非数値: exit 1" "1" "$RC"
assert_grep "TC-1.3c reason=p61c_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_pr_number_invalid'

# TC-1.4 file_timestamp placeholder 残留
run_skip --post-comment-mode false --pr 123 --file-timestamp "{file_timestamp}" --local-save-failed ""
assert "TC-1.4 file_timestamp placeholder 残留: exit 1" "1" "$RC"
assert_grep "TC-1.4 reason=p61c_file_timestamp_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unset'

# TC-1.5 整合性違反: unknown ∧ local_save_failed≠1 (単独 emit は観測値混線の兆候)
run_skip --post-comment-mode false --pr 123 --file-timestamp unknown --local-save-failed ""
assert "TC-1.5a unknown ∧ local_save_failed='': exit 1" "1" "$RC"
assert_grep "TC-1.5a reason=p61c_file_timestamp_unknown_without_failure emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unknown_without_failure'
run_skip --post-comment-mode false --pr 123 --file-timestamp unknown --local-save-failed 0
assert "TC-1.5b unknown ∧ local_save_failed=0: exit 1" "1" "$RC"
assert_grep "TC-1.5b reason=p61c_file_timestamp_unknown_without_failure emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unknown_without_failure'

# TC-1.6 local_save_failed 値検証 (許容: 空文字 / 0 / 1)
run_skip --post-comment-mode false --pr 123 --file-timestamp 20260101120000 --local-save-failed 2
assert "TC-1.6 local_save_failed=2: exit 1" "1" "$RC"
assert_grep "TC-1.6 reason=p61c_local_save_failed_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_local_save_failed_invalid'

# TC-1.7 ケース 1 (通常経路): INFO + ローカルファイル path 表示 + exit 0
run_skip --post-comment-mode false --pr 123 --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.7a ケース 1 (local_save_failed=''): exit 0" "0" "$RC"
assert_grep "TC-1.7a INFO にローカルファイル path を表示" "$ERR" '\.rite/review-results/123-20260101120000\.json'
assert_not_grep "TC-1.7a REVIEW_OUTPUT_FAILED を emit しない" "$ERR" 'REVIEW_OUTPUT_FAILED'
assert "TC-1.7a stdout は空 ([review:error] なし)" "" "$(cat "$OUT")"
run_skip --post-comment-mode false --pr 123 --file-timestamp 20260101120000 --local-save-failed 0
assert "TC-1.7b ケース 1 (local_save_failed=0): exit 0" "0" "$RC"

# TC-1.8 ケース 2 (silent data loss 防止の hard-fail): 最重要 invariant
run_skip --post-comment-mode false --pr 123 --file-timestamp unknown --local-save-failed 1
assert "TC-1.8a ケース 2 (unknown ∧ local_save_failed=1): exit 2" "2" "$RC"
assert_grep "TC-1.8a reason=p61c_persistence_unrecoverable emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable'
assert_grep "TC-1.8a [review:error] を stdout に emit" "$OUT" '\[review:error\]'
assert_grep "TC-1.8a 復旧方法を案内 (fix 即時実行)" "$ERR" '/rite:fix'
# timestamp が正常値でも local_save_failed=1 ならケース 2 (分岐は LOCAL_SAVE_FAILED のみで決まる)
run_skip --post-comment-mode false --pr 123 --file-timestamp 20260101120000 --local-save-failed 1
assert "TC-1.8b ケース 2 (正常 timestamp ∧ local_save_failed=1): exit 2" "2" "$RC"
assert_grep "TC-1.8b reason=p61c_persistence_unrecoverable emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable'

# =====================================================================
echo "=== TC-2: review-comment-post.sh (6.1.b) ==="
# =====================================================================

# 後続 gate 用のダミー content file (gate 順序検証で再利用)
DUMMY_CONTENT="$TMP_ROOT/dummy-content.md"
echo "dummy" > "$DUMMY_CONTENT"

# TC-2.1 post_comment_mode=false → silent skip (exit 0 + 出力なし + gh 不実行)
run_post --pr 123 --post-comment-mode false --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.1 post_comment_mode=false: exit 0" "0" "$RC"
assert "TC-2.1 stdout は空 (silent skip)" "" "$(cat "$OUT")"
assert "TC-2.1 stderr は空 (silent skip)" "" "$(cat "$ERR")"
if [ -s "$GH_LOG" ]; then
  fail "TC-2.1 gh pr comment を絶対に実行しない (stub gh が呼ばれた: $(head -1 "$GH_LOG"))"
else
  pass "TC-2.1 gh pr comment を絶対に実行しない"
fi

# TC-2.2 post_comment_mode 不正値
run_post --pr 123 --post-comment-mode maybe --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.2 post_comment_mode 不正値: exit 1" "1" "$RC"
assert_grep "TC-2.2 reason=p61b_post_comment_mode_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61b_post_comment_mode_invalid'
assert_grep "TC-2.2 [review:error] を stdout に emit" "$OUT" '\[review:error\]'

# TC-2.3 pr_number gate: 空文字 / 非数値
run_post --pr "" --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.3a pr_number 空文字: exit 1" "1" "$RC"
assert_grep "TC-2.3a reason=p61b_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61b_pr_number_invalid'
run_post --pr "{pr_number}" --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.3b pr_number placeholder 残留: exit 1" "1" "$RC"
assert_grep "TC-2.3b reason=p61b_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61b_pr_number_invalid'

# TC-2.4 json_saved gate (6.1.a の JSON_SAVED emit の literal substitute 漏れ)
run_post --pr 123 --post-comment-mode true --json-saved "" --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.4 json_saved 空文字: exit 1" "1" "$RC"
assert_grep "TC-2.4 reason=json_saved_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=json_saved_from_p61a_unset'

# TC-2.5 content-file gate: 不在 path
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$TMP_ROOT/no-such-file.md"
assert "TC-2.5 content-file 不在: exit 1" "1" "$RC"
assert_grep "TC-2.5 reason=tmpfile_write_failure emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=tmpfile_write_failure'

# TC-2.6 iso_timestamp gate: placeholder 残留 / 空文字 / sentinel そのもの
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "{iso_timestamp}" --content-file "$DUMMY_CONTENT"
assert "TC-2.6a iso_timestamp placeholder 残留: exit 1" "1" "$RC"
assert_grep "TC-2.6a reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "" --content-file "$DUMMY_CONTENT"
assert "TC-2.6b iso_timestamp 空文字: exit 1" "1" "$RC"
assert_grep "TC-2.6b reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "$SENTINEL" --content-file "$DUMMY_CONTENT"
assert "TC-2.6c iso_timestamp が sentinel そのもの: exit 1" "1" "$RC"
assert_grep "TC-2.6c reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
# TC-2.6d ISO 8601 allowlist: 非 ISO 形状は旧 denylist 通過形でも reject
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "not-a-timestamp" --content-file "$DUMMY_CONTENT"
assert "TC-2.6d iso_timestamp 非 ISO 形状: exit 1" "1" "$RC"
assert_grep "TC-2.6d reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
# TC-2.6e awk replacement metachar 注入形 (`&` / `\`) も allowlist が reject (gsub metachar 防御の第一層)
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp '2026-01-02T03:04:05+09:00&\evil' --content-file "$DUMMY_CONTENT"
assert "TC-2.6e iso_timestamp metachar 注入形: exit 1" "1" "$RC"
assert_grep "TC-2.6e reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
# TC-2.6f 複数行値 bypass 防止: grep -qE は行単位マッチのため 2 行目の valid ISO で素通りする (=~ の文字列全体 anchor を検証)
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "$(printf 'garbage\n2026-01-02T03:04:05Z')" --content-file "$DUMMY_CONTENT"
assert "TC-2.6f iso_timestamp 複数行値: exit 1" "1" "$RC"
assert_grep "TC-2.6f reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
# TC-2.6g degraded 値 `unknown` (6.1.a EXIT trap の正規 emit) は専用診断で reject — 「emit 値を渡せ」の誤診断で再投入ループに誘導しない
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "unknown" --content-file "$DUMMY_CONTENT"
assert "TC-2.6g iso_timestamp=unknown: exit 1" "1" "$RC"
assert_grep "TC-2.6g reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
assert_grep "TC-2.6g 専用診断 (degraded 値) を表示" "$ERR" "degraded 値 'unknown'"
assert_grep "TC-2.6g 再投入では解決しない旨を案内" "$ERR" '再投入では解決しません'

# TC-2.7 happy path: 全 gate 通過 + Raw JSON 内 sentinel のみ scope 限定置換
POST_CONTENT="$TMP_ROOT/post-content.md"
cat > "$POST_CONTENT" <<EOF
## レビュー結果

Markdown 本文の literal sentinel は保存される: $SENTINEL

### 📄 Raw JSON

\`\`\`json
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": []
}
\`\`\`
EOF
rm -f "$GH_BODY"
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$POST_CONTENT"
assert "TC-2.7 happy path: exit 0" "0" "$RC"
if [ -s "$GH_LOG" ]; then
  pass "TC-2.7 gh pr comment が実行された"
else
  fail "TC-2.7 gh pr comment が実行された (stub gh 未呼出)"
fi
assert_grep "TC-2.7 Raw JSON 内 sentinel が iso_timestamp に置換" "$GH_BODY" '"timestamp": "2026-01-02T03:04:05\+09:00"'
assert_not_grep "TC-2.7 Raw JSON 内に quoted sentinel が残留しない" "$GH_BODY" "\"$SENTINEL\""
assert_grep "TC-2.7 Markdown 本文の literal sentinel は保存 (post-condition b)" "$GH_BODY" "literal sentinel は保存される: $SENTINEL"

# TC-2.8 gh 失敗経路: gh_comment_post_failure emit + json_saved 併記
GH_STUB_RC=1 run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$POST_CONTENT"
assert "TC-2.8 gh 失敗: exit 1" "1" "$RC"
assert_grep "TC-2.8 reason=gh_comment_post_failure emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=gh_comment_post_failure'
assert_grep "TC-2.8 json_saved を併記 (fallback 判断材料)" "$ERR" 'json_saved=true'

# =====================================================================
echo "=== TC-3: review-result-save.sh (6.1.a, D-04 非ブロッキング契約) ==="
# =====================================================================

# TC-3.1 pr_number gate: 非ブロッキング (exit 0) + EXIT trap の必須 emit
run_save --pr "{pr_number}" --content-file "$TMP_ROOT/no-such.json" --results-dir "$TMP_ROOT/results-tc31"
assert "TC-3.1 pr_number placeholder 残留: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.1 reason=pr_number_placeholder_residue emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=pr_number_placeholder_residue'
assert_grep "TC-3.1 EXIT trap が FILE_TIMESTAMP=unknown を必ず emit" "$ERR" 'FILE_TIMESTAMP=unknown'
assert_grep "TC-3.1 EXIT trap が ISO_TIMESTAMP=unknown を必ず emit" "$ERR" 'ISO_TIMESTAMP=unknown'
assert_grep "TC-3.1 EXIT trap が JSON_SAVED=false を必ず emit" "$ERR" 'JSON_SAVED=false'

# TC-3.2 --content-file 引数欠落: caller bug の fail-fast (exit 1 を維持する documented 例外)
run_save --pr 123
assert "TC-3.2 --content-file 欠落: exit 1 (caller bug fail-fast)" "1" "$RC"

# TC-3.3 --content-file 不在 path: 非ブロッキング write_failure
run_save --pr 123 --content-file "$TMP_ROOT/no-such.json" --results-dir "$TMP_ROOT/results-tc33"
assert "TC-3.3 content-file 不在: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.3 reason=write_failure emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=write_failure'
assert_grep "TC-3.3 EXIT trap が JSON_SAVED=false を必ず emit" "$ERR" 'JSON_SAVED=false'

# TC-3.4 happy path: 保存成功 + sentinel → ISO timestamp 置換
RESULTS_TC34="$TMP_ROOT/results-tc34"
JSON_OK="$TMP_ROOT/json-ok.json"
cat > "$JSON_OK" <<EOF
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": []
}
EOF
run_save --pr 123 --content-file "$JSON_OK" --results-dir "$RESULTS_TC34"
assert "TC-3.4 happy path: exit 0" "0" "$RC"
assert_grep "TC-3.4 JSON_SAVED=true emit" "$ERR" 'JSON_SAVED=true'
assert_grep "TC-3.4 FILE_TIMESTAMP は YYYYMMDDHHMMSS 形式" "$ERR" 'FILE_TIMESTAMP=[0-9]{14}'
assert_not_grep "TC-3.4 LOCAL_SAVE_FAILED を emit しない" "$ERR" 'LOCAL_SAVE_FAILED'
saved_file=$(find "$RESULTS_TC34" -name '123-*.json' 2>/dev/null | head -1)
if [ -n "$saved_file" ] && [ -f "$saved_file" ]; then
  pass "TC-3.4 結果ファイルが results-dir に保存された"
  assert_not_grep "TC-3.4 保存 JSON に sentinel が残留しない" "$saved_file" "$SENTINEL"
  assert_grep "TC-3.4 保存 JSON の timestamp は ISO 8601 (+09:00)" "$saved_file" '"timestamp": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+09:00"'
else
  fail "TC-3.4 結果ファイルが results-dir に保存された (123-*.json 不在)"
fi

# TC-3.5 必須フィールド欠落 (valid JSON だが schema_version / pr_number / findings なし)
JSON_NO_REQ="$TMP_ROOT/json-no-req.json"
printf '{"timestamp": "%s", "foo": 1}\n' "$SENTINEL" > "$JSON_NO_REQ"
run_save --pr 123 --content-file "$JSON_NO_REQ" --results-dir "$TMP_ROOT/results-tc35"
assert "TC-3.5 必須フィールド欠落: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.5 reason=schema_required_fields_missing emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=schema_required_fields_missing'

# TC-3.6 invalid JSON (jq timestamp 注入が parse 段階で fail → write_failure)
JSON_BROKEN="$TMP_ROOT/json-broken.json"
printf '{ broken json\n' > "$JSON_BROKEN"
run_save --pr 123 --content-file "$JSON_BROKEN" --results-dir "$TMP_ROOT/results-tc36"
assert "TC-3.6 invalid JSON: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.6 reason=write_failure emit (注入段階で検出)" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=write_failure'

# TC-3.7 findings[].id 書式違反 (F-1 は ^F-[0-9]{2,}$ に不一致)
JSON_BAD_ID="$TMP_ROOT/json-bad-id.json"
cat > "$JSON_BAD_ID" <<EOF
{
  "schema_version": "1.0.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": [{"id": "F-1"}]
}
EOF
run_save --pr 123 --content-file "$JSON_BAD_ID" --results-dir "$TMP_ROOT/results-tc37"
assert "TC-3.7 findings id 書式違反: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.7 reason=finding_id_format_or_uniqueness_violation emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=finding_id_format_or_uniqueness_violation'

# TC-3.8 findings[].id 重複 (書式は valid だが一意性違反)
JSON_DUP_ID="$TMP_ROOT/json-dup-id.json"
cat > "$JSON_DUP_ID" <<EOF
{
  "schema_version": "1.0.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": [{"id": "F-01"}, {"id": "F-01"}]
}
EOF
run_save --pr 123 --content-file "$JSON_DUP_ID" --results-dir "$TMP_ROOT/results-tc38"
assert "TC-3.8 findings id 重複: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.8 reason=finding_id_format_or_uniqueness_violation emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=finding_id_format_or_uniqueness_violation'

# TC-3.9 scope enum 違反 (schema 1.1.0 のみ検証される)
JSON_BAD_SCOPE="$TMP_ROOT/json-bad-scope.json"
cat > "$JSON_BAD_SCOPE" <<EOF
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": [{"id": "F-01", "scope": "bogus"}]
}
EOF
run_save --pr 123 --content-file "$JSON_BAD_SCOPE" --results-dir "$TMP_ROOT/results-tc39"
assert "TC-3.9 scope enum 違反: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.9 reason=scope_enum_violation emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=scope_enum_violation'

# TC-3.10 cross-field invariant #4: CRITICAL/HIGH × nit-noted の禁止
JSON_INV4="$TMP_ROOT/json-inv4.json"
cat > "$JSON_INV4" <<EOF
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": [{"id": "F-01", "severity": "CRITICAL", "scope": "nit-noted"}]
}
EOF
run_save --pr 123 --content-file "$JSON_INV4" --results-dir "$TMP_ROOT/results-tc310"
assert "TC-3.10 CRITICAL×nit-noted: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.10 reason=critical_high_scope_nit_noted_invariant emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=critical_high_scope_nit_noted_invariant'

# --- TC-3.11 save-pending marker のライフサイクル (ステップ 8.0.4 の機械強制の土台) ---
# marker が意味するのは「本 helper が完走した」であって「保存に成功した」ではない。
# 成功時のみ削除する実装にすると、D-04 非ブロッキング契約 (保存失敗は WARNING のみ) が
# 8.0.4 経由で blocking gate に化ける (AC-3 違反)。よって失敗経路でも削除を要求する。
# trap 設置**前**の exit 1 (caller 契約違反) だけは残す — 8.0.3 の引数 gate 群と同じ境界。

# TC-3.11a 保存成功: marker を削除し REVIEW_SAVE_DONE に saved=true を載せる
#          fixture の id は helper が内部導出する marker path (${TMPDIR}/rite-p61a-pending-<id>) と
#          対応させる — 対応しないと helper は別 path を探し、テストが「削除されない」を誤って退行として報告する。
MARKER_OK_ID="123-1700000010"
MARKER_OK="${TMPDIR:-/tmp}/rite-p61a-pending-$MARKER_OK_ID"
: > "$MARKER_OK"
run_save --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-tc311a" --pending-id "$MARKER_OK_ID"
assert "TC-3.11a 保存成功: exit 0" "0" "$RC"
# `marker=` は `.*` で受け流さない — この 1 フィールドが 8.0.4 の prose **Check**「本 cycle の
# REVIEW_SAVE_PENDING_MARKER と一致するか」が読む唯一の入力であり、`.*` は空文字にもマッチするため
# helper の emit を `marker=` 固定 (常に空) へ改変しても全 assertion が green のままになる
# (cycle N と N-1 を区別する術が検査層から消える)。実パスの等値で固定する。
assert_grep "TC-3.11a REVIEW_SAVE_DONE に saved=true と自 marker のパスを載せる" "$ERR" "REVIEW_SAVE_DONE=1; pr=123; marker=$MARKER_OK; saved=true"
if [ -e "$MARKER_OK" ]; then
  fail "TC-3.11a 保存成功時に save-pending marker が削除される (残存 = 8.0.4 が誤って差し戻す)"
else
  pass "TC-3.11a 保存成功時に save-pending marker が削除される"
fi

# TC-3.11b 非ブロッキング失敗 (content-file 不在) でも marker を削除する
#          — ここが残ると 8.0.4 が exit 1 を返し続け、保存失敗が blocking 化する (AC-3 の中核)
MARKER_FAIL_ID="123-1700000011"
MARKER_FAIL="${TMPDIR:-/tmp}/rite-p61a-pending-$MARKER_FAIL_ID"
: > "$MARKER_FAIL"
run_save --pr 123 --content-file "$TMP_ROOT/no-such.json" --results-dir "$TMP_ROOT/results-tc311b" --pending-id "$MARKER_FAIL_ID"
assert "TC-3.11b 非ブロッキング失敗: exit 0 (D-04 維持)" "0" "$RC"
assert_grep "TC-3.11b LOCAL_SAVE_FAILED は従来どおり emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=write_failure'
assert_grep "TC-3.11b REVIEW_SAVE_DONE に saved=false と自 marker のパスを載せる" "$ERR" "REVIEW_SAVE_DONE=1; pr=123; marker=$MARKER_FAIL; saved=false"
if [ -e "$MARKER_FAIL" ]; then
  fail "TC-3.11b 保存失敗でも save-pending marker が削除される (残存 = 非ブロッキング契約が blocking gate に化ける)"
else
  pass "TC-3.11b 保存失敗でも save-pending marker が削除される"
fi

# TC-3.11c trap 設置前の exit 1 (--content-file 引数欠落 = caller 契約違反) では marker を残す
MARKER_RETAIN_ID="123-1700000012"
MARKER_RETAIN="${TMPDIR:-/tmp}/rite-p61a-pending-$MARKER_RETAIN_ID"
: > "$MARKER_RETAIN"
run_save --pr 123 --pending-id "$MARKER_RETAIN_ID"
assert "TC-3.11c caller 契約違反: exit 1" "1" "$RC"
if [ -e "$MARKER_RETAIN" ]; then
  pass "TC-3.11c caller 契約違反では save-pending marker を残す (8.0.4 が差し戻す)"
else
  fail "TC-3.11c caller 契約違反では save-pending marker を残す (削除された = 未実行が silent に通る)"
fi

# TC-3.11d --pending-id 未指定でも従来どおり動作する (後方互換 / marker 機構は opt-in)
run_save --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-tc311d"
assert "TC-3.11d --pending-id 未指定: exit 0" "0" "$RC"
assert_grep "TC-3.11d marker 空でも REVIEW_SAVE_DONE を emit" "$ERR" 'REVIEW_SAVE_DONE=1; pr=123; marker=; saved=true'

# TC-3.11e 再レビューサイクル経路 (loop_count >= 1 相当) の pin: cycle ごとに別 marker を渡すと
#          cycle ごとに 1 本の JSON が永続化され、各 cycle の marker が個別に consume される。
#          ステップ 6 全体が skip された cycle では複数サイクル実行でも一部しか残らない As-Is を assertion で固定する。
RESULTS_CYCLES="$TMP_ROOT/results-tc311e"
for _cyc in 1 2 3; do
  _mid="123-170000002$_cyc"
  _m="${TMPDIR:-/tmp}/rite-p61a-pending-$_mid"
  : > "$_m"
  cat > "$TMP_ROOT/json-cycle-$_cyc.json" <<EOF
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "commit_sha": "sha-cycle-$_cyc",
  "findings": [],
  "non_blocking_findings": []
}
EOF
  run_save --pr 123 --content-file "$TMP_ROOT/json-cycle-$_cyc.json" --results-dir "$RESULTS_CYCLES" --pending-id "$_mid"
  if [ -e "$_m" ]; then
    fail "TC-3.11e cycle $_cyc の marker が consume される"
  else
    pass "TC-3.11e cycle $_cyc の marker が consume される"
  fi
  # cycle 間の staleness 判別 (AC-4) は sentinel の marker= が**自 cycle のパス**を載せて初めて
  # 成立する。TC-3.11a/b の単発 assert と違い、ここは cycle ごとに値が変わるので multi-cycle で固定する。
  assert_grep "TC-3.11e cycle $_cyc の sentinel が自 cycle の marker を載せる" "$ERR" "REVIEW_SAVE_DONE=1; pr=123; marker=$_m; saved=true"
  # cycle 間で秒境界を跨がせ、collision suffix 経路に入るか否かを実行速度に依存させない
  # (決定性の確保)。collision 経路そのものの検証は本ケースの責務ではない — リポジトリ全体で
  # LOCAL_SAVE_COLLISION / collision_resolution_exhausted を検証する assertion は現状 0 件。
  sleep 1
done
_cycle_files=$(find "$RESULTS_CYCLES" -name '123-*.json' 2>/dev/null | grep -c . || true)
assert "TC-3.11e 3 サイクル実行で 3 本の JSON が永続化される (1 cycle = 1 JSON)" "3" "$_cycle_files"
_cycle_shas=$(cat "$RESULTS_CYCLES"/123-*.json 2>/dev/null | grep -c 'sha-cycle-' || true)
assert "TC-3.11e 各 JSON が自 cycle の commit_sha を保持する (上書きされていない)" "3" "$_cycle_shas"

# TC-3.11f signal 中断 (TERM) でも LOCAL_SAVE_FAILED を emit する。
#   cleanup だけを呼ぶ実装では marker は消え saved=false も出るが reason が 1 件も出ず、
#   (a) 8.0.4 Routing の「saved=false なら reason を転記」が入力を持たず、
#   (b) 既定 post_comment:false では 6.1.c が --local-save-failed だけを見てケース 1 に落ち、
#       **存在しないパスを「保存済み」として提示する**。sibling の signal_aborted と対称。
_sig_id="123-1700000050"
_sig_marker="${TMPDIR:-/tmp}/rite-p61a-pending-$_sig_id"
: > "$_sig_marker"
_slow_dir=$(mktemp -d "$TMP_ROOT/slowjq-XXXXXX")
# kill は t=1s なので 2s の margin があれば足りる (bash は foreground の子が返るまで trap を
# 遅延させるため、shim の sleep 長がそのまま実行時間になる)。
printf '#!/bin/bash\nsleep 3\n' > "$_slow_dir/jq"
chmod +x "$_slow_dir/jq"
_sig_err="$TMP_ROOT/sig-err.txt"
PATH="$_slow_dir:$PATH" bash "$PLUGIN_ROOT/hooks/review-result-save.sh" \
  --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-tc311f" \
  --pending-id "$_sig_id" >/dev/null 2>"$_sig_err" &
_sig_pid=$!
sleep 1
kill -TERM "$_sig_pid" 2>/dev/null
_sig_rc=0
wait "$_sig_pid" 2>/dev/null || _sig_rc=$?
assert "TC-3.11f SIGTERM 中断: rc=143 (signal trap 経由)" "143" "$_sig_rc"
assert "TC-3.11f SIGTERM 中断でも LOCAL_SAVE_FAILED=1; reason=signal_aborted を emit" "1" \
  "$(grep -c 'LOCAL_SAVE_FAILED=1; reason=signal_aborted' "$_sig_err" || true)"
assert "TC-3.11f SIGTERM 中断でも terminal sentinel を自 marker + saved=false で emit" "1" \
  "$(grep -cF "REVIEW_SAVE_DONE=1; pr=123; marker=$_sig_marker; saved=false" "$_sig_err" || true)"
if [ -e "$_sig_marker" ]; then
  fail "TC-3.11f SIGTERM 中断でも marker を consume する (残存 = 非ブロッキング契約が blocking 化)"
else
  pass "TC-3.11f SIGTERM 中断でも marker を consume する"
fi

# TC-3.11g pr_number 置換漏れ (非ブロッキング失敗) でも marker を consume する。
#   marker path は --pending-id から独立に導出されるため pr gate の位置に依存しない。
#   3 箇所の文書 (helper docstring / common-error-handling.md / measured-gate-record.md) が
#   「--pr 欠落は marker を残さない」と明記する唯一の非対称ケースで、これを固定しないと
#   pr gate が trap 設置前へ移る退行が無検出で通り、非ブロッキング失敗が 8.0.4 経由で
#   収束しない blocking ループに化ける (AC-3 / T-03 の中核)。
MARKER_PR_ID="123-1700000013"
MARKER_PR="${TMPDIR:-/tmp}/rite-p61a-pending-$MARKER_PR_ID"
: > "$MARKER_PR"
run_save --pr '{pr_number}' --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-tc311g" --pending-id "$MARKER_PR_ID"
assert "TC-3.11g pr_number 置換漏れ: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.11g reason=pr_number_placeholder_residue emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=pr_number_placeholder_residue'
if [ -e "$MARKER_PR" ]; then
  fail "TC-3.11g pr_number 置換漏れでも marker を consume する (残存 = 非ブロッキング失敗が blocking 化)"
else
  pass "TC-3.11g pr_number 置換漏れでも marker を consume する"
fi

# TC-3.11h mv 成功**後**の SIGTERM では保存失敗を宣言しない。
#   json_saved を見ずに一律 signal_aborted を出すと、JSON が実在するのに 6.1.c ケース 2 が
#   exit 2 して「レビュー結果は失われた」と誤報告する (保存成功 cycle の停止 = MUST NOT より強い違反)。
_sig2_id="123-1700000051"
_sig2_marker="${TMPDIR:-/tmp}/rite-p61a-pending-$_sig2_id"
: > "$_sig2_marker"
_slow2=$(mktemp -d "$TMP_ROOT/slowrm-XXXXXX")
# 窓を固定 sleep で狙わず決定論化する。shim が mv-err の削除に入った時点で通知ファイルを作り、
# テストはその出現を待ってから TERM を送る。固定 sleep だと実行速度で窓を外し、しかも外れた run が
# 「検証済み」と同じ見え方をするため退行注入時も green のまま通る。
_sig2_ready="$TMP_ROOT/sig2-ready"
# shim の shebang は `#!/usr/bin/env bash` — macOS の `/bin/bash` は 3.2 だが rite は bash 4+ を
# 要求し、CI もそのために Homebrew bash 5 を入れている (.github/workflows/ci.yml 冒頭)。
# `#!/bin/bash` 固定だと shim だけが 3.2 に落ち、スイート本体と別の bash で動く。
printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in *rite-review-p61a-mv-err-*) : > "%s"; sleep 3 ;; esac; done\nexec /bin/rm "$@"\n' "$_sig2_ready" > "$_slow2/rm"
chmod +x "$_slow2/rm"
_sig2_err="$TMP_ROOT/sig2-err.txt"
PATH="$_slow2:$PATH" bash "$PLUGIN_ROOT/hooks/review-result-save.sh" \
  --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-tc311h" \
  --pending-id "$_sig2_id" >/dev/null 2>"$_sig2_err" &
_sig2_pid=$!
_sig2_wait=0
while [ ! -e "$_sig2_ready" ] && [ "$_sig2_wait" -lt 100 ]; do sleep 0.05; _sig2_wait=$((_sig2_wait + 1)); done
kill -TERM "$_sig2_pid" 2>/dev/null
wait "$_sig2_pid" 2>/dev/null || true
if [ -e "$_sig2_ready" ]; then
  # mv は既に完了している (shim は mv-err の削除時にしか ready を立てない)
  assert "TC-3.11h mv 成功後の TERM では LOCAL_SAVE_FAILED を emit しない" "0" \
    "$(grep -c 'LOCAL_SAVE_FAILED' "$_sig2_err" || true)"
  assert_grep "TC-3.11h 保存済みである旨を WARNING で伝える" "$_sig2_err" 'JSON は保存済みです'
else
  # 前提を満たせなかった run は pass で埋めない — 埋めると退行注入時も green で通る。
  # 併せて helper の stderr を出す: 「窓を作れなかった」だけでは原因 (shim 不発 / 別経路で
  # 早期 return / 環境差) が読めず、再現できない CI 上では診断が 1 往復ぶん遅れる。
  fail "TC-3.11h 前提未成立: shim が mv-err の削除に到達しなかった (窓を作れていない)"
  _dump_precondition_stderr "$_sig2_err"
fi

# TC-3.11j dangling symlink の marker も consume する。
#   `[ -e ]` は dangling symlink を偽と返すため単独では消し残す。8.0.4 側の同判定は (h-3) が
#   literal で pin しているが helper 側は無検査だったので、behavioral に固定する。
#   両者が食い違うと (helper は不在と読み 8.0.4 は残存と読む) 8.0.4 が全 cycle で exit 1 を返す。
_dang_id="123-1700000014"
_dang_marker="${TMPDIR:-/tmp}/rite-p61a-pending-$_dang_id"
ln -s "$TMP_ROOT/nonexistent-target" "$_dang_marker"
run_save --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-tc311j" --pending-id "$_dang_id"
assert "TC-3.11j dangling symlink marker でも exit 0" "0" "$RC"
if [ -L "$_dang_marker" ]; then
  fail "TC-3.11j dangling symlink の marker が consume されない (8.0.4 が全 cycle で exit 1 を返す)"
else
  pass "TC-3.11j dangling symlink の marker を consume する"
fi

# TC-3.11i mv 完了直後・json_saved 代入**前**の窓で TERM を受けても保存失敗を宣言しない。
#   bash は foreground コマンドの完了まで trap を遅延させるため、mv が成功して戻った直後に
#   handler が走る窓がある。json_saved だけを見ると「JSON が実在するのに失敗宣言」→
#   6.1.c ケース 2 が exit 2 で「レビュー結果は失われた」と誤報告する (保存成功 cycle の停止)。
#   TC-3.11h は mv-err の rm 窓 (= json_saved 代入の**後**) しか踏まないので本ケースが要る。
_sig3_id="123-1700000052"
_sig3_marker="${TMPDIR:-/tmp}/rite-p61a-pending-$_sig3_id"
: > "$_sig3_marker"
_sig3_res="$TMP_ROOT/results-tc311i"
_slow3=$(mktemp -d "$TMP_ROOT/slowmv-XXXXXX")
_sig3_ready="$TMP_ROOT/sig3-ready"
# 実 mv を先に済ませ、宛先が results-dir 配下のときだけ ready を立てて sleep する
# (= mv 完了後・json_saved 代入前の窓を決定論的に開く)
# shebang / 最終引数の取り方は TC-3.11h の shim と同じ理由で可搬形にする
# (`#!/usr/bin/env bash` = bash 4+ を要求する本体と同じ bash、`${!#}` を使わない)。
cat > "$_slow3/mv" <<MVEOF
#!/usr/bin/env bash
_dst=""; for _a in "\$@"; do _dst="\$_a"; done
/bin/mv "\$@"; _rc=\$?
case "\$_dst" in
  $_sig3_res/*) : > "$_sig3_ready"; sleep 3 ;;
esac
exit \$_rc
MVEOF
chmod +x "$_slow3/mv"
_sig3_err="$TMP_ROOT/sig3-err.txt"
PATH="$_slow3:$PATH" bash "$PLUGIN_ROOT/hooks/review-result-save.sh" \
  --pr 123 --content-file "$JSON_OK" --results-dir "$_sig3_res" \
  --pending-id "$_sig3_id" >/dev/null 2>"$_sig3_err" &
_sig3_pid=$!
_sig3_wait=0
while [ ! -e "$_sig3_ready" ] && [ "$_sig3_wait" -lt 100 ]; do sleep 0.05; _sig3_wait=$((_sig3_wait + 1)); done
kill -TERM "$_sig3_pid" 2>/dev/null
wait "$_sig3_pid" 2>/dev/null || true
if [ -e "$_sig3_ready" ]; then
  _sig3_json=$(find "$_sig3_res" -name '123-*.json' 2>/dev/null | grep -c . || true)
  assert "TC-3.11i 前提: mv は完了し JSON が実在する" "1" "$_sig3_json"
  assert "TC-3.11i mv 完了直後の TERM では LOCAL_SAVE_FAILED を emit しない (保存成功 cycle を停止させない)" "0" \
    "$(grep -c 'LOCAL_SAVE_FAILED' "$_sig3_err" || true)"
  # 判定 (「保存済み」) と machine-readable 側 (saved= / JSON_SAVED=) の一致を固定する。
  # 揃っていないと 8.0.4 Routing の「saved=false なら reason を転記」が転記対象を持たないまま
  # 発火し、6.1.b は実在する JSON を「保存失敗」と案内する。
  assert_grep "TC-3.11i 保存済み判定と JSON_SAVED= が一致する" "$_sig3_err" 'JSON_SAVED=true'
  assert_grep "TC-3.11i 保存済み判定と terminal sentinel の saved= が一致する" "$_sig3_err" 'REVIEW_SAVE_DONE=1;.*saved=true'
else
  fail "TC-3.11i 前提未成立: mv shim が results-dir 宛の mv に到達しなかった (窓を作れていない)"
  _dump_precondition_stderr "$_sig3_err"
fi

# TC-3.11k mv を 1 度も実行していない窓での TERM は、宛先が既に実在していても保存失敗を宣言する。
#   signal handler の「保存済み」判定は 3 条件の AND。`mv_attempted` 項を落とすと、同一秒衝突で
#   宛先が先に実在する cycle は「JSON は保存済み」と誤報告し LOCAL_SAVE_FAILED を 1 件も出さない
#   → 8.0.4 の「saved=false なら reason を転記」が入力を失い、保存されなかった cycle が silent に通る。
#   TC-3.11h/i は mv 完了**後**の窓しか踏まないので本ケースが要る。
_sig4_id="123-1700000053"
_sig4_marker="${TMPDIR:-/tmp}/rite-p61a-pending-$_sig4_id"
: > "$_sig4_marker"
_sig4_res="$TMP_ROOT/results-tc311k"
mkdir -p "$_sig4_res"
# date を固定して json_path を予測可能にし、宛先を先に実在させる (同一秒衝突と同じ状態)
: > "$_sig4_res/123-20260101000000.json"
_slow4=$(mktemp -d "$TMP_ROOT/slowmkdir-XXXXXX")
_sig4_ready="$TMP_ROOT/sig4-ready"
printf '#!/bin/bash\nprintf "%%s\\n" "2026-01-01T00:00:00+09:00|20260101000000"\n' > "$_slow4/date"
# json_path 確定**後**・json_tmp 作成**前**の窓を決定論的に開く (mv は未実行)
printf '#!/bin/bash\n/bin/mkdir "$@"; : > "%s"; sleep 3\n' "$_sig4_ready" > "$_slow4/mkdir"
chmod +x "$_slow4/date" "$_slow4/mkdir"
_sig4_err="$TMP_ROOT/sig4-err.txt"
PATH="$_slow4:$PATH" bash "$PLUGIN_ROOT/hooks/review-result-save.sh" \
  --pr 123 --content-file "$JSON_OK" --results-dir "$_sig4_res" \
  --pending-id "$_sig4_id" >/dev/null 2>"$_sig4_err" &
_sig4_pid=$!
_sig4_wait=0
while [ ! -e "$_sig4_ready" ] && [ "$_sig4_wait" -lt 100 ]; do sleep 0.05; _sig4_wait=$((_sig4_wait + 1)); done
kill -TERM "$_sig4_pid" 2>/dev/null
wait "$_sig4_pid" 2>/dev/null || true
if [ -e "$_sig4_ready" ]; then
  assert_grep "TC-3.11k mv 未実行 + 宛先実在の TERM でも signal_aborted を宣言する" "$_sig4_err" \
    'LOCAL_SAVE_FAILED=1; reason=signal_aborted'
  assert "TC-3.11k 「保存済み」の誤報告を出さない" "0" \
    "$(grep -c 'JSON は保存済みです' "$_sig4_err" || true)"
else
  fail "TC-3.11k 前提未成立: mkdir shim が json_path 確定後の窓を開けなかった"
fi

# TC-3.11l mv が**中断**された窓 (宛先に部分ファイル / source は健在) では保存失敗を宣言する。
#   cross-device mv は copy+unlink なので、殺されると宛先に壊れた断片が残る。宛先 inode の存在を
#   「保存済み」の証拠に使うと、この断片を完成品と読んで LOCAL_SAVE_FAILED を出さない
#   → 壊れた JSON が「保存済み」として 8.0.4 を通る。**完了した mv だけが source を消す**という
#   性質 (`[ ! -e "$json_tmp" ]`) が両者を分ける唯一の観測点なので behavioral に固定する。
_sig5_id="123-1700000054"
_sig5_marker="${TMPDIR:-/tmp}/rite-p61a-pending-$_sig5_id"
: > "$_sig5_marker"
_sig5_res="$TMP_ROOT/results-tc311l"
_slow5=$(mktemp -d "$TMP_ROOT/partialmv-XXXXXX")
_sig5_ready="$TMP_ROOT/sig5-ready"
# 宛先へ断片だけを書いて source を残したまま停止する (= 中断された cross-device copy の状態)
cat > "$_slow5/mv" <<MVEOF
#!/usr/bin/env bash
_dst=""; for _a in "\$@"; do _dst="\$_a"; done
case "\$_dst" in
  # 断片を書いたら実 mv は**実行しない**まま終了する (実行すると source が消え、それは
  # 「完了した mv」= TC-3.11i と同じ状態になってしまい本ケースを踏めない)
  $_sig5_res/*) head -c 10 "\$1" > "\$_dst"; : > "$_sig5_ready"; sleep 3; exit 1 ;;
esac
exec /bin/mv "\$@"
MVEOF
chmod +x "$_slow5/mv"
_sig5_err="$TMP_ROOT/sig5-err.txt"
PATH="$_slow5:$PATH" bash "$PLUGIN_ROOT/hooks/review-result-save.sh" \
  --pr 123 --content-file "$JSON_OK" --results-dir "$_sig5_res" \
  --pending-id "$_sig5_id" >/dev/null 2>"$_sig5_err" &
_sig5_pid=$!
_sig5_wait=0
while [ ! -e "$_sig5_ready" ] && [ "$_sig5_wait" -lt 100 ]; do sleep 0.05; _sig5_wait=$((_sig5_wait + 1)); done
kill -TERM "$_sig5_pid" 2>/dev/null
wait "$_sig5_pid" 2>/dev/null || true
if [ -e "$_sig5_ready" ]; then
  assert_grep "TC-3.11l mv 中断 (宛先に断片) では signal_aborted を宣言する" "$_sig5_err" \
    'LOCAL_SAVE_FAILED=1; reason=signal_aborted'
  assert "TC-3.11l 断片を完成品と読んで「保存済み」と誤報告しない" "0" \
    "$(grep -c 'JSON は保存済みです' "$_sig5_err" || true)"
else
  fail "TC-3.11l 前提未成立: mv shim が results-dir 宛の mv に到達しなかった (窓を作れていない)"
  _dump_precondition_stderr "$_sig5_err"
fi

# TC-3.11m source が消えたのに宛先が無い状態では「保存済み」と宣言しない。
#   不変条件は「宛先が存在しないなら決して保存済みと言わない」。source 消滅 (TC-3.11l が固定する
#   完了判定) だけを根拠にすると、source を先に unlink して宛先を作れなかった mv が「保存済み」に
#   化け、JSON が実在しないのに 8.0.4 が saved=true を読んで通る (silent data loss)。
_sig6_id="123-1700000055"
_sig6_marker="${TMPDIR:-/tmp}/rite-p61a-pending-$_sig6_id"
: > "$_sig6_marker"
_sig6_res="$TMP_ROOT/results-tc311m"
_slow6=$(mktemp -d "$TMP_ROOT/lostmv-XXXXXX")
_sig6_ready="$TMP_ROOT/sig6-ready"
# source だけを消して宛先を作らずに終了する (= 宛先も source も失われた状態)
cat > "$_slow6/mv" <<MVEOF
#!/usr/bin/env bash
_dst=""; for _a in "\$@"; do _dst="\$_a"; done
case "\$_dst" in
  $_sig6_res/*) /bin/rm -f "\$1"; : > "$_sig6_ready"; sleep 3; exit 1 ;;
esac
exec /bin/mv "\$@"
MVEOF
chmod +x "$_slow6/mv"
_sig6_err="$TMP_ROOT/sig6-err.txt"
PATH="$_slow6:$PATH" bash "$PLUGIN_ROOT/hooks/review-result-save.sh" \
  --pr 123 --content-file "$JSON_OK" --results-dir "$_sig6_res" \
  --pending-id "$_sig6_id" >/dev/null 2>"$_sig6_err" &
_sig6_pid=$!
_sig6_wait=0
while [ ! -e "$_sig6_ready" ] && [ "$_sig6_wait" -lt 100 ]; do sleep 0.05; _sig6_wait=$((_sig6_wait + 1)); done
kill -TERM "$_sig6_pid" 2>/dev/null
wait "$_sig6_pid" 2>/dev/null || true
if [ -e "$_sig6_ready" ]; then
  _sig6_json=$(find "$_sig6_res" -name '123-*.json' 2>/dev/null | grep -c . || true)
  assert "TC-3.11m 前提: 宛先 JSON は実在しない" "0" "$_sig6_json"
  assert_grep "TC-3.11m 宛先不在なら source が消えていても signal_aborted を宣言する" "$_sig6_err" \
    'LOCAL_SAVE_FAILED=1; reason=signal_aborted'
  assert "TC-3.11m 実在しない JSON を「保存済み」と誤報告しない" "0" \
    "$(grep -c 'JSON は保存済みです' "$_sig6_err" || true)"
else
  fail "TC-3.11m 前提未成立: mv shim が results-dir 宛の mv に到達しなかった (窓を作れていない)"
  _dump_precondition_stderr "$_sig6_err"
fi

# =====================================================================
echo "=== TC-4: review-nonblocking-record.sh (6.1.d) ==="
# =====================================================================

NBR_BODY="$TMP_ROOT/nbr-body.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count: 1\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY"
# count/body variant 整合検査 (F-01, cycle 2 review) の対象となるテストは、それぞれの --count と
# 一致する `📎 non_blocking_count:` 行を持つ専用 body fixture を使う (NBR_BODY は count=1 用)。
NBR_BODY_C0="$TMP_ROOT/nbr-body-c0.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n本 cycle の非実測指摘: 0 件\n\n📎 non_blocking_count: 0\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_C0"
NBR_BODY_C2="$TMP_ROOT/nbr-body-c2.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count: 2\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_C2"
NBR_BODY_C3="$TMP_ROOT/nbr-body-c3.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count: 3\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_C3"
# [test-reviewer F-03 指摘, cycle 3]: count fixture が 0/1/2/3 の 1 桁のみだと、helper の
# `grep -oE '[0-9]+'` を `[0-9]` へ退行させても全 assertion が緑のままになる (先頭 1 桁しか
# 拾わなくても 1 桁値なら一致するため)。production では非実測指摘が 10 件以上出た cycle に
# 限って毎回 count_body_mismatch → outcome=failed となり、最も記録が必要な局面で D-01 の
# 永続チャネルが落ちる。2 桁 fixture で桁境界を固定する。
NBR_BODY_C12="$TMP_ROOT/nbr-body-c12.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count: 12\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_C12"
NBR_EMPTY_BODY="$TMP_ROOT/nbr-empty.md"
: > "$NBR_EMPTY_BODY"

# lookup fixture: id=11 と id=13 が 1 行目 marker **かつ機械専用 sentinel** を持つ本物の記録
# コメント (id=13 が自 login の最新)。デコイは 3 種で、いずれも対象コメント id=13 より **後ろ**に
# 置く (前に置くと述語が壊れても位置的に id=13 が最後のままになり検出が vacuous になる):
#   - id=12: marker 文字列を **本文中に引用しただけ** (人間の Quote reply 相当)。`contains($MARKER)`
#            述語ならマッチしうる (startswith では拾えない)。
#   - id=99: **第三者 author** による marker 投稿。author 条件が無ければ PATCH 先を奪える。
#   - id=98: **同一 author が書いた、引用接頭辞を持たない、marker 前方一致の人間コメント**
#            (記録の対応状況メモ相当)。author + startswith の 2 条件では除外できず、機械専用
#            sentinel を持たないことだけが本物との違い。sentinel 条件を落とすと `last` がこれを
#            掴み、PATCH が人間の本文を丸ごと上書き破壊する (F-09, cycle 6)。
#   - id=97: 同上だが、人間が**記録コメントの raw markdown を一部貼り込んだ**ため sentinel を
#            本文**途中**に持つ。sentinel を位置非依存の `contains` で見ると `last` がこれを掴み、
#            id=98 と同じ破壊が起きる。
#   なお id=11 は **CRLF 改行**にしてある — GitHub は本文を CRLF で返すことがあり、read 側の
#   CR 除去 (map(sub("\r$"; ""))) を落とすと最終非空行が sentinel と一致せず自分の投稿を miss して
#   記録コメントが増殖する。この 1 行を pin するための形状。
#   - id=96: 同上だが、**最終行が `> <!-- rite:nbr:v1 -->`**(Quote reply / raw 引用)。本文全体への
#            `endswith` は行頭 `> ` を吸収するため素通りする。**最終非空行の等値**でのみ除外できる。
# なお id=11/13/99 の body は実 write 経路 (jq --rawfile) と同じく **末尾改行を持つ**形にしてある
# (id=13 は空行 2 連)。末尾改行の無い非実在形状だと、read 側の「空白のみの行を除く」処理が
# どの assertion にも pin されない。
# 3 条件 (startswith ∧ 最終非空行 == sentinel ∧ author 一致) が id=13 を選ぶことを固定する。
NBR_COMMENTS="$TMP_ROOT/nbr-comments.json"
cat > "$NBR_COMMENTS" <<'EOF'
[[{"id":11,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 (non-blocking)\r\n\r\nold\r\n\r\n<!-- rite:nbr:v1 -->\r\n"},{"id":13,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 (non-blocking)\n\nnewer (degraded 縮退で生まれた 2 件目)\n\n<!-- rite:nbr:v1 -->\n\n"},{"id":12,"user":{"login":"rite-bot"},"body":"> ## 📜 rite 非実測指摘の記録 への返信"},{"id":99,"user":{"login":"other-user"},"body":"## 📜 rite 非実測指摘の記録 (non-blocking)\n\nhijack attempt\n\n<!-- rite:nbr:v1 -->\n"},{"id":98,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 の対応状況\n\nF-03 は次 PR で対応予定。F-05 は仕様どおりのため対応しない。"},{"id":97,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 の対応方針メモ\n\n元記録から引用:\n\n<!-- rite:nbr:v1 -->\n\n上記のうち F-02 だけ対応する。"},{"id":96,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 の対応方針 (引用付き)\n\n以下は元記録の引用です:\n\n> <!-- rite:nbr:v1 -->\n"}]]
EOF
# 孤児ちょうど **1 件** の fixture。sentinel 導入前の記録コメントが 1 本残っている migration の
# 支配的ケースで、`legacy_orphan_count -gt 0` の**境界値**を押さえる (3 件 fixture だけでは
# 閾値を -gt 1 に退行させても検出できない)。
NBR_ONE_ORPHAN="$TMP_ROOT/nbr-one-orphan.json"
cat > "$NBR_ONE_ORPHAN" <<'EOF'
[[{"id":41,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 (non-blocking)\n\nsentinel 導入前の記録\n"}]]
EOF
NBR_EMPTY_COMMENTS="$TMP_ROOT/nbr-empty-comments.json"
echo '[[]]' > "$NBR_EMPTY_COMMENTS"
# 2 ページ fixture: 対象コメントを **2 ページ目** に置く。単一ページ fixture では jq の `add`
# (全ページ平坦化) と `.[0]` (1 ページ目のみ) が観測上同一で、--paginate --slurp の集約契約
# (コメント 30 件超の PR で marker を miss しない) が pin されない。
NBR_PAGED_COMMENTS="$TMP_ROOT/nbr-paged-comments.json"
cat > "$NBR_PAGED_COMMENTS" <<'EOF'
[[{"id":21,"user":{"login":"rite-bot"},"body":"page1 noise"}],[{"id":11,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 (non-blocking)\n\nold\n\n<!-- rite:nbr:v1 -->\n"}]]
EOF
# durable comment id 経路 (TC-4.16) の fixture。id は **PR body 側**に置くのが本経路の要点で、
# 記録コメント本文には一切現れない — 本文に置くと raw markdown の copy-paste で複製され、本文照合と
# 同じ誤認経路が再生する。$NBR_COMMENTS は id=11 と id=13 の**両方**が 3 条件を満たすため、
# 本文照合なら last=13 を掴む。PR body に id=11 を置いた状態で PATCH 先が 11 になることが、
# 「verbatim に近い複製があっても id で canonical を特定できる」ことの弁別になる (AC-1)。
NBR_PRBODY_ID11="$TMP_ROOT/nbr-prbody-id11.md"
printf '## 概要\n\nPR の説明本文\n\n<!-- rite:nbr:comment-id:11 -->\n' > "$NBR_PRBODY_ID11"
# 手動編集で値が壊れた PR body。numeric guard が弾いて fallback へ倒れることを固定する。
NBR_PRBODY_MALFORMED="$TMP_ROOT/nbr-prbody-malformed.md"
printf '## 概要\n\nPR の説明本文\n\n<!-- rite:nbr:comment-id:abc -->\n' > "$NBR_PRBODY_MALFORMED"
# marker を持たない PR body (初回 cycle / 永続化前)。fallback の結果が現行 3 条件と一致し、
# かつ投稿後に id が書き足されること (migration) を固定する。
NBR_PRBODY_PLAIN="$TMP_ROOT/nbr-prbody-plain.md"
printf '## 概要\n\nPR の説明本文\n' > "$NBR_PRBODY_PLAIN"
# **散文中に marker と同形の文字列を持つ** PR body。read/write の両式が行アンカー (`^`/`$`) を
# 要求しないと、(a) 抽出が散文行から偽の id を拾い、(b) 除去がその一節を PR 説明から無音で消す。
# 本 PR (#2112) の説明文自身がこの形をしているため、helper を自分自身に対して走らせると発火する。
# 2 つの fixture で marker 行と散文行の**順序を入れ替える** — 抽出は `tail -1` で最後のマッチを採る
# ため、散文が後ろにある方 (INLINE_LAST) でしか抽出側の欠陥は観測できない。
NBR_PRBODY_INLINE_FIRST="$TMP_ROOT/nbr-prbody-inline-first.md"
printf '## 概要\n\nid は `<!-- rite:nbr:comment-id:11 -->` のような行で PR body に置く\n\n<!-- rite:nbr:comment-id:11 -->\n' > "$NBR_PRBODY_INLINE_FIRST"
NBR_PRBODY_INLINE_LAST="$TMP_ROOT/nbr-prbody-inline-last.md"
printf '## 概要\n\n<!-- rite:nbr:comment-id:11 -->\n\nid は `<!-- rite:nbr:comment-id:BROKEN -->` のような行で PR body に置く\n' > "$NBR_PRBODY_INLINE_LAST"
# 上の 2 fixture は decoy の**両側**に非空白を置くため、`^` と `$` の**論理積**しか固定できない
# (片方だけを外した mutant は残る方のアンカーに阻まれて生存する)。各アンカーを独立に殺すには
# decoy の片側だけを非空白にする必要がある。どちらも正規の marker 行を**先**に置き、decoy を
# 後ろに置く (抽出は `tail -1` を採るため、decoy が後ろでないと抽出側の欠陥が観測できない)。
# DECOY_TAIL: 行頭は marker、後ろに散文 → `$` を外すと抽出が偽 id を拾い、除去がこの行を消す。
NBR_PRBODY_DECOY_TAIL="$TMP_ROOT/nbr-prbody-decoy-tail.md"
printf '## 概要\n\n<!-- rite:nbr:comment-id:11 -->\n\n<!-- rite:nbr:comment-id:BROKEN --> (注記: この行は marker ではない)\n' > "$NBR_PRBODY_DECOY_TAIL"
# DECOY_HEAD: 前に散文、行末が marker → `^` を外すと同じ 2 つが起きる。
NBR_PRBODY_DECOY_HEAD="$TMP_ROOT/nbr-prbody-decoy-head.md"
printf '## 概要\n\n<!-- rite:nbr:comment-id:11 -->\n\n例: <!-- rite:nbr:comment-id:BROKEN -->\n' > "$NBR_PRBODY_DECOY_HEAD"
# marker 行が完全一致から外れる 3 形。GitHub の web UI で PR 説明を編集すると本文は CRLF で返り、
# 人間が字下げや末尾空白を混ぜることもある。両式が行頭・行末の空白を許容しないと、これらは
# 「抽出も除去も外れる」= marker 不在と区別できない無音の破損になる (helper の形状定義コメントが
# 自ら避けると宣言している状態)。3 形とも durable id 経路が成立することを固定する。
NBR_PRBODY_CRLF_ID11="$TMP_ROOT/nbr-prbody-crlf-id11.md"
printf '## 概要\r\n\r\nPR の説明本文\r\n\r\n<!-- rite:nbr:comment-id:11 -->\r\n' > "$NBR_PRBODY_CRLF_ID11"
NBR_PRBODY_INDENT_ID11="$TMP_ROOT/nbr-prbody-indent-id11.md"
printf '## 概要\n\nPR の説明本文\n\n  <!-- rite:nbr:comment-id:11 -->\n' > "$NBR_PRBODY_INDENT_ID11"
NBR_PRBODY_TRAILING_ID11="$TMP_ROOT/nbr-prbody-trailing-id11.md"
printf '## 概要\n\nPR の説明本文\n\n<!-- rite:nbr:comment-id:11 --> \n' > "$NBR_PRBODY_TRAILING_ID11"
# marker 行は実在するが値を取り出せない PR body (手動編集で値だけ消えた形)。「marker 不在」に
# 畳むと PR body 側の破損が無音になるため、probe で切り分けて id_malformed へ倒すことを固定する。
NBR_PRBODY_BROKEN_SHAPE="$TMP_ROOT/nbr-prbody-broken-shape.md"
printf '## 概要\n\nPR の説明本文\n\n<!-- rite:nbr:comment-id: -->\n' > "$NBR_PRBODY_BROKEN_SHAPE"
# 同じ破損を**字下げ付き**で持つ形。probe の行頭 `[[:space:]]*` を外す mutation は、字下げなしの
# 上の fixture では落ちない (素通りして無音の破損が復活する)。字下げ marker が実在形であることは
# $NBR_PRBODY_INDENT_ID11 が示している。
NBR_PRBODY_BROKEN_INDENT="$TMP_ROOT/nbr-prbody-broken-indent.md"
printf '## 概要\n\nPR の説明本文\n\n  <!-- rite:nbr:comment-id: -->\n' > "$NBR_PRBODY_BROKEN_INDENT"
# **抽出可能な marker を持たず**、行末が marker 形の散文行だけを持つ PR body (この機構を説明する
# PR 説明が取りうる形)。probe の `^` を外す mutation はここでしか落ちない — 正規の marker を
# 併記した fixture では抽出が成功して probe 分岐に到達せず、assert が空振りする。
NBR_PRBODY_PROSE_TAIL="$TMP_ROOT/nbr-prbody-prose-tail.md"
printf '## 概要\n\n形式は 例: <!-- rite:nbr:comment-id:11 -->\n' > "$NBR_PRBODY_PROSE_TAIL"
# **行頭が marker 接頭辞で、後ろに散文が続く**行だけを持つ PR body。probe と除去式は同一の正規表現
# から導出され「行全体が marker 形」を要求するので、この行は破損でも marker でもない散文として
# 扱われる (除去もされない — TC-4.16n' が同じ形で非削除を pin している)。probe だけを接頭辞一致へ
# 戻す mutation は、正規 marker を併記しないこの fixture でしか落ちない (cycle 3 F-34)。
NBR_PRBODY_PROSE_HEAD="$TMP_ROOT/nbr-prbody-prose-head.md"
printf '## 概要\n\n<!-- rite:nbr:comment-id:BROKEN --> (注記: この行は marker ではない)\n' > "$NBR_PRBODY_PROSE_HEAD"
# create 経路が永続化する id (stub の GH_POST_URL 既定値) を canonical に持つコメント一覧。
NBR_COMMENTS_4242="$TMP_ROOT/nbr-comments-4242.json"
cat > "$NBR_COMMENTS_4242" <<'EOF'
[[{"id":4242,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 (non-blocking)\n\nrecorded\n\n<!-- rite:nbr:v1 -->\n"}]]
EOF

# TC-4.1 placeholder residue gate 5 種はすべて exit 1 (skill 定義のバグ = loud fail)
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr "{pr_number}" --owner-repo o/r --count 1 --iteration-id 9-1 --content-file "$NBR_BODY"
assert "TC-4.1a pr_number placeholder: exit 1" "1" "$RC"
assert_grep "TC-4.1a reason=pr_number_placeholder_residue emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; reason=pr_number_placeholder_residue'
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo "{owner_repo}" --count 1 --iteration-id 9-1 --content-file "$NBR_BODY"
assert "TC-4.1b owner_repo placeholder: exit 1" "1" "$RC"
assert_grep "TC-4.1b reason=owner_repo_placeholder_residue emit" "$ERR" 'reason=owner_repo_placeholder_residue'
# owner_repo の allowlist: gh は `[HOST/]OWNER/REPO` を受けるため 3 セグメント値は別ホストへの送出になる。
# パストラバーサル・許可外文字も同じ gate で拒否する (producer 側 git-remote.sh の allowlist を継承)。
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo "ghe.example.com/o/r" --count 1 --iteration-id 9-1 --content-file "$NBR_BODY"
assert "TC-4.1b2 HOST/OWNER/REPO 形式: exit 1" "1" "$RC"
assert_grep "TC-4.1b2 reason=owner_repo_placeholder_residue" "$ERR" 'reason=owner_repo_placeholder_residue'
assert_not_grep "TC-4.1b2 terminal sentinel を emit しない" "$ERR" 'NONBLOCKING_RECORD_DONE=1'
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo "o/../r" --count 1 --iteration-id 9-1 --content-file "$NBR_BODY"
assert "TC-4.1b3 パストラバーサル: exit 1" "1" "$RC"
assert_grep "TC-4.1b3 reason=owner_repo_placeholder_residue" "$ERR" 'reason=owner_repo_placeholder_residue'
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo 'o/r;id' --count 1 --iteration-id 9-1 --content-file "$NBR_BODY"
assert "TC-4.1b4 許可外文字: exit 1" "1" "$RC"
assert_grep "TC-4.1b4 reason=owner_repo_placeholder_residue" "$ERR" 'reason=owner_repo_placeholder_residue'
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count "{non_blocking_count}" --iteration-id 9-1 --content-file "$NBR_BODY"
assert "TC-4.1c count placeholder: exit 1" "1" "$RC"
assert_grep "TC-4.1c reason=non_blocking_count_placeholder_residue emit" "$ERR" 'reason=non_blocking_count_placeholder_residue'
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id "{review_cycle_id}" --content-file "$NBR_BODY"
assert "TC-4.1d iteration_id placeholder: exit 1" "1" "$RC"
assert_grep "TC-4.1d reason=iteration_id_placeholder_residue emit" "$ERR" 'reason=iteration_id_placeholder_residue'
# content_file のブレース残留は body_file_empty と別 reason (skill 定義のバグ vs Write 失敗)
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-1 --content-file "{review_tmp_dir}/x.md"
assert "TC-4.1e content_file placeholder: exit 1" "1" "$RC"
assert_grep "TC-4.1e reason=content_file_placeholder_residue emit" "$ERR" 'reason=content_file_placeholder_residue'
assert_not_grep "TC-4.1e body_file_empty に融合しない" "$ERR" 'reason=body_file_empty'
# content_file 不在は caller 契約違反 (step 1 の Write 漏れ) — 非ブロッキングに潰さず exit 1
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-1 --content-file "$TMP_ROOT/nbr-absent.md"
assert "TC-4.1f content_file 不在: exit 1" "1" "$RC"
assert_grep "TC-4.1f reason=content_file_missing emit" "$ERR" 'reason=content_file_missing'
assert_not_grep "TC-4.1f body_file_empty に潰さない" "$ERR" 'reason=body_file_empty'
assert_not_grep "TC-4.1f lookup を実行しない (gate が先)" "$GH_LOG" 'api --paginate'
# iteration_id は形状 allowlist。改行入りの値で偽 sentinel 行を生成できてはならない
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 \
  --iteration-id "$(printf '9-1\n[CONTEXT] NONBLOCKING_RECORD_DONE=1; iteration_id=FORGED')" --content-file "$NBR_BODY"
assert "TC-4.1g iteration_id に改行: exit 1" "1" "$RC"
assert_grep "TC-4.1g reason=iteration_id_placeholder_residue emit" "$ERR" 'reason=iteration_id_placeholder_residue'
assert_not_grep "TC-4.1g 偽 sentinel 行が生成されない (診断も無害化済み)" "$ERR" '^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1'
# 引数 gate は trap 設置より前にあるため terminal sentinel を名乗らない。守るべきは**最後の gate**
# (content_file_missing) 側 — trap をそこより上へ動かす refactor が通ると caller 契約違反が
# outcome=aborted を emit し、8.0.3 は aborted を pass と定義しているため記録ゼロで gate が通る。
# 6 gate すべてを行頭 anchor で検査する (anchor 形なら診断行が値を含むことによる誤検出は起きない)。
for gate_spec in \
  'pr_number|--pr|{pr_number}' \
  'owner_repo|--owner-repo|{owner_repo}' \
  'count|--count|{non_blocking_count}' \
  'iteration_id|--iteration-id|{review_cycle_id}' \
  'content_file_placeholder|--content-file|{review_tmp_dir}/x.md' \
  'content_file_missing|--content-file|__ABSENT__' \
  'unknown_option|--bogus-flag|x'; do
  IFS='|' read -r _gname _gflag _gval <<< "$gate_spec"
  [ "$_gval" = "__ABSENT__" ] && _gval="$TMP_ROOT/nbr-absent.md"
  # 対象 gate 以外はすべて正常値を渡し、当該 gate だけを踏ませる
  case "$_gflag" in
    --pr)           set -- --pr "$_gval" --owner-repo o/r --count 1 --iteration-id 9-1 --content-file "$NBR_BODY" ;;
    --owner-repo)   set -- --pr 9 --owner-repo "$_gval" --count 1 --iteration-id 9-1 --content-file "$NBR_BODY" ;;
    --count)        set -- --pr 9 --owner-repo o/r --count "$_gval" --iteration-id 9-1 --content-file "$NBR_BODY" ;;
    --iteration-id) set -- --pr 9 --owner-repo o/r --count 1 --iteration-id "$_gval" --content-file "$NBR_BODY" ;;
    --content-file) set -- --pr 9 --owner-repo o/r --count 1 --iteration-id 9-1 --content-file "$_gval" ;;
    # 未知フラグは引数解析ループ内 (placeholder gate より前、trap 設置より前) で落ちる経路。
    # 他 6 gate と同じく terminal sentinel を名乗ってはならない。
    *)              set -- --pr 9 --owner-repo o/r --count 1 --iteration-id 9-1 --content-file "$NBR_BODY" "$_gflag" "$_gval" ;;
  esac
  GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr "$@"
  assert "TC-4.1h-$_gname: exit 1" "1" "$RC"
  assert_grep "TC-4.1h-$_gname reason=$_gname 系の診断を emit" "$ERR" "NONBLOCKING_RECORD_FAILED=1"
  assert_not_grep "TC-4.1h-$_gname terminal sentinel を emit しない" "$ERR" '^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1'
done
# 上記ループの reason 名は gate ごとに異なるため、unknown_option だけ個別に固定する
# (helper の reason 語彙のうち、これが唯一 test 参照ゼロだった)。
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-1 --content-file "$NBR_BODY" --bogus-flag x
assert "TC-4.1i unknown option: exit 1" "1" "$RC"
assert_grep "TC-4.1i reason=unknown_option emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; reason=unknown_option'
assert_not_grep "TC-4.1i 投稿呼び出しが無い" "$GH_LOG" '^pr comment'

# TC-4.2 既存コメントあり → update-in-place (AC-2)。前方一致で id=11 を選ぶ (引用返信 id=12 ではない)
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-200 --content-file "$NBR_BODY_C2"
assert "TC-4.2a 既存あり: exit 0" "0" "$RC"
# 自 login の marker コメントが 2 件あるときは **最新 (last)** を掴む。degraded 縮退で 2 件目が
# 生まれた次 cycle に古い方を更新し続けると、最新の記録が孤児化する。
assert_grep "TC-4.2a outcome=updated + comment_id=13 (自 login の最新を掴む)" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=updated; count=2; iteration_id=9-200; comment_id=13;'
assert_grep "TC-4.2b PATCH が実行された (SoT 正規形 -X PATCH --input -)" "$GH_LOG" '^api repos/o/r/issues/comments/13 -X PATCH --input -'
# positive control: 以降の TC-4.2f / 4.4c / 4.8b / 4.8d が使う **negative control の pattern そのもの** を、
# PATCH が確かに存在するログに対して assert_grep で当てる。pattern が grep のオプションとして食われる
# (先頭 `-X` が option 解釈され rc=2 → assert_not_grep が「不在」と読む) 種類の vacuous pass を、
# pattern を変更した瞬間にこの assertion が落ちる形で構造的に排除する。
assert_grep "TC-4.2b' [positive control] negative control の pattern は PATCH を検出できる" "$GH_LOG" '^api repos/.* -X PATCH'
assert_not_grep "TC-4.2c 引用返信 (id=12) を PATCH しない" "$GH_LOG" 'issues/comments/12'
# author 条件: 第三者 (other-user) が 1 行目 marker で投稿しても PATCH 先を奪われない
assert_not_grep "TC-4.2d 第三者 author (id=99) を PATCH しない" "$GH_LOG" 'issues/comments/99'
# 投稿本文の 1 行目 marker が保持されている (lookup needle と write 側契約の一致)
# PATCH は SoT 正規形 (jq --rawfile | gh api --input -) のため本文は stdin の JSON で届く。
# jq で body を取り出し「1 行目が marker」という write 側契約が保たれていることを確認する。
if [ -s "$GH_STDIN" ]; then
  _patch_first_line=$(jq -r '.body' "$GH_STDIN" 2>/dev/null | head -n 1)
  case "$_patch_first_line" in
    "## 📜 rite 非実測指摘の記録"*) pass "TC-4.2e PATCH 本文の 1 行目が marker 見出し" ;;
    *) fail "TC-4.2e PATCH 本文の 1 行目が marker 見出しでない: [$_patch_first_line]" ;;
  esac
else
  fail "TC-4.2e PATCH の stdin JSON が capture されていない ($GH_STDIN)"
fi
# --paginate --slurp の全ページ走査: 対象コメントが 2 ページ目にあっても掴む
# (jq の `add` を `.[0]` に退行させるとここで comment_id 不一致になる)
GH_LOOKUP_JSON="$NBR_PAGED_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-220 --content-file "$NBR_BODY_C2"
assert "TC-4.2g 2 ページ目の既存コメント: exit 0" "0" "$RC"
assert_grep "TC-4.2g 2 ページ目の id=11 を掴む" "$ERR" 'outcome=updated; count=2; iteration_id=9-220; comment_id=11;'
assert_grep "TC-4.2g PATCH 先が id=11" "$GH_LOG" 'issues/comments/11'
# gh api user が失敗したら既存コメントを特定できない → degraded に倒す (誤 PATCH しない)
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_ME_RC=1 run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-210 --content-file "$NBR_BODY_C2"
assert "TC-4.2f 自 login 取得失敗: exit 0" "0" "$RC"
assert_grep "TC-4.2f degraded=1 かつ created に縮退" "$ERR" 'outcome=created; count=2; iteration_id=9-210; comment_id=; degraded=1'
assert_not_grep "TC-4.2f 誤って PATCH しない" "$GH_LOG" '^api repos/.* -X PATCH'
assert_grep "TC-4.2f 投稿は実行される (create)" "$GH_LOG" '^pr comment'
# degraded は update-in-place を諦めるだけで **記録自体は投稿される**。ここで記録失敗用の案内
# (「レビューをやり直してください」) を出すと、成功経路で operator を不要な再レビューへ誘導する。
assert_grep "TC-4.2f degraded 用の案内を出す (update-in-place を諦める)" "$ERR" 'update-in-place を諦めます'
assert_not_grep "TC-4.2f 記録失敗用の案内は出さない" "$ERR" 'レビューをやり直してください'
# degraded の案内は結末 (投稿されるか否か) を断定しない。断定すると 0 件 skip 経路で
# 「投稿されました」と誤報する (結末は terminal sentinel の outcome= が担う)。
# [test-reviewer F-02, cycle 4]: 元の pattern はテストファイル自身にしか存在しないリテラル
# 一語一句の guard に退化していた (helper にも SKILL.md にも同一文字列が無い)。防ぎたい欠陥は
# 「degraded 案内が結末を断定する」という性質であり特定の言い回しではないため、言い換えられた
# 瞬間に guard が外れる。ERE を広げ、意味的に同種の断定文 (「記録され(る/ます)」「投稿され(る/ます)」)
# を捕捉する。
assert_not_grep "TC-4.2f degraded 案内が結末を断定しない (広域 ERE)" "$ERR" '(記録|投稿)[^。]*(されます|される)'

# TC-4.2h [error-handling-reviewer 指摘, cycle 4]: 実 gh は `gh api user` の HTTP エラー時に
# --jq フィルタを適用せずレスポンス body をそのまま stdout へ出す (rc!=0 と非空 stdout が同時に
# 成立する)。rc を見ず空文字判定だけに依存すると、この非空な JSON エラー body が `gh_login` として
# 通過してしまい degraded 検出が素通りする (existing_id="" のまま degraded=0 で新規作成に縮退し、
# WARNING も一切出ない — 「silent 縮退しない」契約への正面からの違反)。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_ME_RC=1 GH_ME_STDOUT_ON_ERROR='{"message":"Bad credentials"}' \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-215 --content-file "$NBR_BODY_C2"
assert "TC-4.2h gh api user が rc!=0 かつ body を stdout に出す: exit 0" "0" "$RC"
assert_grep "TC-4.2h rc チェックにより degraded=1 に倒れる (body を成功と誤判定しない)" "$ERR" 'outcome=created; count=2; iteration_id=9-215; comment_id=; degraded=1'
assert_grep "TC-4.2h WARNING を出す (silent 縮退しない)" "$ERR" 'gh api user による自 login の取得に失敗しました'
assert_not_grep "TC-4.2h 誤って PATCH しない (body を login と誤認しない)" "$GH_LOG" '^api repos/.* -X PATCH'

# TC-4.2h' [test-reviewer F-01, cycle 5]: TC-4.2h は選言 `rc!=0 || -z "$gh_login"` の rc 側だけを
# 検証しており、`-z` 側 (rc=0 だが `.login` が空 — endpoint 変更や scope 不足で `--jq` が空文字を
# 返す場合) を再現するテストが無かった。実測: この分岐 (`|| [ -z "$gh_login" ]`) を削除しても
# 旧 suite は 280/280 green のままだった (回帰を止められない構造的な穴)。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_ME_EMPTY=1 \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-219 --content-file "$NBR_BODY_C2"
assert "TC-4.2h' gh api user が rc=0 かつ空 stdout: exit 0" "0" "$RC"
assert_grep "TC-4.2h' -z 側の rc=0+空文字 も degraded=1 に倒れる" "$ERR" 'outcome=created; count=2; iteration_id=9-219; comment_id=; degraded=1'
assert_grep "TC-4.2h' WARNING を出す (silent 縮退しない)" "$ERR" 'gh api user による自 login の取得に失敗しました'
assert_not_grep "TC-4.2h' 誤って PATCH しない" "$GH_LOG" '^api repos/.* -X PATCH'

# TC-4.2i [application-reviewer F-9, cycle 4]: `gh api --paginate --slurp` が 0 ページ
# (真の空配列 `[]` を返す稀な経路) だと、jq の `add` は `null` を返し、後続の `.[]` が
# jq エラー (rc=5) で落ちる。修正前はこの jq エラーが degraded フォールバック
# (WARNING + degraded=1) に潰れ、「本当は既存コメントが 0 件」なだけの正常系を誤って
# degraded 扱いしていた。`(add // [])` により、空配列は素直に「既存コメントなし」
# (degraded=0) として扱われる。
GH_LOOKUP_ZERO_PAGES=1 run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-218 --content-file "$NBR_BODY_C2"
assert "TC-4.2i lookup が 0 ページ (リテラル []) を返す: exit 0" "0" "$RC"
assert_not_grep "TC-4.2i jq クラッシュを degraded と誤判定しない" "$ERR" '既存の非実測記録コメントの検索に失敗しました'
assert_grep "TC-4.2i degraded=0 のまま created (正常系として扱う)" "$ERR" 'outcome=created; count=2; iteration_id=9-218; comment_id=; degraded=0'

# TC-4.3 既存なし ∧ count>0 → 新規作成 (AC-1)
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 3 --iteration-id 9-201 --content-file "$NBR_BODY_C3"
assert "TC-4.3a 既存なし count>0: exit 0" "0" "$RC"
assert_grep "TC-4.3a outcome=created" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=created; count=3; iteration_id=9-201;'
assert_grep "TC-4.3b gh pr comment が実行された" "$GH_LOG" '^pr comment 9 -R o/r --body-file'

# TC-4.3c/d 多桁 count。(c) と (d) は**別軸**を固定する (cycle 4 で実測し直した — 旧コメントは
# 両者を同軸の一致/不一致方向と書いていたが誤り):
#   (c) 抽出の桁境界: body_count 抽出を先頭 1 桁に退行させる (`grep -oE '[0-9]+'` → `'[0-9]'`) と
#       (c) の 2 assertion が落ちる。この軸は (c) 単独で捕捉できる ((d) は緑のまま)。
#   (d)(d') 比較の等値性: `[ "$body_count" != "$NB_COUNT" ]` を先頭一致へ退行させたときに落ちる。
#       **前方一致は非対称なので両方向の fixture が要る** — 退行形 `[ "${NB_COUNT#$body_count}" =
#       "$NB_COUNT" ]` は「body_count が NB_COUNT の接頭辞でない」を不一致とみなすため、
#       (d) の向き (--count 1 / 本文 12) では `${1#12}` = `1` = NB_COUNT となり不一致判定が
#       保たれて緑のまま通る。落とせるのは (d') の向き (--count 12 / 本文 1) だけで、
#       そこでは `${12#1}` = `2` ≠ `12` となり一致扱いに化けて投稿が通る。片方向だけ pin すると
#       production で「非実測 12 件の cycle に本文が 1 件と申告する」虚偽記録が無検出になる。
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 12 --iteration-id 9-231 --content-file "$NBR_BODY_C12"
assert "TC-4.3c 2 桁 count 一致: exit 0" "0" "$RC"
assert_grep "TC-4.3c outcome=created かつ count=12 を echo back" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=created; count=12; iteration_id=9-231;'
assert_grep "TC-4.3c gh pr comment が実行された" "$GH_LOG" '^pr comment 9 -R o/r --body-file'
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-232 --content-file "$NBR_BODY_C12"
assert "TC-4.3d --count 1 と本文 12 の不一致: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.3d reason=count_body_mismatch (先頭一致で通さない)" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=count_body_mismatch'
assert_not_grep "TC-4.3d 投稿呼び出しが 1 件も無い" "$GH_LOG" '^pr comment'
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 12 --iteration-id 9-233 --content-file "$NBR_BODY"
assert "TC-4.3d' --count 12 と本文 1 の不一致 (逆向き): exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.3d' reason=count_body_mismatch (逆向き前方一致で通さない)" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=count_body_mismatch'
assert_not_grep "TC-4.3d' 投稿呼び出しが 1 件も無い" "$GH_LOG" '^pr comment'

# TC-4.4 既存なし ∧ 0 件 → 投稿しない (AC-4 非退行)。事実と異なる「0 件」コメントを作らない
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 0 --iteration-id 9-202 --content-file "$NBR_BODY_C0"
assert "TC-4.4a 0 件 ∧ 既存なし: exit 0" "0" "$RC"
assert_grep "TC-4.4a outcome=skipped" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=skipped; count=0; iteration_id=9-202;'
assert_not_grep "TC-4.4b 投稿呼び出しが 1 件も無い (create)" "$GH_LOG" '^pr comment'
assert_not_grep "TC-4.4c 投稿呼び出しが 1 件も無い (PATCH)" "$GH_LOG" '^api repos/.* -X PATCH'
# lookup が成功して「本当に既存なし」と分かっている skip では stale 警告を出さない
# (出すと毎 cycle の正常な 0 件 skip で不要な目視確認を促す)。TC-4.7b と対。
assert_not_grep "TC-4.4d 非 degraded の skip では stale 警告を出さない" "$ERR" '前 cycle の記録コメントが PR 上に残っている可能性'

# TC-4.4e pending marker をディレクトリにして rm -f を決定論的に失敗させる。cleanup の失敗は
# terminal outcome / exit code を変えず、marker を残したまま 5 行の復旧案内を stderr に出す。
_rm_fail_marker="$TMPDIR/rite-nbr-pending-9-202-rm-fail"
mkdir "$_rm_fail_marker"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 0 --iteration-id 9-202-rm-fail --content-file "$NBR_BODY_C0"
assert "TC-4.4e marker 削除失敗でも exit 0 (非ブロッキング)" "0" "$RC"
assert "TC-4.4e 削除できなかった marker が残る" "yes" "$([ -d "$_rm_fail_marker" ] && echo yes || echo no)"
assert_grep "TC-4.4e terminal outcome=skipped を維持" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=skipped; count=0; iteration_id=9-202-rm-fail;'
assert_grep "TC-4.4e 8.0.3 の継続差し戻しを報告" "$ERR" 'ステップ 8.0.3 は本 cycle の 6.1.d を未実行と誤判定します'
assert_grep "TC-4.4e 再実行では収束しない旨を報告" "$ERR" '6.1.d の再実行では収束しません'
assert_grep "TC-4.4e option 終端付きの手動削除手順を報告" "$ERR" 'rm -f -- '
_rm_fail_warning_lines=$(grep -cE '^(WARNING: non-blocking pending marker|  marker が残っている間|  対処:|  marker を手動で削除|  6\.1\.d の terminal sentinel)' "$ERR" || true)
assert "TC-4.4e WARNING + stderr 5 行契約" "5" "$_rm_fail_warning_lines"
rmdir "$_rm_fail_marker"

# TC-4.5 既存あり ∧ 0 件 → 収束 cycle のクリアとして update-in-place (AC-2)
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 0 --iteration-id 9-203 --content-file "$NBR_BODY_C0"
assert "TC-4.5a 0 件 ∧ 既存あり: exit 0" "0" "$RC"
assert_grep "TC-4.5a outcome=updated (count=0)" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=updated; count=0; iteration_id=9-203;'
assert_grep "TC-4.5b comment_id は最新の自 login コメント" "$ERR" 'comment_id=13;'

# TC-4.6 gh 失敗は非ブロッキング (AC-3): WARNING + reason emit、exit は 0 のまま
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_STUB_RC=1 run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-204 --content-file "$NBR_BODY"
assert "TC-4.6a PATCH 失敗: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.6a reason=patch_failed emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=patch_failed'
assert_grep "TC-4.6a outcome=failed" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=failed;'
assert_grep "TC-4.6a mergeable 判定に影響しない旨を案内" "$ERR" '非ブロッキング'
# gh stderr の詳細は `gh:` prefix 付きで出す。無加工 (字下げのみ) で再出力すると、gh 側の
# stderr に混じった sentinel 同形の行が gate の部分一致述語をすり抜けて偽の完了報告になる。
assert_grep "TC-4.6a gh stderr 詳細は gh: prefix 付き" "$ERR" '^  gh: stub: post failure'
assert_not_grep "TC-4.6a gh stderr 由来の sentinel 同形行が素の形で残らない" "$ERR" '^[[:space:]]*\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; pr=9; outcome=updated; count=99'
assert_grep "TC-4.6a 本物の terminal sentinel は行頭に出る" "$ERR" '^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; pr=9; outcome=failed;'
# positive control (relocated, cycle 4): 「レビューをやり直してください」は _record_gh_io_failure_hint
# (gh/IO 起因の失敗専用) がまだ出す文言であることを、実際に失敗する gh/IO 経路で固定する。
# 本文検査起因の 4 reason (body_file_empty / body_marker_missing / body_sentinel_missing / count_body_mismatch) は
# _record_body_check_failure_hint に分離され、この文言はもう出さない (下記 TC-4.8d' 参照)。
assert_grep "TC-4.6a [positive control] gh/IO 起因の記録失敗案内が出る" "$ERR" 'レビューをやり直してください'
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" GH_STUB_RC=1 run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-205 --content-file "$NBR_BODY"
assert "TC-4.6b create 失敗: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.6b reason=create_failed emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=create_failed'
# gh が signal で死んだとき (rc>=128) は signal 番号を併記する (兄弟 review-comment-post.sh と対称)。
# rc=1 のケースだけでは else 側しか通らず、この分岐が死に分岐化しても検出できない。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_STUB_RC=143 run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-205b --content-file "$NBR_BODY"
assert "TC-4.6c gh signal death: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.6c rc と signal を併記" "$ERR" 'reason=patch_failed; rc=143; signal=15'

# TC-4.6d lookup パイプの **jq 側** の失敗も degraded として扱い、その stderr を診断に出す。
# gh セグメントにしか 2> を付けていないと jq の stderr だけが素通りし、API レスポンス由来の
# バイト列が無加工で gate の読む fd に出る。
GH_LOOKUP_MALFORMED=1 run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-205c --content-file "$NBR_BODY"
assert "TC-4.6d jq 失敗: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.6d degraded=1 かつ created に縮退" "$ERR" 'outcome=created; count=1; iteration_id=9-205c; comment_id=; degraded=1'
assert_grep "TC-4.6d jq の stderr が gh: prefix 付きで診断に出る" "$ERR" '^  gh: jq: error'

# TC-4.7 lookup 失敗 → degraded=1 で存在不明扱い。0 件は skip / >0 件は新規作成に縮退 (silent 縮退禁止)
GH_LOOKUP_RC=1 run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-206 --content-file "$NBR_BODY"
assert "TC-4.7a lookup 失敗 ∧ count>0: exit 0" "0" "$RC"
assert_grep "TC-4.7a WARNING を出す (silent 縮退しない)" "$ERR" '既存の非実測記録コメントの検索に失敗'
assert_grep "TC-4.7a degraded=1 かつ created に縮退" "$ERR" 'outcome=created; count=1; iteration_id=9-206; comment_id=; degraded=1'
assert_grep "TC-4.7a degraded 用の案内を出す" "$ERR" 'update-in-place を諦めます'
assert_not_grep "TC-4.7a 記録失敗用の案内は出さない (投稿は成功する)" "$ERR" 'レビューをやり直してください'
# [test-reviewer F-02, cycle 4] 広域 ERE 化 (TC-4.2f と同じ理由)
assert_not_grep "TC-4.7a degraded 案内が結末を断定しない (広域 ERE)" "$ERR" '(記録|投稿)[^。]*(されます|される)'
# F-02 (cycle 2 review): created ∧ degraded=1 は既存記録を検出できないまま重複作成した縮退であり、
# skip 経路 (_record_degraded_skip_hint) と対称に専用の案内を出す (_record_degraded_create_hint)。
assert_grep "TC-4.7a degraded ∧ created 専用の重複警告を出す" "$ERR" '既存の記録コメントを特定できないまま新規作成したため、前 cycle の記録コメントが PR 上に重複して残っている可能性があります'
# TC-4.7a' [application-reviewer + error-handling-reviewer 指摘, cycle 3, negative control]:
# degraded (lookup 失敗) ∧ create 自体も失敗 (GH_STUB_RC=1) の組み合わせでは、実際には何も
# 投稿されていない (outcome=failed) にもかかわらず「重複して新規作成した」という未確定の結末を
# 断定する案内を出してはならない。_record_degraded_create_hint を outcome="created" 確定後の
# 成功分岐内へ移したことで、この run では create_failed の失敗案内のみが出る。
GH_LOOKUP_RC=1 GH_STUB_RC=1 run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-206b --content-file "$NBR_BODY"
assert "TC-4.7a' lookup 失敗 ∧ create 失敗: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.7a' outcome=failed (投稿されていない)" "$ERR" 'outcome=failed; count=1; iteration_id=9-206b; comment_id=; degraded=1'
assert_grep "TC-4.7a' reason=create_failed emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=create_failed'
assert_not_grep "TC-4.7a' 未確定の重複警告を出さない (虚偽案内防止)" "$ERR" '既存の記録コメントを特定できないまま新規作成したため'
GH_LOOKUP_RC=1 run_nbr --pr 9 --owner-repo o/r --count 0 --iteration-id 9-207 --content-file "$NBR_BODY_C0"
assert "TC-4.7b lookup 失敗 ∧ 0 件: exit 0" "0" "$RC"
assert_grep "TC-4.7b degraded=1 かつ skipped" "$ERR" 'outcome=skipped; count=0; iteration_id=9-207; comment_id=; degraded=1'
assert_not_grep "TC-4.7b 事実と異なる 0 件コメントを作らない" "$GH_LOG" '^pr comment'
# degraded 由来の「既存なし」は「既存が実在しても検出できなかった」可能性を含むため、
# 収束 cycle のクリア (AC-2) が成立していないことを明示する必要がある。
assert_grep "TC-4.7b stale 記録が残りうることを明示する" "$ERR" '前 cycle の記録コメントが PR 上に残っている可能性'
# [test-reviewer F-02, cycle 4]: TC-4.7b は outcome=skipped — 何も投稿されない経路であり、
# 「記録され(る/ます)」「投稿され(る/ます)」の断定文が誤報として最も有害な場所 (TC-4.2f /
# TC-4.7a は投稿が成功する経路のため、断定してもまだ事実に近い)。この経路にも同じ広域 ERE を適用する。
assert_not_grep "TC-4.7b degraded skip 案内が結末を断定しない (広域 ERE、何も投稿されない経路)" "$ERR" '(記録|投稿)[^。]*(されます|される)'

# TC-4.7c [test-reviewer F-02, cycle 4, positive control]: 上記 3 件の広域 ERE が単なる恒真の
# guard に退化していないことを、代表的な断定文に対して実際にマッチすることで示す (production
# コードを mutate せずに regex 自体の生死を確認する自己検査)。
_f02_sample='なお記録は投稿されますのでご安心ください'
if printf '%s' "$_f02_sample" | grep -qE '(記録|投稿)[^。]*(されます|される)'; then
  pass "TC-4.7c [positive control] 広域 ERE は代表的な断定文を検出できる"
else
  fail "TC-4.7c [positive control] 広域 ERE が代表的な断定文を検出できない (regex 自体の不備)"
fi

# TC-4.8 本文ファイルが空 → 投稿中止 (空 body PATCH による 1 行目 marker 消失の防止)
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-208 --content-file "$NBR_EMPTY_BODY"
assert "TC-4.8a 本文空: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.8a reason=body_file_empty emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=body_file_empty'
assert_not_grep "TC-4.8b 空 body で PATCH しない" "$GH_LOG" '^api repos/.* -X PATCH'
# 非空だが 1 行目が marker でない本文 → 空 body と同じ破綻 (marker 消失) を起こすため別 reason で遮断
NBR_NOMARKER_BODY="$TMP_ROOT/nbr-nomarker.md"
printf 'ERROR: reviewer output could not be rendered\n' > "$NBR_NOMARKER_BODY"
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id 9-209 --content-file "$NBR_NOMARKER_BODY"
assert "TC-4.8c 1 行目 marker 欠落: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.8c reason=body_marker_missing emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=body_marker_missing'
assert_not_grep "TC-4.8c body_file_empty に融合しない" "$ERR" 'reason=body_file_empty'
assert_not_grep "TC-4.8d marker 欠落本文で PATCH しない" "$GH_LOG" '^api repos/.* -X PATCH'
# positive control (cycle 4 で再設計): body_marker_missing は本文検査起因の失敗であり、
# gh 認証 / network / 権限とは無関係 (F-12 tech-writer + F-03 prompt-engineer, cycle 4)。
# _record_body_check_failure_hint が出す専用の案内文言を固定する。「レビューをやり直してください」
# はもう出ない (gh/IO 起因の案内の positive control は TC-4.6a に relocate 済み)。
assert_grep "TC-4.8d' [positive control] 本文検査起因の記録失敗案内が出る (gh 認証/network/権限を指さない)" "$ERR" 'ステップ 6\.1\.d step 1 の本文生成'
assert_not_grep "TC-4.8d' 本文検査起因の失敗で gh/IO 用の案内 (誤誘導) を出さない" "$ERR" 'レビューをやり直してください'

# TC-4.9 【最重要 invariant】terminal sentinel は「動作の完了」を表す。
# gate は本 sentinel だけを pass 条件にするため、outcome が created|updated を名乗るときは
# gh stub log に投稿呼び出しが**実在**していなければならない (動作前 marker で green を騙れない)。
# TC-4.2/4.3 は個別に log を検査済。ここでは全 outcome を横断して対応関係を機械的に固定する。
for case_spec in \
  "$NBR_COMMENTS|2|updated|yes" \
  "$NBR_EMPTY_COMMENTS|2|created|yes" \
  "$NBR_EMPTY_COMMENTS|0|skipped|no"; do
  IFS='|' read -r _fx _cnt _want _expect_post <<< "$case_spec"
  # F-01 (cycle 3 review): count/body 整合検査が skip 判定より前に移動したため、skip ケース
  # (count=0) も本文検査を通過する必要がある。--count と一致する body fixture を都度選択する。
  case "$_cnt" in
    0) _body_fx="$NBR_BODY_C0" ;;
    2) _body_fx="$NBR_BODY_C2" ;;
    *) _body_fx="$NBR_BODY" ;;
  esac
  GH_LOOKUP_JSON="$_fx" run_nbr --pr 9 --owner-repo o/r --count "$_cnt" --iteration-id "9-30-$_want" --content-file "$_body_fx"
  assert_grep "TC-4.9 outcome=$_want を emit" "$ERR" "outcome=$_want;"
  _posted=no
  grep -qE '^(pr comment|api repos/.* -X PATCH --input -)' "$GH_LOG" && _posted=yes
  assert "TC-4.9 outcome=$_want ⇒ 投稿呼び出し実在=$_expect_post" "$_expect_post" "$_posted"
done

# TC-4.9b abort 経路: helper が判定分岐に到達する前に signal で落ちたとき、terminal sentinel は
# outcome=aborted を **1 回だけ** emit し、投稿呼び出しは 1 件も無い。outcome の初期値が
# success 値を騙れないという中核契約を、初期値を書き換える mutation で落ちる形に固定する。
: > "$GH_LOG"; rm -f "$GH_BODY" "$GH_STDIN"
_abort_err="$TMP_ROOT/abort-err"
_abort_hang_pid_file="$TMP_ROOT/abort-hang-pid"
rm -f "$_abort_hang_pid_file"
PATH="$STUB_DIR:$PATH" GH_STUB_LOG="$GH_LOG" GH_LOOKUP_JSON="$NBR_COMMENTS" GH_LOOKUP_HANG=1 \
  GH_HANG_PID_FILE="$_abort_hang_pid_file" \
  bash "$PLUGIN_ROOT/hooks/review-nonblocking-record.sh" \
  --pr 9 --owner-repo o/r --count 2 --iteration-id 9-900 --content-file "$NBR_BODY" \
  >"$OUT" 2>"$_abort_err" &
_abort_pid=$!
# lookup が hang している間に TERM を送る (判定分岐に到達する前)。
# **待機点は stub が書く PID ファイル**: stub の stderr は helper が tempfile へ退避するため
# $_abort_err では観測できず、そこを待つと述語が一度も成立せずタイムアウト待ちの時間依存同期に
# 退化する (= 「hang に入る前に TERM を送ってしまう」退行を検出できない)。
_waited=0
while [ "$_waited" -lt 100 ] && [ ! -s "$_abort_hang_pid_file" ]; do
  _waited=$((_waited + 1)); sleep 0.1
done
if [ "$_waited" -lt 100 ]; then
  pass "TC-4.9b 同期成立: stub が hang に入ったことを観測できた ($_waited 回転)"
else
  fail "TC-4.9b 同期が成立しなかった (上限 $_waited 回転で述語が一度も成立せず = 時間依存同期に退化)"
fi
kill -TERM "$_abort_pid" 2>/dev/null
# helper への TERM は foreground の lookup pipeline 完了まで遅延するため、stub 側も落とす。
# これを省くと wait が stub の sleep 満了まで戻らない (実行時間が 30 秒に膨らむ)。
[ -s "$_abort_hang_pid_file" ] && kill -TERM "$(cat "$_abort_hang_pid_file")" 2>/dev/null
wait "$_abort_pid" 2>/dev/null; _abort_rc=$?
# rc=143 単独は「trap が走った」ことを意味しない (trap 設置前の既定 signal death も 128+15)。
# 直下の terminal sentinel assertion と **対で** 初めて trap 経路であることを示す。
assert "TC-4.9b SIGTERM: rc=143 (直下の sentinel assertion と対で trap 経路を示す)" "143" "$_abort_rc"
assert_grep "TC-4.9b outcome=aborted を emit" "$_abort_err" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=aborted;'
_abort_sentinels=$(grep -c '^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1' "$_abort_err" || true)
assert "TC-4.9b terminal sentinel は 1 回だけ (trap 再入の冪等化)" "1" "$_abort_sentinels"
assert_grep "TC-4.9b signal 中断が loud に出る" "$_abort_err" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=signal_aborted'
assert_not_grep "TC-4.9b 投稿呼び出しが無い (create)" "$GH_LOG" '^pr comment'
assert_not_grep "TC-4.9b 投稿呼び出しが無い (PATCH)" "$GH_LOG" '^api repos/.* -X PATCH'
# [error-handling-reviewer F-01, cycle 5]: signal_aborted は他 5 つの非ブロッキング失敗 reason と
# 異なり「対処」行を持たず、次 cycle が自己修復する事実が operator に届かなかった。2 行追加した。
assert_grep "TC-4.9b 対処行で自己修復を案内する (他 5 reason と同じ規律)" "$_abort_err" '対処: 次 cycle の lookup \+ PATCH が update-in-place で自己修復するため'

# TC-4.10 iteration_id は verbatim に echo back される (AC-7: gate の cycle 一致判定の入力)
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 1 --iteration-id "9-1799999999" --content-file "$NBR_BODY"
assert_grep "TC-4.10 iteration_id を verbatim に echo back" "$ERR" 'iteration_id=9-1799999999;'

# TC-4.11 F-01 (cycle 2 review): --count と本文の `📎 non_blocking_count:` 行が不一致のとき
# 投稿を中止する (count=0 + variant A 本文 で D-01 の記録が無音で消える経路の再現、および
# 逆向き count>0 + variant B「0 件」本文 の両方を固定する)。既存コメントありの lookup を使い、
# count=0 でも skip 分岐 (existing_id 空 ∧ count=0) より先にこの検査へ到達させる。
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 0 --iteration-id 9-211 --content-file "$NBR_BODY"
assert "TC-4.11a count(0) と本文(1) 不一致: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.11a reason=count_body_mismatch emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=count_body_mismatch'
assert_grep "TC-4.11a outcome=failed" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=failed;'
assert_not_grep "TC-4.11a 不一致時は投稿しない (PATCH)" "$GH_LOG" '^api repos/.* -X PATCH'
# [tech-writer F-12 + prompt-engineer F-03 統合, cycle 4]: count_body_mismatch も本文検査起因
# (caller の --count/本文置換ミス) であり、gh 認証/network/権限とは無関係。誤った gh/IO 向け
# 案内を出すと、原因と無関係な確認に operator を誘導し、真因 (step 1-2 の再置換漏れ) への
# 復旧が遅れる。
assert_grep "TC-4.11a 本文検査起因の記録失敗案内が出る (count_body_mismatch)" "$ERR" 'ステップ 6\.1\.d step 1 の本文生成'
assert_not_grep "TC-4.11a gh/IO 用の案内 (誤誘導) を出さない" "$ERR" 'レビューをやり直してください'
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-212 --content-file "$NBR_BODY"
assert "TC-4.11b count(2) と本文(1) 不一致 (既存あり): exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.11b reason=count_body_mismatch emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=count_body_mismatch'
assert_not_grep "TC-4.11b 不一致時は投稿しない (PATCH)" "$GH_LOG" '^api repos/.* -X PATCH'
# non_blocking_count 行自体が欠落 (variant テンプレート未追従等) も同じ reason で捕捉する。
# 既存コメントありの lookup を使い skip 分岐を回避する (上記と同じ理由)。
NBR_NOCOUNT_BODY="$TMP_ROOT/nbr-nocount.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n本 cycle の非実測指摘: 0 件\n\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_NOCOUNT_BODY"
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 0 --iteration-id 9-213 --content-file "$NBR_NOCOUNT_BODY"
assert "TC-4.11c non_blocking_count 行欠落: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.11c reason=count_body_mismatch emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=count_body_mismatch'
assert_not_grep "TC-4.11c 不一致時は投稿しない (PATCH)" "$GH_LOG" '^api repos/.* -X PATCH'
# [application-reviewer 指摘, cycle 3]: 行欠落時のプレースホルダ `<欠落>` は日本語マルチバイト文字を
# 含むため、neutralize_ctrl の C1 帯バイト単位置換を誤って通すと中間バイトが破壊され文字化けする。
# リテラルをそのまま出力していること (文字化けしていないこと) を固定する。
assert_grep "TC-4.11c 欠落プレースホルダが文字化けしていない" "$ERR" "値: '<欠落>'"
# TC-4.11d [application-reviewer 指摘, cycle 3]: F-01 が本来対象としていた「--count 0 の誤置換 +
# N 件を表示する本文 + 既存コメントなし」のシナリオ。count/body 整合検査が skip 判定より前に
# 無いと、この run は existing_id 空 ∧ NB_COUNT==0 の skip 条件に一致して本文を読まないまま
# outcome=skipped (degraded=0) に落ち、AC-4 の正当な no-op と観測上区別できないまま D-01 の記録が
# 無音で消える。本文検査を先に置くことでこの run も count_body_mismatch で捕捉されることを固定する。
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 0 --iteration-id 9-214 --content-file "$NBR_BODY"
assert "TC-4.11d 既存なし ∧ count(0)-本文(1) 不一致: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.11d reason=count_body_mismatch emit (skipped に縮退しない)" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=count_body_mismatch'
assert_not_grep "TC-4.11d outcome=skipped に縮退しない (無音喪失防止)" "$ERR" 'outcome=skipped;'
assert_grep "TC-4.11d outcome=failed" "$ERR" 'NONBLOCKING_RECORD_DONE=1; pr=9; outcome=failed;'
assert_not_grep "TC-4.11d 不一致時は投稿しない (create)" "$GH_LOG" '^pr comment'

# TC-4.11e [application-reviewer F-1, cycle 4]: 本文は毎 cycle LLM が生成する自由文であり、
# コロン直後の空白量・行末 trailing space のような意味を変えない整形のブレで count 整合検査が
# no-match になり、記録が丸ごと投稿されなくなってはならない。値そのもの (数字) は厳格に保ちつつ
# 周囲の空白だけ許容することを固定する。
NBR_BODY_WS="$TMP_ROOT/nbr-body-ws.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count:2 \n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_WS"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-216 --content-file "$NBR_BODY_WS"
assert "TC-4.11e コロン直後の空白なし・行末 trailing space: exit 0" "0" "$RC"
assert_not_grep "TC-4.11e 整形のブレを count_body_mismatch と誤判定しない" "$ERR" 'reason=count_body_mismatch'
assert_grep "TC-4.11e outcome=created (記録は投稿される)" "$ERR" 'outcome=created; count=2; iteration_id=9-216;'
assert_grep "TC-4.11e 投稿呼び出しが実在する" "$GH_LOG" '^pr comment'

# TC-4.11f [application-reviewer F-2, cycle 4]: 本文中に行頭 `📎 non_blocking_count:` 形の行が
# canonical な末尾行より**前**に (例: 前 cycle 記録の残骸) 現れても、read 側は本文「末尾」の
# canonical な行を採る契約 (SKILL.md の variant A/B・診断文と一致)。先頭一致 (旧 `-m1`) の
# ままだと非 canonical な先行行を誤って読み、事実と異なる count_body_mismatch を発火させる。
NBR_BODY_DECOY="$TMP_ROOT/nbr-body-decoy.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n📎 non_blocking_count: 9\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count: 2\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_DECOY"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-217 --content-file "$NBR_BODY_DECOY"
assert "TC-4.11f 本文中の先行デコイ行: exit 0" "0" "$RC"
assert_not_grep "TC-4.11f 末尾の canonical な行を読み、デコイと誤判定しない" "$ERR" 'reason=count_body_mismatch'
assert_grep "TC-4.11f outcome=created (記録は投稿される)" "$ERR" 'outcome=created; count=2; iteration_id=9-217;'

# TC-4.11g [F-09 指摘, cycle 6]: 本文が機械専用 sentinel を欠くと投稿を中止する。
# sentinel は lookup 述語の第 3 条件であり、欠いた本文を投稿すると次 cycle の lookup が自分の
# 投稿を検出できず記録コメントが cycle ごとに増殖する (1 行目 marker 欠落と同じ結末)。
NBR_BODY_NOSENT="$TMP_ROOT/nbr-body-nosentinel.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count: 2\n📎 reviewed_commit: abc\n' > "$NBR_BODY_NOSENT"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-218 --content-file "$NBR_BODY_NOSENT"
assert "TC-4.11g sentinel 欠落 (create 経路): exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.11g reason=body_sentinel_missing emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=body_sentinel_missing'
assert_grep "TC-4.11g outcome=failed" "$ERR" 'outcome=failed;'
assert_not_grep "TC-4.11g 投稿呼び出しは実在しない" "$GH_LOG" '^pr comment'
# [positive control] 本文検査起因の案内が出る (gh 認証/network を指す誤案内でないこと)
assert_grep "TC-4.11g [positive control] 本文検査起因の案内が出る" "$ERR" 'gh 認証 / network / 権限の問題ではありません'

# TC-4.11g' [F-08 指摘, cycle 7]: 既存コメントありの **PATCH 経路**でも sentinel 検査が効くこと。
# 兄弟の TC-4.8b / TC-4.8d (body_file_empty / body_marker_missing) は NBR_COMMENTS を使い
# 「PATCH を実行しない」を assert する規律を持つのに、3 番目の本文検査だけが create 経路限定だった。
# PATCH 側は「既存の記録コメントを sentinel 無し本文で上書きする」= 以降の lookup が恒久的に
# miss して記録コメントが cycle ごとに増殖する、より破壊的な方向。
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-219 --content-file "$NBR_BODY_NOSENT"
assert "TC-4.11g' sentinel 欠落 (PATCH 経路): exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.11g' reason=body_sentinel_missing emit" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=body_sentinel_missing'
assert_not_grep "TC-4.11g' sentinel 欠落本文で PATCH しない" "$GH_LOG" '\-X PATCH'

# TC-4.11h [F-03 指摘, cycle 7]: sentinel が本文**途中**にあるだけでは通さない (write 側末尾検査)。
# read 側 lookup が最終非空行の等値なのに write 側が位置非依存だと、sentinel を途中にだけ持つ本文が
# 投稿され、次 cycle の lookup がその投稿を miss して記録が増殖する (片側だけ強めた場合の増殖経路)。
NBR_BODY_MIDSENT="$TMP_ROOT/nbr-body-midsentinel.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n<!-- rite:nbr:v1 -->\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count: 2\n📎 reviewed_commit: abc\n' > "$NBR_BODY_MIDSENT"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-220 --content-file "$NBR_BODY_MIDSENT"
assert "TC-4.11h sentinel が途中のみ: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.11h reason=body_sentinel_missing emit (末尾でないため)" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=body_sentinel_missing'
assert_not_grep "TC-4.11h 投稿呼び出しは実在しない" "$GH_LOG" '^pr comment'
assert_grep "TC-4.11h 診断が実際の最終非空行を示す" "$ERR" '実際の最終非空行:'
# [positive control] 末尾に置けば通ること (検査が「常に落ちる」死んだ条件でないこと)
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-221 --content-file "$NBR_BODY_C2"
assert_grep "TC-4.11h [positive control] 末尾 sentinel なら投稿される" "$ERR" 'outcome=created; count=2; iteration_id=9-221;'

# TC-4.14 [F-03 指摘, cycle 7]: sentinel を末尾に持たない自分の marker コメント (legacy 記録 /
# 人間の手書きメモ) を検出したら silent にせず WARNING + marker を emit する。
# 述語変更由来の縮退だけを無音にすると、既存記録コメントの孤児化を観測する手段が無くなる。
# NBR_COMMENTS の id=98 (sentinel なし) と id=97 (sentinel が途中) の 2 件が near-miss。
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-222 --content-file "$NBR_BODY_C2"
assert "TC-4.14 legacy orphan 検出時も exit 0" "0" "$RC"
# near-miss は id=98 (sentinel なし) / id=97 (sentinel が途中) / id=96 (最終行が引用付き sentinel) の 3 件
assert_grep "TC-4.14 legacy orphan marker を emit (3 件)" "$ERR" 'NONBLOCKING_LEGACY_ORPHAN=1; pr=9; count=3'
assert_grep "TC-4.14 WARNING に件数が出る" "$ERR" '最終非空行が機械専用 sentinel でない自分のコメントが 3 件'
assert_grep "TC-4.14 canonical な id=13 が PATCH 先のまま (孤児に奪われない)" "$ERR" 'comment_id=13;'

# TC-4.11i [F-04 指摘, cycle 7]: sentinel 行の**後に空行が続く**本文を write 側が受理する。
# 実 write 経路 (jq --rawfile) は末尾改行を付けるし、GitHub 側の整形でも末尾空行は増減しうる。
# write 側の「空白のみの行を除く」処理を落とす (単純な tail -n 1 に退行させる) と、この形状が
# body_sentinel_missing で毎 cycle 弾かれ記録が一度も投稿されなくなる。
NBR_BODY_TRAILBLANK="$TMP_ROOT/nbr-body-trailblank.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| r | HIGH | a.ts:1 |\n\n📎 non_blocking_count: 2\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n\n\n' > "$NBR_BODY_TRAILBLANK"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-225 --content-file "$NBR_BODY_TRAILBLANK"
assert "TC-4.11i sentinel 後の空行を許容: exit 0" "0" "$RC"
assert_not_grep "TC-4.11i 末尾空行を sentinel 欠落と誤判定しない" "$ERR" 'reason=body_sentinel_missing'
assert_grep "TC-4.11i outcome=created (投稿される)" "$ERR" 'outcome=created; count=2; iteration_id=9-225;'

# TC-4.11l [F-05 指摘, cycle 9]: `実際の最終非空行:` 診断に**日本語がそのまま現れる**。
# neutralize_ctrl の既定モードは C1 帯 (0x80-0x9f) をバイト単位で ? 化するため、日本語 UTF-8 の
# 第 2/第 3 バイトを巻き込んで診断が読めなくなる。本行は LLM 生成の自由文が渡る唯一の call site で、
# かつ body_sentinel_missing は 8.0.3 が差し戻す経路のため、読めないと caller が本文の作り直し先を
# 特定できない。`--c0-only` なら C0 + DEL は ? 化されたまま UTF-8 は保持される。
NBR_BODY_JP="$TMP_ROOT/nbr-body-jp.md"
printf '## \360\237\223\234 rite 非実測指摘の記録 (non-blocking)\n\n\360\237\223\216 non_blocking_count: 2\n\nご確認をお願いします。\n' > "$NBR_BODY_JP"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-232 --content-file "$NBR_BODY_JP"
assert_grep "TC-4.11l 診断の日本語が文字化けしない" "$ERR" "実際の最終非空行: 'ご確認をお願いします。'"
assert_grep "TC-4.11l reason=body_sentinel_missing (本文検査自体は成立)" "$ERR" 'reason=body_sentinel_missing'

# TC-4.11l' [cycle 10]: --c0-only でも C0 (ESC) は ? 化される。TC-4.11l (日本語がそのまま出る) だけでは
# `| neutralize_ctrl --c0-only` を丸ごと外す退行が検出できない (素通しでも日本語は出るため)。
# ESC が素通りすると端末制御シーケンスが診断行とコンテキストに到達する。
NBR_BODY_ESC="$TMP_ROOT/nbr-body-esc.md"
printf '## \360\237\223\234 rite 非実測指摘の記録 (non-blocking)\n\n\360\237\223\216 non_blocking_count: 2\n\nescape \033[31m here\n' > "$NBR_BODY_ESC"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-233 --content-file "$NBR_BODY_ESC"
assert_grep "TC-4.11l' C0 (ESC) は ? 化される" "$ERR" "実際の最終非空行: 'escape \?\[31m here'"

# TC-4.11k [F-01 指摘, cycle 9]: 本文述語 (jq) の**評価自体が失敗**したら caller 契約違反ではなく
# 環境起因として扱う — pending marker を残さず (8.0.3 が差し戻さない)、reason は body_check_unavailable。
# 本文を作り直しても解消しない原因を retain 側に落とすと result pattern が永久に emit できなくなる。
# 注: PATH 先頭の壊れた jq は lookup 側の jq も壊すため、本 TC は「lookup degraded + 本文述語の
# 評価失敗」の複合経路を通る。write 側だけを壊す現実的な原因は無い — read/write は同一の jq
# バイナリと同一の述語定数 (LAST_CONTENT_LINE_JQ) を共有する。
_jq_stub_dir="$TMP_ROOT/jq-stub"; mkdir -p "$_jq_stub_dir"
printf '#!/bin/sh\nexit 127\n' > "$_jq_stub_dir/jq"; chmod +x "$_jq_stub_dir/jq"
_nbr_marker_k="${TMPDIR:-/tmp}/rite-nbr-pending-9-231"
: > "$_nbr_marker_k"
PATH="$_jq_stub_dir:$PATH" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-231 --content-file "$NBR_BODY_C2"
assert "TC-4.11k jq 評価失敗: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.11k reason=body_check_unavailable" "$ERR" 'NONBLOCKING_RECORD_FAILED=1; pr=9; reason=body_check_unavailable'
assert_not_grep "TC-4.11k body_sentinel_missing と誤分類しない" "$ERR" 'reason=body_sentinel_missing'
if [ -e "$_nbr_marker_k" ]; then _k_marker="present"; else _k_marker="absent"; fi
assert "TC-4.11k pending marker を残さない (8.0.3 が差し戻さない)" "absent" "$_k_marker"
assert_grep "TC-4.11k outcome=failed (terminal sentinel)" "$ERR" 'outcome=failed; count=2; iteration_id=9-231;'
# 案内は原因に一致させる (helper の _record_env_failure_hint)。gh auth / network を指す誤案内は
# operator を真因 (jq 実行環境) から遠ざけるため禁止 — helper 自身が hint 分離の規律として明文化している。
assert_grep "TC-4.11k 原因に一致した案内 (jq 実行環境)" "$ERR" 'jq --version で jq の実行環境を確認'
# 複合経路では lookup degraded hint が 'gh auth status を確認してください' を正当に出すため、
# not_grep は _record_gh_io_failure_hint 固有の文言 (write 権限 + レビューやり直し) に絞る。
assert_not_grep "TC-4.11k gh io 失敗の誤案内を出さない" "$ERR" 'write 権限を確認し、レビューをやり直してください'
# 静的 pin: _body_jq_err は生成直後 (jq 実行より前) に gh_err へ代入され EXIT trap の保護下に入る。
# 代入が jq 実行の後だと、jq 実行中に INT/TERM/HUP を受けた場合に一時ファイルだけが TMPDIR に残る
# (signal-timing テストは本質的に racy なため、順序の静的 pin で代替する。mutation 実測済み)。
_k_nbr_sh="$PLUGIN_ROOT/hooks/review-nonblocking-record.sh"  # NBR_SH は TC-5 で定義されるため直接導出
_k_assign_line=$(grep -n 'gh_err="\$_body_jq_err"' "$_k_nbr_sh" | head -1 | cut -d: -f1)
_k_jq_line=$(grep -n 'if ! _body_last_line=\$(jq -Rrs' "$_k_nbr_sh" | head -1 | cut -d: -f1)
if [ -n "$_k_assign_line" ] && [ -n "$_k_jq_line" ] && [ "$_k_assign_line" -lt "$_k_jq_line" ] 2>/dev/null; then _k_order="before"; else _k_order="after-or-missing"; fi
assert "TC-4.11k' gh_err への代入が jq 実行より前 (signal 窓の trap 保護)" "before" "$_k_order"
rm -f "$_nbr_marker_k"; rm -rf "$_jq_stub_dir"

# TC-4.11j [F-05 指摘, cycle 8]: **CRLF 本文**を write 側が受理する (read 側の CRLF fixture id=11 と対称)。
# read/write は同一の jq 述語を共有するが、その CR 除去を落とすと CRLF 本文が body_sentinel_missing で
# 毎 cycle 弾かれ、retain_pending_marker=1 → 8.0.3 が exit 1 で差し戻す固定ループになる
# (記録が一度も投稿されず [review:mergeable] も出ない)。
NBR_BODY_CRLF="$TMP_ROOT/nbr-body-crlf.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\r\n\r\n| r | HIGH | a.ts:1 |\r\n\r\n📎 non_blocking_count: 2\r\n📎 reviewed_commit: abc\r\n\r\n<!-- rite:nbr:v1 -->\r\n' > "$NBR_BODY_CRLF"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-229 --content-file "$NBR_BODY_CRLF"
assert "TC-4.11j CRLF 本文: exit 0" "0" "$RC"
assert_not_grep "TC-4.11j CRLF を sentinel 欠落と誤判定しない" "$ERR" 'reason=body_sentinel_missing'
assert_grep "TC-4.11j outcome=created (投稿される)" "$ERR" 'outcome=created; count=2; iteration_id=9-229;'

# TC-4.14d [F-04 指摘, cycle 9]: 孤児が**ちょうど 1 件**でも marker と件数を emit する
# (`legacy_orphan_count -gt 0` の境界値)。migration の支配的ケースであり、ここが無音になると
# 手動削除の案内が operator に届かず、両 gate の転記条件も何も転記しない。
GH_LOOKUP_JSON="$NBR_ONE_ORPHAN" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-230 --content-file "$NBR_BODY_C2"
assert_grep "TC-4.14d 孤児 1 件でも LEGACY_ORPHAN marker を emit" "$ERR" 'NONBLOCKING_LEGACY_ORPHAN=1; pr=9; count=1'
assert_grep "TC-4.14d canonical 不在なので新規作成へ縮退" "$ERR" 'outcome=created; count=2; iteration_id=9-230;'

# TC-4.15 [F-06 指摘, cycle 7]: lookup が非数値の id を返したら PATCH 先にしない。
# existing_id は mutating な API path (issues/comments/$existing_id の PATCH) へ補間されるため、
# 同じ jq 出力から取る件数側に数値 guard があるのに書き込み先だけ無検証、という非対称を作らない。
# 空へ倒せば既存の「既存なし」経路 (count>0 なら create) に乗る。
NBR_COMMENTS_BADID="$TMP_ROOT/nbr-comments-badid.json"
cat > "$NBR_COMMENTS_BADID" <<'EOF'
[[{"id":"1/../../../repos/attacker/evil/issues/comments/999","user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 (non-blocking)\n\nx\n\n<!-- rite:nbr:v1 -->\n"}]]
EOF
GH_LOOKUP_JSON="$NBR_COMMENTS_BADID" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-226 --content-file "$NBR_BODY_C2"
assert "TC-4.15 非数値 id: exit 0" "0" "$RC"
assert_not_grep "TC-4.15 非数値 id を PATCH パスへ補間しない" "$GH_LOG" 'attacker/evil'
assert_grep "TC-4.15 create へ倒れる (既存なし扱い)" "$ERR" 'outcome=created; count=2; iteration_id=9-226;'

# TC-4.14b [F-05 指摘, cycle 7]: canonical な記録コメントが 2 件以上あるとき専用 marker を出す。
# 過去の degraded 縮退が生んだ重複で、`last` を採るため古い方は恒久的に stale で残る。
# legacy_orphan とは原因も復旧手順も違うため合算せず別 marker にする (合算すると WARNING の
# 文面が事実と異なり operator を誤った削除対象へ誘導する)。fixture の id=11 / id=13 が該当。
# 直前 run の $ERR に依存しないよう自前で run する (間に別 TC が挿入されても壊れない)。
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-227 --content-file "$NBR_BODY_C2"
assert_grep "TC-4.14b canonical 重複 marker を emit (2 件)" "$ERR" 'NONBLOCKING_DUPLICATE_RECORD=1; pr=9; count=2'
assert_grep "TC-4.14b WARNING が古い方の手動削除を案内" "$ERR" '古い方を手動削除してください'
# [negative control] canonical が 1 件なら重複 marker を出さない
GH_LOOKUP_JSON="$NBR_PAGED_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-224 --content-file "$NBR_BODY_C2"
assert_not_grep "TC-4.14b [negative control] canonical 1 件なら重複 marker を出さない" "$ERR" 'NONBLOCKING_DUPLICATE_RECORD=1'

# TC-4.14c [F-04 指摘, cycle 7 / F-02 指摘, cycle 8]: 最終行が `> <!-- rite:nbr:v1 -->`
# (Quote reply / raw 引用) の人間コメント (id=96) を PATCH 先に選ばない。本文全体への endswith は
# 行頭 `> ` を吸収するため素通りし、人間の本文を丸ごと上書き破壊する。**最終非空行の等値**で
# のみ除外できる。
# **自前 run が必須** — 直前 run の $GH_LOG に依存すると、その run の fixture に id=96 が
# 含まれない場合 assertion が恒真になる (cycle 7 で実際にそうなっており、述語を endswith へ
# 退行させても pass し続けた)。id=96 を含む NBR_COMMENTS で run し、positive control として
# 「canonical な id=13 を PATCH する」も置いて not_grep が常に真でないことを固定する。
GH_LOOKUP_JSON="$NBR_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-228 --content-file "$NBR_BODY_C2"
assert_not_grep "TC-4.14c 引用付き末尾 sentinel の人間コメント (id=96) を PATCH しない" "$GH_LOG" '^api repos/.*/comments/96 -X PATCH'
assert_grep "TC-4.14c [positive control] canonical な id=13 を PATCH する" "$GH_LOG" '^api repos/.*/comments/13 -X PATCH'
# [negative control] near-miss が 0 件なら marker を出さない (常時 emit の死んだ分岐でないこと)
GH_LOOKUP_JSON="$NBR_PAGED_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-223 --content-file "$NBR_BODY_C2"
assert_not_grep "TC-4.14 [negative control] near-miss 0 件なら marker を出さない" "$ERR" 'NONBLOCKING_LEGACY_ORPHAN=1'

# =====================================================================
# TC-4.16 [the governing rationale]: PATCH 先の同定を本文照合から durable な comment id へ移す
# =====================================================================
# 本文照合は「同一 author が記録コメントの raw markdown を複製した人間コメント」を構造的に
# 除外できない (述語を 4 度強化してもこの残余は残った)。第一候補を PR body に永続化した
# comment id へ移し、本文照合は id が使えないときの fallback に降ろす。
echo "--- TC-4.16: durable comment id による PATCH 先の同定 ---"

# TC-4.16a [T-01, AC-1] id 経路で canonical を解決し、本文照合なら掴む last (id=13) を PATCH しない。
# $NBR_COMMENTS は id=11 / id=13 の両方が 3 条件を満たす — 本文照合だけなら last=13 が PATCH 先に
# なる (TC-4.2a で固定済)。PR body に id=11 を置くと PATCH 先が 11 に変わることが、
# 「id が本文照合を上書きしている」ことの弁別になる。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-401 --content-file "$NBR_BODY_C2"
assert "TC-4.16a durable id 経路: exit 0" "0" "$RC"
assert_grep "TC-4.16a comment_id=11 (本文照合の last=13 ではなく id が決める)" "$ERR" 'outcome=updated; count=2; iteration_id=9-401; comment_id=11; degraded=0'
assert_grep "TC-4.16a PATCH 先が id=11" "$GH_LOG" '^api repos/o/r/issues/comments/11 -X PATCH --input -'
assert_not_grep "TC-4.16a 複製側 (id=13) を PATCH しない" "$GH_LOG" 'issues/comments/13 -X PATCH'
assert_not_grep "TC-4.16a 正常解決では UNRESOLVED marker を出さない" "$ERR" 'NONBLOCKING_ID_UNRESOLVED'
# id 経路で解決できた cycle は PR body に同じ値が既にあるため書き直さない (毎 cycle の無駄な
# PR body 更新を避ける)。positive ペアは TC-4.16b-1 (`^pr edit` が実在する) 側にある。
assert_not_grep "TC-4.16a id 経路で解決した cycle は PR body を書き直さない" "$GH_LOG" '^pr edit'
# 本文照合の走査は id 解決の成否に依らず走る (孤児 / 重複の観測を落とさない)。
assert_grep "TC-4.16a id で解決した cycle でも孤児の観測は継続する" "$ERR" 'NONBLOCKING_LEGACY_ORPHAN=1'

# TC-4.16b [T-02] create → 永続化 → 次 run が id 経路で update-in-place する一巡。
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" GH_PR_BODY="$NBR_PRBODY_PLAIN" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-402 --content-file "$NBR_BODY_C2"
assert "TC-4.16b-1 新規作成: exit 0" "0" "$RC"
assert_grep "TC-4.16b-1 outcome=created" "$ERR" 'outcome=created; count=2; iteration_id=9-402;'
assert_grep "TC-4.16b-1 PR body 更新が実行された" "$GH_LOG" '^pr edit 9 -R o/r --body-file'
assert_grep "TC-4.16b-1 投稿 URL の id が PR body へ永続化される" "$GH_PR_EDIT" '<!-- rite:nbr:comment-id:4242 -->'
assert_grep "TC-4.16b-1 PR body の既存本文を破壊しない" "$GH_PR_EDIT" 'PR の説明本文'
assert_not_grep "TC-4.16b-1 永続化に成功したら FAILED marker を出さない" "$ERR" 'NONBLOCKING_ID_PERSIST_FAILED'
# 次 run: 直前に書かれた PR body をそのまま入力にする (run_nbr が $GH_PR_EDIT を消すため退避)。
NBR_PRBODY_ROUND2="$TMP_ROOT/nbr-prbody-round2.md"
cp "$GH_PR_EDIT" "$NBR_PRBODY_ROUND2"
GH_LOOKUP_JSON="$NBR_COMMENTS_4242" GH_PR_BODY="$NBR_PRBODY_ROUND2" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-403 --content-file "$NBR_BODY_C2"
assert "TC-4.16b-2 2 回目: exit 0" "0" "$RC"
assert_grep "TC-4.16b-2 永続化された id で update-in-place する" "$ERR" 'outcome=updated; count=2; iteration_id=9-403; comment_id=4242; degraded=0'
assert_not_grep "TC-4.16b-2 2 通目を作らない" "$GH_LOG" '^pr comment'
# **id 経路と fallback 経路を弁別する assertion**。fixture の canonical が 1 件しかないため
# `comment_id=4242` は両経路で成立してしまい、上の 3 本だけでは id 解決を無効化しても落ちない
# (T-02 が名目のみになる)。id 経路は永続化を skip し fallback 経路は `pr edit` を出すので、
# 「PR body を書き直さない」ことが id 経路を通った唯一の観測可能な証拠になる。
assert_not_grep "TC-4.16b-2 id 経路で解決した cycle は PR body を書き直さない" "$GH_LOG" '^pr edit'
# 初回書き込みで marker が 1 本だけ入ること (marker 0 本の PR body からの生成)。
# **既存 marker がある PR body での strip 冪等性は TC-4.16e が固定する** (本 assert は run 1 の
# 出力を見ているだけで、strip 経路を通っていない)。
_id_marker_count=$(grep -c 'rite:nbr:comment-id:' "$NBR_PRBODY_ROUND2" || true)
assert "TC-4.16b-2 初回書き込みで PR body の id marker は 1 本" "1" "$_id_marker_count"

# TC-4.16c [T-04, AC-3] id 永続化の失敗は投稿を成功扱いのまま通し、pending marker も残さない。
GH_PR_EDIT_RC=1 GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" GH_PR_BODY="$NBR_PRBODY_PLAIN" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-404 --content-file "$NBR_BODY_C2"
assert "TC-4.16c 永続化失敗: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-4.16c 記録自体は成功 (outcome=created)" "$ERR" 'outcome=created; count=2; iteration_id=9-404;'
assert_grep "TC-4.16c reason=body_edit_failed emit" "$ERR" 'NONBLOCKING_ID_PERSIST_FAILED=1; pr=9; reason=body_edit_failed'
assert_grep "TC-4.16c 投稿は実行されている" "$GH_LOG" '^pr comment'
# MUST NOT「永続化失敗を pending marker の retain 側へ落とさない」の pin は、marker lifecycle を
# per-reason で固定している TC-4.12h' に置く (helper `_nbr_marker_after` の定義がそこにあるため)。

# TC-4.16d [T-05, AC-4] id が指すコメントが 404 でも **エラーにせず fallback へ倒す**。
# 当初は recreate (既存なし = 新規作成) へ倒していたが、$NBR_COMMENTS には本文照合で拾える
# canonical (id=13) が実在するため、それを無視して 2 通目を作る挙動になっていた。fallback は
# 「author ∧ 1 行目 marker ∧ 最終非空行 sentinel」を満たすコメントしか掴まないので、削除済み id の
# 代わりに採っても安全。**fallback が空なら既存の「既存なし」経路がそのまま新規作成へ倒す**ため
# AC-4 の帰結 (エラーにしない) は保たれる — その経路は TC-4.16d'' が固定する。
GH_COMMENT_GET_RC=1 GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-406 --content-file "$NBR_BODY_C2"
assert "TC-4.16d 404: exit 0" "0" "$RC"
assert_grep "TC-4.16d reason=id_comment_deleted; action=fallback" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_comment_deleted; action=fallback'
assert_grep "TC-4.16d 実在する canonical (id=13) を掴み重複を作らない" "$ERR" 'outcome=updated; count=2; iteration_id=9-406; comment_id=13;'
assert_not_grep "TC-4.16d 2 通目を新規作成しない" "$GH_LOG" '^pr comment'
# 404 を「エラー」にしない (AC-4): 記録失敗の reason は emit されない。
assert_not_grep "TC-4.16d 404 を記録失敗として扱わない" "$ERR" 'NONBLOCKING_RECORD_FAILED'

# TC-4.16d'' [AC-4 の帰結] 404 かつ fallback も空なら新規作成へ倒る (「エラーにしない」の担保)。
GH_COMMENT_GET_RC=1 GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-406b --content-file "$NBR_BODY_C2"
assert "TC-4.16d'' 404 ∧ fallback 空: exit 0" "0" "$RC"
assert_grep "TC-4.16d'' 新規作成へ倒れる" "$ERR" 'outcome=created; count=2; iteration_id=9-406b;'
assert_grep "TC-4.16d'' 投稿は実行される" "$GH_LOG" '^pr comment'

# TC-4.16d''' [T-05 の識別力、F-10 対応] 実 gh は HTTP エラー時に --jq を適用せずレスポンス body を
# stdout へ出す。この軸を stub が再現しないと「rc ではなく stdout 非空を成功条件にする」実装バグを
# 検出できず、404 が id_author_mismatch に化けて AC-4 が反転する (`gh api user` の
# GH_ME_STDOUT_ON_ERROR と同型の軸)。
GH_COMMENT_GET_RC=1 GH_COMMENT_GET_STDOUT_ON_ERROR='{"message":"Not Found"}' \
  GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-406c --content-file "$NBR_BODY_C2"
assert "TC-4.16d''' 404 + 非空 stdout: exit 0" "0" "$RC"
assert_grep "TC-4.16d''' rc を見るため 404 判定が維持される" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_comment_deleted; action=fallback'
assert_not_grep "TC-4.16d''' エラー body を author と誤読しない" "$ERR" 'reason=id_author_mismatch'

# TC-4.16d' [reason の分離] 404 以外の取得失敗は別 reason (`id_fetch_failed`) で報告する。
# 帰結は 404 と同じ fallback だが、復旧手順が違う (削除済み = 放置可 / 一時障害 = network 確認) ため
# reason は分ける。
GH_COMMENT_GET_RC=1 GH_COMMENT_GET_STDERR='gh: connection reset by peer' \
  GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-407 --content-file "$NBR_BODY_C2"
assert "TC-4.16d' 一時障害: exit 0" "0" "$RC"
assert_grep "TC-4.16d' reason=id_fetch_failed; action=fallback" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_fetch_failed; action=fallback'
assert_grep "TC-4.16d' 本文照合の canonical (id=13) へ倒す" "$ERR" 'outcome=updated; count=2; iteration_id=9-407; comment_id=13;'
assert_not_grep "TC-4.16d' 重複を作らない" "$GH_LOG" '^pr comment'

# TC-4.16d4 [AC-5 の拡張] id が **別 PR / 別 Issue** のコメントを指していたら PATCH せず fallback。
# `issues/comments/{id}` は repo スコープで issue 非依存のため author 一致だけでは防げない。
# PR body は書き込み権限を持たない PR 作成者でも編集できるので、これは author 検証の穴になる。
GH_COMMENT_GET_ISSUE_URL='https://api.github.com/repos/o/r/issues/777' \
  GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-407b --content-file "$NBR_BODY_C2"
assert "TC-4.16d4 別 PR のコメント: exit 0" "0" "$RC"
assert_grep "TC-4.16d4 reason=id_pr_mismatch; action=fallback" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_pr_mismatch; action=fallback'
assert_not_grep "TC-4.16d4 別 PR のコメント (id=11) を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'
assert_grep "TC-4.16d4 本文照合の canonical (id=13) へ倒す" "$ERR" 'outcome=updated; count=2; iteration_id=9-407b; comment_id=13;'

# TC-4.16d5 [AC-5 の境界] `/issues/{PR}` の **prefix 一致では通さない** (末尾一致であること)。
# `/issues/99` は `/issues/9` を prefix に持つため、suffix 判定を緩めると別 PR が通る。
GH_COMMENT_GET_ISSUE_URL='https://api.github.com/repos/o/r/issues/99' \
  GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-407c --content-file "$NBR_BODY_C2"
assert "TC-4.16d5 prefix 衝突 (/issues/99 vs PR 9): exit 0" "0" "$RC"
assert_grep "TC-4.16d5 prefix 一致では通さない" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_pr_mismatch; action=fallback'
assert_not_grep "TC-4.16d5 id=11 を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'

# TC-4.16e [T-06, AC-5] id が指すコメントの author が自分でなければ PATCH せず fallback へ倒す。
GH_COMMENT_GET_LOGIN='other-user' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-408 --content-file "$NBR_BODY_C2"
assert "TC-4.16e author 不一致: exit 0" "0" "$RC"
assert_grep "TC-4.16e reason=id_author_mismatch; action=fallback" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_author_mismatch; action=fallback'
assert_not_grep "TC-4.16e 他人のコメント (id=11) を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'
assert_grep "TC-4.16e 本文照合の canonical (id=13) へ倒す" "$ERR" 'outcome=updated; count=2; iteration_id=9-408; comment_id=13;'
# **既存 marker を持つ PR body での strip 冪等性の pin**。本 run は marker 1 本を持つ
# $NBR_PRBODY_ID11 を入力に fallback 経由で永続化するため、strip → 付け直しの経路を実際に通る。
# strip を no-op に mutate すると marker が 2 本になり、行アンカーを外すと 24 行目相当の散文が消える。
_e_marker_count=$(grep -c 'rite:nbr:comment-id:' "$GH_PR_EDIT" || true)
assert "TC-4.16e 既存 marker を持つ PR body でも marker は 1 本 (strip の冪等性)" "1" "$_e_marker_count"
assert_grep "TC-4.16e strip は PR 説明本文を壊さない" "$GH_PR_EDIT" 'PR の説明本文'

# TC-4.16e' [AC-5 の境界] rc=0 だが author が空 (レスポンス形状の drift) も PATCH 先にしない。
# author を確認できない値で PATCH すると、他人のコメントを破壊しうる。
GH_COMMENT_GET_LOGIN='' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-409 --content-file "$NBR_BODY_C2"
assert "TC-4.16e' author 空: exit 0" "0" "$RC"
assert_grep "TC-4.16e' reason=id_fetch_unparseable; action=fallback" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_fetch_unparseable; action=fallback'
assert_not_grep "TC-4.16e' 未検証の id=11 を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'

# TC-4.16f [T-07] 非数値の id は本文照合側と同一の numeric guard で弾き fallback へ倒す。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_MALFORMED" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-410 --content-file "$NBR_BODY_C2"
assert "TC-4.16f 非数値 id: exit 0" "0" "$RC"
assert_grep "TC-4.16f reason=id_malformed; action=fallback" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_malformed; action=fallback'
assert_grep "TC-4.16f 本文照合の canonical (id=13) へ倒す" "$ERR" 'outcome=updated; count=2; iteration_id=9-410; comment_id=13;'
# 非数値が API path へ補間されない (`issues/comments/abc` を叩かない)。
assert_not_grep "TC-4.16f 非数値を API path へ補間しない" "$GH_LOG" 'issues/comments/abc'

# TC-4.16g [T-03, AC-2] marker 不在の初回 cycle は現行 3 条件と同一に振る舞い、UNRESOLVED marker を
# 出さない (初回は正常系。毎 cycle WARNING を出すと本当の異常が埋もれる)。投稿後は id を書き足して
# 次 cycle から id 経路に乗せる (durable id を持たない既存 PR の migration)。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_PLAIN" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-411 --content-file "$NBR_BODY_C2"
assert "TC-4.16g marker 不在: exit 0" "0" "$RC"
assert_grep "TC-4.16g 現行 3 条件と同一の結果 (comment_id=13)" "$ERR" 'outcome=updated; count=2; iteration_id=9-411; comment_id=13; degraded=0'
assert_not_grep "TC-4.16g marker 不在は正常系 (UNRESOLVED を出さない)" "$ERR" 'NONBLOCKING_ID_UNRESOLVED'
assert_grep "TC-4.16g fallback 経由の update は id を永続化する (migration)" "$GH_PR_EDIT" '<!-- rite:nbr:comment-id:13 -->'

# TC-4.16h [観測] PR body を読めなくても本文照合は成立するため degraded にはしない。
GH_PR_VIEW_RC=1 GH_LOOKUP_JSON="$NBR_COMMENTS" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-412 --content-file "$NBR_BODY_C2"
assert "TC-4.16h PR body 読取失敗: exit 0" "0" "$RC"
assert_grep "TC-4.16h reason=id_read_failed; action=fallback" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_read_failed; action=fallback'
assert_grep "TC-4.16h 本文照合で PATCH 先が確定するため degraded=0" "$ERR" 'outcome=updated; count=2; iteration_id=9-412; comment_id=13; degraded=0'
# 同一 run で write 側 (`_persist_comment_id`) も `gh pr view` に失敗する。**読めなかった body を
# 空とみなして PR body を上書きしない**ことが最重要 — この guard を外すと PR 説明が marker だけに
# なって消える (記録の失敗ではなく PR 本文の破壊)。
assert_grep "TC-4.16h reason=body_read_failed emit" "$ERR" 'NONBLOCKING_ID_PERSIST_FAILED=1; pr=9; reason=body_read_failed'
assert_not_grep "TC-4.16h 読めない body を空とみなして PR 説明を上書きしない" "$GH_LOG" '^pr edit'

# TC-4.16i 【本 Issue の中核】本文照合の lookup が失敗しても、durable id で PATCH 先が確定すれば
# update-in-place は成立する。ここが従来「degraded → 新規作成へ縮退 → 重複記録コメント」となって
# いた経路で、TC-4.7a (id なし) と**同じ lookup 失敗**でありながら結末が変わることが弁別になる。
GH_LOOKUP_RC=1 GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-413 --content-file "$NBR_BODY_C2"
assert "TC-4.16i lookup 失敗 ∧ id あり: exit 0" "0" "$RC"
assert_grep "TC-4.16i id で PATCH 先が確定し degraded=0" "$ERR" 'outcome=updated; count=2; iteration_id=9-413; comment_id=11; degraded=0'
assert_not_grep "TC-4.16i 重複記録コメントを作らない" "$GH_LOG" '^pr comment'
assert_grep "TC-4.16i 孤児 / 重複を走査できていない事実は明示する" "$ERR" '孤児 / 重複の走査を行えていません'
# degraded 用の案内 (update-in-place を諦める) は出さない — id で特定できているため事実と異なる。
assert_not_grep "TC-4.16i 事実と異なる degraded 案内を出さない" "$ERR" 'update-in-place を諦めます'

# TC-4.16j [degraded の境界] id も本文照合も使えない (id 削除済み ∧ lookup 失敗) なら、PATCH 先を
# 特定できていないので **degraded=1**。recreate 分岐を持っていた頃はここが degraded=0 になり、
# 「既存を走査できないまま新規作成した」事実が転記条件のどれにも載らず completion report から
# 消えていた。degraded を立てることで既存の転記経路 (`_record_degraded_create_hint`) に復帰する。
GH_LOOKUP_RC=1 GH_COMMENT_GET_RC=1 GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-414 --content-file "$NBR_BODY_C2"
assert "TC-4.16j lookup 失敗 ∧ id 削除済み: exit 0" "0" "$RC"
assert_grep "TC-4.16j PATCH 先を特定できないので degraded=1" "$ERR" 'outcome=created; count=2; iteration_id=9-414; comment_id=; degraded=1'
assert_grep "TC-4.16j degraded 由来の重複警告を出す (転記条件へ載る)" "$ERR" '既存の記録コメントを特定できないまま新規作成したため'

# TC-4.16k [観測] 投稿 URL から id を取れないときは永続化を諦めるが、記録自体は成功扱いのまま。
GH_POST_URL='' GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" GH_PR_BODY="$NBR_PRBODY_PLAIN" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-415 --content-file "$NBR_BODY_C2"
assert "TC-4.16k id 抽出不能: exit 0" "0" "$RC"
assert_grep "TC-4.16k outcome=created (記録は成功)" "$ERR" 'outcome=created; count=2; iteration_id=9-415;'
assert_grep "TC-4.16k reason=comment_id_unresolved emit" "$ERR" 'NONBLOCKING_ID_PERSIST_FAILED=1; pr=9; reason=comment_id_unresolved'
assert_not_grep "TC-4.16k 空 id で PR body を書き換えない" "$GH_LOG" '^pr edit'

# TC-4.16m [F-08 対応] 散文中に marker と同形の文字列がある PR body で、**除去は独立行の marker
# だけを消す**。行アンカーを外すと散文中の marker 文字列まで無音で削除され PR 説明が壊れる。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_INLINE_FIRST" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-417 --content-file "$NBR_BODY_C2"
assert "TC-4.16m 散文中の marker 同形文字列: exit 0" "0" "$RC"
assert_grep "TC-4.16m id 経路で解決する (散文行は marker として拾わない)" "$ERR" 'outcome=updated; count=2; iteration_id=9-417; comment_id=11; degraded=0'
# id 経路で解決した cycle は PR body を書き直さないため、除去の観測には fallback 経由が要る。
GH_COMMENT_GET_LOGIN='other-user' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_INLINE_FIRST" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-418 --content-file "$NBR_BODY_C2"
assert "TC-4.16m' fallback 経由で永続化: exit 0" "0" "$RC"
assert_grep "TC-4.16m' 散文中の marker 同形文字列を消さない" "$GH_PR_EDIT" 'id は .<!-- rite:nbr:comment-id:11 -->. のような行で'
_m_marker_lines=$(grep -c '^<!-- rite:nbr:comment-id:' "$GH_PR_EDIT" || true)
assert "TC-4.16m' 独立行の marker は 1 本だけ" "1" "$_m_marker_lines"

# TC-4.16m'' [F-08 対応、抽出側] 散文中の marker 同形文字列が **marker 行より後ろ** にあるとき、
# 抽出が行アンカーを欠くと `tail -1` が散文行の値 (BROKEN) を拾い id_malformed になる。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_INLINE_LAST" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-419 --content-file "$NBR_BODY_C2"
assert "TC-4.16m'' 散文が marker 行より後ろ: exit 0" "0" "$RC"
assert_not_grep "TC-4.16m'' 散文行から偽の id を拾わない" "$ERR" 'reason=id_malformed'
assert_grep "TC-4.16m'' 独立行の marker (id=11) で解決する" "$ERR" 'outcome=updated; count=2; iteration_id=9-419; comment_id=11; degraded=0'

# TC-4.16n [cycle 2 F-18 対応] 片側アンカーを独立に固定する。decoy の片側だけが非空白なので、
# `^` / `$` のどちらか一方を外しただけの mutant もここで落ちる (両アンカー同時除去でしか落ちない
# TC-4.16m 系との差がそのまま identification power の差になる)。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_DECOY_TAIL" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-420 --content-file "$NBR_BODY_C2"
assert "TC-4.16n 行頭 marker + 後続散文: exit 0" "0" "$RC"
assert_not_grep "TC-4.16n 後続散文つきの行から偽の id を拾わない" "$ERR" 'reason=id_malformed'
assert_grep "TC-4.16n 独立行の marker (id=11) で解決する" "$ERR" 'outcome=updated; count=2; iteration_id=9-420; comment_id=11; degraded=0'
GH_COMMENT_GET_LOGIN='other-user' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_DECOY_TAIL" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-421 --content-file "$NBR_BODY_C2"
assert "TC-4.16n' fallback 経由で永続化: exit 0" "0" "$RC"
assert_grep "TC-4.16n' 後続散文つきの行を消さない" "$GH_PR_EDIT" '(注記: この行は marker ではない)'

GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_DECOY_HEAD" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-422 --content-file "$NBR_BODY_C2"
assert "TC-4.16n'' 先行散文 + 行末 marker: exit 0" "0" "$RC"
assert_not_grep "TC-4.16n'' 先行散文つきの行から偽の id を拾わない" "$ERR" 'reason=id_malformed'
assert_grep "TC-4.16n'' 独立行の marker (id=11) で解決する" "$ERR" 'outcome=updated; count=2; iteration_id=9-422; comment_id=11; degraded=0'
GH_COMMENT_GET_LOGIN='other-user' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_DECOY_HEAD" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-423 --content-file "$NBR_BODY_C2"
assert "TC-4.16n''' fallback 経由で永続化: exit 0" "0" "$RC"
assert_grep "TC-4.16n''' 先行散文つきの行を消さない" "$GH_PR_EDIT" '例: <!-- rite:nbr:comment-id:BROKEN -->'

# TC-4.16o [cycle 2 F-16 対応] marker 行が CRLF / 字下げ / 末尾空白を伴っても durable id 経路が
# 成立する。両式の行頭・行末が空白を許容しないと 3 形とも「marker 不在」に畳まれ、本 Issue の
# 中核保証 (AC-1) が WARNING 1 行も出さずに失われる。
for _fx in "CRLF:$NBR_PRBODY_CRLF_ID11:9-424" "INDENT:$NBR_PRBODY_INDENT_ID11:9-425" "TRAILING:$NBR_PRBODY_TRAILING_ID11:9-426"; do
  _fx_label="${_fx%%:*}"; _fx_rest="${_fx#*:}"; _fx_path="${_fx_rest%%:*}"; _fx_iter="${_fx_rest##*:}"
  GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$_fx_path" \
    run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id "$_fx_iter" --content-file "$NBR_BODY_C2"
  assert "TC-4.16o [$_fx_label] exit 0" "0" "$RC"
  assert_grep "TC-4.16o [$_fx_label] id 経路で解決する (comment_id=11)" "$ERR" "outcome=updated; count=2; iteration_id=$_fx_iter; comment_id=11; degraded=0"
  assert_not_grep "TC-4.16o [$_fx_label] UNRESOLVED marker を出さない" "$ERR" 'NONBLOCKING_ID_UNRESOLVED'
  assert_not_grep "TC-4.16o [$_fx_label] id 経路なので PR body を書き直さない" "$GH_LOG" '^pr edit'
done
# 上のループは **抽出側**しか通らない (id 経路は永続化を skip するため)。除去側は fallback 経由でしか
# 観測できないので、同じ 3 形を author 不一致で fallback へ倒して張り直させ、**marker 行が 1 本のまま**
# であることを固定する。除去式だけを行末空白に不寛容へ戻す mutation はここでしか落ちない
# (抽出側が通っていても、除去が外れれば marker 行は cycle ごとに積む)。
for _fx in "CRLF:$NBR_PRBODY_CRLF_ID11:9-424b" "INDENT:$NBR_PRBODY_INDENT_ID11:9-425b" "TRAILING:$NBR_PRBODY_TRAILING_ID11:9-426b"; do
  _fx_label="${_fx%%:*}"; _fx_rest="${_fx#*:}"; _fx_path="${_fx_rest%%:*}"; _fx_iter="${_fx_rest##*:}"
  GH_COMMENT_GET_LOGIN='other-user' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$_fx_path" \
    run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id "$_fx_iter" --content-file "$NBR_BODY_C2"
  assert "TC-4.16o'''' [$_fx_label] fallback 経由で永続化: exit 0" "0" "$RC"
  _o_marker_count=$(grep -c 'rite:nbr:comment-id:' "$GH_PR_EDIT" || true)
  assert "TC-4.16o'''' [$_fx_label] 旧 marker を除去して 1 本に保つ" "1" "$_o_marker_count"
done

# TC-4.16o' [cycle 2 F-16 対応] marker 行は実在するが値を取り出せない形は、「marker 不在」ではなく
# id_malformed として loud に落とす。畳むと PR body 側の破損が無音になり、helper 自身の形状定義
# コメントが避けると宣言している状態が成立する。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_BROKEN_SHAPE" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-427 --content-file "$NBR_BODY_C2"
assert "TC-4.16o' 値が空の marker 行: exit 0" "0" "$RC"
assert_grep "TC-4.16o' reason=id_malformed; action=fallback (無音にしない)" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_malformed; action=fallback'
assert_grep "TC-4.16o' 本文照合の fallback で記録は継続する" "$ERR" 'outcome=updated; count=2; iteration_id=9-427; comment_id=13; degraded=0'
# marker を持たない PR body は従来どおり無音 (正常系)。probe が緩すぎると初回 cycle で毎回
# id_malformed が出る誤検出になるため、negative control を対で置く。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_PLAIN" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-428 --content-file "$NBR_BODY_C2"
assert_not_grep "TC-4.16o'' marker 不在は正常系 (marker を出さない)" "$ERR" 'NONBLOCKING_ID_UNRESOLVED'
# 散文中に marker 同形の文字列があるだけの PR body も破損ではない (この機構を説明する PR 説明が
# この形になる)。**この fixture は正規の marker 行を持たない** — 併記すると抽出が成功して probe 分岐に
# 到達せず assert が空振りし、probe の `^` を外す mutation を落とせない (cycle 3 F-30)。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_PROSE_TAIL" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-429 --content-file "$NBR_BODY_C2"
assert "TC-4.16o''' 行末が marker 形の散文のみ: exit 0" "0" "$RC"
assert_not_grep "TC-4.16o''' 散文中の同形文字列を破損と誤検出しない" "$ERR" 'reason=id_malformed'
assert_grep "TC-4.16o''' marker 不在として fallback で記録は継続する" "$ERR" 'outcome=updated; count=2; iteration_id=9-429; comment_id=13; degraded=0'
# 字下げ付きの破損 marker も loud に落とす。probe の行頭 [[:space:]]* を外す mutation はここでしか
# 落ちない (字下げなしの $NBR_PRBODY_BROKEN_SHAPE では素通りする)。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_BROKEN_INDENT" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-429b --content-file "$NBR_BODY_C2"
assert "TC-4.16o-5 字下げされた破損 marker: exit 0" "0" "$RC"
assert_grep "TC-4.16o-5 reason=id_malformed; action=fallback (字下げでも無音にしない)" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_malformed; action=fallback'
# 破損と判定した行は **除去もできる** ことを固定する (probe と除去式が同一の正規表現から導出される
# ことの帰結)。受理集合が食い違うと「破損と言いながら消せない」= hint の「張り直します」が偽になる。
_o_broken_lines=$(grep -c 'rite:nbr:comment-id:' "$GH_PR_EDIT" || true)
assert "TC-4.16o-5 破損 marker 行を除去して 1 本に保つ" "1" "$_o_broken_lines"

# TC-4.16o-6 [cycle 3 F-34 対応] probe と除去式の受理集合が一致していることを固定する。
# 行頭が marker 接頭辞で後ろに散文が続く行は、除去式が「行全体が marker 形」を要求して残すのだから、
# probe も破損と判定してはならない (判定だけして消せない = hint の「張り直します」が偽になる)。
# probe を接頭辞一致へ戻す mutation はここでしか落ちない。
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_PROSE_HEAD" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-429c --content-file "$NBR_BODY_C2"
assert "TC-4.16o-6 行頭 marker + 後続散文のみ: exit 0" "0" "$RC"
assert_not_grep "TC-4.16o-6 除去できない行を破損と判定しない" "$ERR" 'reason=id_malformed'
assert_grep "TC-4.16o-6 marker 不在として fallback で記録は継続する" "$ERR" 'outcome=updated; count=2; iteration_id=9-429c; comment_id=13; degraded=0'
assert_grep "TC-4.16o-6 後続散文つきの行を消さない" "$GH_PR_EDIT" '(注記: この行は marker ではない)'

# TC-4.16p [cycle 2 F-17 対応] durable id が **同一 PR の記録コメント以外** を指すとき PATCH しない。
# PR body は書き込み権限を持たない PR 作成者でも編集でき、marker を 1 行足すだけで PATCH 先を
# 指し替えられる。author 一致 + 所属 PR 一致だけでは同 PR のレビュー結果コメント等が素通りし、
# その本文が記録コメント本文で丸ごと破壊される (fallback 側が 3 述語を持つのはこれを防ぐため)。
GH_COMMENT_GET_BODY='## 📜 rite レビュー結果

blocking 指摘 3 件

<!-- rite:review-result:v1 -->
' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-430 --content-file "$NBR_BODY_C2"
assert "TC-4.16p 記録コメント以外を指す id: exit 0" "0" "$RC"
assert_grep "TC-4.16p reason=id_target_not_record; action=fallback" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_target_not_record; action=fallback'
assert_not_grep "TC-4.16p 記録コメントでない id=11 を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'
assert_grep "TC-4.16p 本文照合の fallback へ倒れて記録は継続する" "$ERR" 'outcome=updated; count=2; iteration_id=9-430; comment_id=13; degraded=0'
# marker 見出しは持つが sentinel を欠く形 (sentinel 導入前の記録コメント / marker を写した人間の
# コメント) も同様に弾く。述語の連言のうち **sentinel 側を丸ごと削除する** mutation をここで落とす。
# ただし上の TC-4.16p と本 TC はどちらも 2 つの conjunct を**同時に** false にするため、
# 「片側だけを弱める」mutation は落とせない — それは下の TC-4.16p'' / p''' が担う (cycle 3 F-29)。
GH_COMMENT_GET_BODY='## 📜 rite 非実測指摘の記録 (non-blocking)

sentinel を持たない
' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-431 --content-file "$NBR_BODY_C2"
assert_grep "TC-4.16p' marker はあるが sentinel を欠く id も弾く" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_target_not_record; action=fallback'
assert_not_grep "TC-4.16p' sentinel を欠く id=11 を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'

# TC-4.16p'' [cycle 3 F-29 対応] **marker 側 conjunct だけ**が false の body。1 行目は散文で、
# marker 見出しを本文中に引用し、最終非空行は sentinel と等しい — 記録コメントの raw を写した
# 人間のメモが取る形そのもの。`startswith($marker)` を `contains` へ弱める mutation と、marker 側
# conjunct を丸ごと削除する mutation は、**ここでしか落ちない** (上の 2 TC はどちらも 2 conjunct を
# 同時に false にするため、片側の弱化では判定が変わらない)。
GH_COMMENT_GET_BODY='以下は記録コメントの写しです

## 📜 rite 非実測指摘の記録 (non-blocking)

x

<!-- rite:nbr:v1 -->
' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-432 --content-file "$NBR_BODY_C2"
assert "TC-4.16p'' marker 側のみ false: exit 0" "0" "$RC"
assert_grep "TC-4.16p'' 1 行目が marker でない id を弾く (前方一致は位置固定)" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_target_not_record; action=fallback'
assert_not_grep "TC-4.16p'' 引用された人間コメント (id=11) を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'

# TC-4.16p''' [cycle 3 F-29 対応] **sentinel 側 conjunct だけ**が false の body。1 行目は marker
# 見出しで、sentinel は本文**途中**にあり、最終非空行は別の行。最終非空行の等値を `contains` へ
# 弱める mutation は、ここでしか落ちない (TC-4.16p' の body は sentinel をどこにも持たないため、
# 位置固定を外しても判定が変わらない)。
GH_COMMENT_GET_BODY='## 📜 rite 非実測指摘の記録 (non-blocking)

<!-- rite:nbr:v1 -->

この行が最終非空行なので記録コメントではない
' GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-433 --content-file "$NBR_BODY_C2"
assert "TC-4.16p''' sentinel 側のみ false: exit 0" "0" "$RC"
assert_grep "TC-4.16p''' sentinel が最終非空行でない id を弾く (等値は位置固定)" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_target_not_record; action=fallback'
assert_not_grep "TC-4.16p''' sentinel を途中に持つコメント (id=11) を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'

# TC-4.16q [cycle 2 F-21 / F-19 対応] 静的 pin: `_persist_comment_id` が使う tempfile 3 本
# (作業用 / 自分の stderr / 呼び出し元 stderr の退避枠) はグローバルに持ち、EXIT / signal trap の
# 回収対象に載せる。関数ローカルに閉じると gh 実行中の INT/TERM/HUP で TMPDIR に残る
# (TC-4.11k' と同じく signal-timing テストは racy なため、宣言位置の静的 pin で代替する)。
_q_nbr_sh="$PLUGIN_ROOT/hooks/review-nonblocking-record.sh"
_q_cleanup_line=$(grep -n 'rm -f "\${gh_err:-}"' "$_q_nbr_sh" | head -1)
for _q_var in id_persist_tmp id_persist_err id_persist_prev_err; do
  case "$_q_cleanup_line" in
    *"\${$_q_var:-}"*) _q_in_cleanup="yes" ;;
    *)                 _q_in_cleanup="no" ;;
  esac
  assert "TC-4.16q $_q_var が cleanup の rm -f 対象" "yes" "$_q_in_cleanup"
  # 関数ローカルへ戻す mutation を落とす (cleanup 側の grep だけでは検出できない)。
  # **禁止したい表記を列挙する denylist にしない** — bash では `local` / `declare` / `typeset` が
  # いずれも関数内で同じスコープを作るため、`local` だけを見る形は表記を替えるだけで素通りする
  # (measured-gate-record.md#static-pin 規則 3「現行表記への係留を避ける」)。関数スコープを作りうる
  # キーワード全体を allowlist として並べ、そのどれも当該変数を宣言していないことを固定する。
  if grep -qE "^[[:space:]]*(local|declare|typeset)[[:space:]].*\b$_q_var\b" "$_q_nbr_sh"; then
    _q_is_local="yes"
  else
    _q_is_local="no"
  fi
  assert "TC-4.16q $_q_var を関数スコープ宣言に戻していない" "no" "$_q_is_local"
  # 「初期化がトップレベルにあること」を最初の関数定義との行番号比較で固定する形は**採らない** —
  # 無関係な helper 関数を上に足しただけで、コードが正しいまま pin だけが落ちる (`local` の
  # denylist を allowlist へ反転したのと同じ false precision)。かつ、それが捕捉するとされる
  # 「宣言キーワード無しで関数内代入する」形は bash ではグローバルへの代入であって欠陥ではない。
  # 上の allowlist だけで `local` / `declare` / `typeset` いずれの差し戻しも落ちる (mutation 実測済み)。
done

# TC-4.16l [degraded 非回帰の positive control] 自 login が取れないときは id 経路も評価できないため
# 従来どおり degraded=1。段 1 を「自 login 不要」に緩める mutation をここで落とす。
GH_ME_RC=1 GH_LOOKUP_JSON="$NBR_COMMENTS" GH_PR_BODY="$NBR_PRBODY_ID11" \
  run_nbr --pr 9 --owner-repo o/r --count 2 --iteration-id 9-416 --content-file "$NBR_BODY_C2"
assert "TC-4.16l 自 login 不明: exit 0" "0" "$RC"
assert_grep "TC-4.16l id があっても degraded=1 のまま created へ縮退" "$ERR" 'outcome=created; count=2; iteration_id=9-416; comment_id=; degraded=1'
assert_not_grep "TC-4.16l author 未検証の id=11 を PATCH しない" "$GH_LOG" 'issues/comments/11 -X PATCH'
# 段 1 自体を通っていないことの弁別: 個別 GET (`api repos/.../issues/comments/11`) が 1 度も
# 走らない。`pr view` では弁別できない — create 経路の id 永続化が同じ API を呼ぶため。
assert_not_grep "TC-4.16l 自 login 不明なら id の解決自体を試みない (個別 GET を叩かない)" "$GH_LOG" '^api repos/o/r/issues/comments/11'
assert_not_grep "TC-4.16l 段 1 を通らないので UNRESOLVED marker も出ない" "$ERR" 'NONBLOCKING_ID_UNRESOLVED'

# =====================================================================
# TC-4.17 / TC-4.18 [the governing rationale]: ポインタのみ本文の受理と旧 6 列記録との互換
# =====================================================================
echo "--- TC-4.17/4.18: pointer-only 本文  ---"

# TC-4.17 [the governing rationale] `-` 入りの `file:line` セルを含む本文が helper の本文検査 4 段を素通り
# すること (= 規約どおり書いた本文が弾かれないこと) を固定する。**規約そのもの (行を落とさず `-`
# を入れる) を pin するのは TC-5i 側**で、helper は表の行数も列も検査しないため本 TC では弁別
# できない — 下の negative control がその事実を実測で示す。3 行 (うち 1 行が `-`) / 申告 3 の
# 整合ペアで、count 検査が通り投稿されることまで見る。
NBR_BODY_DASH="$TMP_ROOT/nbr-body-dash.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| レビュアー | 重要度 | ファイル:行 |\n|-----------|--------|------------|\n| security-reviewer | CRITICAL | src/db/users.ts:42 |\n| code-quality-reviewer | MEDIUM | - |\n| test-reviewer | LOW | t/a.test.sh:7 |\n\n> 各指摘の詳細は `.rite/review-results/9-*.json` の `non_blocking_findings[]` にあります。\n\n📎 non_blocking_count: 3\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_DASH"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 3 --iteration-id 9-501 --content-file "$NBR_BODY_DASH"
assert "TC-4.17 file:line がハイフン (-) の行を含む本文: exit 0" "0" "$RC"
assert_grep "TC-4.17 outcome=created (本文検査 4 段を通過し投稿される)" "$ERR" 'outcome=created; count=3; iteration_id=9-501;'
assert_not_grep "TC-4.17 count_body_mismatch にならない (申告 3 と --count 3 が一致)" "$ERR" 'reason=count_body_mismatch'
# [negative control] positive との差分を **1 変数 (行を 1 本落としただけ)** に保つ。所在行など
# 他の要素は positive と同一にすること — 2 変数差分にすると「どちらの差が結果を変えなかったか」
# が言えなくなる。行を落として 2 行にすると申告 3 と食い違うが、helper は行数を見ないためここは
# 通る。これは helper の現行挙動 (行数検査なし = caller 責務) の意図的な lock-in であり、将来
# helper 側へ行数検査を移す場合は本 assert を意図的に更新すること。この assertion が無いと
# TC-4.17 の positive だけでは「helper が行数を検査している」と誤読しうる。
NBR_BODY_DROPPED="$TMP_ROOT/nbr-body-dropped.md"
printf '## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| レビュアー | 重要度 | ファイル:行 |\n|-----------|--------|------------|\n| security-reviewer | CRITICAL | src/db/users.ts:42 |\n| test-reviewer | LOW | t/a.test.sh:7 |\n\n> 各指摘の詳細は `.rite/review-results/9-*.json` の `non_blocking_findings[]` にあります。\n\n📎 non_blocking_count: 3\n📎 reviewed_commit: abc\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_DROPPED"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS" run_nbr --pr 9 --owner-repo o/r --count 3 --iteration-id 9-502 --content-file "$NBR_BODY_DROPPED"
assert_grep "TC-4.17 [negative control] 行を落としても helper は検出しない (行数は caller 責務)" "$ERR" 'outcome=created; count=3; iteration_id=9-502;'

# TC-4.18 [T-05 / AC-5] 旧 6 列形式の記録コメントが PR 上に既存としてあるとき、新形式 (3 列) で
# update-in-place される。lookup 述語が見るのは 1 行目 marker への前方一致と最終非空行 sentinel の
# 2 つだけで**列構成に非依存**なので、列を変えても孤児化・重複作成は起きない — この非依存性が
# AC-5 の根拠であり、述語に本文形状 (列見出し等) を足す退行をここで落とす。
NBR_LEGACY6="$TMP_ROOT/nbr-legacy-6col.json"
cat > "$NBR_LEGACY6" <<'EOF'
[[{"id":71,"user":{"login":"rite-bot"},"body":"## 📜 rite 非実測指摘の記録 (non-blocking)\n\n| レビュアー | 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |\n|-----------|--------|----------|------------|------|---------|\n| security-reviewer | CRITICAL | current-pr | src/db/users.ts:42 | 旧形式の全文 | 旧形式の推奨対応 |\n\n📎 non_blocking_count: 1\n📎 reviewed_commit: old\n\n<!-- rite:nbr:v1 -->\n"}]]
EOF
GH_LOOKUP_JSON="$NBR_LEGACY6" run_nbr --pr 9 --owner-repo o/r --count 3 --iteration-id 9-503 --content-file "$NBR_BODY_DASH"
assert "TC-4.18 旧 6 列の既存コメント: exit 0" "0" "$RC"
assert_grep "TC-4.18 outcome=updated (新形式で update-in-place)" "$ERR" 'outcome=updated; count=3; iteration_id=9-503; comment_id=71;'
assert_not_grep "TC-4.18 LEGACY_ORPHAN を emit しない (sentinel を持つため孤児ではない)" "$ERR" 'NONBLOCKING_LEGACY_ORPHAN'
assert_not_grep "TC-4.18 DUPLICATE_RECORD を emit しない (1 件しかない)" "$ERR" 'NONBLOCKING_DUPLICATE_RECORD'
assert_not_grep "TC-4.18 新規作成へ縮退しない" "$ERR" 'degraded=1'
assert_grep "TC-4.18 PATCH 先が既存 id=71 (新規 create ではない)" "$GH_LOG" 'issues/comments/71 -X PATCH'

# =====================================================================
# TC-4.12 [F-03 指摘, cycle 6]: pending marker lifecycle の per-reason 振る舞い
# =====================================================================
# 8.0.3 の機械強制へ差し戻す境界は **原因** で引く (exit code ではない):
#   - caller (LLM) 契約違反 → marker を残す (差し戻せば 1 iteration で収束する)
#   - gh / network / IO 起因 → marker を消す (差し戻しても同 cycle 内で収束しない)
#   - 正常終了 (created / updated / skipped) → marker を消す
# 本 TC が固定する軸: marker 保持/削除の境界は exit code (trap 設置の前後) ではなく **原因** で引く。
# exit code で引くと、本文検査段の契約違反だけが gh outage と同じ扱いで marker を失い、
# 8.0.3 を素通りする。TC-5b の静的 pin は「削除文が
# cleanup 区間内に 1 本」しか固定せず、**どの reason が marker を残すか**を検証していなかった
# ため、この分類の回帰を検出できなかった。本 TC は等値 assert でその軸を固定する。
echo "--- TC-4.12: pending marker lifecycle (per-reason) ---"
NBR_BODY_EMPTY="$TMP_ROOT/nbr-body-empty.md"
: > "$NBR_BODY_EMPTY"
NBR_BODY_NOMARK="$TMP_ROOT/nbr-body-nomarker.md"
printf 'ERROR: something went wrong\n\n📎 non_blocking_count: 2\n\n<!-- rite:nbr:v1 -->\n' > "$NBR_BODY_NOMARK"

# marker を張ってから helper を走らせ、走行後に marker が残っているかを yes/no で返す。
# TMPDIR は helper の導出式 (`${TMPDIR:-/tmp}/rite-nbr-pending-<id>`) と同一の値を渡す必要がある。
_nbr_marker_after() {  # $1=iteration_id, 残りは run_nbr へ渡す引数
  local iid="$1"; shift
  local marker="${TMPDIR:-/tmp}/rite-nbr-pending-${iid}"
  : > "$marker"
  run_nbr "$@"
  if [ -e "$marker" ]; then rm -f "$marker"; printf '%s' "yes"; else printf '%s' "no"; fi
}

# (1) caller 契約違反 4 種 → marker RETAIN (8.0.3 が差し戻す)
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS"
assert "TC-4.12a body_file_empty は marker を残す" "yes" \
  "$(_nbr_marker_after 9-301 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-301 --content-file "$NBR_BODY_EMPTY")"
assert "TC-4.12b body_marker_missing は marker を残す" "yes" \
  "$(_nbr_marker_after 9-302 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-302 --content-file "$NBR_BODY_NOMARK")"
assert "TC-4.12c body_sentinel_missing は marker を残す" "yes" \
  "$(_nbr_marker_after 9-303 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-303 --content-file "$NBR_BODY_NOSENT")"
assert "TC-4.12d count_body_mismatch は marker を残す" "yes" \
  "$(_nbr_marker_after 9-304 --pr 9 --owner-repo o/r --count 5 --iteration-id 9-304 --content-file "$NBR_BODY_C2")"
# content_file_missing は trap 設置**前**の exit 1 なので構造的に marker が残る (境界の対称性確認)
assert "TC-4.12e content_file_missing は marker を残す (trap 前 exit 1)" "yes" \
  "$(_nbr_marker_after 9-305 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-305 --content-file "$TMP_ROOT/nbr-does-not-exist.md")"

# (2) gh / IO 起因 → marker DELETE (非ブロッキング契約を gate 側へ持ち込まない)
GH_STUB_RC=1
assert "TC-4.12f create_failed は marker を消す (gh 起因)" "no" \
  "$(_nbr_marker_after 9-306 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-306 --content-file "$NBR_BODY_C2")"
GH_STUB_RC=0
GH_LOOKUP_JSON="$NBR_COMMENTS" GH_STUB_RC=1
assert "TC-4.12g patch_failed は marker を消す (gh 起因)" "no" \
  "$(_nbr_marker_after 9-307 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-307 --content-file "$NBR_BODY_C2")"
GH_STUB_RC=0
GH_ME_RC=1
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS"
assert "TC-4.12h lookup degraded は marker を消す (gh 起因)" "no" \
  "$(_nbr_marker_after 9-308 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-308 --content-file "$NBR_BODY_C2")"
GH_ME_RC=0
# [the contract の MUST NOT] durable id の永続化失敗も環境/IO 起因であり、caller が本文を作り直しても
# 解消しない。retain 側へ落とすと 8.0.3 が毎 cycle 差し戻し、result pattern を永久に emit できなくなる。
GH_PR_EDIT_RC=1
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS"
assert "TC-4.12h' id 永続化の失敗は marker を消す (環境/IO 起因)" "no" \
  "$(_nbr_marker_after 9-312 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-312 --content-file "$NBR_BODY_C2")"
GH_PR_EDIT_RC=0

# (3) 正常終了 3 種 → marker DELETE
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS"
assert "TC-4.12i outcome=created は marker を消す" "no" \
  "$(_nbr_marker_after 9-309 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-309 --content-file "$NBR_BODY_C2")"
GH_LOOKUP_JSON="$NBR_COMMENTS"
assert "TC-4.12j outcome=updated は marker を消す" "no" \
  "$(_nbr_marker_after 9-310 --pr 9 --owner-repo o/r --count 2 --iteration-id 9-310 --content-file "$NBR_BODY_C2")"
GH_LOOKUP_JSON="$NBR_EMPTY_COMMENTS"
assert "TC-4.12k outcome=skipped は marker を消す (AC-4 正常系)" "no" \
  "$(_nbr_marker_after 9-311 --pr 9 --owner-repo o/r --count 0 --iteration-id 9-311 --content-file "$NBR_BODY_C0")"

# =====================================================================
# TC-4.13 [F-06 指摘, cycle 6]: 8.0.3 Pre-Check (機械強制 bash) の分岐を **実行**する
# =====================================================================
# 8.0.3 の Pre-Check は本 PR で実行可能な bash block になったが、その 4 分岐を実行するテストが
# 1 件も無く静的 pin のみで担保されていた。AC-5 (「step 1-2 を skip した場合に gate が ERROR を
# 出す」) を直接検証したテストが存在しない状態だったため、SKILL.md から fence を抽出して実行し、
# rc と retained flag を等値 assert する。抽出は「8.0.3 節の最初の ```bash fence」で、fence が
# 見つからなければ fail で loud に落とす (vacuous pass を作らない)。
echo "--- TC-4.13: 8.0.3 Pre-Check の実行テスト (AC-5) ---"
_P8_MD="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
_P8_FENCE="$TMP_ROOT/p803-precheck.sh"
awk '
  !inside && /^### 8\.0\.3 / { inside = 1; next }
  inside && /^### / { exit }
  inside && !infence && /^```bash$/ { infence = 1; next }
  inside && infence && /^```[[:space:]]*$/ { exit }
  inside && infence { print }
' "$_P8_MD" > "$_P8_FENCE"
if [ ! -s "$_P8_FENCE" ]; then
  fail "TC-4.13 precondition: 8.0.3 節から Pre-Check の bash fence を抽出できません"
else
  pass "TC-4.13 precondition: 8.0.3 の Pre-Check fence を抽出できた ($(grep -c . "$_P8_FENCE") 行)"
  # placeholder を実値へ置換して実行するヘルパー。rc と stderr を返す。
  _run_p803() {  # $1=pending_marker の置換値
    P8_RC=0
    sed "s|{pending_marker}|$1|" "$_P8_FENCE" > "$_P8_FENCE.run"
    bash "$_P8_FENCE.run" >"$OUT" 2>"$ERR" || P8_RC=$?
  }

  # (a) marker 残存 → ERROR + exit 1 (AC-5 の本体: 6.1.d を skip した cycle を機械的に落とす)
  _p8_marker="$TMP_ROOT/p803-marker-present"
  : > "$_p8_marker"
  _run_p803 "$_p8_marker"
  assert "TC-4.13a marker 残存: exit 1 (gate 失敗)" "1" "$P8_RC"
  assert_grep "TC-4.13a retained flag に reason=pending_marker_present" "$ERR" 'NONBLOCKING_GATE_FAILED=1; reason=pending_marker_present'
  # ACTION は 2 分岐 (caller 契約違反なら本文を作り直す / 6.1.d 未実行なら step 1-2 を実行) を
  # 提示する必要がある。片方だけになると「同一 content-file で step 2 だけ再実行」へ誘導され、
  # 本文検査 4 段の差し戻しが収束しない (F-04, cycle 7)。
  assert_grep "TC-4.13a ACTION が本文検査 4 reason の確認を先に指示" "$ERR" 'reason=body_file_empty / body_marker_missing / body_sentinel_missing / count_body_mismatch のいずれかがあるか確認'
assert_grep "TC-4.13a ACTION が body_check_unavailable を対象外と明示" "$ERR" 'body_check_unavailable は対象外'
  assert_grep "TC-4.13a ACTION が本文の作り直しを指示 (契約違反側)" "$ERR" '本文を作り直してから'
  # assert_grep は ERE のため丸括弧は使わない (グループとして解釈され literal 一致しない)
  assert_grep "TC-4.13a ACTION が step 1-2 の実行を指示 (未実行側)" "$ERR" '6\.1\.d 自体が未実行です'
  # gate 自身が marker を削除しないこと (削除すると再評価だけで通せる)
  if [ -e "$_p8_marker" ]; then pass "TC-4.13a gate は marker を削除しない"; else fail "TC-4.13a gate は marker を削除しない"; fi
  rm -f "$_p8_marker"

  # (b) marker 不在 → pass
  _run_p803 "$TMP_ROOT/p803-marker-absent"
  assert "TC-4.13b marker 不在: exit 0 (pass)" "0" "$P8_RC"
  assert_grep "TC-4.13b retained flag に reason=pending_marker_absent" "$ERR" 'NONBLOCKING_GATE=pass; reason=pending_marker_absent'

  # (c) placeholder 未置換 → degraded (機械強制を skip し prose 判定へ)
  P8_RC=0
  bash "$_P8_FENCE" >"$OUT" 2>"$ERR" || P8_RC=$?
  assert "TC-4.13c placeholder 未置換: exit 0 (degraded)" "0" "$P8_RC"
  assert_grep "TC-4.13c retained flag に reason=pending_marker_placeholder_residue" "$ERR" 'NONBLOCKING_GATE=degraded; reason=pending_marker_placeholder_residue'

  # (d) 空値 (6.1.a step 0 が marker を作れなかった) → degraded
  _run_p803 ""
  assert "TC-4.13d 空値: exit 0 (degraded)" "0" "$P8_RC"
  assert_grep "TC-4.13d retained flag に reason=pending_marker_unavailable" "$ERR" 'NONBLOCKING_GATE=degraded; reason=pending_marker_unavailable'
fi

# =====================================================================
echo "=== TC-5: skills/pr-review/SKILL.md 静的 pin (6.1.d / 8.0.3) ==="
# =====================================================================
# 6.1.d の記録経路と実行保証 gate のうち、**prose 部分**(分岐表・ACTION 文・順序規定) は markdown
# 埋め込みのため実行テストできない。silent failure に直結する契約だけを静的に固定する。
# なお 8.0.3 の Pre-Check は実行可能な bash block であり、その 4 分岐は **TC-4.13 が fence を
# 抽出して実際に実行**する (静的 pin だけに頼らない)。本 TC-5 が担うのは prose 部分と、
# 実行テストでは届かない「どこに何が書かれているか」の配置契約。**pin を追加・変更するときは、その場で
# mutation (述語置換 / 死に分岐化 / 変数リネーム / 散文追加 / 区間境界変更) を当て、落ちること
# および無害な変更では落ちないことを実測してから commit する**。手順は下記 rationale を参照。
# rationale: ../../skills/pr-review/references/measured-gate-record.md#static-pin
REVIEW_MD="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
if [ ! -f "$REVIEW_MD" ]; then
  fail "TC-5 precondition: skills/pr-review/SKILL.md が存在しません"
else
  # [prompt-engineer F-02 指摘, cycle 4]: 区間 pin の終端を `^### 8\.1 ` のような**特定の次節**へ
  # ハードコードすると、その手前に新節 (8.0.4 等) が挿入されたとき区間が新節を飲み込み、
  # `assert_grep_in_section` 系は新節の該当行を拾って **vacuous に pass** する (元の節から当該行を
  # 削除しても検出できなくなる)。実測: SKILL.md 8.0 節末の新 gate 追加手順どおり 8.0.4 を 8.0.3 と 8.1 の
  # 間へ追加すると TC-5b の 2 assertion が expected=1 actual=2 で落ちた
  # (手順の見出し番号はゲート追加のたびに繰り上がるため、リテラル引用では参照先が腐る)。
  # TC-5e 層 3 が既に採っている「次の同レベル見出しまで」を全区間 pin の共通 idiom に統一する。
  # `_section_of <start-regex> <heading-level-regex>` は開始行の次から最初に現れる見出しの直前
  # までを stdout に出す。開始行が見つからなければ空を返す (呼び出し側の件数 assert が loud に落ちる)。
  # 正規表現は ENVIRON 経由で渡す。`awk -v` は代入時にバックスラッシュエスケープを解釈するため、
  # `'^### 8\.0 '` を渡すと (a) 警告が毎回 stderr に出て、(b) awk が受け取る実正規表現が
  # `^### 8.0 ` になり `.` が任意 1 文字へ弱まる (見出しアンカーがコードの見た目より緩くなる)。
  # ENVIRON はエスケープを解釈しないため、書いたとおりの ERE が awk に届く。
  _section_of() {
    start_re="$1" head_re="$2" awk '
      !inside && $0 ~ ENVIRON["start_re"] { inside = 1; print; next }
      inside && $0 ~ ENVIRON["head_re"] { exit }
      inside { print }
    ' "$REVIEW_MD"
  }
  # 6.1.d は h4 なので同レベル (h4) または上位 (h3) の見出しで閉じる。8.0.3 は h3。
  _sec_610d() { _section_of '^#### 6\.1\.d ' '^(#{3}|#{4}) '; }
  _sec_803()  { _section_of '^### 8\.0\.3 ' '^### '; }
  # 区間解決そのものの健全性を先に固定する (区間が空 / 巨大化していれば以降の pin は無意味)。
  # 上限は「次の見出しで閉じる」ことの確認 — 閉じ損ねると SKILL.md 末尾まで飲み込んで数百行になる。
  _sec_610d_lines=$(_sec_610d | grep -c . || true)
  _sec_803_lines=$(_sec_803 | grep -c . || true)
  if [ "$_sec_610d_lines" -ge 20 ] && [ "$_sec_610d_lines" -le 200 ] 2>/dev/null; then
    pass "TC-5 区間解決: 6.1.d が妥当な行数で閉じる ($_sec_610d_lines 行)"
  else
    fail "TC-5 区間解決: 6.1.d の行数が想定外 ($_sec_610d_lines) — 開始 anchor 消失か終端の閉じ損ね"
  fi
  if [ "$_sec_803_lines" -ge 10 ] && [ "$_sec_803_lines" -le 200 ] 2>/dev/null; then
    pass "TC-5 区間解決: 8.0.3 が妥当な行数で閉じる ($_sec_803_lines 行)"
  else
    fail "TC-5 区間解決: 8.0.3 の行数が想定外 ($_sec_803_lines) — 開始 anchor 消失か終端の閉じ損ね"
  fi
  # grep の rc=1 (0 件 = 正常) と rc>=2 (IO エラー) を区別する。融合すると IO エラー時に
  # 変数が空文字になり「expected 1, got 」という原因不明の失敗として報告される (診断の誤誘導)。
  count_lit() {  # $1=pattern $2=label
    local out rc
    out=$(grep -cF "$1" "$REVIEW_MD"); rc=$?
    case "$rc" in
      0|1) printf '%s' "${out:-0}" ;;
      *)   echo "  TC-5: grep IO error on $2 (rc=$rc)" >&2; printf '%s' "IOERR(rc=$rc)" ;;
    esac
  }

  # (a) 6.1.d が helper を呼ぶ行が 1 箇所だけ存在し、かつ **live な bash block 内**にある。
  #     検索は**行頭 anchor 付き ERE**で行う: `grep -F` の部分一致だと行頭に `# ` を足した
  #     コメントアウト版も同じ 1 件として match し、そのコメントアウト行は同じ ```bash fence 内に
  #     留まるため直後の fence 検査も通ってしまう (= 2 文字で helper 呼び出しを無効化できるのに
  #     CI が green のまま)。行頭 anchor にすると `# bash ...` は 0 件になり検出される。
  #     fence 検査は「行頭 anchor で拾えた行が実際に bash fence の内側にあるか」を確認する
  #     (fence は番号付きリスト内にありインデントされるため fence 側も行頭 anchor は使えない)。
  nbr_invoke_line=$(grep -nE '^[[:space:]]*bash \{plugin_root\}/hooks/review-nonblocking-record\.sh' "$REVIEW_MD" | cut -d: -f1)
  nbr_invoke_count=$(printf '%s\n' "$nbr_invoke_line" | grep -c '[0-9]' || true)
  assert "TC-5a 6.1.d の helper 呼び出しが live な行として 1 箇所" "1" "$nbr_invoke_count"
  # [伝播修正, cycle 2 F-04 と同型]: 上記はファイル全体の件数で、ラベルが表明する scope (6.1.d) を
  # 検査していない。呼び出しを 6.1.d の外へ移しても件数は 1 のままだが、6.1.d を読む LLM には
  # 呼び出しが見えなくなり記録経路が実行されない。区間限定でも 1 本であることを併せて固定する。
  nbr_invoke_in_section=$(_sec_610d | grep -cE '^[[:space:]]*bash \{plugin_root\}/hooks/review-nonblocking-record\.sh' || true)
  assert "TC-5a 6.1.d 区間に helper 呼び出しが 1 箇所" "1" "$nbr_invoke_in_section"
  # 到達性 assertion を件数 pin の内側に入れない。gate すると件数 pin が落ちたとき到達性側が
  # 無言で実行されず、総 assertion 数だけが減る (赤にはなるが「何本走ったか」が変わる)。
  # 前提が崩れているときは fail で 1 本計上し、集計を安定させる。
  # 窓幅ベースの opener 計数 (直前 N 行に ```bash が 1 個あるか) はやめ、ファイル先頭から
  # fence の開閉状態を逐次追跡して「呼び出し行の時点で実際に fence が開いているか」を直接判定する。
  # 窓幅方式は (a) 閉じ fence を呼び出し行の直前へ移動する死に分岐化 (呼び出しは fence 外の
  # 散文になるが、直前 10 行に opener が 1 個残るため見逃す)、(b) fence 内に無害なコメントを
  # 数行足すだけで opener が窓の外に押し出され偽陽性 FAIL になる、の両方向で不正確だった。
  if [ "$nbr_invoke_count" = "1" ]; then
    in_fence=$(awk -v n="$nbr_invoke_line" '
      NR < n {
        if ($0 ~ /^[[:space:]]*```bash$/) { f = 1 }
        else if ($0 ~ /^[[:space:]]*```[[:space:]]*$/) { f = 0 }
      }
      NR == n { print f + 0 }
    ' "$REVIEW_MD")
    assert "TC-5a 呼び出しが live な bash fence 内にある (到達性)" "1" "$in_fence"
  else
    fail "TC-5a 呼び出しが live な bash fence 内にある (到達性) — 呼び出し行を特定できず評価不能"
  fi

  # (a-3) [F-09 指摘, cycle 7] step 1 が Write する本文パスと step 2 が `--content-file` に渡す
  #     パスは同一文字列でなければならない 2 箇所 coupling だが pin が無かった。TC-5a (a) は
  #     helper 呼び出し行の**存在と到達性**しか固定しておらず引数の値を見ていない。片側だけ改名
  #     すると production では毎 cycle content_file_missing で **trap 設置前の exit 1** となり
  #     terminal sentinel が 1 本も出ないため、6.1.d step 3 と 8.0.3 の両 gate が ERROR、かつ
  #     pending marker も残るので差し戻しループになる。SKILL.md 6.1.d step 1 の「パスに cycle 識別子を含めるのは必須」自身がこのパス構成を
  #     明記しているのに、その不変条件を機械的に確認する層が無かった。
  #     抽出失敗は `fail` で loud に落とす (TC-5c / TC-5g の抽出失敗ハンドリングと同型)。
  _p1_path=$(_sec_610d | sed -n 's/.*Write tool で `\([^`]*\)` に保存.*/\1/p' | head -1)
  _p2_path=$(_sec_610d | sed -n 's/^[[:space:]]*--content-file \([^ ]*\)[[:space:]]*\\*[[:space:]]*$/\1/p' | head -1)
  if [ -n "$_p1_path" ] && [ -n "$_p2_path" ]; then
    assert "TC-5a step 1 の Write 先と step 2 の --content-file が一致" "$_p1_path" "$_p2_path"
  else
    fail "TC-5a step1/step2 パス coupling — 抽出に失敗 (step1='$_p1_path' step2='$_p2_path')"
  fi

  # (a-2) 8.0.3 の機械強制 (pending marker 検査) が live な bash fence 内に実在する。
  #     prose gate は LLM が ERROR text を読む前提であり、読まずに result pattern へ進む経路を
  #     構造的に塞げない。marker は 6.1.d の helper (EXIT trap) でしか消えないため、gate の bash が
  #     `[ -e ]` で見るだけで「6.1.d が完走したか」を LLM の認識に依存せず判定できる。
  #     本 pin が守るのは (i) 判定式そのもの、(ii) 失敗時に非ゼロ終了すること、(iii) marker を
  #     ここで削除しないこと (削除すると 6.1.d を実行せず再評価だけで gate を通せてしまう)。
  pm_check_line=$(grep -nF 'if [ -e "$pending_marker" ]; then' "$REVIEW_MD" | cut -d: -f1)
  pm_check_count=$(printf '%s\n' "$pm_check_line" | grep -c '[0-9]' || true)
  assert "TC-5b 8.0.3 の pending marker 判定式が 1 箇所" "1" "$pm_check_count"
  assert "TC-5b 8.0.3 区間に pending marker 判定式が 1 箇所" "1" \
    "$(_sec_803 | grep -cF 'if [ -e "$pending_marker" ]; then' || true)"
  if [ "$pm_check_count" = "1" ]; then
    pm_in_fence=$(awk -v n="$pm_check_line" '
      NR < n {
        if ($0 ~ /^[[:space:]]*```bash$/) { f = 1 }
        else if ($0 ~ /^[[:space:]]*```[[:space:]]*$/) { f = 0 }
      }
      NR == n { print f + 0 }
    ' "$REVIEW_MD")
    assert "TC-5b pending marker 判定が live な bash fence 内にある (到達性)" "1" "$pm_in_fence"
  else
    fail "TC-5b pending marker 判定が live な bash fence 内にある (到達性) — 判定行を特定できず評価不能"
  fi
  # 残存検出時に非ゼロ終了すること。`exit 1` を落とすと ERROR text だけが出て gate が素通りする。
  assert "TC-5b 8.0.3 区間に marker 残存時の retained flag が 1 本" "1" \
    "$(_sec_803 | grep -cF 'NONBLOCKING_GATE_FAILED=1; reason=pending_marker_present' || true)"
  assert "TC-5b 8.0.3 区間に marker 残存時の exit 1 が 1 本" "1" \
    "$(_sec_803 | grep -cE '^[[:space:]]*exit 1$' || true)"
  # marker をこの gate で削除しない (削除すると再評価だけで通せる)。`rm -f "$pending_marker"` の不在を固定。
  assert "TC-5b 8.0.3 は pending marker を削除しない" "0" \
    "$(_sec_803 | grep -cF 'rm -f "$pending_marker"' || true)"
  # helper 側が marker を消す唯一の主体であること。**件数ではなく配置**を固定する:
  # 削除文を `_rite_p61d_cleanup` の外 (末尾 `exit 0` の直前) へ 1 行移すだけで件数は 1 のまま
  # 緑になるが、early `exit 0` で抜ける経路 (AC-4 正常系の「0 件 ∧ 既存なし」skip、および
  # 本文検査失敗) で marker が残り、8.0.3 が毎 cycle exit 1 を返して [review:mergeable] を
  # 永久に emit できないデッドロックになる。区間内 1 本 / 区間外 0 本の両方を等値で固定する
  # (TC-5a / TC-5h の「区間解決 + 件数等値」idiom と同型)。
  NBR_SH="$PLUGIN_ROOT/hooks/review-nonblocking-record.sh"
  # `_rite_p61d_cleanup() {` から対応する列 0 の `}` までを切り出す。関数定義が見つからなければ
  # 空を返し、呼び出し側の件数 assert が loud に落ちる。
  _nbr_cleanup_body() {
    awk '
      !inside && /^_rite_p61d_cleanup\(\) \{[[:space:]]*$/ { inside = 1; next }
      inside && /^\}[[:space:]]*$/ { exit }
      inside { print }
    ' "$NBR_SH"
  }
  _nbr_cleanup_lines=$(_nbr_cleanup_body | grep -c . || true)
  if [ "$_nbr_cleanup_lines" -ge 1 ] && [ "$_nbr_cleanup_lines" -le 40 ] 2>/dev/null; then
    pass "TC-5b 区間解決: _rite_p61d_cleanup が妥当な行数で閉じる ($_nbr_cleanup_lines 行)"
  else
    fail "TC-5b 区間解決: _rite_p61d_cleanup の行数が想定外 ($_nbr_cleanup_lines) — 関数名変更か閉じ括弧の消失"
  fi
  assert "TC-5b helper の cleanup **区間内** に pending marker 削除が 1 本" "1" \
    "$(_nbr_cleanup_body | grep -cF 'rm -f -- "$PENDING_MARKER"' || true)"
  assert "TC-5b helper の cleanup は marker 実在時だけ削除を試みる (-e ∨ -L)" "1" \
    "$(_nbr_cleanup_body | grep -cF '[ -e "$PENDING_MARKER" ] || [ -L "$PENDING_MARKER" ]' || true)"
  assert "TC-5b helper の cleanup は pending marker 削除 rc を検査する" "1" \
    "$(_nbr_cleanup_body | grep -cF 'if ! LC_ALL=C rm -f -- "$PENDING_MARKER"; then' || true)"
  assert "TC-5b helper の cleanup は表示前に marker path の制御文字を中和する" "1" \
    "$(_nbr_cleanup_body | grep -cF 'pending_marker_display=$(printf' || true)"
  assert "TC-5b marker 削除失敗は 8.0.3 の継続差し戻しを loud に報告する" "1" \
    "$(_nbr_cleanup_body | grep -cF 'ステップ 8.0.3 は本 cycle の 6.1.d を未実行と誤判定します' || true)"
  assert "TC-5b marker 削除失敗は手動 rm の復旧手順を示す" "1" \
    "$(_nbr_cleanup_body | grep -cF 'marker を手動で削除してからステップ 8.0 を再評価してください' || true)"
  # 区間外 0 本。ファイル全体の件数から区間内の件数を引いて求める (区間外だけを直接切り出すより
  # 「移動しても総数は変わらない」という変異の性質を素直に写す)。
  _nbr_pm_rm_total=$(grep -cF 'rm -f -- "$PENDING_MARKER"' "$NBR_SH" || true)
  _nbr_pm_rm_inside=$(_nbr_cleanup_body | grep -cF 'rm -f -- "$PENDING_MARKER"' || true)
  assert "TC-5b helper の cleanup **区間外** に pending marker 削除が 0 本" "0" \
    "$(( _nbr_pm_rm_total - _nbr_pm_rm_inside ))"

  # 6.1.a step 0 が marker を作る側であること。作成が落ちると gate は degraded 側へ倒れ機械強制が失われる。
  # [F-05 指摘, cycle 6]: 本 pin は「区間限定 + 行頭 anchor + fence 到達性」を要求する (TC-5a と同一方式)。
  # 行頭 anchor なしの部分一致・区間非限定・fence 到達性検査なしの `count_lit` 方式では、
  # 生成行に `# ` を付けるだけの死に分岐化を検出できない。6.1.a step 0 は番号付きリスト項目のため
  # `^0\. \*\*Write 先実パス解決` を開始 anchor に、次の番号付き項目 (`^1\. `) を終端にする。
  _sec_610a_step0() { _section_of '^0\. \*\*Write 先実パス解決' '^1\. '; }
  _sec_610a_step0_lines=$(_sec_610a_step0 | grep -c . || true)
  if [ "$_sec_610a_step0_lines" -ge 10 ] && [ "$_sec_610a_step0_lines" -le 120 ] 2>/dev/null; then
    pass "TC-5b 区間解決: 6.1.a step 0 が妥当な行数で閉じる ($_sec_610a_step0_lines 行)"
  else
    fail "TC-5b 区間解決: 6.1.a step 0 の行数が想定外 ($_sec_610a_step0_lines) — 開始 anchor 消失か終端の閉じ損ね"
  fi
  assert "TC-5b 6.1.a step 0 区間に pending marker パス**代入**行が 1 本 (行頭 anchor)" "1" \
    "$(_sec_610a_step0 | grep -cE '^[[:space:]]*pending_marker="\$\{TMPDIR:-/tmp\}/rite-nbr-pending-\$review_cycle_id"' || true)"
  # [F-03 指摘, cycle 7] 上は**代入**行の pin であって、marker を実際に作る文は別物。
  # 生成文を落とすと marker は永久に作られず、8.0.3 Pre-Check の `[ -e ]` が常に false になって
  # 毎 cycle `pending_marker_absent` で pass する = 機械強制層が無音の no-op に変わる
  # (実測: 生成文と emit 4 行を削除しても suite は 377/0 で緑だった)。生成文そのものを pin する。
  # `set -C` (noclobber) も同じ行で固定する — 素の `: >` は symlink を追随して任意ファイルを
  # truncate でき、かつ他者が作った既存ファイルを掴む (marker の存在/不在が gate の判定値であるため)。
  assert "TC-5b 6.1.a step 0 区間に pending marker **生成文** が 1 本 (noclobber 付き)" "1" \
    "$(_sec_610a_step0 | grep -cE '^[[:space:]]*if \( set -C; : > "\$pending_marker" \)' || true)"
  # 8.0.3 が置換入力として読む emit 行も pin する (この行を殺すと機械強制は degraded に倒れる)。
  assert "TC-5b 6.1.a step 0 区間に NONBLOCKING_PENDING_MARKER emit が 1 本 (行頭 anchor)" "1" \
    "$(_sec_610a_step0 | grep -cE '^[[:space:]]*echo "\[CONTEXT\] NONBLOCKING_PENDING_MARKER=\$pending_marker"' || true)"
  # 生成行が live な bash fence 内にあること (死に分岐化検出)。
  pm_gen_line=$(grep -nE '^[[:space:]]*pending_marker="\$\{TMPDIR:-/tmp\}/rite-nbr-pending-\$review_cycle_id"' "$REVIEW_MD" | cut -d: -f1)
  pm_gen_count=$(printf '%s\n' "$pm_gen_line" | grep -c '[0-9]' || true)
  if [ "$pm_gen_count" = "1" ]; then
    pm_gen_in_fence=$(awk -v n="$pm_gen_line" '
      NR < n {
        if ($0 ~ /^[[:space:]]*```bash$/) { f = 1 }
        else if ($0 ~ /^[[:space:]]*```[[:space:]]*$/) { f = 0 }
      }
      NR == n { print f + 0 }
    ' "$REVIEW_MD")
    assert "TC-5b pending marker 生成が live な bash fence 内にある (到達性)" "1" "$pm_gen_in_fence"
  else
    fail "TC-5b pending marker 生成が live な bash fence 内にある (到達性) — 生成行を特定できず評価不能"
  fi

  # [F-04 指摘, cycle 6]: pending marker のパスは 3 者 (6.1.a step 0 が作成 / helper が削除 /
  # 8.0.3 が検査) で結合している。TC-5c (MARKER 値 ⇄ variant 見出し) / TC-5g (count needle ⇄
  # variant テンプレート) は同型の coupling を「片側から抽出して他方に照合する」形で pin して
  # いるが、3 本目のこの coupling だけが抜けていた。片側だけ prefix を変えると作成側と削除側が
  # desync し、marker が永久に残って 8.0.3 が全 cycle で exit 1 を返す。
  # 変数名の差 (helper: `${ITERATION_ID}` / SKILL.md: `$review_cycle_id`) を正規化してから照合する。
  _pm_path_helper=$(sed -n 's/^PENDING_MARKER="\(.*\)"$/\1/p' "$NBR_SH" | head -1 \
    | sed 's/\${ITERATION_ID}/__CYCLE__/')
  _pm_path_skill=$(_sec_610a_step0 \
    | sed -n 's/^[[:space:]]*pending_marker="\(.*\)"$/\1/p' | head -1 \
    | sed 's/\$review_cycle_id/__CYCLE__/')
  if [ -n "$_pm_path_helper" ] && [ -n "$_pm_path_skill" ]; then
    assert "TC-5b pending marker のパス導出が helper と 6.1.a step 0 で一致" \
      "$_pm_path_helper" "$_pm_path_skill"
  else
    fail "TC-5b pending marker のパス導出 coupling — 抽出に失敗 (helper='$_pm_path_helper' skill='$_pm_path_skill')"
  fi

  # (b) 二層 gate (6.1.d step 3 / 8.0.3) がともに **terminal sentinel** を pass 条件にしている。
  #     動作前 marker (lookup 系) を pass 条件に戻す退行が本 pin の検出対象。
  #     pin するのは「区間内のリテラル出現数」ではなく **gate の live な Check 行そのもの**。
  #     出現数の等値 pin は双方向に誤る: Check を動作前 marker に差し替えつつ同区間に散文を
  #     1 行足すと数が相殺されて素通りし (false negative)、逆に gate 無変更の散文追加だけで
  #     落ちる (false positive)。Check 行を直接要求すれば散文に影響されず marker 差し替えを検出する。
  # [F-02 指摘, cycle 5 — test / application / error-handling の 3 reviewer が独立指摘]:
  # `assert_grep_in_section` で終端を `^### 6\.2 ` / `^### 8\.1 ` にハードコードする形は採らない。
  # `assert_grep_in_section` は内部で awk の range 形を使うため、cycle 4 で
  # 「全廃した」と表明した `sed -n "/a/,/b/p"` と機能的に同一で、新節を 8.0.x と 8.1 の間へ
  # 挿入すると区間が新節を飲み込む (presence-only なので false green にはならないが、表明と実装が
  # 食い違う #2030 F-09 型)。区間は `_sec_610d` / `_sec_803` の動的解決に統一し、あわせて
  # presence ではなく**件数 1 の等値**で固定する (区間が広がって新節の Check 行を拾えば 2 になる)。
  # 終端 anchor の存在 assert は `_section_of` が「次の同レベル以上の見出しで閉じる」ため不要になった
  # (閉じ損ねは区間解決の健全性 assert が行数レンジで捕捉する)。
  #
  # AC-7/T-06: sentinel の存在だけでは前 cycle の marker に false-positive match しうる。
  # Check 行自体が iteration_id と REVIEW_CYCLE_ID の**鮮度比較 (一致判定)** まで言及していることを
  # 要求する。単に両語の共起だけを pin すると、比較セマンティクス (「と一致するか」) を削って
  # 「が存在するか」に弱めても、REVIEW_CYCLE_ID を定義するだけの後続節に語が残っていれば素通りする
  # (cycle 3 の mutation 実測で確認)。`一致` を両語の後に置くことで比較動詞そのものの削除を検出する。
  _chk_sent_610d=$(_sec_610d | grep -cE '\*\*Check\*\*:.*NONBLOCKING_RECORD_DONE=1' || true)
  _chk_sent_803=$(_sec_803 | grep -cE '\*\*Check\*\*:.*NONBLOCKING_RECORD_DONE=1' || true)
  assert "TC-5b 6.1.d step 3 の Check が terminal sentinel を参照 (区間内 1 本)" "1" "$_chk_sent_610d"
  assert "TC-5b 8.0.3 の Check が terminal sentinel を参照 (区間内 1 本)" "1" "$_chk_sent_803"
  _chk_fresh_610d=$(_sec_610d | grep -cE '\*\*Check\*\*:.*NONBLOCKING_RECORD_DONE=1.*iteration_id.*REVIEW_CYCLE_ID.*一致' || true)
  _chk_fresh_803=$(_sec_803 | grep -cE '\*\*Check\*\*:.*NONBLOCKING_RECORD_DONE=1.*iteration_id.*REVIEW_CYCLE_ID.*一致' || true)
  assert "TC-5b 6.1.d step 3 の Check が iteration_id/REVIEW_CYCLE_ID の一致判定に言及 (区間内 1 本)" "1" "$_chk_fresh_610d"
  assert "TC-5b 8.0.3 の Check が iteration_id/REVIEW_CYCLE_ID の一致判定に言及 (区間内 1 本)" "1" "$_chk_fresh_803"
  # 上記 4 件は「トークン全体を含む Check 行が区間内にちょうど 1 本」を見るが、操作対象の
  # `**Check**:` 行を弱体化しつつ別の `**Check**:` 行を 1 本足す 2 編集では、前者が 0 本・後者が
  # パターン外のままなので件数 1 に戻らず落ちる。一方「弱体化した行がなおパターンを満たす」形の
  # 編集は件数が 1 のままになるため、`**Check**:` という**見出しラベルそのもの**の出現数を
  # 区間ごとに数えて 1 本に固定し、行の追加を独立に検出する。
  _check_label_610d=$(_sec_610d | grep -cE '\*\*Check\*\*:' || true)
  assert "TC-5b 6.1.d step 3 の \`**Check**:\` 見出しは区間内に 1 本だけ" "1" "$_check_label_610d"
  _check_label_803=$(_sec_803 | grep -cE '\*\*Check\*\*:' || true)
  assert "TC-5b 8.0.3 の \`**Check**:\` 見出しは区間内に 1 本だけ" "1" "$_check_label_803"

  # 上記 4 件の allowlist はトークンの**出現順**しか見ておらず比較の**向き**を固定していない。
  # Check を「一致しなくてもよい (存在すれば十分)」へ反転しても全トークンが同順で残る。反転が
  # production に入ると両 gate が前 cycle の stale sentinel を受理し、AC-7/T-06 が禁じる当の
  # false-positive match が成立する。
  #
  # cycle 2 はこれを「Check 行の否定形 denylist + Routing 表の『不一致 → ERROR』行の実在」の
  # 2 層で塞ごうとしたが、cycle 3 で両層とも実効性を持たないことが実測された:
  #   - denylist は 4 表現の列挙で、`一致することは要求しない` / `一致するかは問わない` のような
  #     同義形をすり抜ける。そもそも本 PR が SoT として新設した measured-gate-record.md#static-pin
  #     の規則 3「denylist ではなく allowlist で書く (現行表記への係留を避ける)」に反していた。
  #   - 「不一致 → ERROR」の grep は同一行内のトークン**出現順**しか見ておらず、Action セルを
  #     「ERROR にはしない — Gate passes」へ反転しても本数が変わらない (極性が未固定)。
  #   - どちらの層も、実際に判定を担う **pass 行の Condition 列**を拘束していなかった。
  #
  # cycle 3 はこれを「Condition 列と Action 列の対応を awk で検査する構造述語」に置き換えたが、
  # cycle 4 で**セル分割しても substring 検査のままである**ことが実測された。3 経路が残った:
  #   - 「違反 0 件」を期待する述語は、対象行が **0 本のときも 0** を返す。6.1.d の ERROR 行を
  #     丸ごと削除しても 306/0 の完全緑だった (空 domain と全件正常が観測上同一)。
  #   - `cond ~ /一致/ && cond !~ /不一致/` は「一致するかは問わない」を除外できない
  #     (`一致` を含み `不一致` を含まない)。
  #   - `act ~ /Gate passes/` が Action 先頭を要求せず、ERROR 行の文中の `Gate passes` も数える。
  #
  # 4 世代にわたる pin 強化 (合計下限 → gate ごとの下限 → 厳密等値+共起 → セル分割) が毎回
  # 「隣の穴」を残したのは、いずれも**散文に対する substring 検査**だったから。そこで軸を変え、
  # **canonical なセル文字列そのものを期待値としてリテラルに固定**する。言い換えは即 loud fail に
  # なり、意図的な変更なら期待値の更新という形で必ず人手を経る (それが「不変条件を再確認せよ」の
  # 強制になる)。substring ではなく**完全一致**なので、否定形の挿入も極性反転も原理的に通らない。
  #
  # あわせて「不変条件の対象行が実在すること」を行数の厳密等値で固定し、空 domain を排除する。
  #
  # **本 pin が保証しないこと**: Routing 表の**意味**が正しいことは保証しない (canonical 文字列
  # 自体が誤っていれば pin は誤りを固定する)。保証するのは「レビューで妥当性を確認した文字列から
  # 無断で変わらないこと」だけ。`**Check**:` 行 4 件の allowlist も従来どおりトークンの出現順しか
  # 見ないが、routing を決めるのは Routing 表であり Check 行はそれを説明する散文なので許容する。
  #
  # canonical セル: `Condition|Action` を `~` 区切りで並べる (セル内の前後空白は除去して比較)。
  #
  # [error-handling 調査推奨, cycle 4]: 6.1.d 区間には ```markdown フェンス内に variant A の
  # **サンプル表** (6 列) があり、Routing 表と同じ `|` 始まりの行として現れる。フェンス内を
  # 除外しないと行 index がずれる (実測: サンプル表のヘッダーが Routing[1] として拾われた)。
  # 「たまたま列名が衝突しないから無害」という暗黙依存を残さず、フェンスの開閉を追跡して除外する。
  _routing_rows() {  # $1=section-fn-name — Routing 表のデータ行だけを stdout に出す
    "$1" | awk '
      /^[[:space:]]*```/ { fence = !fence; next }
      fence { next }
      /^[[:space:]]*\|/ {
        split($0, c, "|")
        if (c[2] ~ /Condition/) next                       # ヘッダー行
        if (c[2] ~ /^[[:space:]]*-+[[:space:]]*$/) next    # セパレータ行
        print
      }
    '
  }
  _routing_canonical() {  # $1=section-fn-name $2=row-index(1-origin, データ行のみ)
    _routing_rows "$1" | awk -F'|' -v want="$2" '
      { n++ }
      n == want {
        cond = $2; act = $3
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cond)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", act)
        print cond "~" act
        exit
      }
    '
  }
  _routing_rowcount() {  # $1=section-fn-name
    _routing_rows "$1" | grep -c . || true
  }
  # (i) データ行数の厳密等値 — 行の削除・無断追加を検出し、以下の行 index pin の前提を保証する
  assert "TC-5b 6.1.d step 3 の Routing データ行数" "2" "$(_routing_rowcount _sec_610d)"
  assert "TC-5b 8.0.3 の Routing データ行数" "4" "$(_routing_rowcount _sec_803)"
  # (ii) Routing 全データ行を canonical 文字列で完全一致固定する。
  #      **本数だけを数える層 (TC-5e 層 3) は Action 列を変えずに Condition 列だけを
  #      狭める / 広げる編集を一切検出しない**ため、行 index ごとの完全一致が要る。
  #      特に 8.0.3 Routing[3] (sentinel なし → ERROR) は「6.1.d を丸ごと skip した cycle を
  #      捕まえる」本 gate の存在理由そのものの行で、ここが設定依存に狭められると D-01 の
  #      永続チャネルが無音でゼロになる。Routing[1] (legitimate skip) も同様に、条件を広げると
  #      本来 ERROR にすべき skip が正当化されて素通りする。
  assert "TC-5b 6.1.d step 3 Routing[1]: cycle 一致 → Gate passes (canonical)" \
    'sentinel あり かつ `iteration_id` が本 cycle の `REVIEW_CYCLE_ID` と一致 (`outcome` は問わない)~Gate passes — ステップ 6.2 へ。`outcome=failed` / `aborted`、`degraded=1`（`outcome` を問わない）、または `NONBLOCKING_LEGACY_ORPHAN=1` / `NONBLOCKING_DUPLICATE_RECORD=1` を観測したときは (ステップ 8.0.3 と同一条件 — 片側だけに置かない) helper の WARNING / `NONBLOCKING_RECORD_FAILED` の reason を completion report に転記する (判定は不変、AC-3)' \
    "$(_routing_canonical _sec_610d 1)"
  assert "TC-5b 6.1.d step 3 Routing[2]: 不一致 → ERROR (canonical)" \
    'sentinel なし、または `iteration_id` が本 cycle の `REVIEW_CYCLE_ID` と不一致 (前 cycle のもの)~**ERROR**: 6.1.d が本 cycle で未評価。下記 ACTION を実行' \
    "$(_routing_canonical _sec_610d 2)"
  assert "TC-5b 8.0.3 Routing[1]: ステップ 6 失敗 → legitimate skip (canonical)" \
    'ステップ 6 が 6.1.b hard error / 6.1.c ケース 2 (`exit 2`) で fail し 6.1.d に到達していない~Gate は legitimately skipped — 6.1.d へ戻さず **ステップ 6 の失敗として扱う** (永続化の復旧が非実測記録より優先。6.1.c ケース 2 の silent data loss 防止を無効化しないため)' \
    "$(_routing_canonical _sec_803 1)"
  assert "TC-5b 8.0.3 Routing[2]: cycle 一致 → Gate passes (canonical)" \
    'sentinel found AND `iteration_id` == 本 cycle の `REVIEW_CYCLE_ID` (`outcome` は問わない)~Gate passes — ただし `outcome=failed` / `aborted`、`degraded=1`（`outcome` を問わない）、または `NONBLOCKING_LEGACY_ORPHAN=1` / `NONBLOCKING_DUPLICATE_RECORD=1` を観測したときは **LLM が helper の WARNING / `NONBLOCKING_RECORD_FAILED` の reason を completion report に転記してから** the next gate in the 8.0 evaluation order へ進む (6.1.d step 3 と同一条件 — 片側だけに置かない)' \
    "$(_routing_canonical _sec_803 2)"
  assert "TC-5b 8.0.3 Routing[3]: sentinel なし → ERROR (canonical)" \
    'sentinel NOT found (ステップ 6 は正常完了している)~**ERROR**: ステップ 6.1.d entire procedure was skipped. Execute ACTION below' \
    "$(_routing_canonical _sec_803 3)"
  assert "TC-5b 8.0.3 Routing[4]: 不一致 → ERROR (canonical)" \
    'sentinel found but `iteration_id` != 本 cycle の `REVIEW_CYCLE_ID` (cycle N-1 のもの)~**ERROR**: ステップ 6.1.d was skipped in current cycle. Execute ACTION below' \
    "$(_routing_canonical _sec_803 4)"

  # (c) helper の MARKER 値と SKILL.md の variant 見出しの前方一致関係を固定する。
  #      helper 側だけを変えれば TC-4.2 が落ちるが、SKILL.md の見出しテンプレートだけを変えると
  #      TC-4 の fixture はハードコードのため全 green のまま production の lookup が毎 cycle
  #      新規作成に落ちる。両者の coupling はここでしか固定されていない。
  nbr_marker=$(sed -n "s/^MARKER='\(.*\)'$/\1/p" "$PLUGIN_ROOT/hooks/review-nonblocking-record.sh" | head -1)
  if [ -z "$nbr_marker" ]; then
    fail "TC-5c helper の MARKER 値を抽出できない (定義形式の drift)"
  else
    # インデント幅への係留をやめ「行頭 + 任意長空白 + MARKER」で数える。3 スペース固定だと
    # 整形変更だけで expected=2 actual=0 の原因不明な失敗を出す (false positive)。
    _marker_re=$(printf '%s' "$nbr_marker" | sed 's/[][\.*^$(){}?+|/]/\\&/g')
    variant_heads=$(grep -cE "^[[:space:]]*${_marker_re}" "$REVIEW_MD" || true)
    assert "TC-5c SKILL.md の variant 見出しが MARKER で始まる (A/B の 2 箇所)" "2" "$variant_heads"
  fi

  # (g) [test-reviewer 指摘, cycle 3] helper が count/body 整合検査で grep する
  #     `📎 non_blocking_count:` needle と SKILL.md の variant A/B テンプレートの coupling を固定する
  #     (TC-5c の MARKER coupling と同型)。SKILL.md 側の needle だけ改名すると、production では
  #     毎 cycle 記録が count_body_mismatch で失敗するが、TC-4 の fixture はハードコードのため
  #     全 green のまま検出漏れになる。
  nbr_count_needle=$(sed -n "s/^body_count=\$(grep -E '\^\(📎 non_blocking_count:\)\[\[:space:\]\]\*\[0-9\]+\[\[:space:\]\]\*\$'.*/\1/p" "$PLUGIN_ROOT/hooks/review-nonblocking-record.sh" | head -1)
  if [ -z "$nbr_count_needle" ]; then
    fail "TC-5g helper の non_blocking_count needle を抽出できない (定義形式の drift)"
  else
    _count_re=$(printf '%s' "$nbr_count_needle" | sed 's/[][\.*^$(){}?+|/]/\\&/g')
    count_heads=$(grep -cE "^[[:space:]]*${_count_re}" "$REVIEW_MD" || true)
    assert "TC-5g SKILL.md の variant テンプレートが helper の non_blocking_count needle と一致 (A/B の 2 箇所)" "2" "$count_heads"

    # (g') [application-reviewer F-1/F-2 + test-reviewer F-01, cycle 4]: 上記の coupling assertion
    # は needle の**前方一致**しか見ておらず、helper が要求する行全体の形状 (コロン後・行末の
    # 空白量、値部分が数字であること) までは検査しない。SKILL.md 側テンプレート行に装飾
    # (単位・全角スペース等) を足す編集は、この前方一致 pin を素通りしたまま production の
    # count_body_mismatch を毎 cycle 発火させる。helper の全体形 regex 相当
    # (`^[[:space:]]*📎 non_blocking_count:[[:space:]]*(値)[[:space:]]*$`) を SKILL.md 側にも
    # 適用する。値は variant A の `{non_blocking_count}` placeholder (実行時に LLM が数字へ置換)
    # と variant B の literal 数字の両方を許容する — production 実行後はどちらも helper の
    # `[0-9]+` 一致形に収束するため、テンプレート時点でこの 2 形を許容するのは equivalence の
    # 弛緩ではない。
    shape_heads=$(grep -cE "^[[:space:]]*${_count_re}[[:space:]]*(\\{non_blocking_count\\}|[0-9]+)[[:space:]]*\$" "$REVIEW_MD" || true)
    assert "TC-5g' SKILL.md の variant テンプレートが helper の行全体形状と一致 (A/B の 2 箇所)" "2" "$shape_heads"

    # (g'') [test-reviewer F-04, cycle 4]: 上記 2 件の pin はファイル全体の件数しか見ておらず、
    # その 2 件が variant A と variant B に 1 件ずつ入っていることは要求していない。片方の
    # variant を壊して別の場所に同形の行を足せば件数は 2 のまま保たれ検出できない。
    # TC-5a と同じ規律で、見出し行の位置を先に特定してから区間ごとに検査する。
    _va_line=$(grep -n '\*\*variant A' "$REVIEW_MD" | head -1 | cut -d: -f1)
    _vb_line=$(grep -n '\*\*variant B' "$REVIEW_MD" | head -1 | cut -d: -f1)
    _next_line=$(grep -n '^2\. \*\*記録' "$REVIEW_MD" | head -1 | cut -d: -f1)
    if [ -n "$_va_line" ] && [ -n "$_vb_line" ] && [ -n "$_next_line" ] \
       && [ "$_va_line" -lt "$_vb_line" ] && [ "$_vb_line" -lt "$_next_line" ]; then
      _va_count=$(sed -n "${_va_line},$(( _vb_line - 1 ))p" "$REVIEW_MD" | grep -cE "^[[:space:]]*${_count_re}" || true)
      _vb_count=$(sed -n "${_vb_line},$(( _next_line - 1 ))p" "$REVIEW_MD" | grep -cE "^[[:space:]]*${_count_re}" || true)
      assert "TC-5g'' variant A 区間に needle が 1 件 (位置検証)" "1" "$_va_count"
      assert "TC-5g'' variant B 区間に needle が 1 件 (位置検証)" "1" "$_vb_count"

      # (g''') [test-reviewer F-02, cycle 5] TC-5g' の値 union (`{non_blocking_count}` ¦ `[0-9]+`)
      # はファイル全体の件数しか見ておらず、variant A が placeholder 側、variant B が literal `0`
      # 側であることは要求していない。variant A の placeholder を literal 数字 (例: `3`) に、
      # variant B の `0` を別の数字 (例: `7`) に書き換えても union は変わらず TC-5g' は green の
      # まま通る (テンプレートが提示する値そのものの誤りを検出できない)。TC-5g'' で特定済みの
      # 区間を再利用し、値の種別を variant ごとに固定する。
      _va_placeholder_count=$(sed -n "${_va_line},$(( _vb_line - 1 ))p" "$REVIEW_MD" | grep -cE "^[[:space:]]*${_count_re}[[:space:]]*\\{non_blocking_count\\}[[:space:]]*\$" || true)
      _vb_literal0_count=$(sed -n "${_vb_line},$(( _next_line - 1 ))p" "$REVIEW_MD" | grep -cE "^[[:space:]]*${_count_re}[[:space:]]*0[[:space:]]*\$" || true)
      assert "TC-5g''' variant A 区間の値は {non_blocking_count} placeholder (literal 数字への drift 検出)" "1" "$_va_placeholder_count"
      assert "TC-5g''' variant B 区間の値は literal 0 (別数字への drift 検出)" "1" "$_vb_literal0_count"

      # (g'''') [F-06 指摘, cycle 7] helper の RECORD_SENTINEL ⇄ variant A/B テンプレートの
      #     coupling。TC-5c (MARKER 値) と TC-5g (count needle) は同型の coupling を pin して
      #     いるのに、cycle 6 新設の 3 本目 (sentinel) だけが無防備だった。helper 側の改名は
      #     TC-4 fixture がハードコードのため落ちるが、**SKILL.md 側の脱落・改名は fixture に
      #     触れないため全 green のまま通る**。production では毎 cycle body_sentinel_missing と
      #     なり、この reason は retain_pending_marker=1 に分類されているため 8.0.3 が exit 1 で
      #     差し戻し、同じテンプレートから本文を作り直す差し戻しループになる (記録は一度も
      #     投稿されない)。SKILL.md には sentinel の散文言及もあるためファイル全体 count では
      #     なく **variant 区間限定 + 行全体 anchor** で数える (TC-5g'' と同型)。
      nbr_sentinel=$(sed -n "s/^RECORD_SENTINEL='\(.*\)'\$/\1/p" "$PLUGIN_ROOT/hooks/review-nonblocking-record.sh" | head -1)
      if [ -z "$nbr_sentinel" ]; then
        fail "TC-5g'''' helper の RECORD_SENTINEL を抽出できない (定義形式の drift)"
      else
        _sentinel_re=$(printf '%s' "$nbr_sentinel" | sed 's/[][\.*^$(){}?+|/]/\\&/g')
        _va_sent=$(sed -n "${_va_line},$(( _vb_line - 1 ))p" "$REVIEW_MD" | grep -cE "^[[:space:]]*${_sentinel_re}[[:space:]]*\$" || true)
        _vb_sent=$(sed -n "${_vb_line},$(( _next_line - 1 ))p" "$REVIEW_MD" | grep -cE "^[[:space:]]*${_sentinel_re}[[:space:]]*\$" || true)
        assert "TC-5g'''' variant A 区間に sentinel 行が 1 件 (helper 定数と一致)" "1" "$_va_sent"
        assert "TC-5g'''' variant B 区間に sentinel 行が 1 件 (helper 定数と一致)" "1" "$_vb_sent"
        # read 側が最終非空行の等値である以上、テンプレート側でも sentinel が **fence 内の最終非空行**
        # でなければならない (途中に置くと write 側検査で毎 cycle body_sentinel_missing になる)。
        # 区間ではなく ```markdown fence の中身に限定して評価する (fence の後に散文が続くため)。
        _fence_last_line() {  # $1=start_line $2=end_line
          sed -n "${1},$(( $2 - 1 ))p" "$REVIEW_MD" | awk '
            !infence && /^[[:space:]]*```markdown[[:space:]]*$/ { infence = 1; next }
            infence && /^[[:space:]]*```[[:space:]]*$/ { exit }
            infence && $0 !~ /^[[:space:]]*$/ { last = $0 }
            END { sub(/^[[:space:]]+/, "", last); sub(/[[:space:]]+$/, "", last); print last }
          '
        }
        assert "TC-5g'''' variant A テンプレート fence の最終非空行が sentinel" "$nbr_sentinel" "$(_fence_last_line "$_va_line" "$_vb_line")"
        assert "TC-5g'''' variant B テンプレート fence の最終非空行が sentinel" "$nbr_sentinel" "$(_fence_last_line "$_vb_line" "$_next_line")"
      fi

      # (i) [the governing rationale T-07] variant A の表が **ポインタ 3 列のみ** であることを構造 pin する。
      #     6.1.d の記録コメントは pr_review.post_comment に依存せず public PR へ投稿されるため、
      #     description / suggestion 列を戻すと既定構成のまま非実測 CRITICAL の詳細 (脆弱性の
      #     再現手順等) が修正前に先行開示される。この開示方針は SKILL.md のテンプレート以外に
      #     強制点を持たない — helper は本文の列構成を検査しない (見るのは 1 行目 marker /
      #     最終非空行 sentinel / count 行の 3 つだけ) ため、列を戻す編集は helper 側テストを
      #     全 green のまま通す。テンプレート側の pin が唯一の防御層になる。
      #     negative assert (列が無い) 単体は fence が空になる mutation で trivially pass する
      #     ため、positive (ヘッダ / データ行の 3 列一致) と対で置く。
      _fence_body() {  # $1=start_line $2=end_line — fence 内の生行を出す
        sed -n "${1},$(( $2 - 1 ))p" "$REVIEW_MD" | awk '
          !infence && /^[[:space:]]*```markdown[[:space:]]*$/ { infence = 1; next }
          infence && /^[[:space:]]*```[[:space:]]*$/ { exit }
          infence { print }
        '
      }
      _va_fence=$(_fence_body "$_va_line" "$_vb_line")
      # positive: ヘッダ行とデータ行が期待どおり 3 列 (列の増減・改名を検出)
      assert "TC-5i variant A の表ヘッダが 3 列 (レビュアー / 重要度 / ファイル:行)" "1" \
        "$(printf '%s\n' "$_va_fence" | grep -cE '^[[:space:]]*\| レビュアー \| 重要度 \| ファイル:行 \|[[:space:]]*$' || true)"
      assert "TC-5i variant A のデータ行が 3 列 placeholder" "1" \
        "$(printf '%s\n' "$_va_fence" | grep -cE '^[[:space:]]*\| \{reviewer_type\} \| \{severity\} \| \{file\}:\{line\} \|[[:space:]]*$' || true)"
      # negative: 全文を載せる列 / placeholder が fence 内に 1 つも無い (列を戻す mutation を検出)
      assert "TC-5i variant A fence に 内容 / 推奨対応 の列見出しが無い" "0" \
        "$(printf '%s\n' "$_va_fence" | grep -cE '\| *(内容|推奨対応) *\|' || true)"
      assert "TC-5i variant A fence に description / suggestion placeholder が無い" "0" \
        "$(printf '%s\n' "$_va_fence" | grep -cE '\{(description|suggestion)\}' || true)"
      # AC-3: 全文の所在 (ローカル JSON のパスと配列名) が **同一行に** 明記されている。
      #     2 本の独立 grep にすると、パスと配列名を別行へ割った mutation を通す
      #     (ラベルが「所在行」と表明している以上、同一行であることまで要求する)。
      assert "TC-5i variant A fence の所在行がパスと non_blocking_findings を同一行で示す" "1" \
        "$(printf '%s\n' "$_va_fence" | grep -cE '\.rite/review-results/.*non_blocking_findings' || true)"
      # 列形状の pin だけでは「表を 3 列に保ったまま fence 内の別の場所へ全文を再掲載する」
      #     退行 (箇条書き / 脚注 / 追加 fence) を 1 assert も捕捉できない (実測: 表の下に
      #     `- **{file}:{line}** — {finding_detail_text}` を足しても全 assert green)。
      #     fence が持ってよい placeholder を allowlist で固定し、全文を運ぶ新しい placeholder の
      #     追加を落とす。値の追加・改名はどちらもここで loud fail し、期待値更新という形で
      #     人手のレビューを強制する。
      #     **ラベルは「新規 placeholder の検出」までしか名乗らない** — allowlist 内の 7 種を
      #     使って全文を再掲載する形はここでは落ちず、下の出現回数 pin が担う。
      #     placeholder を 1 つも含まない literal な散文はどちらの pin も見ないが、それは射程の
      #     穴ではない: 本 fence はレンダリング前のテンプレートで、finding ごとの全文は
      #     placeholder 経由でしか入らない。散文はどの finding についても何も開示しえない
      #     (「下の pin が担う」と委譲すると、出現回数しか数えない相手に測れない量を渡すことになる)。
      #     文字クラスは `[^}]` — `[a-z_]` だと数字・大文字・ハイフンを含む placeholder
      #     (`{finding_detail_1}` 等) を 1 件も拾わず allowlist を素通りする (実測)。
      #     **空白も除外してはならない** — `[^}[:space:]]` にすると `{finding full description}` の
      #     ような空白入り placeholder を 1 件も拾わず、AC-1 が禁じる「表の外への全文再掲載」を
      #     そのまま通す (実測: fence に空白入り placeholder の箇条書きを足しても全 assert green)。
      #     `}` の除外だけで `{a} と {b}` の跨ぎ match は防げるため、空白の除外は識別力を落とす。
      #     `LC_ALL=C` は prefix を共有する placeholder が将来現れたときの並び順を環境非依存にする。
      _va_ph=$(printf '%s\n' "$_va_fence" | grep -oE '\{[^}]+\}' | LC_ALL=C sort -u | tr '\n' ' ')
      assert "TC-5i variant A fence の placeholder 集合が allowlist と一致 (全文を運ぶ新規 placeholder の検出)" \
        "{current_commit_sha} {file} {line} {non_blocking_count} {pr_number} {reviewer_type} {severity} " \
        "$_va_ph"
      # allowlist 内の placeholder だけで全文を再掲載する形 (表の下に
      #     `- **{file}:{line}** — 指摘の全文` を足す / **2 つ目の表を足す** 等) を落とす。
      #     **行の形ではなく fence 全体での出現回数**を pin する — finding 単位の 4 placeholder
      #     (`{reviewer_type}` / `{severity}` / `{file}` / `{line}`) はデータ行 1 本に各 1 回だけ
      #     現れるので、2 回目の出現は「finding をもう一度列挙している」ことと同値になる。
      #     行形状フィルタ (`grep -v '^ *|'` で表行を除外する形) にすると、**2 つ目の表**による
      #     再掲載を 1 assert も捕捉できない (実測: 第 2 表を足しても 670/0 で通る)。出現回数なら
      #     箇条書き・脚注・追加 fence・追加表のすべてが同じ 1 本で落ちる。
      for _ph in reviewer_type severity file line; do
        _va_ph_n=$(printf '%s\n' "$_va_fence" | grep -oF "{$_ph}" | wc -l | tr -d ' ')
        assert "TC-5i variant A fence の {$_ph} 出現回数が 1 (finding 再列挙 = 全文再掲載の検出)" "1" "$_va_ph_n"
      done

      # (h) 「本文は列 0 から書き出す」指示が variant テンプレートより **前** に 1 本だけ存在する。
      #     variant A/B は番号付きリスト項目の内側にあるため表示上 3 スペース字下げされる一方、
      #     helper の本文検査 2 段は行頭 anchor (`case "$(head -n 1 ...)" in "$MARKER"*)` と
      #     `grep -E '^📎 non_blocking_count:...'`) で先頭空白を許容しない。指示が無いと LLM は
      #     表示どおり字下げごと転記し、毎 cycle body_marker_missing で outcome=failed となる
      #     (本文検査は逐次評価のため最初の失敗段のみが発火する)。marker が残るので 8.0.3
      #     Pre-Check が exit 1 で差し戻し、本文を直すまで result pattern も emit されない。TC-5g''/g''' の needle 照合は `^[[:space:]]*` で字下げを許容する
      #     ため、この乖離は本 pin でしか検出できない。位置も固定する — テンプレートより後ろに
      #     置かれた指示は読み手が本文生成を終えた後に現れるので用をなさない。
      # [test-reviewer F-04 指摘, cycle 2]: 第 1 版はファイル全体の件数しか数えておらず、ラベルが
      # 表明する scope (6.1.d) と検査範囲が食い違っていた。指示文を 6.1.d から約 2370 行離れた
      # 無関係な節へ移しても、位置条件 (rule < variant A) が成立するため素通りする (#2030 F-09 と
      # 同型)。TC-5b と同じ区間限定 idiom に揃え、ラベルの表明どおり 6.1.d 区間内で数える。
      _indent_rule_line=$(grep -n '本文は列 0 から書き出すこと' "$REVIEW_MD" | head -1 | cut -d: -f1)
      _indent_rule_count=$(_sec_610d | grep -c '本文は列 0 から書き出すこと' || true)
      assert "TC-5h 6.1.d 区間に字下げ禁止の指示が 1 箇所" "1" "$_indent_rule_count"
      if [ -n "$_indent_rule_line" ] && [ "$_indent_rule_line" -lt "$_va_line" ] 2>/dev/null; then
        pass "TC-5h 字下げ禁止の指示が variant テンプレートより前にある ($_indent_rule_line < $_va_line)"
      else
        fail "TC-5h 字下げ禁止の指示が variant テンプレートより前にない (rule=$_indent_rule_line va=$_va_line)"
      fi
    else
      fail "TC-5g'' variant A/B の見出し位置を特定できない (va=$_va_line vb=$_vb_line next=$_next_line)"
    fi
  fi

  # (i') [the governing rationale] 開示方針を守る **散文側** の pin。述語は `_sec_610d` 区間だけに依存し
  #     variant 見出しの位置を要らないので、`_va_line`/`_vb_line` の解決 gate の **外** に置く。
  #     内側に入れると variant 見出しの改名だけでこの 2 本を含む 18 assert が無音で実行されなく
  #     なる (同ファイル冒頭の「到達性 assertion を件数 pin の内側に入れない」規約と同じ理由。
  #     実測: 見出しを改名しつつ両規約文を削除すると FAIL は見出し検出の 1 件だけで、
  #     削除した 2 規約は 1 件も検出されない)。
  #
  #     全文掲載の禁止は「列」ではなく「本文への掲載そのもの」であることを宣言した文が消える
  #     退行を落とす。placeholder allowlist / row-scoped pin は形を見るが、この宣言は射程を
  #     決めており、消えると後続の編集者が「3 列なら何を足してもよい」と読む。
  assert "TC-5i' 6.1.d 区間に「表の外への全文再掲載も禁止」の宣言が 1 箇所" "1" \
    "$(_sec_610d | grep -c '表の外に別形式で全文を再掲載することも禁止' || true)"
  #     [T-04 / AC-2] `file:line` 未取得時に行を落とさず `-` を入れる規約。helper は表の行数を
  #     検査しない (TC-4.17 の negative control が実測で固定) ため、この規約を守らせる層は
  #     6.1.d の散文しかない (TC-5h の字下げ禁止 pin と同型)。
  assert "TC-5i' 6.1.d 区間に -（行を落とさない）規約が 1 箇所" "1" \
    "$(_sec_610d | grep -c '行ごと落とさず' || true)"

  # (h) 8.0.4 (ステップ 6.1.a JSON 保存の実行保証) の三者 coupling を固定する。
  #     ステップ 6 を丸ごと skip した cycle は 8.0.3 の anchor (REVIEW_CYCLE_ID /
  #     pending marker) がどちらも 6.1.a step 0 = ステップ 6 の内側で作られるため自己整合し、
  #     全 gate が誤 pass した (実測: 5 cycle で永続 JSON 2 本 / 記録コメント未 PATCH)。
  #     8.0.4 の anchor は 5.3.0.M step 2 = ステップ 6 の**外側**に置くことが設計の核心なので、
  #     生成位置・consume 位置・検査位置の 3 点をそれぞれ pin する。
  SAVE_SH="$PLUGIN_ROOT/hooks/review-result-save.sh"
  _sec_804() { _section_of '^### 8\.0\.4 ' '^### '; }
  _sec_804_lines=$(_sec_804 | grep -c . || true)
  if [ "$_sec_804_lines" -ge 10 ] && [ "$_sec_804_lines" -le 200 ] 2>/dev/null; then
    pass "TC-5h 区間解決: 8.0.4 が妥当な行数で閉じる ($_sec_804_lines 行)"
  else
    fail "TC-5h 区間解決: 8.0.4 の行数が想定外 ($_sec_804_lines) — 開始 anchor 消失か終端の閉じ損ね"
  fi

  # (h-1) 生成側: marker を作るのは 5.3.0.M step 2 の bash block (= ゲート helper 呼び出しと同じ
  #       block) でなければならない。step 1 (REVIEW_TMP_DIR emit だけの block) へ移すと、その値は
  #       セッション不変で stale でも下流が壊れないため anchor 自身が skip されうる (6.1.a step 0 が
  #       skip された理由と構造的に同一)。step 2 の blocking={n} は result pattern に直結するため
  #       skip できない。**区間は「helper 呼び出し行の直後から step 3 見出しまで」で取る**。
  _sec_530m_step2() { _section_of '^bash \{plugin_root\}/scripts/review-measured-gate\.sh' '^\*\*step 3:'; }
  assert "TC-5h 5.3.0.M step 2 区間に save-pending marker パス**代入**行が 1 本 (行頭 anchor)" "1" \
    "$(_sec_530m_step2 | grep -cE '^[[:space:]]*save_pending_marker="\$\{TMPDIR:-/tmp\}/rite-p61a-pending-' || true)"
  assert "TC-5h 5.3.0.M step 2 区間に save-pending marker **生成文** が 1 本 (noclobber 付き)" "1" \
    "$(_sec_530m_step2 | grep -cE '^[[:space:]]*(el)?if \( set -C; : > "\$save_pending_marker" \)' || true)"
  # squat 先置き検査。noclobber は FIFO を拒否しないため、この 1 行を落とすと生成文の open(2) が
  # 無期限ブロックする (下の [実測] arm が rc=124 で red になる)。静的 pin は行の所在を固定する。
  assert "TC-5h 5.3.0.M step 2 が生成前に既存エントリを検査する (FIFO squat のハング回避)" "1" \
    "$(_sec_530m_step2 | grep -cE '^[[:space:]]*if \[ -e "\$save_pending_marker" \] \|\| \[ -L "\$save_pending_marker" \]; then' || true)"
  assert "TC-5h 5.3.0.M step 2 区間に REVIEW_SAVE_PENDING_MARKER emit が 1 本 (行頭 anchor)" "1" \
    "$(_sec_530m_step2 | grep -cE '^[[:space:]]*echo "\[CONTEXT\] REVIEW_SAVE_PENDING_MARKER=\$save_pending_marker"' || true)"
  assert "TC-5h 5.3.0.M step 2 区間に REVIEW_SAVE_PENDING_ID emit が 1 本 (6.1.a へ渡す値)" "1" \
    "$(_sec_530m_step2 | grep -cE '^[[:space:]]*echo "\[CONTEXT\] REVIEW_SAVE_PENDING_ID=\$save_pending_id"' || true)"

  # (h-1b) caller 配線: 6.1.a の helper 呼び出しが marker id を渡すこと。marker の生成・consume・
  #        検査の 3 点を pin しても、**caller が helper へ id を渡す 1 行**が無検査だとこの行を
  #        消すだけで helper は opt-out 経路 (no-op) に落ち、marker が一切消えず 8.0.4 が毎 cycle
  #        exit 1 を返して ステップ 8.1 に永久到達できなくなる。sibling は path を内部導出するため
  #        配線 drift が構造的に起こり得ないが、本 helper は id を受け取るのでここが単一障害点。
  _sec_610a() { _section_of '^bash \{plugin_root\}/hooks/review-result-save\.sh' '^```$'; }
  assert "TC-5h 6.1.a の helper 呼び出しが --pending-id を渡す (配線 drift の検出)" "1" \
    "$(_sec_610a | grep -cE '^[[:space:]]*--pending-id "\{save_pending_id\}"$' || true)"
  # 生成側の変数名と caller placeholder 名が一致すること (片側改名で silent に空文字が渡る)
  assert "TC-5h 6.1.a が渡す placeholder 名が 5.3.0.M step 2 の変数名と一致する" "1" \
    "$(_sec_530m_step2 | grep -cE '^[[:space:]]*save_pending_id="' || true)"
  # ゲート helper が非ゼロ終了した cycle では marker を張らない (step 3 の再試行経路で orphan を
  # 残さない)。この条件を落とすと、再試行で JSON を作り直した cycle に marker が 2 本生まれる。
  assert "TC-5h 5.3.0.M step 2 の marker 生成が gate 成功 (rc=0) に条件付けられている" "1" \
    "$(_sec_530m_step2 | grep -cE '^if \[ "\$_gate_rc" -eq 0 \]; then' || true)"
  # marker 生成の `if`/`fi` を挟んだことで block 全体の終了コードが 0 に化ける。step 3 の routing は
  # 「rc が最終的な権威」(marker は stderr の自由記述と同居するため) と規定しているので、helper の
  # rc を再送出しないと MEASURED_GATE_FAILED の routing が丸ごと観測不能になる。
  assert "TC-5h 5.3.0.M step 2 が helper の rc を block 終了コードとして再送出する" "1" \
    "$(_sec_530m_step2 | grep -cE '^exit "\$_gate_rc"$' || true)"
  # 実測: 抽出した block を bash に食わせ、helper 失敗時に非ゼロで終わることを確認する
  # (静的 pin だけでは `exit "$_gate_rc"` が生成 if の**内側**へ移動した変異を検出できない)。
  _gate_block_probe=$(_sec_530m_step2 | sed \
    -e 's#^bash {plugin_root}/scripts/review-measured-gate\.sh.*#( exit 3 )#' \
    -e '/^  --input /d' -e '/^  --reject-preset-verification$/d')
  _probe_rc=0
  printf '%s\n' "$_gate_block_probe" | TMPDIR="$TMP_ROOT" bash >/dev/null 2>&1 || _probe_rc=$?
  assert "TC-5h [実測] helper 非ゼロ終了時に step 2 block が同じ rc で終わる" "3" "$_probe_rc"
  # positive control: helper 成功時は rc=0 で終わり marker が生成される
  _probe_ok_rc=0
  _probe_marker_dir=$(mktemp -d "$TMP_ROOT/gate-probe-XXXXXX")
  _probe_err=$(printf '%s\n' "$_gate_block_probe" | sed 's#^( exit 3 )$#( exit 0 )#' \
    | TMPDIR="$_probe_marker_dir" bash 2>&1 >/dev/null) || _probe_ok_rc=$?
  assert "TC-5h [実測] helper 成功時に step 2 block が rc=0 で終わる" "0" "$_probe_ok_rc"
  assert "TC-5h [実測] helper 成功時に marker が実際に生成され path が emit される" "1" \
    "$(printf '%s\n' "$_probe_err" | grep -cE '^\[CONTEXT\] REVIEW_SAVE_PENDING_MARKER=.+/rite-p61a-pending-' || true)"
  assert "TC-5h [実測] 生成された marker ファイルが実在する" "1" \
    "$(find "$_probe_marker_dir" -name 'rite-p61a-pending-*' 2>/dev/null | grep -c . || true)"

  # (h-1c) [実測] marker path に FIFO を先置きされてもハングせず degraded へ倒れること。
  #        `set -C` が拒否するのは既存**通常ファイル**だけなので、FIFO では `: >` の open(2) が
  #        reader を待って無期限にブロックし、review が 5.3.0.M step 2 で止まる (rc=124)。
  #        **本 arm が固定するのは「先置き」ケースのみ** — 検査から生成までの窓に FIFO を
  #        置かれる競合ケースは `set -C` では塞がらず、本 arm の covering 範囲外 (実装側の
  #        コメントに同じ限界を明記済み)。
  #        epoch を固定するため date を shim して path を予測可能にする。
  _squat_dir=$(mktemp -d "$TMP_ROOT/squat-XXXXXX")
  _squat_bin=$(mktemp -d "$TMP_ROOT/squatbin-XXXXXX")
  printf '#!/bin/bash\nprintf "%%s\\n" "1700000099"\n' > "$_squat_bin/date"
  chmod +x "$_squat_bin/date"
  if mkfifo "$_squat_dir/rite-p61a-pending-{pr_number}-1700000099" 2>/dev/null; then
    _squat_rc=0
    # `timeout` は macOS CI (BSD / coreutils なし) に存在しないため `_timeout` を使う。bare
    # `timeout` だと rc=127 (command not found) で block 自体が走らず、下の marker assertion が
    # 「degraded に倒れなかった」と誤検出する一方、兄弟の rc!=124 assertion は 127≠124 で
    # 素通りするため、失敗が片側にしか出ず原因が読めなくなる。
    # 代入前置き (`VAR=x _timeout ...`) は **関数呼び出し**では代入がシェルに残りうるので使わない —
    # `env` に渡して起動対象の環境だけに閉じる。
    _squat_err=$(printf '%s\n' "$_gate_block_probe" | sed 's#^( exit 3 )$#( exit 0 )#' \
      | _timeout 5 env PATH="$_squat_bin:$PATH" TMPDIR="$_squat_dir" bash 2>&1 >/dev/null) || _squat_rc=$?
    assert "TC-5h [実測] FIFO 先置きでも step 2 block がハングしない (rc!=124)" "0" \
      "$([ "$_squat_rc" = "124" ] && echo 1 || echo 0)"
    assert "TC-5h [実測] FIFO 先置き時は空 marker を emit して degraded へ倒す" "1" \
      "$(printf '%s\n' "$_squat_err" | grep -cE '^\[CONTEXT\] REVIEW_SAVE_PENDING_MARKER=$' || true)"
  else
    fail "TC-5h [実測] 前提未成立: mkfifo に失敗した (FIFO 未対応 FS?)"
  fi

  # 生成側が emit する id が **消費側 helper の allowlist を通り、実際に marker を consume できるか**
  # を end-to-end で固定する。probe の id は `{pr_number}` が未置換のままなので、そのままでは
  # helper に弾かれる形状 (= (h-5) arm A が「拒否される側」として使う値と同型)。ここで置換して
  # 実 id にしてから helper に渡すことで、生成側テンプレートが allowlist 外の文字を含む形へ
  # drift した場合に落ちる。これが無いと drift 時は「marker は作られたが helper が消せず
  # 8.0.4 が毎 cycle exit 1」という本 Issue の失敗クラスがそのまま再現する。
  _probe_id_raw=$(printf '%s\n' "$_probe_err" | sed -n 's/^\[CONTEXT\] REVIEW_SAVE_PENDING_ID=//p' | head -1)
  _probe_id=${_probe_id_raw//\{pr_number\}/123}
  if [ -n "$_probe_id" ]; then
    _probe_e2e_marker="${TMPDIR:-/tmp}/rite-p61a-pending-$_probe_id"
    : > "$_probe_e2e_marker"
    run_save --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-probe-e2e" --pending-id "$_probe_id"
    if [ -e "$_probe_e2e_marker" ]; then
      fail "TC-5h [実測] 生成側 id が helper の allowlist を通らない (marker が consume されない = 8.0.4 が毎 cycle 落ちる)"
    else
      pass "TC-5h [実測] 生成側 id が helper の allowlist を通り marker が consume される"
    fi
  else
    fail "TC-5h [実測] 生成側 block から REVIEW_SAVE_PENDING_ID を抽出できない (emit 行が drift した)"
  fi

  # (h-2) consume 側: 削除文は helper の EXIT trap 関数**内**に 1 本、関数外に 0 本。
  #       関数外 (末尾 exit 0 の直前) へ移すと、trap 到達前に exit する非ブロッキング失敗経路
  #       (LOCAL_SAVE_FAILED 全 15 種) で marker が残り、8.0.4 が毎 cycle exit 1 を返して
  #       保存失敗が blocking 化する (D-04 / AC-3 の破壊)。件数 pin では移動を検出できないため配置で固定する。
  _sec_p61a_cleanup() {
    awk '
      !inside && /^_rite_review_p61a_cleanup\(\) \{/ { inside = 1; print; next }
      inside && /^\}/ { print; exit }
      inside { print }
    ' "$SAVE_SH"
  }
  _sec_p61a_cleanup_lines=$(_sec_p61a_cleanup | grep -c . || true)
  if [ "$_sec_p61a_cleanup_lines" -ge 5 ] && [ "$_sec_p61a_cleanup_lines" -le 60 ] 2>/dev/null; then
    pass "TC-5h 区間解決: _rite_review_p61a_cleanup が妥当な行数で閉じる ($_sec_p61a_cleanup_lines 行)"
  else
    fail "TC-5h 区間解決: _rite_review_p61a_cleanup の行数が想定外 ($_sec_p61a_cleanup_lines)"
  fi
  _pm_rm_total=$(grep -cE 'rm -f "\$PENDING_MARKER"' "$SAVE_SH" || true)
  _pm_rm_in_cleanup=$(_sec_p61a_cleanup | grep -cE 'rm -f "\$PENDING_MARKER"' || true)
  assert "TC-5h helper の cleanup **区間内** に save-pending marker 削除が 1 本" "1" "$_pm_rm_in_cleanup"
  assert "TC-5h helper の cleanup **区間外** に save-pending marker 削除が 0 本" "0" "$(( _pm_rm_total - _pm_rm_in_cleanup ))"
  # terminal sentinel も同じ trap 内で emit する (8.0.4 の prose Check の唯一の入力)。
  assert "TC-5h helper の cleanup 区間内に REVIEW_SAVE_DONE emit が 1 本" "1" \
    "$(_sec_p61a_cleanup | grep -cE 'REVIEW_SAVE_DONE=1; pr=' || true)"

  # (h-3) 検査側: 8.0.4 が marker の残存を見て exit 1 し、marker を削除しない。
  #       gate 側で削除すると 6.1.a を実行せず再評価だけで通せてしまい機械強制の意味が消える
  #       (8.0.3 の同名 pin と同型)。判定式は `-e` 単独ではなく `-L` との OR — `-e` だけだと
  #       dangling symlink を「不在」と読んで fail-open し、6.1.a 未実行でも gate が通る。
  assert "TC-5h 8.0.4 区間に save-pending marker 判定式が 1 箇所 (-e と -L の OR)" "1" \
    "$(_sec_804 | grep -cE '^[[:space:]]*if \[ -e "\$save_pending_marker" \] \|\| \[ -L "\$save_pending_marker" \]; then' || true)"
  assert "TC-5h 8.0.4 区間に marker 残存時の retained flag が 1 本" "1" \
    "$(_sec_804 | grep -cF 'REVIEW_SAVE_GATE_FAILED=1; reason=save_pending_marker_present' || true)"
  assert "TC-5h 8.0.4 区間に marker 残存時の exit 1 が 1 本" "1" \
    "$(_sec_804 | grep -cE '^[[:space:]]*exit 1$' || true)"
  assert "TC-5h 8.0.4 は save-pending marker を削除しない" "0" \
    "$(_sec_804 | grep -cE 'rm -f .*save_pending_marker' || true)"
  # 差し戻し先が **step 0** であること自体が不変条件 — step 2 だけを名指しすると 8.0.3 の anchor
  # (REVIEW_CYCLE_ID / NONBLOCKING_PENDING_MARKER) が前 cycle のまま残り、8.0.3 が再び誤 pass する。
  # 8.0.4 の発火が 8.0.3 の anchor 再生成を連鎖させる推移的性質が、ステップ 6 全体の回復を担保する。
  # 差し戻し先の指示は Pre-Check の ERROR echo と On ERROR ブロックの 2 箇所にあり、両方に
  # 現れることを要求する (片方だけに残すと、もう一方の経路で step 2 単独実行へ誘導される)。
  assert "TC-5h 8.0.4 の ACTION が 2 経路とも 6.1.a **step 0** からの再実行を指示している" "2" \
    "$(_sec_804 | grep -c 'step 0 から' || true)"

  # (h-3') 検査側の **実測**: 8.0.4 Pre-Check の bash を 4 arm すべて実行する。上の静的 pin は
  #        「判定式が存在する」ことしか言えず、pass / degraded の emit 入れ替えや、到達しない
  #        case arm を検出できない。本 gate は AC-1 / AC-2 が依存する load-bearing 層なので、
  #        生成側 (h-1 の probe) と同じ強度で実行して固定する。
  # 抽出は `esac` で止めない — positive 検査 (review-save-json-verify.sh) は case の**外**に
  # 置かれており、`esac` で切ると本 PR が塞いだ「marker degraded 時に positive 検査が走らない」
  # 経路を arm テストが一切踏めなくなる。閉じ fence まで取る。
  _sec_804_precheck() { _sec_804 | awk '/^save_pending_marker="/{f=1} f&&/^```$/{exit} f{print}'; }
  # marker 不在の arm は positive 検査 (review-save-json-verify.sh) まで到達する。同 helper は
  # state-path-resolve.sh で results dir を解決するため、arm は **cwd 配下に .rite/review-results を
  # 持つ一時ディレクトリ**で走らせる。`--results-dir` を後付けせず本番と同じ既定解決を通すことで、
  # SKILL.md の呼び出し行が引数を落とした / 解決経路が変わった退行もここで落ちる。
  _804_pr=804001
  _804_sha=feedface1234
  # The positive helper independently resolves HEAD from its cwd. These state-root
  # fixtures are intentionally non-git directories, so provide the same explicit
  # git boundary used by review-save-json-verify.test.sh instead of accidentally
  # exercising only the degraded HEAD-unresolved path.
  _804_bin=$(mktemp -d "$TMP_ROOT/gate804bin-XXXXXX")
  cat > "$_804_bin/git" <<EOF
#!/bin/bash
if [ "\$1 \$2" = "rev-parse HEAD" ]; then
  printf '%s\n' '$_804_sha'
  exit 0
fi
exit 2
EOF
  chmod +x "$_804_bin/git"
  _run_804_arm() {  # $1=marker 値, $2=cwd (省略: 本 cycle の JSON を持つ dir) → "rc|stderr" を返す
    local _m="$1" _cwd="${2:-$_804_json_ok}" _rc=0 _err
    _err=$(printf '%s\n' "$(_sec_804_precheck)" \
      | sed "1s#^save_pending_marker=.*#save_pending_marker='$_m'#" \
      | sed "s#{plugin_root}#$PLUGIN_ROOT#g; s#{pr_number}#$_804_pr#g; s#{current_commit_sha}#$_804_sha#g" \
      | (cd "$_cwd" && PATH="$_804_bin:$PATH" bash) 2>&1 >/dev/null) || _rc=$?
    printf '%s|%s' "$_rc" "$_err"
  }
  _804_probe_dir=$(mktemp -d "$TMP_ROOT/gate804-XXXXXX")
  # 本 cycle の commit SHA を持つ JSON が実在する state root (正常系の arm 用)
  _804_json_ok=$(mktemp -d "$TMP_ROOT/gate804ok-XXXXXX")
  mkdir -p "$_804_json_ok/.rite/review-results"
  printf '%s\n' "{\"schema_version\":\"1.1.0\",\"pr_number\":$_804_pr,\"timestamp\":\"2026-01-01T00:00:00+09:00\",\"commit_sha\":\"$_804_sha\",\"overall_assessment\":\"mergeable\",\"findings\":[],\"non_blocking_findings\":[]}" \
    > "$_804_json_ok/.rite/review-results/$_804_pr-20260101000001.json"
  # 区間ごと skip の再現: results dir はあるが本 cycle の JSON が無い state root
  _804_json_missing=$(mktemp -d "$TMP_ROOT/gate804miss-XXXXXX")
  mkdir -p "$_804_json_missing/.rite/review-results"
  _804_precheck_lines=$(_sec_804_precheck | grep -c . || true)
  if [ "$_804_precheck_lines" -ge 10 ] 2>/dev/null; then
    pass "TC-5h 区間解決: 8.0.4 Pre-Check の bash を抽出できる ($_804_precheck_lines 行)"
  else
    fail "TC-5h 区間解決: 8.0.4 Pre-Check の bash 抽出に失敗 ($_804_precheck_lines 行) — case 構造の drift"
  fi

  # arm 1: marker 残存 → rc=1 + REVIEW_SAVE_GATE_FAILED。**かつ marker を削除しない**
  #        (gate 側削除は「6.1.a を実行せず再評価だけで通せる」抜け道になる。今までは grep -c 頼りだった)
  _804_present="$_804_probe_dir/rite-p61a-pending-123-1700000000"
  : > "$_804_present"
  _r=$(_run_804_arm "$_804_present")
  assert "TC-5h [実測] 8.0.4 arm=marker 残存: rc=1 (差し戻し)" "1" "${_r%%|*}"
  assert "TC-5h [実測] 8.0.4 arm=marker 残存: REVIEW_SAVE_GATE_FAILED を emit" "1" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_GATE_FAILED=1; reason=save_pending_marker_present' || true)"
  if [ -e "$_804_present" ]; then
    pass "TC-5h [実測] 8.0.4 は marker を削除しない (再評価だけで通せない)"
  else
    fail "TC-5h [実測] 8.0.4 は marker を削除しない — 削除された = 機械強制が再評価で迂回可能になる"
  fi

  # arm 2: marker 不在 **かつ本 cycle の結果 JSON が実在** → rc=0 + pass
  _r=$(_run_804_arm "$_804_probe_dir/rite-p61a-pending-123-1700000001")
  assert "TC-5h [実測] 8.0.4 arm=marker 不在 + JSON 実在: rc=0" "0" "${_r%%|*}"
  assert "TC-5h [実測] 8.0.4 arm=marker 不在 + JSON 実在: GATE=pass; reason=..._absent" "1" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_GATE=pass; reason=save_pending_marker_absent' || true)"

  # arm 2': marker 不在 **かつ本 cycle の結果 JSON が不在** → rc=1 (5.3.0.M〜6.1.a を区間ごと
  #         skip した cycle。marker は一度も張られないため negative 検査だけでは観測値が arm 2 と
  #         同一になる。ここが緑のままだと本 gate は「区間ごとの skip」に対して無音の no-op に戻る)
  _r=$(_run_804_arm "$_804_probe_dir/rite-p61a-pending-123-1700000002" "$_804_json_missing")
  assert "TC-5h [実測] 8.0.4 arm=marker 不在 + JSON 不在: rc=1 (差し戻し)" "1" "${_r%%|*}"
  assert "TC-5h [実測] 8.0.4 arm=marker 不在 + JSON 不在: GATE_FAILED; reason=save_result_json_absent" "1" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_GATE_FAILED=1; reason=save_result_json_absent' || true)"
  # 2 層設計では marker 層の pass と positive 層の fail が同一 run に共起する (層ごとに独立した
  # marker を出す契約)。gate の可否を決めるのは **GATE_FAILED の有無と rc** であって pass 行の
  # 不在ではない — pass 行の不在を pin すると、marker 層の inline emit を消す変異が緑になる。
  assert "TC-5h [実測] 8.0.4 arm=marker 不在 + JSON 不在: marker 層の pass は出てよい (可否は rc と GATE_FAILED で決まる)" "1" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_GATE=pass; reason=save_pending_marker_absent' || true)"
  assert "TC-5h [実測] 8.0.4 arm=marker 不在 + JSON 不在: positive 層の成功 marker は出ない" "0" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_JSON_OK=1' || true)"

  # arm 3: placeholder 残留 → rc=0 + degraded (機械強制を skip し prose 判定へ縮退)
  _r=$(_run_804_arm '{save_pending_marker}')
  assert "TC-5h [実測] 8.0.4 arm=placeholder 残留: rc=0 (非致命)" "0" "${_r%%|*}"
  assert "TC-5h [実測] 8.0.4 arm=placeholder 残留: GATE=degraded; reason=..._placeholder_residue" "1" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_GATE=degraded; reason=save_pending_marker_placeholder_residue' || true)"

  # arm 4: 空文字 (5.3.0.M step 2 が marker を作れなかった degraded cycle) → rc=0 + degraded
  _r=$(_run_804_arm '')
  assert "TC-5h [実測] 8.0.4 arm=空文字: rc=0 (非致命)" "0" "${_r%%|*}"
  assert "TC-5h [実測] 8.0.4 arm=空文字: GATE=degraded; reason=..._unavailable" "1" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_GATE=degraded; reason=save_pending_marker_unavailable' || true)"

  # arm 3' / 4': marker 層が degraded **かつ** 本 cycle の JSON が不在 → rc=1。
  # AC-2 の Given (marker が一度も設置されていない) はまさにこの marker 値になるため、positive
  # 検査を `*)` arm の内側に置くと守るべき経路でだけ機械強制が降りる。両 arm を pin する。
  _r=$(_run_804_arm '' "$_804_json_missing")
  assert "TC-5h [実測] 8.0.4 arm=空文字 + JSON 不在: rc=1 (marker degraded でも positive 層は落とす)" "1" "${_r%%|*}"
  assert "TC-5h [実測] 8.0.4 arm=空文字 + JSON 不在: reason=save_result_json_absent" "1" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_GATE_FAILED=1; reason=save_result_json_absent' || true)"
  _r=$(_run_804_arm '{save_pending_marker}' "$_804_json_missing")
  assert "TC-5h [実測] 8.0.4 arm=placeholder + JSON 不在: rc=1" "1" "${_r%%|*}"

  # 正常系の degraded arm では positive 層が通過し観測 marker を出す (誤 blocking を作らない)。
  _r=$(_run_804_arm '')
  assert "TC-5h [実測] 8.0.4 arm=空文字 + JSON 実在: positive 層は REVIEW_SAVE_JSON_OK を出す" "1" \
    "$(printf '%s' "${_r#*|}" | grep -cF 'REVIEW_SAVE_JSON_OK=1' || true)"

  # (h-5) helper の --pending-id gate: marker path は helper が id から内部導出するため、
  #       caller から任意の path を受け取る経路そのものが存在しない (sibling と同形)。
  #       残る caller 契約違反は「id の形状が壊れている」1 種だけで、その場合は導出せず
  #       marker を残す = 8.0.4 が loud に差し戻す方向へ倒れることを固定する。
  # fixture は helper が実際に導出する場所に置く。別ディレクトリに置くと helper がどう振る舞っても
  # 残るため「削除しない」assertion が恒真になり、guard を外す退行を検出できない。
  _gate_id_marker="${TMPDIR:-/tmp}/rite-p61a-pending-{pr_number}-1"
  : > "$_gate_id_marker"
  run_save --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-guard-id" --pending-id '{pr_number}-1'
  assert "TC-5h pending-id gate: 不正 id でも保存自体は成功する (exit 0)" "0" "$RC"
  if [ -e "$_gate_id_marker" ]; then
    pass "TC-5h pending-id gate: 置換漏れ id では marker を削除しない (8.0.4 が差し戻す)"
  else
    fail "TC-5h pending-id gate: 置換漏れ id で marker を削除した — 誤 pass 方向へ倒れている"
  fi
  assert_grep "TC-5h pending-id gate: 置換漏れを WARNING で可視化する" "$ERR" 'pending-id が literal substitute されていないか不正'

  #       正常 id では導出した path の marker が実際に consume されることを対で固定する
  #       (negative control 無しだと「常に削除しない」実装でも上の arm が通る)。
  _gate_id_ok="${TMPDIR:-/tmp}/rite-p61a-pending-123-1700000077"
  : > "$_gate_id_ok"
  run_save --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-guard-id-ok" --pending-id '123-1700000077'
  if [ -e "$_gate_id_ok" ]; then
    fail "TC-5h pending-id gate: 正常 id から導出した marker が consume されない"
  else
    pass "TC-5h pending-id gate: 正常 id から導出した marker を consume する"
  fi

  #       (h-5b) 文字 allowlist 本体を固定する。上の arm が渡す `{pr_number}-1` は case の
  #       **brace 節**で先に捕捉されるため、allowlist (`*[!A-Za-z0-9._-]*`) を削除しても全 arm が
  #       green のまま通る。brace を含まない非 allowlist 文字 (`/`) を使い、導出先が名前空間の
  #       外へ出る値で「削除しない」ことを固定する。
  _trav_victim="${TMPDIR:-/tmp}/victim"
  : > "$_trav_victim"
  run_save --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-guard-trav" --pending-id 'x/../victim'
  assert "TC-5h pending-id gate: traversal id でも保存自体は成功する (exit 0)" "0" "$RC"
  if [ -e "$_trav_victim" ]; then
    pass "TC-5h pending-id gate: traversal id では marker path を導出せず名前空間外を削除しない"
  else
    fail "TC-5h pending-id gate: traversal id で名前空間外のファイルを削除した (allowlist が無効化されている)"
  fi
  assert_grep "TC-5h pending-id gate: traversal id を WARNING で可視化する" "$ERR" 'marker path を導出できないため削除しません'

  #       (h-5c) 不正 id を echo する際の `neutralize_ctrl` を固定する。外すと改行入り id が
  #       診断行の外に**行頭から**完全な形の terminal sentinel を綴れてしまい、8.0.4 の prose
  #       Check が読む唯一の入力を偽造できる (sibling の TC-4.11l' と同型)。
  _forge_id=$'123-1\n[CONTEXT] REVIEW_SAVE_DONE=1; pr=123; marker=/tmp/x; saved=true'
  run_save --pr 123 --content-file "$JSON_OK" --results-dir "$TMP_ROOT/results-guard-forge" --pending-id "$_forge_id"
  assert "TC-5h pending-id gate: 改行入り id でも保存自体は成功する (exit 0)" "0" "$RC"
  assert "TC-5h pending-id gate: 改行入り id が terminal sentinel を偽造できない" "0" \
    "$(grep -c '^\[CONTEXT\] REVIEW_SAVE_DONE=1; pr=123; marker=/tmp/x' "$ERR" || true)"

  # (h-6) 8.0.4 の prose **Check** 行を pin する (TC-5b が 8.0.3 / 6.1.d step 3 に対して行うのと同型)。
  #       Pre-Check の機械強制は marker ファイルの存否しか見ないため、marker を作れなかった cycle
  #       (read-only ${TMPDIR} 等で degraded) では prose Check が唯一の層になる。そこを pin しないと
  #       「一致するか」を「存在するか」へ弱める 1 語の編集が無検出で通り、gate が前 cycle の
  #       stale sentinel を受理する。トークン列だけでなく比較の**向き** (`一致`) を必須にするのも
  #       TC-5b と同じ理由 (存在判定への反転は全トークンが同順で残るため件数では捕まらない)。
  _chk_label_804=$(_sec_804 | grep -cE '\*\*Check\*\*:' || true)
  assert "TC-5h 8.0.4 の \`**Check**:\` 見出しは区間内に 1 本だけ" "1" "$_chk_label_804"
  _chk_sent_804=$(_sec_804 | grep -cE '\*\*Check\*\*:.*REVIEW_SAVE_DONE=1.*REVIEW_SAVE_PENDING_MARKER.*一致' || true)
  assert "TC-5h 8.0.4 の Check が terminal sentinel と本 cycle marker の一致判定に言及 (区間内 1 本)" "1" "$_chk_sent_804"

  # (h-4) 生成側と consume 側で marker のパス prefix が一致する (TC-5b の 3 者 coupling pin と同型)。
  #       片側だけ prefix を変えると marker が永久に残り 8.0.4 が全 cycle で exit 1 を返す。
  _spm_prefix_skill=$(_sec_530m_step2 \
    | sed -n 's/^[[:space:]]*save_pending_marker="\(\${TMPDIR:-\/tmp}\/rite-p61a-pending-\).*$/\1/p' | head -1)
  # consume 側 (helper の内部導出行) が同じ prefix を使うことも固定する。片側だけ変えると
  # 5.3.0.M が張った marker を 6.1.a が別 path として探し、8.0.4 が全 cycle で exit 1 を返す。
  _spm_prefix_helper=$(grep -cF 'PENDING_MARKER="${TMPDIR:-/tmp}/rite-p61a-pending-${PENDING_ID}"' \
    "$PLUGIN_ROOT/hooks/review-result-save.sh" || true)
  assert "TC-5h helper の内部導出が生成側と同じ marker prefix を使う" "1" "$_spm_prefix_helper"
  # consume 側は helper の内部導出行で pin する (下の _spm_prefix_helper)。**8.0.4 区間では pin しない** —
  # 8.0.4 Pre-Check は `{save_pending_marker}` で full path を受け取るだけで path 導出を一切持たず、
  # prefix リテラルを含みうるのは診断文字列だけになる。そこを件数で pin すると、診断文が実装から
  # drift しても「prefix が 1 回出る」条件は満たされ続け、逆に診断文を正しく直すと pin が落ちる
  # (= テストが dangling reference を固定する)。8.0.4 側は下の (h-3) が実際の判定式と exit 1 を
  # 押さえており、そちらが本来の不変条件。
  if [ -n "$_spm_prefix_skill" ]; then
    pass "TC-5h save-pending marker のパス prefix を 5.3.0.M step 2 から抽出できる ($_spm_prefix_skill)"
  else
    fail "TC-5h save-pending marker のパス prefix を 5.3.0.M step 2 から抽出できない — 代入行の形が drift した"
  fi

  # (d) 8.0 の gate 評価順序規定が 1 箇所存在する (8.0.4 追加時に全 pass 行を書き換えない構造)
  order_rule_count=$(count_lit '8.0.1 (W Phase / Wiki ingest) → 8.0.2 (ステップ 7 disposition) → 8.0.3 (ステップ 6.1.d 非実測記録) → 8.0.4 (ステップ 6.1.a JSON 保存) → ステップ 8.1' '8.0 順序規定')
  assert "TC-5d 8.0 の gate 評価順序規定が 1 箇所" "1" "$order_rule_count"
  # [伝播修正, cycle 2 F-04 と同型]: count_lit はファイル全体を数えるため、順序規定を 8.0 の外へ
  # 移しても通る。8.0 冒頭に置くこと自体が「gate 追加時に既存 pass 行を書き換えない」設計の要
  # (各 pass 行は「次の gate へ」としか書かず、順序は 1 箇所の規定が担う) なので区間で固定する。
  order_rule_in_section=$(_section_of '^### 8\.0 ' '^### 8\.0\.' | grep -cF '8.0.1 (W Phase / Wiki ingest) → 8.0.2 (ステップ 7 disposition) → 8.0.3 (ステップ 6.1.d 非実測記録) → 8.0.4 (ステップ 6.1.a JSON 保存) → ステップ 8.1' || true)
  assert "TC-5d 8.0 区間に gate 評価順序規定が 1 箇所" "1" "$order_rule_in_section"

  # (e) 8.0.x の gate 表が終端 (ステップ 8.1) を名指ししない。名指しすると、後から 8.0.4 を足した
  #     ときに既存 pass 行が 8.1 へ直行し続け、新設 gate が到達不能になる。検査は表の行に限定する
  #     — 区間全体で素の `ステップ 8.1` を数えると、ERROR text の否定文
  #     (`Do NOT proceed to ステップ 8.1 without ...`) や節の cross-reference といった正当な散文でも落ちる。
  s801=$(grep -n '^### 8\.0\.1 ' "$REVIEW_MD" | head -1 | cut -d: -f1)
  s81=$(grep -n '^### 8\.1 ' "$REVIEW_MD" | head -1 | cut -d: -f1)
  if [ -n "$s801" ] && [ -n "$s81" ] && [ "$s801" -lt "$s81" ]; then
    _gate_section=$(sed -n "${s801},$(( s81 - 1 ))p" "$REVIEW_MD")
    # 【層 1 / 構造 denylist】区間内の **表の行** (`^|`) が終端 8.1 を (「ステップ」接頭辞の有無に
    # 関わらず) 名指ししないこと。`ステップ 8\.1` のリテラルにのみ係留する形では、
    # 「ステップ」を欠いた bare `8.1` へ言い換えるだけで検出をすり抜けた。`[^0-9.]8\.1` 相当
    # (直前が数字/ドットでない `8.1`) へ広げることで表記揺れを吸収する。散文中の言及
    # (例: 「いずれもステップ 8.1 result emit の前に発火する」) は表の行ではないため対象外で、
    # 正当な cross-reference を壊さない。
    _rows_naming_terminal=$(printf '%s\n' "$_gate_section" | grep -cE '^\|.*[^0-9.]8\.1([^0-9]|$)' || true)
    assert "TC-5e 8.0.x の表の行が終端 (8.1) を名指ししない" "0" "$_rows_naming_terminal"
    # 【層 2 / 言語非依存 allowlist】区間内の全データ行 (`^|` かつヘッダー/セパレータ行を除く) が
    # 「the next gate in the 8.0 evaluation order」/ `**ERROR**` / 「legitimately skipped」の
    # いずれかを含むこと。判定対象を英語リテラル `Gate passes` を含む行に絞り込む形では
    # 「次の gate へ」規約文言の有無を数えていたため、和文だけで書かれた pass 行はそもそも
    # 分子・分母の対象から漏れて素通りした (F-04 と同型の実退行を検出できない穴)。全データ行を
    # 対象にした「含む/含まない」の 2 値判定に変えることで、対象そのものが漏れる経路を塞ぐ。
    _data_rows=$(printf '%s\n' "$_gate_section" | grep -E '^\|' | grep -vE '^\|[[:space:]]*(Condition|-+)')
    _data_row_count=$(printf '%s\n' "$_data_rows" | grep -c . || true)
    _conforming=$(printf '%s\n' "$_data_rows" | grep -cE 'next gate in the 8\.0 evaluation order|\*\*ERROR\*\*|legitimately skipped' || true)
    assert "TC-5e 全データ行が言語非依存の許容フレーズ (次 gate へ/ERROR/legitimately skipped) を含む" "$_data_row_count" "$_conforming"
    # 【層 3 / gate ごとの実在性と hand-off】層 1・層 2 はいずれも「行の削除」に無反応である。
    # 層 2 の等値判定は _data_row_count と _conforming を同一集合 (_data_rows) から導出するため、
    # 行を消しても両辺が同時に減って等値が保たれる。合計下限 (旧 `-ge 3`) も 3 gate 合算のため、
    # 1 gate 分の表 (4 行) が丸ごと消えても残り 7 本で閾値を満たして通る (#2030 F-09 の
    # 「pin コメントが謳う保証を実装が持たない」/ F-10 の「合計下限が個別削除を吸収する」と同型)。
    # 実測: 8.0.2 の pass 行 2 本を削除して 8.0.3 を到達不能にしても suite は緑のままだった。
    # これは AC-6 が守ると宣言している当の failure mode (先行 PR の F-04) そのもの。
    #
    # [test-reviewer F-01/F-02 指摘, cycle 2]: 上記を gate ごとの `-ge 1` に細分した第 1 版は、
    # (a) 8.0.3 を hand-off 検査から除外し、(b) 下限判定のまま、(c) 規約フレーズの有無だけを見て
    # いたため、同型の穴を 3 つ残していた。(a) の除外理由「終端 gate は次の gate を持たない」は
    # SKILL.md の実物と食い違う — 8.0.3 の pass 行も規約統一のため同じフレーズを持ち、除外すると
    # その唯一の pass 行 (WARNING 転記義務が書かれている行) を消しても検出されない。(b) は 1 gate が
    # pass 行を複数持つとき「正常系が通る当の行」の削除を他の行が吸収する。(c) は pass 行を ERROR 行へ
    # **反転**しても同じ本数を数える。よって 3 gate すべてを対象にし、`Gate passes` と規約フレーズの
    # **共起**を要求し、データ行数・pass 行数とも**厳密な等値**で固定する。gate 表を意図的に変えた
    # ときは本 pin が落ちるので、期待値の更新とあわせて hand-off の再確認が強制される。
    # [test-reviewer / error-handling F-01 指摘, cycle 5]: 上記 2 本 (データ行数 / pass 行数) だけでは
    # **ERROR 行の極性反転**が通る。ERROR 行を「Gate は legitimately skipped — 先へ進む」へ書き換えても
    # (a) データ行数は不変、(b) pass 行数も不変 (`Gate passes` を含まないため)、(c) 層 2 の allowlist は
    # `legitimately skipped` を許容トークンに持つため満たされる、で 310/0 の完全緑になる。**allowlist の
    # トークン自体が escape hatch** になっていた。8.0.3 の該当行は「sentinel NOT found → ERROR」= 6.1.d を
    # 丸ごと skip したケースを捕まえる行であり、8.0.3 gate が存在する唯一の理由。実測で 3 表とも素通りを確認。
    #
    # canonical pin を個別行に足す修正では当てた表しか守れない (8.0.3 に足しても 8.0.1/8.0.2 は露出)。
    # **層で当てる** — 行の役割ごとの本数を厳密等値で固定し、ループが 3 表すべてに適用されるようにする。
    #
    # 期待値 `見出し:データ行数:pass 行数:ERROR 行数`:
    #   - 8.0.1 = 3:2:1  (pass 2 / ERROR 1)
    #   - 8.0.2 = 4:2:2  (pass 2 / ERROR 2)
    #   - 8.0.3 = 4:1:2  (pass 1 / ERROR 2)。pass が 1 本なのは legitimate-skip 行 (ステップ 6 hard fail) が
    #     hand-off を持たない片方向の終端行だから。この行は ERROR でも pass でもないため 1+2 < 4 になる。
    #   - 8.0.4 = 4:1:2  (pass 1 / ERROR 2)。8.0.3 と同型の 4 行構成 (legitimate-skip 1 / pass 1 / ERROR 2)。
    for _g_spec in '8.0.1:3:2:1' '8.0.2:4:2:2' '8.0.3:4:1:2' '8.0.4:4:1:2'; do
      _g=${_g_spec%%:*}
      _g_rest=${_g_spec#*:}
      _g_rows_exp=${_g_rest%%:*}
      _g_rest=${_g_rest#*:}
      _g_pass_exp=${_g_rest%%:*}
      _g_err_exp=${_g_rest#*:}
      _g_re=$(printf '%s' "$_g" | sed 's/\./\\./g')
      _g_start=$(grep -n "^### ${_g_re} " "$REVIEW_MD" | head -1 | cut -d: -f1)
      if [ -z "$_g_start" ]; then
        fail "TC-5e gate 見出し '### $_g' が見つからない — gate 定義の削除または見出しの drift"
        continue
      fi
      # 次の `### ` 見出し (8.0.x でも 8.1 でも可) の直前までを当該 gate の区間とする
      _g_end=$(awk -v s="$_g_start" 'NR > s && /^### / { print NR; exit }' "$REVIEW_MD")
      [ -n "$_g_end" ] || _g_end=$(( $(wc -l < "$REVIEW_MD") + 1 ))
      _g_rows=$(sed -n "${_g_start},$(( _g_end - 1 ))p" "$REVIEW_MD" | grep -E '^\|' | grep -vE '^\|[[:space:]]*(Condition|-+)')
      _g_row_count=$(printf '%s\n' "$_g_rows" | grep -c . || true)
      assert "TC-5e $_g のデータ行数 (部分削除・無断追加の検出)" "$_g_rows_exp" "$_g_row_count"
      # `Gate passes` と規約フレーズの共起を要求する — フレーズ単独では pass 行を ERROR 行へ
      # 反転する変異を見逃す (フレーズが残るため本数が変わらない)。
      _g_pass=$(printf '%s\n' "$_g_rows" | grep -cE 'Gate passes.*next gate in the 8\.0 evaluation order' || true)
      assert "TC-5e $_g の次 gate への pass 行数 (後続 gate の到達性)" "$_g_pass_exp" "$_g_pass"
      # ERROR 行数の厳密等値 — 上記 2 本が素通りさせる「ERROR 行の極性反転」を捕まえる唯一の層。
      _g_err=$(printf '%s\n' "$_g_rows" | grep -cE '\*\*ERROR\*\*' || true)
      assert "TC-5e $_g の ERROR 行数 (極性反転の検出)" "$_g_err_exp" "$_g_err"
    done
  else
    fail "TC-5e 8.0.1 / 8.1 の見出しが見つからない (s801=$s801 s81=$s81)"
  fi
fi

if ! print_summary "$(basename "$0")" \
  "drift: review helper 4 件 (review-skip-notification / review-comment-post / review-result-save / review-nonblocking-record) の gate 分岐・reason 語彙・exit code 契約、または skills/pr-review/SKILL.md ステップ 6.1.d / 8.0.3 の gate 契約が変更された可能性。各 helper のヘッダ契約コメントと skills/pr-review/SKILL.md ステップ 6.1 / 8.0 を確認すること。"; then
  exit 1
fi
