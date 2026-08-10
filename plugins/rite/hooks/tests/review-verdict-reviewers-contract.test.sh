#!/bin/bash
# review-verdict-reviewers-contract.test.sh
#
# merge ゲートが結果 JSON に要求する 2 キー (`verdict` / `reviewers`) について、
# **要求側と生成側の契約が一致していること**を固定する。
#
# 背景: merge ゲートは `schema_version` / `verdict` / `reviewers` (長さ >= 2) を必須にしたが、
# 後 2 者はスキーマ SoT に定義が無く正典 writer も書かなかった。ゲート導入後しばらく通っていたのは、
# 当時のセッションが手書きした JSON がたまたま要求形に適合していたためで、正典機構がフル review を
# 完走した初の in-session merge で全面ブロックが顕在化した。要求キー集合が 4 者
# (スキーマ / SKILL / save helper / ゲート) で揃っていることを機械的に pin するのが本テストの責務。
#
# Coverage:
#   TC-1 各サイトの記述 pin (drift 検知) — スキーマ SoT / pr-review SKILL / save helper /
#        merge ゲートの 4 箇所が同じ 2 キーを要求し、書き手の分担 (verdict = 実測必須ゲート
#        helper のみ / reviewers = 5.3.0.M step 1) が各所で一致していること。**キー集合の乖離を
#        実効的に検出するのは TC-2 の E2E** — ゲート側だけが要求を増やしても本 TC は green の
#        まま通る。両者の役割を混同しないこと (AC-5 は TC-1 + TC-2 の組で満たす)
#   TC-2 正典形 JSON のゲート素通し E2E (AC-1 / AC-3 / T-01 / T-03) — findings 0 cycle の
#        5.3.0.M step 1 形 JSON を review-measured-gate.sh → review-result-save.sh の正典
#        チェーンに通し、verdict 確定 + 非空 reviewers 保持を確認したうえで、保存された
#        ファイルを merge ゲートに読ませて allow になること (対照 deny 付き)
#   TC-3 旧形式 JSON の deny 維持 (AC-4 / T-04) — 両キーを欠く JSON しか無い PR は
#        現行どおり deny され、再レビューへ誘導されること
#   TC-4 findings 非 0 cycle の verdict 確定 (極性の反対側) — blocking 残存で fix-needed に
#        なり、reviewers が findings 件数と独立に保持されること
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
ROOT="$SCRIPT_DIR/../.."
SCHEMA="$ROOT/references/review-result-schema.md"
SKILL="$ROOT/skills/pr-review/SKILL.md"
SAVE="$ROOT/hooks/review-result-save.sh"
GUARD="$ROOT/hooks/pre-tool-bash-guard.sh"
MGATE="$ROOT/scripts/review-measured-gate.sh"

for f in "$SCHEMA" "$SKILL" "$SAVE" "$GUARD" "$MGATE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: contract site not found: $f" >&2
    exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for this test" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rite-verdict-contract-XXXXXX")" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "=== TC-1: 4 者契約の pin (AC-5) ==="

# --- 要求側 1/4: スキーマ SoT ---
assert_grep "TC-1 スキーマがトップレベル必須の verdict を定義" "$SCHEMA" '^\| `verdict` \| \*\*enum\*\* \(string\) \| ✅ \|'
assert_grep "TC-1 スキーマがトップレベル必須 (非空) の reviewers を定義" "$SCHEMA" '^\| `reviewers` \| array \(string\) \| ✅ \(非空\) \|'
assert_grep "TC-1 スキーマが verdict の受理値を 2 値に固定" "$SCHEMA" '`verdict`.*`"mergeable"` / `"fix-needed"` の 2 値'
assert_grep "TC-1 スキーマが reviewers を findings 独立と規定 (findings 0 でも非空)" "$SCHEMA" 'findings 0 件の mergeable cycle でも非空'
assert_grep "TC-1 スキーマが floor 非対称 (save=非空 / ゲート=2) を明記" "$SCHEMA" '下限がゲートと save helper で非対称'
assert_grep "TC-1 スキーマが schema_version 据え置きを明記" "$SCHEMA" 'verdict` / `reviewers` も 1.1.0 内で additive 追加した'
assert_grep "TC-1 スキーマが version からのキー存在推論を禁止" "$SCHEMA" 'schema_version == "1.1.0"` から `verdict` / `reviewers` の存在を推論してはならない'

# --- 要求側 2/4: pr-review SKILL (書き出し指示) ---
assert_grep "TC-1 SKILL が 6.1.a Required JSON fields に verdict を含む" "$SKILL" 'Required JSON fields.*\*\*`verdict`\*\*'
assert_grep "TC-1 SKILL が 6.1.a Required JSON fields に reviewers を含む" "$SKILL" 'Required JSON fields.*\*\*`reviewers\[\]`\*\*'
assert_grep "TC-1 SKILL 5.3.0.M step 1 が verdict を書かない規約を持つ" "$SKILL" '\*\*`verdict` は書かない\*\*'
assert_grep "TC-1 SKILL 5.3.0.M step 1 が reviewers を実回収名簿と規定" "$SKILL" '`reviewers\[\]` = 本 cycle で ステップ 5\.1 が Task 結果を回収できた reviewer の名簿'
assert_grep "TC-1 SKILL が findings からの名簿導出を禁止" "$SKILL" '\*\*`findings\[\]` から導出して(は|も)ならない\*\*'
# 名簿の母集団は「ステップ 5.1 が結果を回収できた reviewer」の単一定義。SKILL は同一文言を
# 2 サイト (5.3.0.M step 1 / 6.1.a Required JSON fields) に持つため、ファイル全体 grep では
# 片方があれば緑になる。**両サイトを個別に錨付けする** — 前 cycle は 6.1.a が無保護だった。
# 錨は行頭 + コロンまで含める (`Required JSON fields` の裸リテラルは 5.3.0.M の参照行と
# 6.1.a の導入散文にも現れ、リスト本体から定義が消えてもそれらが pin を代替成立させる)
assert_grep "TC-1 SKILL 6.1.a が名簿の母集団を実回収集合と規定" "$SKILL" \
  '^- Required JSON fields: .*ステップ 5\.1 が Task 結果を回収できた reviewer'
assert_grep "TC-1 SoT が名簿の母集団を実回収集合と規定" "$SCHEMA" 'ステップ 5\.1 が Task 結果を回収できた reviewer'
assert_grep "TC-1 SKILL 5.3.0.M step 1 が reviewers の値形式を導出式で規定" "$SKILL" '`-reviewer` を付した形で書く'
assert_grep "TC-1 SKILL 6.1.a が reviewers の値形式を導出式で規定" "$SKILL" \
  '^- Required JSON fields: .*`-reviewer` を付した形'
assert_grep "TC-1 SoT が reviewers の値形式を導出式で規定" "$SCHEMA" '`-reviewer` を付した'
# SoT のフィールド表と節見出しも同じ述語であること (前 cycle は本文だけ更新して表を掃き残した)
assert_grep "TC-1 SoT のフィールド表が実回収述語を使う" "$SCHEMA" '^\| `reviewers` \|.*ステップ 5\.1 が Task 結果を回収できた'
# 旧語彙の pin は F-24 が掃いた 4 サイト全てに掛ける (SoT だけだと残る 3 サイトが無保護)。
# pattern は名簿文脈に限定する — 裸の `実走` はテストの実走のような無関係な語で誤発火する
assert_not_grep "TC-1 SoT に旧語彙 (実走名簿) が残っていない" "$SCHEMA" '実走(した)? reviewer|実走名簿'
assert_not_grep "TC-1 SKILL に旧語彙 (実走名簿) が残っていない" "$SKILL" '実走(した)? reviewer|実走名簿'
assert_not_grep "TC-1 save helper に旧語彙 (実走名簿) が残っていない" "$SAVE" '実走(した)? reviewer|実走名簿'
assert_not_grep "TC-1 ゲート script に旧語彙 (実走名簿) が残っていない" "$MGATE" '実走(した)? reviewer|実走名簿'
# reason カタログ (SKILL) と helper の WARNING で必須条件の記述が乖離しないことを pin する。
# 前 cycle は「目視で検出する」と宣言しながら同じ commit で drift させた
assert_grep "TC-1 SKILL の reason カタログが reviewers の一意性を含む" "$SKILL" 'reviewers\[\] が重複の無い非空配列'
assert_grep "TC-1 save helper の WARNING が reviewers の一意性を含む" "$SAVE" 'reviewers\[\] は重複の無い非空配列'

# --- 要求側 3/4: save helper (fail-loud 検証) ---
# save helper は必須条件を **1 箇所** (_missing 算出 jq) だけで判定する。強制用と診断用に
# 複製を持たないため、ファイル全体 grep でも「条件を緩めたら落ちる」検出力が成立する
# (複製があると片方を消しても他方が pin を満たしてしまう)。
assert_grep "TC-1 save helper が verdict enum を必須検証" "$SAVE" '\.verdict == "mergeable" or \.verdict == "fix-needed"'
assert_grep "TC-1 save helper が reviewers の配列型を必須検証" "$SAVE" '\(\.reviewers \| type\) == "array"'
assert_grep "TC-1 save helper が reviewers の非空を必須検証" "$SAVE" '\(\.reviewers \| length\) > 0'
assert_grep "TC-1 save helper が reviewers の一意性を必須検証" "$SAVE" '\(\.reviewers \| length\) == \(\.reviewers \| unique \| length\)'
# 判定を 1 箇所に保つ (複製が再導入されると検出力が失われる)
save_uniq_sites=$(grep -c '\.reviewers | unique | length' "$SAVE" || true)
assert "TC-1 save helper の必須条件判定は 1 箇所のみ" "1" "$save_uniq_sites"
# floor 2 を save 側へ持ち込むと 1 名 cycle の結果が保存すらされなくなる (TC-2 の sole ケース参照)。
# `>= 2` と `> 1` の両表記を塞ぐ
assert_not_grep "TC-1 save helper に sole-reviewer floor (2) を持ち込まない" "$SAVE" '\(\.reviewers \| length\) (>= 2|> 1)'
# 同値検査を入れると手組みの復旧用 JSON が保存不能 = merge 不能になり救済経路が閉じる
assert_not_grep "TC-1 save helper が verdict == overall_assessment を検査しない" "$SAVE" '\.verdict == \.overall_assessment'

# --- 要求側 4/4: merge ゲート (受け側。本 Issue では変更しない) ---
assert_grep "TC-1 ゲートが verdict の存在を必須にする" "$GUARD" 'has\("verdict"\)\|not'
assert_grep "TC-1 ゲートが reviewers の配列型を必須にする" "$GUARD" '\(\.reviewers \| type\) != "array"'
assert_grep "TC-1 ゲートが sole-reviewer floor 2 を維持する" "$GUARD" '\(\.reviewers \| length\) < 2'

# --- 書き手の単一性: verdict は実測必須ゲート helper のみ ---
mgate_verdict_writes=$(grep -c '\.verdict = (if \$blocking == 0 then "mergeable" else "fix-needed" end)' "$MGATE" || true)
assert "TC-1 gate helper の verdict 代入は 1 箇所" "1" "$mgate_verdict_writes"
# overall_assessment と同一式であることが「乖離しえない」の根拠。式が割れたら本 assert が落ちる
mgate_assessment_expr=$(grep -c '= (if \$blocking == 0 then "mergeable" else "fix-needed" end)' "$MGATE" || true)
assert "TC-1 verdict と overall_assessment が同一式から代入される" "2" "$mgate_assessment_expr"
assert_grep "TC-1 gate helper docstring が verdict の唯一の書き手であることを宣言" "$MGATE" '\*\*verdict は本 script が唯一の書き手\*\*'

echo ""
echo "=== TC-2: 正典形 JSON のゲート素通し E2E (AC-3 / T-03) ==="

SENTINEL="__RITE_TS_PLACEHOLDER_7f3a9b2c__"
E2E_PR=4242
E2E_ROOT="$TMP_ROOT/e2e"
mkdir -p "$E2E_ROOT/.rite/review-results"

# 5.3.0.M step 1 が Write する形 (verdict は書かない / reviewers は書く / verification は書かない)
STEP1="$TMP_ROOT/step1.json"
cat > "$STEP1" <<JSON
{
  "schema_version": "1.1.0",
  "pr_number": $E2E_PR,
  "timestamp": "$SENTINEL",
  "commit_sha": "0123456789abcdef",
  "overall_assessment": "fix-needed",
  "reviewers": ["code-quality-reviewer", "security-reviewer"],
  "findings": [],
  "non_blocking_findings": [],
  "guardrail_audit_log": []
}
JSON

if bash "$MGATE" --input "$STEP1" --reject-preset-verification >/dev/null 2>&1; then
  pass "TC-2 実測必須ゲートが正常終了"
else
  fail "TC-2 実測必須ゲートが正常終了 (rc=$?)"
fi
gate_verdict=$(jq -r '.verdict // "<absent>"' "$STEP1" 2>/dev/null)
assert "TC-2 ゲートが verdict を確定する (findings 0 → mergeable)" "mergeable" "$gate_verdict"
gate_reviewers=$(jq -c '.reviewers // "<absent>"' "$STEP1" 2>/dev/null)
assert "TC-2 ゲートが caller の reviewers を保持する" '["code-quality-reviewer","security-reviewer"]' "$gate_reviewers"

bash "$SAVE" --pr "$E2E_PR" --content-file "$STEP1" \
  --results-dir "$E2E_ROOT/.rite/review-results" >/dev/null 2>"$TMP_ROOT/save.err"
if grep -q 'JSON_SAVED=true' "$TMP_ROOT/save.err"; then
  pass "TC-2 正典チェーンの JSON が保存される"
else
  fail "TC-2 正典チェーンの JSON が保存される ($(head -3 "$TMP_ROOT/save.err" | tr '\n' ' '))"
fi

# ゲート本体に読ませる。RITE_STATE_ROOT で結果ディレクトリを指すのが guard の一次解決経路。
guard_input() {
  jq -n --arg cmd "$1" '{tool_name:"Bash", tool_input:{command:$cmd}}'
}
# 対照確認を先に置く: 同じ harness・同じ state root で **結果 JSON が無い** PR 番号を投げ、
# ゲートが確かに発火する (deny する) ことを示す。これが無いと、下の allow 判定は「ゲートが
# 何も出力しなかった」— つまり fail-open で素通りした場合 — と区別できない。
out=$(guard_input "gh pr merge 999999 --squash" \
  | RITE_STATE_ROOT="$E2E_ROOT" bash "$GUARD" 2>/dev/null)
ctl_decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)
assert "TC-2 対照: 結果 JSON 不在の PR はゲートが deny する (harness がゲートに到達している)" "deny" "$ctl_decision"

# ゲートの allow は **無出力** で表現される (pre-tool-bash-guard.sh は deny 経路でのみ
# permissionDecision を emit し、成功時は stdout に何も書かない)。よって判定は「出力が空」。
out=$(guard_input "gh pr merge $E2E_PR --squash" \
  | RITE_STATE_ROOT="$E2E_ROOT" bash "$GUARD" 2>/dev/null)
if [ -z "$out" ]; then
  pass "TC-2 正典形 JSON で merge ゲートが deny しない (AC-3)"
else
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  fail "TC-2 正典形 JSON で merge ゲートが deny しない (out=$out reason=$reason)"
fi

echo ""
echo "=== TC-3: 旧形式 JSON の deny 維持 (AC-4 / T-04) ==="

OLD_PR=4343
OLD_ROOT="$TMP_ROOT/old"
mkdir -p "$OLD_ROOT/.rite/review-results"
# ゲート導入前の正典 writer が実際に出していたキー集合 (verdict / reviewers 無し)
cat > "$OLD_ROOT/.rite/review-results/$OLD_PR-20260809120000.json" <<JSON
{
  "schema_version": "1.1.0",
  "pr_number": $OLD_PR,
  "timestamp": "2026-08-09T12:00:00+09:00",
  "commit_sha": "0123456789abcdef",
  "overall_assessment": "mergeable",
  "findings": [],
  "non_blocking_findings": [],
  "guardrail_audit_log": []
}
JSON

out=$(guard_input "gh pr merge $OLD_PR --squash" \
  | RITE_STATE_ROOT="$OLD_ROOT" bash "$GUARD" 2>/dev/null)
decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-json-incomplete"* ]]; then
  pass "TC-3 旧形式 JSON は現行どおり deny される"
else
  fail "TC-3 旧形式 JSON は現行どおり deny される (decision=$decision reason=$reason)"
fi
if [[ "$reason" == *"/rite:pr-review"* ]]; then
  pass "TC-3 deny 理由が再レビューへ誘導する"
else
  fail "TC-3 deny 理由が再レビューへ誘導する (reason=$reason)"
fi

echo ""
echo "=== TC-4: findings 非 0 cycle の verdict 確定 (AC-1 補完) ==="

STEP1B="$TMP_ROOT/step1b.json"
cat > "$STEP1B" <<JSON
{
  "schema_version": "1.1.0",
  "pr_number": $E2E_PR,
  "timestamp": "$SENTINEL",
  "commit_sha": "0123456789abcdef",
  "overall_assessment": "mergeable",
  "reviewers": ["code-quality-reviewer", "security-reviewer", "test-reviewer"],
  "findings": [
    {
      "id": "F-01",
      "reviewer": "code-quality-reviewer",
      "category": "code_quality",
      "severity": "HIGH",
      "scope": "current-pr",
      "file": "path/to/file.sh",
      "line": 42,
      "description": "Verification: repro bash x.sh => exit 1",
      "suggestion": "guard を追加",
      "status": "open"
    }
  ],
  "non_blocking_findings": [],
  "guardrail_audit_log": []
}
JSON
bash "$MGATE" --input "$STEP1B" --reject-preset-verification >/dev/null 2>&1
b_verdict=$(jq -r '.verdict // "<absent>"' "$STEP1B" 2>/dev/null)
b_assessment=$(jq -r '.overall_assessment // "<absent>"' "$STEP1B" 2>/dev/null)
assert "TC-4 blocking 残存で verdict=fix-needed" "fix-needed" "$b_verdict"
assert "TC-4 verdict は overall_assessment と一致する" "$b_assessment" "$b_verdict"
b_reviewers=$(jq -r '.reviewers | length' "$STEP1B" 2>/dev/null)
assert "TC-4 reviewers は findings 件数と独立に保持される" "3" "$b_reviewers"

if ! print_summary "$(basename "$0")" \
  "drift: merge ゲートの必須キー契約 (verdict / reviewers) が 4 者 (references/review-result-schema.md / skills/pr-review/SKILL.md / hooks/review-result-save.sh / hooks/pre-tool-bash-guard.sh) のいずれかで変更された可能性。書き手の分担 (verdict = scripts/review-measured-gate.sh のみ / reviewers = 5.3.0.M step 1) と floor 非対称 (save=非空 / ゲート=2) を review-result-schema.md §verdict と reviewers で確認すること。"; then
  exit 1
fi
