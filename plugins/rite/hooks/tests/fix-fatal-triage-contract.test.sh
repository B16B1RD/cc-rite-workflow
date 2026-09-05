#!/bin/bash
# Contract tests for the fatal triage (致命性仕分け) contract in skills/fix/SKILL.md.
#
# 番号は本スイート独立の採番 (C-nn)。Issue の受入基準 / テストケース番号とは対応しない。
#
# 仕分けの判定そのものは scripts/review-findings-maps.sh 側にあり
# scripts/tests/review-findings-maps.test.sh が実挙動で pin する。本スイートが守るのは
# **SKILL.md 側の契約記述** — helper が no-op になる経路と、移送分を記録できない経路で
# fix が何をするかの規定。ここが消えると helper は無傷のまま「移送分が無記録で消える」に戻る。
#
# C-01 Priority 3 の非永続経路は fail-loud で停止する (契約: 移送分を捨てない)
# C-02 移送件数の読み取り失敗を 0 へ倒さない (fail-loud、guard 自身の無効化を防ぐ)
# C-02d 非空検査を probe より前に置く (readback_failed を到達可能に保つ)
# C-03 marker 不在経路 (会話 / legacy Markdown) では consumer 式を適用しない
# C-04 ステップ 2.1 の選択 UI が marker の有無で分岐する
# C-04d 分類表の行と ステップ 2.1 分岐 5 が同一母集団を主張することを両側で pin
# C-04b marker 不在時の表示規則が単一 SoT に定義され、参照側が委譲を保持している
# C-04c 移送件数の実出力行が記録経路 (4.5.3 / 4.6) に存在する
# C-05 P3 の新 reason が reason 表と Eval-order enumeration の両方に登録されている
# C-05b Eval-order enumeration の P3 区間が実 emit 順と一致する
# C-05c helper 側 Eval-order enumeration が実 emit 順と一致する
# C-07 fatal_triage_jq_failed の cause= 判別子が site ごとに異なる
# C-06 撤去済み reason (fatal_triage_id_union_violation) を helper / SKILL.md が同時に持つか同時に持たない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
MAPS="$PLUGIN_ROOT/scripts/review-findings-maps.sh"

echo "=== fix/SKILL.md 致命性仕分け契約 ==="

assert_file_exists_or_fail "fix/SKILL.md exists" "$FIX" || true
assert_file_exists_or_fail "review-findings-maps.sh exists" "$MAPS" || true

# --- C-01: P3 非永続経路の fail-loud ---
assert_grep "C-01 P3 の非永続移送で [fix:error] へ昇格する" "$FIX" \
  '\[fix:error\] reason=p3_triage_not_persistable'
assert_grep "C-01 停止理由に移送件数を添える" "$FIX" \
  'reason=p3_triage_not_persistable; moved='

# --- C-02: 移送件数の読み取り失敗を 0 へ倒さない ---
# `p3_moved=$(jq ...) || p3_moved=""` + 数値 case という旧形は、jq 失敗を「移送 0 件」に化けさせて
# 直後の fail-loud guard を必ず skip させる。else 節形式で rc を捕捉していることを pin する。
assert_grep "C-02 移送件数の probe が else 節形式で rc を捕捉する" "$FIX" \
  'if p3_moved=\$\(jq '
# 2 つの emit site (jq 失敗 / 非数値) を判別子で個別に pin する。存在だけを見ると
# 片方を消しても緑のままになり、消えた側が sentinel なしで exit 1 する
assert_grep "C-02 probe の jq 失敗分岐が rc 付きで停止する" "$FIX" \
  'reason=p3_triage_moved_probe_failed; rc='
assert_grep "C-02 probe の非数値分岐が value 付きで停止する" "$FIX" \
  'reason=p3_triage_moved_probe_failed; value='
assert_grep "C-02 非数値の移送件数でも停止する (0 へ正規化しない)" "$FIX" \
  'case "\$p3_moved" in .*\[!0-9\]'
assert_grep "C-02 probe 失敗は専用 reason で停止する" "$FIX" \
  '\[fix:error\] reason=p3_triage_moved_probe_failed'
assert_not_grep "C-02 jq 失敗を空文字へ倒す旧形が残っていない" "$FIX" \
  '\) \|\| p3_moved=""'

# --- C-02d: 非空検査は probe より前 ---
# 0 バイトファイルに jq を通すと rc=0 / 空出力になるため、順序が逆だと
# p3_triage_readback_failed が到達不能になり一次原因が診断から消える
_p3_empty_line=$(grep -n 'if \[ ! -s "\$p3_triage_file" \]' "$FIX" | head -1 | cut -d: -f1)
_p3_probe_line=$(grep -n 'if p3_moved=\$(jq ' "$FIX" | head -1 | cut -d: -f1)
if [ -n "$_p3_empty_line" ] && [ -n "$_p3_probe_line" ] && [ "$_p3_empty_line" -lt "$_p3_probe_line" ]; then
  pass "C-02d 非空検査が移送件数 probe より前に置かれている"
else
  fail "C-02d 非空検査が probe より後 (empty=$_p3_empty_line probe=$_p3_probe_line) — readback_failed が到達不能になる"
fi

# --- C-03: marker 不在経路では consumer 式を適用しない ---
assert_grep "C-03 marker 不在経路で consumer 式を適用しない旨の規定がある" "$FIX" \
  'それらの経路では consumer 式を適用してはならない'
assert_grep "C-03 Raw JSON も file-based source に含まれると明記する" "$FIX" \
  'Priority 3 が tempfile 経由で通す Raw JSON'
assert_grep "C-03 marker 不在経路では非致命も従来どおり修正対象に残す" "$FIX" \
  '\*\*従来どおり修正対象にする\*\*'

# --- C-04: ステップ 2.1 の選択 UI が marker の有無で分岐する ---
assert_grep "C-04 marker ありでは致命だけを並べる" "$FIX" \
  'marker あり\).*手動起動時に並ぶのは致命 finding だけ'
assert_grep "C-04 marker 不在では非致命 gated も選択肢に並べる" "$FIX" \
  'marker 不在の経路.*非致命 gated finding も選択肢に並べる'
# 分岐 5 を「致命のみ」へ反転させると、marker 不在経路の非致命 gated finding が
# 移送も記録もされないまま修正対象から消える
assert_grep "C-04 分岐 5 が marker 不在時に severity 帯を絞らない" "$FIX" \
  'marker なし.*severity に依らず本セクション以降を通常通り実行する'

# --- C-04d: 分類表の行と分岐 5 が同一母集団を主張することを両側で pin ---
# 1.3 分類表の「全 severity 帯 (仕分け未適用)」行は自身を「ステップ 2.1 分岐 5 と同一母集団」と
# 宣言するが、その宣言を裏づけるものが無かった。表だけが広い母集団へ戻ると、同一 finding が
# 「Must fix」と「表示のみ; NOT a fix target」の両行に該当して逆の Action が付く。
# 上の C-04 は分岐 5 の**動作句**しか見ておらず、間の条件節は `.*` に飲まれる。両側を同じ粒度で張る
assert_grep "C-04d 分類表の仕分け未適用行が measured != false で母集団を絞る" "$FIX" \
  '\*\*全 severity 帯 \(仕分け未適用\)\*\*.*gated finding のうち \*\*`measured != false`\*\* のもの'
assert_grep "C-04d 分岐 5 が measured != false で母集団を絞る" "$FIX" \
  '仕分けが走らなかった経路.*`scope ∈ \{current-pr, follow-up\}` かつ \*\*measured != false\*\*'

# --- C-04b: marker 不在時の表示規則 ---
# 規則は 1.2.0 (moved_count 系) と 1.4 注記 (fatal_count) の 2 箇所だけに置く。
# 1.4 は fatal_count の SoT であると同時に moved_count の参照側でもあるため、
# 参照側は 1.4 / 4.5.3 / 4.6 / 5.1 / E2E Output Minimization の 5 箇所。
# 参照側が規則本文を再掲すると手書き複製が drift する
assert_grep "C-04b moved_count の marker 不在時規則が 1.2.0 にある" "$FIX" \
  '`{moved_count}件` を `件` ごと `不明 \(FIX_FATAL_TRIAGE marker 不在\)` に置換'
assert_grep "C-04b moved_pointer_suffix の marker 不在時値が定義されている" "$FIX" \
  '`{moved_pointer_suffix}` は空文字列にする'
# 1.4 を委譲へ畳んだ結果、この節が 1.4 の挙動を決める唯一の記述になった。
# 反転すると 4 つの委譲元すべてが黙って別規則を指す
assert_grep "C-04b 1.4 の移送済みセクションは marker 不在時に省略すると規定されている" "$FIX" \
  'ステップ 1\.4 の「移送済み」セクションは見出しごと省略する'
# `.*` は使わない — 規則が住む行は 1 段落 1 行で行前半にも {fatal_count} が出現するため、
# `\{fatal_count\}.*` 形だと委譲節の帰属先を書き換えても行内マッチで緑のまま通る
assert_grep "C-04b fatal_count の規則は 1.4 注記が SoT と委譲されている" "$FIX" \
  '\*\*`\{fatal_count\}`\*\*: 使用箇所はステップ 1\.4 の `### 致命` セクション見出しだけなので、規則はそこの注記を SoT とする'
# 見出しリテラル単独ではなく marker 不在という適用条件ごと pin する (単独だと
# 差し替えの条件を消しても緑のまま通る)
assert_grep "C-04b 1.4 の marker 不在時は severity 限定しない見出しへ差し替える" "$FIX" \
  'marker 不在 \(会話 / legacy Markdown\) → 見出しを `### 全 severity 帯（仕分け未適用）\({listed_count}件\)` にし'
# 件数の決定規則は上の条件節 pin では守れない (条件節を残したまま削除できる) ので独立に pin する
assert_grep "C-04b 1.4 の marker 不在時は実列挙件数を書く" "$FIX" \
  '件数は実際に列挙した行数を書く \({listed_count}\)'
# 件数決定文は marker 不在の見出し規則の直後になければ意味を持たない (無関係な節へ
# 移設すると {listed_count} が決定規則不在のまま見出しに残る)
# 行差ではなく同一注記ブロック内であることを要求する。防ぎたいのは別文脈への移設で
# あって行の折り返しや同一行への統合ではない (差を固定すると通常の編集で偽陽性になる)
_hd_line=$(grep -n '見出しを `### 全 severity 帯（仕分け未適用）' "$FIX" | head -1 | cut -d: -f1)
_cnt_line=$(grep -n '件数は実際に列挙した行数を書く' "$FIX" | head -1 | cut -d: -f1)
_blk_end=$(awk -v s="${_hd_line:-0}" 'NR >= s && /-->/ { print NR; exit }' "$FIX")
if [ -n "$_hd_line" ] && [ -n "$_cnt_line" ] && [ -n "$_blk_end" ] \
   && [ "$_cnt_line" -ge "$_hd_line" ] && [ "$_cnt_line" -lt "$_blk_end" ]; then
  pass "C-04b 件数決定規則が marker 不在の見出し規則と同じ注記ブロック内にある"
else
  fail "C-04b 件数決定規則が見出し規則の注記ブロック外 (heading=$_hd_line count=$_cnt_line blockend=$_blk_end) — {listed_count} の解決規則が別文脈へ移ると見出しに未解決の placeholder が残る"
fi
# 規則本文の手書き複製が増えていないこと (1.2.0 の 1 箇所だけ)。
# `grep -c` は行単位で、本ファイルは 1 段落 1 行のため同一行内の複製を数えない。
# `grep -o | wc -l` で出現数を直接数える
_nb_rule_count=$(grep -o '不明 (FIX_FATAL_TRIAGE marker 不在)' "$FIX" | wc -l | tr -d ' ')
if [ "$_nb_rule_count" = "1" ]; then
  pass "C-04b marker 不在時の文言が 1 箇所にのみ定義されている"
else
  fail "C-04b marker 不在時の文言が $_nb_rule_count 箇所に複製されている (drift 面)"
fi
# 規則の定義位置がステップ 1.2.0 の節内であること。移設されると参照側 4 箇所が空の節を
# 指す dangling delegation になるが、出現数カウントだけでは検出できない
_rule_line=$(grep -n '不明 (FIX_FATAL_TRIAGE marker 不在)' "$FIX" | head -1 | cut -d: -f1)
_sec_start=$(grep -n '^#### 1\.2\.0 ' "$FIX" | head -1 | cut -d: -f1)
_sec_end=$(awk -v s="${_sec_start:-0}" 'NR > s && /^#### / { print NR; exit }' "$FIX")
if [ -z "$_sec_start" ] || [ -z "$_sec_end" ]; then
  fail "C-04b 見出し '#### 1.2.0 ' の範囲を特定できない (見出しレベル / 文言の drift。start=$_sec_start end=$_sec_end)"
elif [ -n "$_rule_line" ] && [ "$_rule_line" -gt "$_sec_start" ] && [ "$_rule_line" -lt "$_sec_end" ]; then
  pass "C-04b marker 不在時規則がステップ 1.2.0 の節内に定義されている"
else
  fail "C-04b 規則の定義位置が 1.2.0 の外 (rule=$_rule_line section=$_sec_start..$_sec_end) — 参照側 4 箇所が空の節を指す"
fi
# 参照側 5 箇所 (1.4 / 4.5.3 / 4.6 / 5.1 / E2E Output Minimization 節) が委譲文を保持している
# こと。E2E 節は出力形 (fenced) を自前で定義するため、移送行の marker 不在時規則を 1.2.0 へ
# 直接委譲する (5.1 経由の 2 ホップにすると、E2E 実行者が読む順序と所有が食い違う)。C-04b の複製禁止が
# 参照側での規則再掲を禁じているため、この 1 文が消えると規則がどこにも残らない
# 委譲先の識別子まで含めて数える。「marker 不在時規則に従う」だけだと委譲先を
# 別ステップへすり替えても件数が変わらず、2 ホップ化が検出できない
_nb_ref_count=$(grep -o 'ステップ 1\.2\.0 の marker 不在時規則に従う' "$FIX" | wc -l | tr -d ' ')
if [ "$_nb_ref_count" = "5" ]; then
  pass "C-04b 参照側 5 箇所が marker 不在時規則への委譲を保持している"
else
  fail "C-04b 委譲文が $_nb_ref_count 箇所 (期待 5 = 1.4 / 4.5.3 / 4.6 / 5.1 / E2E Output Minimization) — 欠けた箇所に規則が残らない"
fi

# --- C-04c: 移送件数の実出力行 ---
# 委譲文カウントが守るのは marker 不在時の委譲だけで、moved_count を出力する行そのもの
# ではない。記録経路 (4.5.3 の Issue コメント / 4.6 の完了報告) の行を消しても緑になる
# 衝突 id の転記欄。marker を登録簿へ足しても受け側スロットが無ければ描画されず、
# 「損失が完了報告に一切現れない」という当の欠陥が残る (移送行だけが「記録済み」と表示する)
assert_grep "C-04c 衝突 id の転記欄が Issue 記録コメントにある" "$FIX" \
  '\{moved_count\}件\{moved_pointer_suffix\}\{collision_line_wm\}'
assert_grep "C-04c 衝突 id の転記欄が完了報告にある" "$FIX" \
  '非致命移送 \(fix 対象外、記録済み\): \{moved_count\}件\{collision_line_report\}'
assert_grep "C-04c 衝突欄の展開ルールが marker の有無で定義されている" "$FIX" \
  '\{collision_line_wm\}` \(4\.5\.3\) \| `\{collision_line_report\}` \(4\.6\)'
assert_grep "C-04c 移送件数が Issue 記録コメントに出力される" "$FIX" \
  '\*\*非致命移送\*\*: \{moved_count\}件\{moved_pointer_suffix\}'
assert_grep "C-04c 移送件数が完了報告に出力される" "$FIX" \
  '非致命移送 \(fix 対象外、記録済み\): \{moved_count\}件'

# --- C-07: fatal_triage_jq_failed の cause= 判別子が site ごとに異なる ---
# 判別子は「非隣接の同一 reason は判別子つきで列挙する」規約の実体。5 site のうち
# transport だけが実挙動で pin できる (他 4 つは jq 自体の失敗を要し全域 stub になる) ため、
# 値の網羅はここで静的に持つ。全 site を同一値へ潰す退行は maps 側の挙動 pin では捕まらない
# (どの値でも reason は同じ) — 実測: 4 site の cause= を一括削除しても maps 34/0・契約 34/0
for _cause in severity_enum_probe measured_probe counts_probe transport nb_type_probe id_collision_probe; do
  assert_grep "C-07 cause=$_cause が helper から emit される" "$MAPS" \
    "reason=fatal_triage_jq_failed; cause=$_cause"
  assert_grep "C-07 cause=$_cause が helper の docstring に登録されている" "$MAPS" \
    "^#.* $_cause"
done
# 判別子の値が互いに異なること (全 site を同一値へ潰す退行は上のループでは捕まらない)
_cause_count=$(grep -oE 'reason=fatal_triage_jq_failed; cause=[a-z_]+' "$MAPS" | sort -u | wc -l | tr -d ' ')
if [ "$_cause_count" = "6" ]; then
  pass "C-07 cause= の相異なる値が 6 つある"
else
  fail "C-07 cause= の相異なる値が $_cause_count 種 (期待 6) — 非隣接 site の判別が失われている"
fi

# --- C-05: 新 reason の documented-union 登録 ---
# emit 箇所だけ増えて reason 表 / Eval-order enumeration が追従しない drift を塞ぐ。
_eval_order=$(grep -n 'Eval-order enumeration.*emit reasons sequence' "$FIX" | head -1 | cut -d: -f1)
if [ -z "$_eval_order" ]; then
  fail "C-05 Eval-order enumeration 行を特定できない (見出し文言の drift)"
else
  _eval_line=$(sed -n "${_eval_order}p" "$FIX")
  for _r in p3_triage_moved_probe_failed p3_triage_not_persistable; do
    if printf '%s' "$_eval_line" | grep -q "$_r"; then
      pass "C-05 $_r が Eval-order enumeration に登録されている"
    else
      fail "C-05 $_r が Eval-order enumeration に無い"
    fi
    # reason 表 (先頭が `| \`reason\` |` の行) にも登録されていること
    if grep -qE "^\| \`$_r\` \|" "$FIX"; then
      pass "C-05 $_r が reason 表に登録されている"
    else
      fail "C-05 $_r が reason 表に無い"
    fi
  done
fi

# --- C-05b: Eval-order enumeration の P3 区間が実 emit 順と一致する ---
# C-05 は membership しか見ないため、emit site を移動しても enumeration が旧順のまま残る
# drift を検出できない (本 reason 群は「emit reasons sequence」と順序を明示的に主張する契約)。
# 比較は [CONTEXT] 行 (機械可読な emit) に限る — [fix:error] 行は判別子を持たない。
# 抽出 0 件は「検査できなかった」であって「一致した」ではないので fail へ倒す
# (両辺が同時に空になると比較が成立し、1 件も検証しないまま緑で通るため。
#  同型の guard: hooks/scripts/fix-reason-coverage-check.sh)
if [ -z "${_eval_order:-}" ]; then
  : # C-05 側が既に fail 済み
else
  _emit_seq=$(grep -o 'FIX_FALLBACK_FAILED=1; reason=p3_triage_[a-z_]*\(; cause=[a-z_]*\)\?' "$FIX" \
    | sed 's/FIX_FALLBACK_FAILED=1; reason=//; s/; cause=/:/' \
    | uniq)   # 連続する同一 reason (同じ guard の rc= / value= 2 分岐) は enumeration では 1 度だけ列挙する
  _decl_seq=$(sed -n "${_eval_order}p" "$FIX" \
    | grep -o 'p3_triage_[a-z_]*` \?\((cause=[a-z_]*)\)\?' \
    | sed 's/`//; s/ (cause=/:/; s/)//; s/ $//')
  if [ -z "$_emit_seq" ] || [ -z "$_decl_seq" ]; then
    fail "C-05b 比較母集団が空 — emit 記法 / enumeration 記法の drift で検査が無効化されている
    実 emit 順: $(printf '%s' "$_emit_seq" | tr '\n' ' ')
    宣言順:     $(printf '%s' "$_decl_seq" | tr '\n' ' ')"
  elif [ "$_emit_seq" = "$_decl_seq" ]; then
    pass "C-05b Eval-order enumeration の P3 区間が実 emit 順と一致する"
  else
    fail "C-05b enumeration の P3 区間が実 emit 順と不一致
    実 emit 順: $(printf '%s' "$_emit_seq" | tr '\n' ' ')
    宣言順:     $(printf '%s' "$_decl_seq" | tr '\n' ' ')"
  fi
fi

# uniq で連続重複を畳む根拠は enumeration 側の規範文にある。これが消えると
# 上の比較が何を正としているかの人間可読な SoT が失われる
assert_grep "C-05b enumeration の重複列挙規約が明文化されている" "$FIX" \
  '同一 reason が非隣接の site から emit される場合は判別子つきで各位置に列挙する \(隣接する同一 reason の分岐は 1 回に畳む\)'

# --- C-05c: helper 側 Eval-order enumeration が実 emit 順と一致する ---
# C-05b は $FIX の P3 区間しか見ない。本 diff は nb_type guard を json_invalid 直後へ移して実 emit 順を
# 変え、$MAPS の enumeration に判別子と新しい順序を書いたが、この 2 つ目のコピーは無保護だった
# (判別子を 1 つ落としても両スイートが緑になる)。C-05b と同じ構成の順序比較を helper 側にも張る。
# 抽出はコメント行を除外する — docstring の stderr contract に emit の例示行があり、除外しないと
# 母集団の先頭に別の reason が混入する
_maps_eval=$(grep -n 'emit reasons sequence' "$MAPS" | head -1 | cut -d: -f1)
if [ -z "$_maps_eval" ]; then
  fail "C-05c helper の Eval-order enumeration 行を特定できない (見出し文言の drift)"
else
  _maps_emit=$(grep -v '^[[:space:]]*#' "$MAPS" \
    | grep -o 'FIX_FALLBACK_FAILED=1; reason=[a-z_]*\(; cause=[a-z_]*\)\?' \
    | sed 's/FIX_FALLBACK_FAILED=1; reason=//; s/; cause=/:/' \
    | uniq)
  _maps_decl=$(sed -n "${_maps_eval}p" "$MAPS" \
    | grep -o '`[a-z_]*`\( (cause=[a-z_]*)\)\?' \
    | sed 's/`//g; s/ (cause=/:/; s/)//')
  # 宣言側は FIX_FALLBACK_FAILED 以外の marker 由来 reason も列挙するため、比較は
  # 実 emit 側に現れる語彙へ絞る (順序は宣言側の並びを保ったまま抽出する)
  _maps_decl_f=$(printf '%s\n' "$_maps_decl" | grep -Fx -f <(printf '%s\n' "$_maps_emit") || true)
  # 両辺が同時に空になると 1 件も検証しないまま緑で通る (C-05b と同じ guard)
  if [ -z "$_maps_emit" ] || [ -z "$_maps_decl_f" ]; then
    fail "C-05c 比較の母集団が空 (記法 drift。emit=$(printf '%s' "$_maps_emit" | tr '\n' ' ') decl=$(printf '%s' "$_maps_decl_f" | tr '\n' ' '))"
  elif [ "$_maps_emit" = "$_maps_decl_f" ]; then
    pass "C-05c helper の enumeration が実 emit 順と一致する"
  else
    fail "C-05c helper の enumeration が実 emit 順と不一致
    実: $(printf '%s' "$_maps_emit" | tr '\n' ' ')
    宣: $(printf '%s' "$_maps_decl_f" | tr '\n' ' ')"
  fi
fi

# --- C-06: 撤去済み reason (fatal_triage_id_union_violation) の双方向 pin ---
# helper 側の自己検証撤去に SKILL.md が追従しないと、存在しない検査を原因として案内することになる。
if grep -q 'fatal_triage_id_union_violation' "$MAPS"; then
  assert_grep "C-06 helper が emit する reason は SKILL.md にも載る" "$FIX" \
    'fatal_triage_id_union_violation'
else
  assert_not_grep "C-06 helper が emit しない reason を SKILL.md が残していない" "$FIX" \
    'fatal_triage_id_union_violation'
fi

if ! print_summary "$(basename "$0")" "fatal triage contract drift — check fix/SKILL.md ステップ 1.2.0 / 1.3 / 2.1"; then
  exit 1
fi
