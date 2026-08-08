---
type: "anti-patterns"
title: "検出器が「走査できなかった」を「問題なし」に畳むと、ガードが黙って無検査になる"
domain: "anti-patterns"
promote: rite-plugin
description: "静的チェックスクリプトが fence 不整合 / awk fatal / target 不在をすべて「findings 0 件 + rc=0」に畳むと、rc=0 を success として扱いスクリプト出力を表示しない呼び出し元の下でガードが無言で無効化される。stderr に WARNING を出していても、呼び出し元が WARNING を表示する経路を持たなければ silent と同義。走査できなかった件数を数えて別 exit code に分けて初めて observable になる。"
created: "2026-07-30T01:20:00+09:00"
updated: "2026-08-06T22:40:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260729T142410Z-pr-2051.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T144345Z-pr-2051.md"
  - type: "reviews"
    ref: "raw/reviews/20260806T103116Z-pr-2124.md"
tags: []
confidence: high
---

# 検出器が「走査できなかった」を「問題なし」に畳むと、ガードが黙って無検査になる

## 概要

静的チェックスクリプトの exit code 設計に「検出できなかった」状態が無いと、走査失敗（対象ファイルを開けない / パーサが fatal で落ちた / 対象が 1 件も見つからない）がすべて「findings 0 件 = 問題なし」として rc=0 で返る。呼び出し元が rc=0 を success と扱い、その場合スクリプト出力を表示しない契約なら、stderr に書いた WARNING は構造的に誰にも届かない。ガードを追加したつもりで、実際には無検査の状態が可視化されずに続く。

## 詳細

### 実測された経路

起点事例で新設した `dollar-zero-check.sh` は当初、以下の 3 つをすべて `Total: 0 findings` + `rc=0` に畳んでいた。

- fence 不整合でファイルを解析しきれなかった
- awk が fatal error で落ちた（ファイル権限 / バイナリ異常）
- `--all` で走査対象が 1 件も見つからなかった

唯一の呼び出し経路である `/rite:lint` Phase 3.5 は rc=0 を success として扱い、その場合スクリプト出力を appendix に載せない（appendix は warning/error 時のみ、summary は E2E で skip）。したがって「スクリプトは実行されたが 1 ファイルも走査できていない」状態が、正常な clean bill と完全に同じ表示になっていた。

**これは同 PR が塞ごうとしていた defect class と構造が同一**だった（skill 本文の awk が壊れて空値を返し、それが呼び出し側の opt-out default に吸収されて正常スキップとして報告される）。silent failure を塞ぐ修正が、同じ silent failure を検出器側に再現していた。

### 「stderr に出しているから silent ではない」は条件付きでしか成立しない

WARNING を stderr に書くこと自体は正しいが、**それが observable かどうかは呼び出し元の表示契約に依存する**。

| 呼び出し元の契約 | stderr WARNING は届くか |
|---|---|
| rc に関わらず常に出力を表示 | 届く |
| 非 0 のときだけ出力を表示 | rc=0 に畳んでいる限り**届かない** |
| 人間が直接叩く | 届く |

rite の lint のように「rc=0 なら出力を表示しない」設計の呼び出し元がある以上、検出器側は rc で状態を分けなければならない。

### 対処: 走査不能を数えて別 rc に分ける

```bash
# 走査できなかったファイルを数える
SKIPPED=0
# ... check_file() 内の全失敗経路で SKIPPED=$((SKIPPED + 1))

# 集約 ERROR は findings 判定より前に出す（両方が起きた run で消えないように）
if [ "$SKIPPED" -gt 0 ]; then
  echo "ERROR: ${SKIPPED} file(s) could not be scanned — this run is not a clean bill" >&2
fi
if [ "$total" -gt 0 ]; then exit 1; fi   # findings あり
if [ "$SKIPPED" -gt 0 ]; then exit 2; fi # 走査不能あり（clean bill ではない）
exit 0                                    # 全ファイル走査済み・findings なし
```

ポイントは 2 つ。

1. **`SKIPPED` の加算を全失敗経路に置く**: ファイル不在 / パーサ fatal / sentinel のどれで抜けても必ず加算する。関数内に「走査されなかったのに加算されない経路」が 1 つでもあれば、そこから silent に戻る。
2. **集約 ERROR を findings の early-exit より前に置く**: findings と走査不能が併発した run は、診断の価値が最も高い状況でありながら、順序を誤ると集約行だけが消える。exit code の優先順位（findings が rc を取る）とは独立に、出力の順序を決める。

### 「走査対象 0 件」の扱いは別問題

対象が 1 件も無いのは、consumer リポジトリ（rite をマーケットプレイス経由でのみ使い `plugins/rite/` を self-host していない）では正常系である。この場合は `--skip-if-no-target` のような明示フラグで「not applicable」を宣言させ、呼び出し元が 1 行の informational note を出す形にする。**「対象が無い」と「対象を開けなかった」を同じ rc に畳まない**。

### guard 自身が、guard の戒めている欠陥を持っていた（PR #2124 cycle 2）

本ページの教訓を header に明記した検出器で、同じ欠陥が**実装側**に残っていた。ハンドル登録が最初の 1 個で `return` しており、1 論理行が複数の tempfile を作る形（`a=$(mktemp) && b=$(mktemp)`）では 2 個目以降が未登録 = その派生パスが恒久的に silent clean になっていた。しかも走査対象ツリーに該当行が実在した（`lib/git-status-filtered.sh:45`）。

**宣言した契約を自分自身の実装で破っていないかは、宣言文の grep ではなく実データでの反証で確かめる。** このケースでは security reviewer が走査対象ツリーから同形の行を探して existing_call_site として提示し、fixture で再現した。header に「走査しなかったものを見つからなかったへ畳まない」と書いてあることは、実装がそうなっている証拠にならない。

### どの先例を写すかで欠陥が決まる

同じ機能の実装がリポジトリに複数あるとき、**どれを写すかで欠陥が決まる**。PR #2124 の新規検出器は、より古い `bash-heaviness-check.sh` の形（`2>/dev/null || true` で失敗を飲む）を写したため、本ページの教訓を持つ `dollar-zero-check.sh` の `SKIPPED` カウンタが伝播しなかった。**レビューを経た最新の実装を写す**。

## 関連ページ

- [CI lint チェックを blocking gate に昇格するときはツール自身の exit code を gate にする](../heuristics/ci-blocking-gate-tool-exit-code.md)
- [新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される](./upstream-silent-path-defeats-new-logged-guard.md)
- [自前 sentinel exit code は呼び出す外部コマンドの予約値を避けて選ぶ](./custom-sentinel-collides-with-tool-exit-code.md)

## ソース

- [PR #2051 review results](../../raw/reviews/20260729T142410Z-pr-2051.md)
- [PR #2051 fix results](../../raw/fixes/20260729T144345Z-pr-2051.md)
- [PR #2124 review results (cycle 2)](../../raw/reviews/20260806T103116Z-pr-2124.md)
