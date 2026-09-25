---
type: "patterns"
title: "pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する"
domain: "patterns"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/patterns/pin-literal-uniqueness-verified-by-mutation.md"
description: "散文の実行契約を守る静的 assert（pin）は、**張っただけでは守れていない**。"
created: "2026-08-02T22:05:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260802T074021Z-pr-2052.md"
  - type: "reviews"
    resource: "raw/reviews/20260802T080828Z-pr-2052.md"
  - type: "fixes"
    resource: "raw/fixes/20260802T082508Z-pr-2052.md"
  - type: "fixes"
    resource: "raw/fixes/20260804T145425Z-pr-2111.md"
  - type: "reviews"
    resource: "raw/reviews/20260813T094525Z-pr-2306.md"
  - type: "fixes"
    resource: "raw/fixes/20260813T094616Z-pr-2306.md"
  - type: "fixes"
    resource: "raw/fixes/20260829T181603Z-pr-2468.md"
  - type: "fixes"
    resource: "raw/fixes/20260829T194742Z-pr-2468.md"
  - type: "reviews"
    resource: "raw/reviews/20260906T134450Z-pr-2582.md"
  - type: "fixes"
    resource: "raw/fixes/20260906T135449Z-pr-2582.md"
  - type: "reviews"
    resource: "raw/reviews/20260911T120212Z-pr-2684.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T083015Z-pr-2808.md"
  - type: "reviews"
    resource: "raw/reviews/20260925T095339Z-pr-3078.md"
  - type: "reviews"
    resource: "raw/reviews/20260925T102510Z-pr-3081.md"
  - type: "reviews"
    resource: "raw/reviews/20260925T110204Z-pr-3084.md"
  - type: "reviews"
    resource: "raw/reviews/20260925T115338Z-pr-3086.md"
tags: ["pin", "mutation-testing", "static-assert", "producer-consumer-symmetry", "drift-detection"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5[1m]", at: "2026-09-25T11:57:22Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5"
    at: "2026-08-30T05:20:00Z"
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-09-11T12:08:00Z"
  - by: "rite-wiki-ingest/claude-opus-5[1m]"
    at: "2026-09-14T08:45:00Z"
---

# pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する

## 概要

散文の実行契約を守る静的 assert（pin）は、**張っただけでは守れていない**。pin literal がラベルの主張する契約より広い文字列だと、対象行を消す変異が全緑で生存する。pin を足したときの確認手順は 2 段階あり、どちらも省略できない。

さらに、marker 契約の pin は **producer 側と consumer 側を対で**張らないと守るものが無くなる。

## 詳細

### 失敗の型 1: pin literal が対象行に固有でない

起点事例は同じ失敗を 2 サイクル連続で起こした。

| サイクル | pin literal | SKILL.md 内の hit 数 | 結果 |
|---|---|---|---|
| 4 | `WIKI_INGEST_STATS=aborted` | 2（表の行 + bash ブロック） | 対象行を消しても kill しない |
| 5 | `n_stats_abort` | 5（SKILL.md 内に分散） | 同じ理由で再発 |

`assert_grep` のラベルは「表のこの行が存在すること」を主張しているのに、pin literal は表以外にも一致する。対象行を削除する変異を注入しても、別の箇所が一致して assert は緑のまま通る。

**ラベルの文言を書き換えたら pin literal も追随させる。** ラベルと literal が指す対象がずれると、テストは「何かが存在すること」しか検証しなくなる。

### 手順: 全編集を適用してから計測する

```bash
# (a) 編集をすべて適用した後に hit 数を確認する
grep -cE '<pin literal>' plugins/rite/skills/<skill>/SKILL.md   # => 1 であること

# (b) 対象行を消す変異を注入し、自分の assert がちょうど 1 件 FAIL することを実測
```

**編集前に計測してはならない。** 同一コミット内の別修正が literal 自体を消したり増やしたりするため、数値が stale になる。起点事例では実際に、後続の修正（F-08）が先行修正（F-02）の pin 対象文字列「最後の Raw Source を処理したときにのみ実行」を消していた。

### 失敗の型 2: consumer だけ pin して producer が無 pin

marker 契約（`[CONTEXT] KEY=value` を emit する側と、それを読んで分岐する側）で、**consumer（展開表）の 2 行だけ pin し producer（emit 契約）が無 pin** という非対称が起きた。

producer が消えると、正常サイクルでも「marker なし → ⚠️ 未確認」が毎回誤発火する。consumer の pin は producer の保証なしでは守るものが無い。

**marker 契約を pin するときは emit 側と解釈側を対で pin する。**

### 失敗の型 3: cp fixture は「実体が持たない構造」を pin できない

配布物を `cp` して fixture にするテストは、**実体が変わると pin 対象も一緒に消える**。テスト総数が変わらないため差分レビューでは見えない。

起点事例で実測された例:

- テンプレートに 5 列テーブルを新設したが、テストは前文しか見ていなかった
- ヘッダー列名の改称（`サマリー` → `概要`）も、表ブロックの全削除も、suite 緑のまま通った（PASS:182 FAIL:0）

さらに悪いことに、**同じコミットが「cp fixture は持たない形式を pin できない」という原則を自ら明文化して literal fixture を 1 本追加していた**のに、その原則を自分が追加した構造には適用していなかった。

> 原則を書いた側の変更にこそ、その原則を適用したか確認する。

cp fixture（配布物の回帰検知）と literal fixture（規則そのものの pin）は目的が異なるので**併用し、TC 番号も分ける**。

### 失敗の型 4: pin されている表に行を足すときの非対称

pin 語句を壊して CI を赤にした反省から文言を復元した一方、**同じ表に新しく足した行**には pin が無かった。削除しても全 111 テストが緑のまま通ることが変異注入で実測された。「唯一の下流検出器」と自称する行が無 pin という非対称。

**pin されている表に行を足すときは、その行の pin も同時に足す。**

### fix が追加した TC 自身にも代表変異を当てる（cycle 3 fix）

「検出力系 fix は変異の fail 化を実測してから commit する」規律を守っていても、**fix 自身が追加した TC の検出力**は検証対象から漏れやすい。起点事例では cycle 2 で追加した invocation-symmetry TC がフラグ「名」の集合突合のみで「呼び出し行の実体」を pin していない穴が cycle 3 で指摘された。以後は fix が追加した TC にも代表変異（対象行の削除・literal の置換）を当てて kill を実測してから commit する。この検証は cycle 3 fix で TC の診断行に潜んでいた set -u バグ（失敗経路でのみ発火する未エスケープ変数）まで検出した — **fix 前 mutation は修正の妥当性検証であると同時に、その修正が testable かの検証でもある**。

### 散文を書き換える前に pin 依存を全走査する

手順書の散文は実行契約であると同時にテストの検査対象でもある。段落単位で書き直すと、その段落中の文字列を pin していたテストを巻き込んで壊す。

```bash
grep -rn '<特徴的な文字列>' plugins/rite/hooks/tests/
```

起点事例では 14 文字列を事前走査して 2 件が test に依存していることを検出した。一度は事前走査を怠って `outstanding-items-contract.test.sh` の assert 語句を巻き込み削除し、CI を赤にしている。

そのとき pin されていた不変条件は新実装でも成立していたので、**直すべきはテストではなく文言側だった**。テスト側の assert を消して緑にするのは、その Issue の charter が無い限り禁じ手。

### 空振りの 2 形: ファイル全体スコープと `grep -c` の行カウント

同一 PR で 2 つの空振り形を実測した。どちらも「pin を張った」実感だけが残り、検出力はゼロ。

| 空振りの形 | 生存する変異 | 対処 |
|---|---|---|
| ファイル全体を見る `assert_grep` | 対象ブロックの行を消しても、同一文字列が他ブロックに在れば PASS | `assert_grep_in_section` でブロックへスコープする |
| `grep -c` で出現回数を数えたつもり | `grep -c` は**行数**しか数えないため、同一行に重複させる変異が生存 | `grep -o ¦ wc -l` で出現回数を数える |

`assert_grep_in_section` へ移すときは **end アンカーの選び方**が新しい罠になる。
`^#### ` のような見出しパターンを end に使うと **start 行自身が end にも一致**し、
awk の flip-flop レンジが 1 行で閉じる。end は直後の散文行やコード行にアンカーする。

### pin を「深く」伸ばすときは既存リテラルを残したまま後ろへ継ぎ足す

pin をより深い内容まで伸ばすとき、途中のリテラルを `.*` に吸収させると、**伸ばした先を守る
代わりに手前を守らなくなる**。実測では件数内訳まで pin を伸ばした結果、ラベル文字列
（`follow-up 再検証: `）の pin が `.*` に吸われ、ラベルだけを改変する変異が 172 PASS のまま
生存した。伸ばすときは既存のリテラルを残し、その後ろへ継ぎ足す。

### pin はキーだけでなく極性・帰結まで含める

`「X は必ず Y」` という散文を `X` だけで pin すると、`Y` を反転させる変異が生存する。
同様に、機構の後半（surface 側）だけを pin すると前半（捕捉側）を切る変異が生存し、
機構全体が無効化されても緑のまま通る。

### negative assert に GNU 拡張を書くと fail-open する

`assert_not_grep` のパターンで `\s` を使うと GNU 拡張依存になり、BSD の ERE では未定義に落ちて
**恒常的に不一致 = fail-open** する。positive assert は同じ事故で FAIL して露見するが、
negative assert は静かに通る。`[[:space:]]` を使う。

### 不在チェックの guard を `elif` で足すと兄弟 assert がまるごと skip される

不在チェックの guard を `elif` で足すとき、後続ブロック全体が `else` 側に入っていると、
その guard が発火した瞬間に**無関係な兄弟 assert がまるごと skip される**。実測では
171 PASS が 131 PASS に落ちた。suite は赤になるので gate としては機能するが、診断粒度が失われる。
ヘルパー側が既に fail-loud に扱う条件（`assert_grep` の file-not-found 分岐など）を、
呼び出し側で二重に guard しない。

### チェックリスト

| 段階 | 確認 |
|---|---|
| pin literal 選定 | 全編集を適用後、`grep -c` で hit 数 1（出現回数が要るなら `grep -o ¦ wc -l`） |
| pin のスコープ | ファイル全体ではなく対象ブロックへ。section 版の end は見出しでなく直後の行にアンカー |
| pin の内容 | キーだけでなく極性・帰結まで。深く伸ばすときは既存リテラルを残して継ぎ足す |
| negative assert | `\s` ではなく `[[:space:]]`（GNU 拡張は BSD で fail-open） |
| pin 有効性 | 対象行を消す変異を注入し、自分の assert が 1 件 FAIL |
| marker 契約 | producer（emit）と consumer（解釈）を対で pin |
| fixture 種別 | cp fixture と literal fixture を併用、TC 番号を分ける |
| 表への行追加 | 既存行に pin があるなら新規行にも pin |
| 散文の書き換え前 | 対象段落の文字列で `hooks/tests/` を grep |

### 交替（alternation）を含む pin は「別文脈への当たり」を先に潰す

`grep -E 'A|B'` のように交替を素で書いた pin は、意図した実行行だけでなく、**その literal を引用している説明文**にも当たる。説明文が同じファイルに常在すると、pin は対象の実行行を消しても生き残り、退行を検出しない（恒真化）。

観測例では、消費側 pin の交替に含めた語が判定ロジックの説明文（`TREND_REASON` の解説）に当たり、fire 側の腕を削除しても pin が pass した。1 行に閉じた `grep -c` の一意性確認では、行が複数ある場合に気づけない。

- 交替を書く前に、各枝を**単独で** `grep -n` して当たった行を目視する
- 説明文に当たるなら、行頭アンカー・周辺トークンの併記・`grep -F` の固定文字列化のいずれかで実行行に限定する
- 消費側 pin に `|` を書くなら ERE 交替にしないようエスケープする。fire 腕は判定語（例: `lost_gate=fire`）まで固定し、raw lost 入力も対で pin する
- 確定は必ず変異注入で行う。**対象の腕を 1 つ削除して pin が落ちること**を実測する

### 追記: 節限定は必要条件であって十分条件ではない

同じ literal が同一節内に複数あるとき、節を限定した存在検査は対象行を消しても満たされ続ける。pin したい主張が「A かつ B」の複合であるなら、単一 literal ではなく主張のペア（同一行に A と B が同時に出現する）か、行形状のアンカー（表の行なら行頭のセル形状）で書く。

加えて、区間抽出が「次の見出しで閉じる」ことを前提にしていると、対象節がファイル末尾まで続く構造では窓が意図の何倍にも広がる。pin を直したら、対象行を削除して実際に red になることを確認する。緑のままなら、その pin は名乗った対象を守っていない。テストが緑であること自体は修正完了の根拠にならない。

### 部分文字列 pin は限定句の削除を検出しない — 全文で pin し、旧文言は stale 側へ

散文の `assertIn` は部分文字列一致なので、pin literal が文の**核だけ**（例: 「選定 reviewer 全員の回収は未検証」）だと、その前に付く限定句（「絶対パス方式による」）を削っても、別の限定句（「他ホストでの」）に差し戻しても緑のまま通る。限定句こそが主張の範囲を決めているのに、pin はそれを守っていない。

- 限定句を含む**文全体**を pin literal にする。旧文言は `assertNotIn` の stale リストへ足し、復帰も検出する
- 既存の短い pin が新しい全文 pin の**真部分文字列**なら、残さず置換してよい。全文が存在すれば部分文字列も存在するので `assertIn` は包含され、検証力は落ちない（残すのは重複であって安全側ではない）
- 効果の確認は本ページの手順どおり: pin を足す**前**に各変異（限定句削除 / 旧文言復帰 / 後続文削除）で suite が green のまま通ることを実測し、足した**後**にそれぞれが対応する assert で red になることを実測する。生存し続ける細粒度変異（末尾への後置弱化、節間移動）は契約に現れない限り non-blocking として記録し、追いかけて pin を増築しない

### 行順 assert の探索パターンが複数行に当たると、先頭一致が別の行へ乗り換える

「診断行が案内行より前に出る」ことを `grep -n '<案内の語句>' ¦ head -1` で得た行番号の比較で固定したところ、案内の語句が案内行とは別の説明行にも含まれていた。案内の呼び出しを消す変異を注入すると、`head -1` が残った説明行へ乗り換え、行番号の比較は緑のまま通った（順序そのものを入れ替える変異は検出した）。

- 行番号を取る grep にも「その行に固有」の確認を当てる。`grep -c` で 1 行であることを確かめ、当たるなら行頭の固定文言（例: `^  対処: `）までアンカーする
- 順序 assert は「A が B より前」という 2 点の関係なので、A と B の **それぞれ** を消す変異で赤くなるかを実測する。順序入れ替えの変異だけでは、どちらかの行が別の行へ乗り換える穴を検出しない
- 否定側（「gh の接頭辞で出ない」）の `assert_not_grep` は、肯定側と揃えて行頭アンカーを足すと条件が緩くなる。否定 assert ではアンカーなしの方が厳しい

### 停止する bash ブロックは文字列ではなく実行で固定する

失敗時に `[review:error]` を出して止まる bash ブロックを `echo "[review:error]"; exit 1` の部分文字列で pin したところ、同じ文字列がブロック内の 2 つの検査行（絶対パス判定と読取確認）の両方にあった。どちらか一方の検査を消す変異は、もう一方が文字列を満たすため緑のまま生存し、読めないパスでも処理が先へ進む状態を検出しなかった。

- 複数の検査が同じ停止文字列を共有するブロックは、文字列の存在ではなく**ブロックを抽出して実行し、rc と出力を assert する**（正常入力・各検査に掛かる入力をそれぞれ 1 ケース）
- 実行による固定なら、どの検査行を消しても対応するケースが赤くなる

### 「複数の定義箇所が同じ規則を持つ」は判定語の位置まで拘束する

3 つの文書が同じ分類規則を持つことを「規則文を含む行に `class A` がある」で固定したところ、2 つの文書では同じ行に既存の `class A` があり、規則の判定句を `class B` に反転させても緑のまま通った。直した後に足した限定文の pin（2 語句の同一行共起）も、限定の主語を書き換える変異で同じように生存した。

- 判定句は「規則文より後ろで最初に現れる判定語」、主語は「限定句より前で最後に現れる判定語」のように、**規則文からの相対位置**で読む
- 複数箇所の一致を固定するときは、各箇所で判定語を反転する変異をそれぞれ注入して、どの箇所でも赤くなるかを実測する

### 位置で判定語を読む pin は、同じ語を含む句が同じ行に足されると崩れる

上の「規則文からの相対位置で読む」pin を入れた直後、同じ行に「不確実を理由に class B へ倒さない」という但し書きを足した。「限定句より前で最後の判定語」を主語とみなす pin は、この但し書きの `class B` を主語と取り違え、限定を class A 側の行末へ移す変異も、主語「class B の」を消す変異も緑のまま通した。

- 判定語を取る前に、同じ判定語を含む既知の句（但し書き等）を文字列として除く。除く句そのものの存在は別の assert で固定しておけば、句の文言が変わったときは先にそちらが赤くなり、除去の空振りで素通りする経路は残らない
- pin の設計と、pin が読む行への文言追加を同じ変更で行うときは、追加後の本文の上で変異実験をやり直す。pin を書いた時点の前提（その行に判定語は 1 つ）は追加で崩れる

### 折り返した散文は行ではなく文で pin する

折り返した英文の各要点を「1 物理行に収まる固定文字列」で pin したところ、pin は行の断片になり、折り返しの直後に来た述語・否定・発火条件が固定から外れた。漏れた行を足しても、次に段落を折り返し直した時点で既存の pin が短くなり、固定していた要点がまた外れる回帰が起きた。

- 対象の節を切り出して空白を 1 つに正規化し、その文字列に対して文全体を `grep -F` で固定する。折り返し位置に依らなくなる
- 折り返しだけを変える変異が green のままであることを陽性対照として実測し、pin が折り返しに依存していないことを確かめる
- 節への帰属を範囲で固定するときは、終端を特定の見出し名ではなく「次の同レベル見出し」で決める。見出しの改名や間への節の挿入で範囲がずれないようにする

## 関連ページ

- [assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる — positive control を対で置く](../anti-patterns/assert-not-grep-vacuous-without-fixture-scope.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)

## ソース

- [fix 結果](../../raw/fixes/20260802T074021Z-pr-2052.md)
- [PR 2052 review cycle 5: pin uniqueness, marker producer/consumer symmetry, guard-induced dead code](../../raw/reviews/20260802T080828Z-pr-2052.md)
- [PR 2052 fix cycle 5: pin selection after edits, producer/consumer marker pins, emit-point relocation](../../raw/fixes/20260802T082508Z-pr-2052.md)
- [fix 結果](../../raw/fixes/20260804T145425Z-pr-2111.md)
- [交替を素で書いた消費側 pin が説明文に当たり fire 腕の退行を検出しなかった](../../raw/reviews/20260813T094525Z-pr-2306.md)
- [pin fix (消費側 pin の | をエスケープし fire 腕と raw lost 入力を固定)](../../raw/fixes/20260813T094616Z-pr-2306.md)
- [ファイル全体スコープと `grep -c` の 2 つの空振り形、flip-flop end アンカー](../../raw/fixes/20260829T181603Z-pr-2468.md)
- [NB sweep results（pin を伸ばすときのリテラル吸収、`elif` guard による兄弟 assert の skip）](../../raw/fixes/20260829T194742Z-pr-2468.md)
- [レビュー結果](../../raw/reviews/20260906T134450Z-pr-2582.md)
- [fix 結果](../../raw/fixes/20260906T135449Z-pr-2582.md)
- [レビュー結果（部分文字列 pin と限定句の削除、真部分文字列の置換）](../../raw/reviews/20260911T120212Z-pr-2684.md)
- [行順 assert の探索パターンが別の行にも当たり案内の削除を見逃した](../../raw/reviews/20260914T083015Z-pr-2808.md)
- [レビュー結果（同じ文字列を持つ 2 行の片方を消す変異が生存）](../../raw/reviews/20260925T095339Z-pr-3078.md)
- [レビュー結果（複数箇所の規則一致の pin が判定句の反転を検出しない）](../../raw/reviews/20260925T102510Z-pr-3081.md)
- [レビュー結果（但し書きの判定語を主語と取り違える位置 pin）](../../raw/reviews/20260925T110204Z-pr-3084.md)
- [レビュー結果（折り返し行の断片 pin が要点を取りこぼす）](../../raw/reviews/20260925T115338Z-pr-3086.md)
