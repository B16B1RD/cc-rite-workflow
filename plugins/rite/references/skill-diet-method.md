# SKILL 記述ダイエットの手法

SKILL.md の**散文層**（モデルが読む指示の密度）を削り、**機械レール**（他のコードが文字列一致で
参照する部分・モデルが逐語実行する部分）を一切変えずに済ませるための手法。

open スキルでのパイロット（#2277）で確立し、実測値を添えてある。第 1 波（iterate / fix / pr-review）は
本ファイルの 3 節をそのまま適用する。

## 1. 線引きチェックリスト

残す対象は 2 層に分かれる。**checker が機械検証するのは前者だけ**で、後者は人間が目視で守る。

**層 A — `skill-rail-diff-check.sh` が機械検証する**（fenced block・markdown table row。インデント有無を問わない）:

- [ ] bash / text fenced block — **コメントを含めて 1 バイトも変えない**。in-fence コメントは
      「rationale っぽく見えても」レールの一部として扱う（判定を曖昧にすると自動検証が壊れる）
- [ ] sentinel literal と `[CONTEXT] FOO=` marker 名を**載せた分岐表の行**（`fenced block` 内も同様）

**層 B — checker の対象外。diff を目視で確認する**:

- [ ] 見出し（`## ステップ N`）— 他スキルが「ステップ 3.5」の形で参照する de facto contract。
      改名しても checker は green を返す（実測: open のステップ 6 を改名しても検出されず、
      `grep -c "ステップ 6" plugins/rite/skills/lint/SKILL.md` = 12 の参照先が消えた）
- [ ] outcome と検証条件（「何が成立したら次へ進むか」「何を観測したら戻るか」）
- [ ] 短い mandate（`silent skip 禁止` / `再 invoke しない` / `破棄しない`）
- [ ] 散文中に埋め込まれた sentinel literal / `[CONTEXT] FOO=` marker 名（分岐表・fenced block の
      外にあるもの）。実例: open のステップ 1.4 は `[CONTEXT] WORKFLOW_LANGUAGE=` を散文行にのみ持ち、
      リポジトリ内の唯一の定義箇所であるにもかかわらず checker のレールに含まれない

**散文層 = 削る**:

- [ ] **inline rationale** — 「なぜこの設計か」「過去にどの障害が起きたか」「Issue #N で入った」。
      同梱 `references/rationale.md` へ退避し、本体には `rationale: references/rationale.md#<anchor>`
      の 1 行だけ残す
- [ ] **行動列挙** — 表・bash・outcome から逆導出できる手順の言い換え
- [ ] **ナレーション** — 「本ステップは〜を担う」「以下を実行する」の前置き
- [ ] **反復 MUST** — 同じ禁止を段落・引用・箇条書きで 3 回言い直しているもの。1 回に統合する
- [ ] **経緯の注記** — 「旧 start.md の flat 設計を継承」「本 PR で削除済」等、現在の実行に効かない履歴

**迷ったときの判定**: その文を消してモデルが**次に打つコマンドを間違える**なら残す。判断の質だけが
落ちるなら rationale へ退避する。どちらでもないなら削る。

## 2. pin 移送手順

SKILL.md の記述を pin しているテストは 2 種類あり、扱いが違う。着手時に**両方を全数列挙**してから
削り始める（削ってから壊れたテストを直す順序にしない — 何が contract だったか事後に判別できなくなる）。

### 2.1 棚卸し

```bash
# 直接 pin: テストがファイルパスを名指ししているもの
grep -rn "skills/<target>" plugins/rite/hooks/tests/ plugins/rite/scripts/tests/ plugins/rite/scripts/

# glob 走査 pin: skills/**/*.md を舐める checker（対象を名指ししないが必ず通る）
grep -rn -E "(find|grep -r).*skills|SKILLS_DIR|SCAN_DIR" plugins/rite/hooks/scripts/*.sh
```

テスト名 × 分類 × 移送方針の表を PR に残す。

| 分類 | 見分け方 | 移送方針 |
|---|---|---|
| **bash 抽出型** | checker script を SKILL.md に対して実行する（`check-no-direct-gh-issue-create.test.sh` 等） | **変更不要**。機械レールを触らない限り通る |
| **散文 pin 型** | `assert_grep "<日本語フレーズ>" "$SKILL_MD"` | 退避でフレーズが移動するなら、pin も退避先ファイルへ追随させる。フレーズが分岐表・bash 側にあるなら pin は据え置き |
| **glob 走査型** | checker が `skills/**/*.md` を舐める | 全数を実行して green を確認する。個別移送は不要 |

### 2.2 逐語一致の証明

**層 A（fenced block と table row）については** `skill-rail-diff-check.sh` が証明する:

```bash
bash plugins/rite/hooks/scripts/skill-rail-diff-check.sh --skill plugins/rite/skills/<target>/SKILL.md
```

インデント有無を問わず fenced block（fence 行込み）と table row を抽出し、base ref（既定
`origin/develop`）と突き合わせて 1 バイトでも違えば exit 1 になる。base ref が解決できない・
rail が 0 行になったときは exit 2 で止まる（証明が空回りしたまま green を返さない）。

**層 B（見出し・outcome・mandate・散文中の sentinel literal / marker 名）は checker が見ない。**
§1 の層 B チェックリストを diff に対して目視で確認する。checker の green は「散文しか触っていない」の
証明ではなく「fenced block と table row は触っていない」の証明である。

**rc=0 だけでも足りない。** stderr に `machine rail identical` が出ていることを確認する。出ていなければ
base ref に対象ファイルが無く（skill の新設・rename・移動）、突合は一度も走っていない。

**diet を始める前に 1 回実行して green を確認してから**削り始めると、途中で壊した瞬間に気付ける。

### 2.3 退避先の作法

- 退避先は同梱 `skills/<target>/references/rationale.md`（共有 references ではない — 1 スキル固有の
  why を全体で共有すると読み手が増えるだけで減らない）
- 退避先に **分岐表・sentinel 一覧・bash を複製しない**。本体が SoT で、退避先は why のみ
- anchor 名は本体のポインタ行と 1:1 にする（`#branch-gate` ↔ `rationale: references/rationale.md#branch-gate`）

## 3. 測定テンプレート

### 3.1 行数分類

```awk
# measure.awk — usage: awk -f measure.awk <SKILL.md>
BEGIN { inb = 0 }
/^[[:space:]]*(```|~~~)/ { inb = !inb; fence++; fence_b += length($0) + 1; next }
{
  n = length($0) + 1
  if (inb)                       { code++;  code_b  += n }
  else if ($0 ~ /^[[:space:]]*\|/) { tbl++; tbl_b   += n }
  else if ($0 ~ /^[[:space:]]*$/){ blank++; blank_b += n }
  else if ($0 ~ /^#/)            { hdr++;   hdr_b   += n }
  else                           { prose++; prose_b += n }
}
END {
  printf "lines_total=%d lines_rail=%d lines_prose=%d lines_blank=%d\n", \
    code + tbl + hdr + blank + prose + fence, code + fence + tbl, prose, blank
  printf "bytes_total=%d bytes_rail=%d bytes_prose=%d\n", \
    code_b + tbl_b + hdr_b + blank_b + prose_b + fence_b, code_b + fence_b + tbl_b, prose_b
}
```

**行数を主指標にしない。** open パイロットの実測（測定時点: `9bf3ebb8`。以降 open/SKILL.md を触る
たびに動くため、引用ではなく再測定して使うこと）: 総行数は 642 → 615（−4.2%）にしかならなかったが、
散文バイト数は 19,238 → 12,359（**−35.8%**）だった。理由は総行数の内訳にある — diet 前の 642 行は
機械レール 305 行 + 空行 161 行 + 見出し 40 行で 8 割を占め、そもそも散文は 136 行しかない。加えて
日本語散文は 1 行が長い（削減前 141 B/行）ため、1 行削るだけで bash 3 行分のバイトが減る。

**主指標は `bytes_prose`、副指標が `lines_prose`。`bytes_rail` は before/after で完全一致すること**
（一致しなければレールを壊している）。

### 3.2 退避／圧縮の作業比率

diet の diff を hunk 単位で「退避（`rationale: references/` ポインタが入った）」と「圧縮（その場で
書き換えた）」に分け、どちらがどれだけ効いたかを測る。ホスト配分（安価モデルへ回せる比率）の根拠になる:

**base ref レンジを必ず渡す。** ref を省いた `git diff` は working tree と index の差分を測るため、
diet を commit した後は空入力になり、`hunks=0 net=0B` を exit 0 で無言のまま返す（測ったのでは
なく、測る対象が無かっただけ）。空入力は非ゼロで止める:

```bash
BASE=${BASE:-origin/develop}
git diff "$BASE...HEAD" --unified=0 -- plugins/rite/skills/<target>/SKILL.md | awk '
/^@@/ { flush(); inhunk = 1; rem = 0; add = 0; isexile = 0; next }
inhunk && /^-/ { rem += length($0); next }
inhunk && /^\+/ { add += length($0); if ($0 ~ /rationale: references\//) isexile = 1; next }
function flush() {
  if (!inhunk) return
  if (isexile) { ex_h++; ex_rem += rem; ex_add += add } else { cp_h++; cp_rem += rem; cp_add += add }
}
END {
  flush()
  if (ex_h + cp_h == 0) {
    print "ERROR: hunk が 0 件 — BASE を確認 (現在: 空入力)" > "/dev/stderr"
    exit 1
  }
  printf "exile:    hunks=%d net=%dB\n", ex_h, ex_add - ex_rem
  printf "compress: hunks=%d net=%dB\n", cp_h, cp_add - cp_rem
}'
```

open パイロットの実測（測定時点: `9bf3ebb8`）: **退避 12 hunk で −3,766 B（削減の 54.7%）、圧縮
36 hunk で −3,116 B（45.3%）**。退避は hunk あたりの効きが圧縮の約 3.6 倍で、判断をほとんど伴わない
（該当段落を references へ移して 1 行ポインタに置き換えるだけ）。**削減の過半は機械的作業であり、
安価なホストへ回せる。**

### 3.3 挙動の非退行（観測点）

diet 後の `/rite:open` を 1 回実行し、以下が従来どおりであることを確認する。行数ではなく**遷移**が
非退行の証拠になる:

- [ ] `[CONTEXT] RESUME_DISPATCH=` / `MULTI_SESSION_ENABLED=`（`SOURCE=branch-gate` 付き）/ `WT_CASE=` /
      `WORKTREE_INVARIANT=ok` / `OPEN_PLAN_MODE=` が順に emit される
- [ ] flow-state の phase が `init → branch → plan → lint → pr` と進む
- [ ] `[lint:*]` と `[pr:created:N]` を受け取って完了通知に到達する
- [ ] batch 実行時にステップ 3.4 で停止しない（`OPEN_PLAN_MODE=batch`）

## 4. 適用順序

1. pin 棚卸し（§2.1）→ 表を PR に残す
2. before 計測（§3.1）+ `skill-rail-diff-check.sh` を green で確認（§2.2）
3. rationale 退避（§2.3）— 効きが大きく判断が要らないのでここから
4. 散文圧縮（§1 層 A のチェックリスト）
5. **層 B の目視確認**（§1 層 B チェックリスト × diff）— 見出し・outcome・mandate・散文中の sentinel
   literal / marker 名が変わっていないこと。checker はここを見ないので、この step を飛ばすと層 A の
   green だけで「散文しか触っていない」と誤認する
6. after 計測（§3.1, §3.2）+ レール逐語一致を再確認（`machine rail identical` の出力まで見る）
7. 対象スキルに `references/` を新設した場合、`docs/SPEC.md` の skills ツリーの当該行へ
   `(+ references/rationale.md)` を追記する（既存 10 スキルと同じ慣行）
8. 全 suite + `sentinel-contract-check.sh --all` を green で確認
9. 遷移観測（§3.3）
