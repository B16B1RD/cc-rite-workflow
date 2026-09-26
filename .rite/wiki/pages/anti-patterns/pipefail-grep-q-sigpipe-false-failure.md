---
type: "anti-patterns"
title: "`set -o pipefail` 下の `... ¦ grep -q` は早期終了の SIGPIPE で偽の失敗になる"
domain: "anti-patterns"
description: "`grep -q` は最初の一致で即座に終了する。"
created: "2026-08-03T07:46:56Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T134206Z-pr-3160.md"
  - type: "fixes"
    resource: "raw/fixes/20260916T235140Z-pr-2920.md"
  - type: "fixes"
    resource: "raw/fixes/20260916T164531Z-pr-2920.md"
  - type: "fixes"
    resource: "raw/fixes/20260916T232344Z-pr-2920.md"
  - type: "reviews"
    resource: "raw/reviews/20260916T165843Z-pr-2920-cycle1.md"
  - type: "reviews"
    resource: "raw/reviews/20260916T170221Z-pr-2920-cycle2-incomplete.md"
  - type: "fixes"
    resource: "raw/fixes/20260803T052647Z-pr-2094.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T043752Z-pr-2112.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T050456Z-pr-2112.md"
  - type: "reviews"
    resource: "raw/reviews/20260806T053845Z-pr-2124.md"
  - type: "fixes"
    resource: "raw/fixes/20260806T055534Z-pr-2124.md"
  - type: "reviews"
    resource: "raw/reviews/20260907T233525Z-pr-2614.md"
  - type: "reviews"
    resource: "raw/reviews/20260911T154811Z-pr-2694.md"
  - type: "reviews"
    resource: "raw/reviews/20260913T073838Z-pr-2773.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T063133Z-pr-3032.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T064703Z-pr-3032.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T070032Z-pr-3032.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T070547Z-pr-3032.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T070926Z-pr-3032.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T105711Z-pr-3149.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T13:47:53Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T13:47:53Z" }
  - { by: "rite-wiki-ingest/gpt-6-astra", at: "2026-09-07T23:54:45Z" }
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-11T16:00:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-13T07:45:50Z" }
  - { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T11:20:00Z" }
---

# `set -o pipefail` 下の `... ¦ grep -q` は早期終了の SIGPIPE で偽の失敗になる

> 本ページのタイトルおよび本文中の `¦` は、パイプ記号 `|` を表す。verification アンカーに raw pipe を書くと検出 regex に一致せず判定が未確定に倒れるため、代替表記を用いる。

## 概要

`grep -q` は最初の一致で即座に終了する。`set -o pipefail` 下で上流にコマンドを繋いでいると、**上流が書き込み中に下流が消えるため SIGPIPE (rc=141) を受け、pipeline 全体が失敗扱いになる**。一致が上流の出力の早い位置にあるときだけ発火するため、flaky な挙動として現れる。

## 詳細

### 実測された症状

parity テストの caller 列挙が `set -o pipefail` 下で `grep -v ... ¦ grep -q ...` を使っており、下流の早期終了で上流が SIGPIPE を受け、**ファイルが無言で skip された**。

- 発生頻度: 200 回中 1 回
- 症状: スイートの PASS 数が 33〜38 で揺れる
- masking: floor guard (`checked >= 24`) の閾値が実数（29〜35）より十分低いため、guard は一度も落ちなかった

つまり「テストは通っているが、通るたびに検査対象が変わっている」状態で、しかもそれを検出するはずの guard が閾値の緩さで沈黙していた。

### 対処

存在検査は pipeline にしない、あるいは失敗を吸収する。

```bash
# ✗ 上流が SIGPIPE で落ち、pipefail が pipeline を失敗にする
if grep -v '^#' "$f" | grep -q "$pattern"; then ...

# ✓ 単体で書く
if grep -q "$pattern" "$f"; then ...

# ✓ pipeline が必要なら明示的に吸収する
if grep -v '^#' "$f" | grep -q "$pattern" || true; then ...
# ただし || true は「一致しなかった」も真にするため、判定値は別途取る
found=$(grep -v '^#' "$f" | grep -c "$pattern" || true)
```

`grep -c` は一致数を数えるため入力を最後まで読み、SIGPIPE を起こさない。存在の有無だけが要るなら `-c` の結果を 0 と比較するのが安全。

### floor guard の閾値は実数に近い値にする

この事故の本質的な問題は、**guard が存在したのに masking された**こと。`checked >= 24` は実数 29〜35 に対して緩すぎ、1 ファイルの skip では落ちない。

floor guard は「明らかな崩壊」ではなく「1 件の欠落」を捕まえられる閾値にする。実数が 29〜35 で揺れているなら、その揺れ自体が異常なので、揺れを許容する閾値ではなく **揺れを検出する厳密値**（`-eq 35` 等）へ寄せるか、揺れの原因を先に潰す。

### 挙動は「入力サイズ」で反転する — 小入力のテストでは絶対に見つからない

ある PR で同型の事故が `... | sed -n '<probe>' | grep -q .` の形で再発した。ここで得られた決定的な観測は、**発火が入力サイズに依存する**こと。

上流が stdio バッファに収まる量しか書かないうちに書き終われば、下流が消えても SIGPIPE は発生しない。**バッファ境界を超えた地点で初めて挙動が反転する**。つまり小さな fixture で書いたテストは、この欠陥に対して構造的に識別力を持たない — 何回流しても緑のままで、本番の入力サイズで初めて偽が返る。

「200 回中 1 回」という flakiness も、実体は乱数ではなくサイズと書き込みタイミングの関数である。**再現しないから無い**とは判断できない。

### 真偽判定にパイプ終端の早期 exit consumer を置かない

対処を一般化すると次になる。

- **真偽判定に使うなら、出力を最後まで読む形にする** — コマンド置換の結果が非空かを見れば SIGPIPE 経路自体が消える
- `grep -q` / `head` / `tail -1` をパイプ終端に置くのは、**rc を見ない用途に限る**

```bash
# ✗ pipefail 下で rc を見る（サイズ依存で反転する）
if printf '%s' "$body" | sed -n "$PROBE" | grep -q .; then ...

# ✓ 出力を最後まで読み、結果の非空で判定する
hit=$(printf '%s' "$body" | sed -n "$PROBE")
if [ -n "$hit" ]; then ...
```

### 併せて起きる同型の事故

同じ `set -euo pipefail` 環境で、コマンド置換内の grep 非マッチ（rc=1）が errexit でテストスイートをプロセスごと中断させる事故も観測されている。アサーション FAIL ではなく中断なので **PASS/FAIL サマリごと消え、以降のアサーションが「実行されていない」ことすら観測できない**。同ファイル内の同型 7 site のうち 1 site だけが `|| true` guard を欠いており、その非対称が漏れの証拠になった。

**`$(... grep ...)` を書いたら、ファイル内の同型 site と guard の有無を突き合わせる。** 実害の確認には「WARNING 文言を変えた mutant で完走するか」を見るのが速い（実例では 94 → 60 アサーションで中断していた）。

### 検出器で免除するときは「真の判定軸」と「実装が何で判定しているか」を突き合わせる

本パターンを検出する lint を書くと、`printf` / `echo` 起点のパイプラインを免除したくなる。根拠は「**短い in-memory 文字列はパイプバッファに収まるので producer が書き終わり、SIGPIPE が成立しない**」だが、実装も文書も**コマンド名**で免除していた。この proxy には 2 つの穴がある。

| 穴 | 実測 |
|---|---|
| payload がリポジトリ規模に比例する `printf` は根拠が成立しない | payload 70000B で rc=141、10000B では rc=0 |
| 免除判定が「パイプライン全体の先頭」を見て「`grep -q` の直前段」を見ていない | `printf ¦ jq ¦ grep -q` が丸ごと免除される |

**真の判定軸は「どのプロセスが実際に死ぬか」= consumer の直前段**であって、パイプライン先頭のコマンド名ではない。コマンド名は proxy にすぎない。

**proxy で判定するなら、proxy が成立する条件を文書に書く。** 書かないと、次の書き手が proxy を真の軸だと信じ、根拠が成立しない入力まで無警告で通す。

### `grep -c . >/dev/null` は述語を変えずに SIGPIPE 経路だけを消す

契約テストの「フェンス内行が非空か」assert で `awk ¦ grep -q .` を `awk ¦ grep -c . >/dev/null` に置き換えた事例。`grep -c` は件数を出すために stdin を EOF まで消費するので上流 awk が EPIPE を受ける経路が構造的に無く、0 一致では rc=1、1 件以上では rc=0 を返すため真偽の述語は `grep -q .` と同一である。同じ入力で旧形は 300 回中 23〜24 回 `no` に転じ、新形は 0 回。大入力での `PIPESTATUS` は旧形 `141 141 0`、新形 `0 0 0` と、rc 141 の消失を直接観測できる。

発火確率は上流の出力行数に比例する（同一スイート内で 125 行のフェンスを持つステップだけが落ち、9〜26 行のステップはほぼ落ちなかった）。**同型 3 箇所は同じ形に揃える** — 1 箇所だけ `-q` が残ると、そこだけがサイズ依存で将来 flaky 化する。

「旧形式を復元すると決定的に落ちる回帰 pin」は要求しない。実データ規模では失敗が scheduler race のため決定的に再現できず、決定的に落とすには MB 級の合成 fixture が要る。判別力（`_fenced` を空出力に変異させて `no` で FAIL する）と 300 回連続 PASS の 2 点で十分と判断する。

### 下流の `awk '... { exit }'` も同じ事故を起こす — 終端行の位置は関係ない

セクション抽出関数の出力を `awk` で受け、終端行で `exit` する形でも同じ SIGPIPE が起きる。上流が `awk` / `sed` などのコマンドや関数だと here-string に置き換えられず、`grep -q` の対処表がそのまま使えない。

- **発生条件**: reader が **writer の最後の write より前に** 終了すること。gawk はパイプへ 4096B 単位で書き、11KB 程度の出力でも 3 回の write になる。合計が 64KB 未満でも起きる
- **終端行が何番目の chunk にあるかは関係ない**: 終端行が 1 つ目の chunk にある経路でも 2 つ目にある経路でも、同じ頻度で rc=141 になった。「終端行が先頭 4KB より後ろだから安全」とは判断できない
- **負荷で再現率が上がる**: 単発の連続実行では 1000 回中 1 回程度だが、16 並列で回すと 200 回中 53 回まで上がった。修正前の陽性対照は並列負荷で取る
- **実装差**: mawk では再現せず gawk で再現した。CI とローカルの awk 実装が違うと片側だけで flaky になる

対処は、終端でフラグを立てて残りの入力を読み切る形にする。

```bash
# ✗ 終端行で exit し、上流の残りの write が SIGPIPE を受ける
extract_section "$file" ¦ awk '/^BEGIN$/ { a=1; next } a && /^END$/ { exit } a { print }'

# ✓ done を先頭ルールに置き、終端以降は next で読み捨てる
extract_section "$file" ¦ awk 'done { next } /^BEGIN$/ { a=1; next } a && /^END$/ { done=1; next } a { print }'
```

`done { next }` は**先頭ルールでなければならない**。末尾に置くと、`a` が立ったままのため終端行より後ろの行も print される。書き換えの前後で抽出結果がバイト単位で一致することを `cmp` で確認してから差し替える。

上流がファイルを直接読む `awk ... "$file"` の `exit` は入力側にパイプを持たないため対象外。writer の出力が小さければ発火しにくいが、発火しないとは言えない。`echo "$output" ¦ grep -q` では、出力が 3 行・約 260 バイトでも CI で `echo: write error: Broken pipe` が観測された（ローカルでは数千回の繰り返しでも再現しない）。

### 全量読取と抽出境界を同時に検証する

全量を消費する修正では、一致・非一致だけでなく抽出範囲の境界も固定する。先頭20行だけを判定する処理なら、大容量本文を維持したまま20行目の marker を採用し21行目を除外する正負ケースを検証する。抽出を `sed -n '1,20p'` にすると、表示範囲を保ちつつ残りの入力も消費できる。

入力バイトを変えずに伝播修正する場合は、直接の `printf` 出力を保ち、検索側を `grep -cF >/dev/null -- "$needle"` のように全量読取へ変える。here-stringが加える末尾改行を避けつつ、一致時0・非一致時1の判定を維持できる。並列CIで複数のテストに同じ偽失敗が実測された場合は、同型の直接パイプを一覧化して修正し、全suiteで確認する。一般のproducerや共通helperまで機械的に広げない。

### 保存済み文字列の検索は producer を作らず入力する

並列テストでは、同じ条件がローカルで成功していてもCIで `printf: write error: Broken pipe` となり得る。実際に複数の肯定・否定アサーションで発生し、hook suiteの偽失敗によって後続suiteも実行されなかった。並列化だけを原因として再試行で隠すと、判定方法の欠陥が残る。

検索対象が既に変数にある場合は、`grep -qE "$pattern" <<< "$text"` のように直接渡せる。パターンと条件分岐を維持し、書き込み側の終了コードが真偽へ混入する経路を除く。here-stringは末尾改行を加えるため、その差が意味を変えない行・部分一致の判定に適用する。小さい入力の繰り返しだけで安全とは判断せず、実測した失敗箇所と同じ入力経路を検証する。

### 早期 return は引数駆動でも起きる — バッファサイズに依存しない確定的トリガー

これまでの事例は、下流コマンドが**入力の内容やサイズ**（一致位置・終端行の位置）によって早期終了するかどうかが決まっていた。別の実例では、下流の helper が `--stdin` フラグで入力を受け取りつつ、**別の引数（`--label` に渡すパス文字列）が特定パターンに一致したときだけ、stdin を一切読まずに早期 return する**という契約になっていた。この場合、早期 return はバッファ境界や一致位置とは無関係に、**呼び出し引数だけで確定的に発火する**。

```bash
# ✗ label が除外パターンに一致すると helper は stdin を読まずに return し、
#   printf の書き込みと衝突して SIGPIPE (rc=141) になる
printf '%s\n' "$body" | bash helper.sh --stdin --label "$excluded_path" --quiet

# ✓ ヒアストリングなら reader が起動する前に入力が用意されるため、
#   reader が読まなくても書き手が SIGPIPE を受ける余地がない
bash helper.sh --stdin --label "$excluded_path" --quiet <<< "$body"
```

この変種は「200 回に 1 回」のような確率的な flakiness ではなく、**同じ引数の組み合わせなら並列負荷下で毎回発火しうる**（単独実行では基盤プロセスの起動順序が安定しているため再現しにくい）。対処は同じ — reader が入力を読むとは限らない契約のときは、パイプではなくヒアストリング / 一時ファイルで渡す。

### 検出器の出力から置換対象を選ぶと、前置きと例外の形が漏れる

同型の直接パイプを一覧化して機械置換するとき、一覧を検出器（lint）の出力の文字列から作ると、出力の表層に依存した取りこぼしが起きる。producer 文字列を「`echo` / `printf` で始まる」で絞ったため、`if echo ...` / `! echo ...` のように前置語が付く行が丸ごと漏れた。さらに、検出器が例外として扱う形（`printf '%s' "$var"`）は、そもそも一覧に上がってこない。

- 対象の選別は、検出器と同じ字句解析で producer の実体（前置語を外した部分）を取り出して行う。
- 置換の対象ディレクトリは明示的に制限する。一覧に範囲外（本番コード）の行が混ざっていると、制限しない変換は範囲外まで書き換える。変更後は計画の範囲と実際の変更パスを突き合わせる。
- 完了条件は「置換した行が正しい」ではなく「対象が残っていない」にする。受入条件が検出器の例外より広いときは、受入条件の文言をそのまま検索式にした残件検索を検証に加える。raw 検索は誤ヒット（`-eq`、`grep -c`、fixture 文字列、コメント）も多いので、ヒットごとに対象外の理由を分類して、対象の残件 0 を示す。
- テストが書き出す別プロセスの stub 本文は、親の `set -o pipefail` を継承しないため、同じ字面でも欠陥クラスに当たらない。

### 診断用の `printf ... | head -N` も同じ欠陥クラスに入る

`set -euo pipefail` の下で、失敗時の診断として長い値を `printf '%s' "$x" | head -5` のように先頭だけ表示する形は、入力が大きいと `head` が先に終了し、書き手の `printf` が SIGPIPE を受ける。パイプラインの rc が非ゼロになり、直後に出すはずの reason marker ごと処理が止まる。診断を出したい経路でこそ診断が消える。

入力はヒアストリング（`head -5 <<< "$x"`）で渡すか、入力を最後まで読むコマンド（`sed -n '1,5p'` 等）で切り出す。

## 関連ページ

- [function 内 `local v=$(...)` と top-level `v=$(...)` の `set -e` 伝播差で writer/reader 非対称が偶然 mask される](./bash-local-vs-toplevel-pipefail-asymmetry.md)
- [PIPESTATUS はコマンド置換 `$(...)` のサブシェル境界を越えない](../heuristics/pipestatus-subshell-scoping-command-substitution.md)
- [bash の算術比較は非数値入力で rc=2 を返し、fail-closed の意図が else 側へ倒れる](./bash-numeric-test-fail-open-on-nonnumeric.md)

## ソース

- [全量読取と大容量・範囲境界の回帰検証](../../raw/reviews/20260907T233525Z-pr-2614.md)
- [契約テストのフェンス抽出 assert を grep -c で全量消費に置換（レビュー結果）](../../raw/reviews/20260911T154811Z-pr-2694.md)
- [セクション抽出の下流 awk を入力を読み切る形へ直した修正のレビュー結果](../../raw/reviews/20260913T073838Z-pr-2773.md)

- [fix 結果](../../raw/fixes/20260803T052647Z-pr-2094.md)
- [`sed -n | grep -q` でバッファ境界を超えた地点の挙動反転を検出](../../raw/reviews/20260805T043752Z-pr-2112.md)
- [真偽判定をコマンド置換の非空判定へ置換](../../raw/fixes/20260805T050456Z-pr-2112.md)
- [免除規則の根拠と実際の判定軸のずれ](../../raw/reviews/20260806T053845Z-pr-2124.md)
- [payload 70000B で rc=141 を実測、判定軸を consumer の直前段へ](../../raw/fixes/20260806T055534Z-pr-2124.md)

- [並列runnerの実測と修正記録](../../raw/fixes/20260916T164531Z-pr-2920.md)
- [並列runnerの実測と修正記録](../../raw/fixes/20260916T232344Z-pr-2920.md)
- [並列runnerの実測と修正記録](../../raw/reviews/20260916T165843Z-pr-2920-cycle1.md)
- [並列runnerの実測と修正記録](../../raw/reviews/20260916T170221Z-pr-2920-cycle2-incomplete.md)

- [並列CIの同型偽失敗を全量読取へ伝播修正](../../raw/fixes/20260916T235140Z-pr-2920.md)

- [echo の grep -q パイプを here-string へ置換したレビュー（cycle 1）](../../raw/reviews/20260924T063133Z-pr-3032.md)
- [前置き付きの置換漏れの修正](../../raw/fixes/20260924T064703Z-pr-3032.md)
- [検出器の例外に隠れた残件（cycle 2）](../../raw/reviews/20260924T070032Z-pr-3032.md)
- [見直しで PR 内に取り込んだ修正](../../raw/fixes/20260924T070547Z-pr-3032.md)
- [受入条件どおりの残件検索（cycle 3）](../../raw/reviews/20260924T070926Z-pr-3032.md)
- [引数駆動の早期 return によるヒアストリング化のレビュー結果](../../raw/reviews/20260926T105711Z-pr-3149.md)
- [診断用の printf と head の組み合わせで reason marker が消える経路を指摘したレビュー結果](../../raw/reviews/20260926T134206Z-pr-3160.md)
