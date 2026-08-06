---
type: "anti-patterns"
title: "`set -o pipefail` 下の `... ¦ grep -q` は早期終了の SIGPIPE で偽の失敗になる"
domain: "anti-patterns"
description: "grep -q は一致した時点で終了するため、上流が SIGPIPE (rc=141) を受けて pipeline 全体が失敗扱いになる。低頻度で発火するため flaky な skip として現れ、閾値の緩い floor guard に masking される。入力が stdio バッファ境界を超えた地点で挙動が反転するため、小さな入力のテストでは絶対に見つからない。"
created: "2026-08-03T07:46:56Z"
updated: "2026-08-06T22:40:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260803T052647Z-pr-2094.md"
  - type: "reviews"
    ref: "raw/reviews/20260805T043752Z-pr-2112.md"
  - type: "fixes"
    ref: "raw/fixes/20260805T050456Z-pr-2112.md"
  - type: "reviews"
    ref: "raw/reviews/20260806T053845Z-pr-2124.md"
  - type: "fixes"
    ref: "raw/fixes/20260806T055534Z-pr-2124.md"
tags: []
confidence: high
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

PR #2112 で同型の事故が `... | sed -n '<probe>' | grep -q .` の形で再発した。ここで得られた決定的な観測は、**発火が入力サイズに依存する**こと。

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

### 検出器で免除するときは「真の判定軸」と「実装が何で判定しているか」を突き合わせる（PR #2124）

本パターンを検出する lint を書くと、`printf` / `echo` 起点のパイプラインを免除したくなる。根拠は「**短い in-memory 文字列はパイプバッファに収まるので producer が書き終わり、SIGPIPE が成立しない**」だが、実装も文書も**コマンド名**で免除していた。この proxy には 2 つの穴がある。

| 穴 | 実測 |
|---|---|
| payload がリポジトリ規模に比例する `printf` は根拠が成立しない | payload 70000B で rc=141、10000B では rc=0 |
| 免除判定が「パイプライン全体の先頭」を見て「`grep -q` の直前段」を見ていない | `printf ¦ jq ¦ grep -q` が丸ごと免除される |

**真の判定軸は「どのプロセスが実際に死ぬか」= consumer の直前段**であって、パイプライン先頭のコマンド名ではない。コマンド名は proxy にすぎない。

**proxy で判定するなら、proxy が成立する条件を文書に書く。** 書かないと、次の書き手が proxy を真の軸だと信じ、根拠が成立しない入力まで無警告で通す。

## 関連ページ

- [function 内 `local v=$(...)` と top-level `v=$(...)` の `set -e` 伝播差で writer/reader 非対称が偶然 mask される](./bash-local-vs-toplevel-pipefail-asymmetry.md)
- [PIPESTATUS はコマンド置換 `$(...)` のサブシェル境界を越えない](../heuristics/pipestatus-subshell-scoping-command-substitution.md)
- [bash の算術比較は非数値入力で rc=2 を返し、fail-closed の意図が else 側へ倒れる](./bash-numeric-test-fail-open-on-nonnumeric.md)

## ソース

- [PR #2094 fix results (cycle 3)](../../raw/fixes/20260803T052647Z-pr-2094.md)
- [PR #2112 review results (cycle 3)（`sed -n | grep -q` でバッファ境界を超えた地点の挙動反転を検出）](../../raw/reviews/20260805T043752Z-pr-2112.md)
- [PR #2112 fix results (cycle 3)（真偽判定をコマンド置換の非空判定へ置換）](../../raw/fixes/20260805T050456Z-pr-2112.md)
- [PR #2124 review results（免除規則の根拠と実際の判定軸のずれ）](../../raw/reviews/20260806T053845Z-pr-2124.md)
- [PR #2124 fix results（payload 70000B で rc=141 を実測、判定軸を consumer の直前段へ）](../../raw/fixes/20260806T055534Z-pr-2124.md)
