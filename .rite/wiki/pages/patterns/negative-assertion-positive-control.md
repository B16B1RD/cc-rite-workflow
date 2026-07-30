---
type: "patterns"
title: "否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す"
domain: "patterns"
description: "「出力が空であること」「canary が作られないこと」で pass する TC では、被テストコマンドの exit code が唯一残った crash signal。`|| true` を付けると abort と正常な無言が区別できなくなり、mutation を注入しても PASS する。肯定アサーション（grep で特定文字列を要求）は crash で fail するため同じ変更でも安全 — この非対称を見落としやすい。同じ fixture で「canary が作られる」ことを先に確認する positive control を置くと、fixture 破損と検証成功が区別できる。"
created: "2026-07-25T07:05:21Z"
updated: "2026-07-26T01:35:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T175144Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T180733Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T184410Z-pr-2013.md"
  - type: "reviews"
    ref: "raw/reviews/20260725T151649Z-pr-2020.md"
  - type: "fixes"
    ref: "raw/fixes/20260725T152249Z-pr-2020.md"
  - type: "reviews"
    ref: "raw/reviews/20260725T154346Z-pr-2020.md"
  - type: "fixes"
    ref: "raw/fixes/20260725T154630Z-pr-2020.md"
  - type: "reviews"
    ref: "raw/reviews/20260725T162025Z-pr-2020.md"
tags: ["test", "negative-assert", "positive-control", "fail-open", "mutation-testing"]
confidence: high
---

# 否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す

## 概要

否定アサーション（「出力が空であること」「canary ファイルが作られないこと」で pass する TC）は、**被テストコマンドの exit code が唯一残った crash signal** である。ここに `|| true` を付けると、abort と「正常に何も出さなかった」が区別できなくなり、mutation を注入しても PASS する。肯定アサーション（grep で特定文字列を要求する形）は crash すれば出力が出ないので fail する — **同じ `|| true` でも肯定側は安全、否定側は致命的**という非対称があり、これを見落としやすい。

## 詳細

### 非対称の構造

```bash
# 肯定アサーション: crash しても fail する（grep がマッチしない）
out=$(target_cmd 2>&1) || true
grep -q "expected marker" <<< "$out" || fail "marker missing"

# ❌ 否定アサーション: crash が「正常な無言」と区別できない
out=$(target_cmd 2>&1) || true
[ -z "$out" ] || fail "unexpected output"     # crash でも空 → PASS
```

否定側では exit code こそが「テストが本当に走った」証拠なので、握り潰してはならない。

```bash
# ✅ exit code を assert する
out=$(target_cmd 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "target_cmd aborted (rc=$rc)"
[ -z "$out" ] || fail "unexpected output: $out"
```

### positive control で fixture 生存を確認する

「canary が作られないこと」で pass する TC は、**子プロセスがそもそも動かなかった場合も pass する**。同じ fixture で「canary が作られる」ことを先に確認する control を置くと、fixture 破損と検証成功が区別できる。

```bash
# positive control: この fixture で canary が作られることを先に示す
run_with_canary_enabled
[ -f "$canary" ] || fail "positive control failed — fixture is broken"
rm -f "$canary"

# 本命の否定アサーション
run_with_canary_disabled
[ -f "$canary" ] && fail "canary must not be created"
```

起点事例では cycle 1 で `|| true` による crash signal 破棄を潰しておきながら、**新規テストの fixture に同型の fail-open を持ち込んでいた**（cycle 2 で検出）。否定側は「潰したつもり」でも別の形で再発しやすい。

### fixture 構築の `|| continue` も silent skip と同じ

```bash
# ❌ ツール欠落を握り潰す
tool_path=$(command -v "$tool") || continue
```

テスト fixture は **本体コード以上に fail-closed であるべき**で、必要なツールが無いなら即 `exit 1` する。あわせて `command -v kill` はシェルビルトイン名を返すため、`ln -sf` すると自己参照 symlink になる（絶対パス検証を入れて弾く）。

### control は「本体が実際に読む入力」から派生させる

control をどう作るかで捕捉範囲が決まる。同じ素材から**独立に組み直した** fixture を control に使うと、本体側の入力生成が壊れても control は緑のまま通り、否定アサーションは静かに vacuous へ戻る。control は**本体アサーションが実際に食わせる入力ファイルそのもの**から派生させ、判定を分ける 1 変数だけを差し替える形にする。

```bash
# 本体が読む入力
build_input > main_in.json
# ❌ 同じ素材から別に組み直した control（main_in.json の破損を捕まえられない）
build_input --as-reviewer > ctl_a.json
# ✅ 本体の入力から 1 フィールドだけ差し替えた control
jq --arg t "$REVIEWER" '.transcript_path = $t' main_in.json > ctl_b.json
```

この非重複性はコメントに明記しないと失われる。既に似たケースが隣接していると、後続サイクルで「重複だから」と削除される。

### 「無出力が正常」な契約では抽出値の非空を liveness signal にできない

被テスト側が permit を**無出力**（rc 0 + stdout 空）で表現する設計だと、`decision=$(... // empty)` の非空チェックは liveness signal として使えない — 正常系で必ず空になるからだ。この場合、liveness は control（同じ入力で deny が返ること）が担い、本体は permit 契約を**肯定形**（`rc = 0` かつ出力が空）で assert する。役割を分けないと、AC の「空出力でも FAIL せよ」と「正常系は PASS せよ」が正面衝突する。

Issue 起票時に提示された修正案が実装の出力契約と噛み合わないことがある。同一ファイル内の既存ヘルパー（allow を `rc 0 かつ空出力` と定義する assert 関数など）を正典として実測で前提を確認してから設計を決める。

### 判定順序で診断の正確さが決まる

出力形状より exit code を先に見ると、「非ゼロ終了しつつ正しい判定結果を返す」経路（fail-closed の deny + exit 2 等）が「クラッシュ」と誤診断される。**出力形状 → exit code → PASS** の順にすると両者が正しく分かれる。

### 検証は mutation で

否定アサーションの非空虚性は、**守っている挙動を実際に壊して赤くなるか** で確認する。`|| true` が入っている状態で mutation を注入しても PASS するなら、そのアサーションは何も守っていない。

旧実装と新実装を**同じ変異**に当てて対比すると増減が議論の余地なく示せる。特に「旧実装では全テストが緑のまま通る変異」を 1 つ見つけられると、問題が実在することの決定的証拠になる。テストが timeout（rc=124）を PASS 扱いしていたケースでは、その guard 自身が「timed-out hook fails OPEN」を防ぐ目的だったため、「設計どおりの permit」と「死んだ結果の permit」を区別できないことが致命的だった。

## 関連ページ

- [absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する](./absence-pin-base-present-head-absent-single-line.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)

## ソース

- [PR #2013 review cycle 1 — 否定アサーションに `|| true` を足すと signal がゼロになる](../../raw/reviews/20260724T175144Z-pr-2013.md)
- [PR #2013 fix results — 失敗の表面化で解く（exit code を assert する）](../../raw/fixes/20260724T180733Z-pr-2013.md)
- [PR #2013 fix results (cycle 2) — positive control / fixture の `|| continue` 禁止](../../raw/fixes/20260724T184410Z-pr-2013.md)
- [PR #2020 review cycle 1 — control の派生元 / hook 出力契約の読み違い](../../raw/reviews/20260725T151649Z-pr-2020.md)
- [PR #2020 fix results — 出力形状優先の判定順序と stderr 診断](../../raw/fixes/20260725T152249Z-pr-2020.md)
- [PR #2020 review cycle 2 — mutation testing による control の非重複性実証](../../raw/reviews/20260725T154346Z-pr-2020.md)
- [PR #2020 fix results (cycle 2) — load-bearing な派生元をコメントに明記](../../raw/fixes/20260725T154630Z-pr-2020.md)
- [PR #2020 review cycle 4 — 旧新対比と蒸し返さない規律](../../raw/reviews/20260725T162025Z-pr-2020.md)
