---
title: "`grep -oE | wc -l` が ratchet ideal 値到達時に pipefail で silent abort"
domain: "anti-patterns"
created: "2026-05-08T17:43:55+00:00"
updated: "2026-08-01T00:21:06+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260508T174355Z-pr-906.md"
  - type: "reviews"
    ref: "raw/reviews/20260508T175233Z-pr-906.md"
  - type: "reviews"
    ref: "raw/reviews/20260725T032345Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260725T033607Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260730T195300Z-pr-2066.md"
tags: ["bash", "pipefail", "set-euo-pipefail", "grep", "ratchet-test", "silent-abort"]
confidence: high
---

# `grep -oE | wc -l` が ratchet ideal 値到達時に pipefail で silent abort

## 概要

`set -euo pipefail` 配下で `count=$(grep -oE 'pattern' file | wc -l | tr -d ' ')` を ratchet test の occurrence count 取得に使うと、grep が 0 マッチ (exit 1) を返した瞬間 pipefail が pipeline 全体を abort させ、test 全体が pass/fail のいずれも emit せず silent terminate する。**最も危険なのは ratchet ideal 値 (= 違反 0 件) に到達した瞬間であり、目標達成のタイミングこそ test が動作不能になる致命的経路**。canonical fix は `count=$({ grep -oE 'pattern' file || true; } | wc -l | tr -d ' ')` のように grep を group + `|| true` で囲み exit 1 を吸収すること。

## 詳細

### 問題の構造（cycle 3 で CRITICAL として実機顕在化）

ratchet test (charter 違反パターンの上限カウント test) で違反 occurrence を数えるために以下のように書かれていた:

```bash
set -euo pipefail
bell_count=$(grep -oE '🚨' "$start_md" | wc -l | tr -d ' ')
issue_count=$(grep -oE 'Issue #[0-9]+' "$start_md" | wc -l | tr -d ' ')
cycle_count=$(grep -oE 'cycle [0-9]+' "$start_md" | wc -l | tr -d ' ')
```

現状は違反多数 (35 件 / 13 件 / 26 件) のため grep が match を返し pipeline は exit 0 で終わる。しかし:

- **後続 PR (B-H) で違反を 0 件まで削減すると**、grep が 0 マッチ (exit 1) を返す
- `set -o pipefail` により pipeline 全体の exit code が grep の 1 になる
- `set -e` により bash script 全体が abort
- test runner は pass/fail の summary line を出力する前に終了 → silent abort

**ratchet ideal 値 (= 0 件) に到達した瞬間 test が壊れる** ため、本来「達成 ✅」を emit すべきタイミングで CI が静かに失敗する。

### canonical fix

5 件すべての pipeline を group + `|| true` で吸収する形式に変更:

```bash
set -euo pipefail
bell_count=$({ grep -oE '🚨' "$start_md" || true; } | wc -l | tr -d ' ')
issue_count=$({ grep -oE 'Issue #[0-9]+' "$start_md" || true; } | wc -l | tr -d ' ')
cycle_count=$({ grep -oE 'cycle [0-9]+' "$start_md" || true; } | wc -l | tr -d ' ')
```

- **`{ cmd || true; }` group**: grep の exit 1 を group 内で 0 に変換し pipefail に伝播させない
- **`wc -l` 側で空 stdin を 0 に集計**: grep が空を返しても wc が `0\n` を出力するので `tr -d ' '` 後の count は `0` になり整数比較が機能する
- **再現確認**: 空 file に対し `grep -oE` で exit 1 を返す経路を実機検証 (cycle 3 reviewer の cross-check)

### Cycle Degeneration として実測された経緯

起点事例で同一 fingerprint が 3 cycle に渡って degenerate した:

- **cycle 1**: 下限 assert を `grep -c` (line 単位) → `grep -oE | wc -l` (occurrence 単位) に変更、ただし `|| true` 防御を失った
- **cycle 2**: 上限 🚨 を同パターンに変更、同じく `|| true` を持たない (修正スコープ漏れの完了でしたが pipefail 防御は未遂)
- **cycle 3**: pipefail bug が CRITICAL として顕在化、5 件すべて `{ grep || true; } | wc -l` に修正

これは [Asymmetric Fix Transcription](./asymmetric-fix-transcription.md) と Quality Signal 1 (fingerprint cycling) の典型例 — 「unit を変更したが defense (`|| true`) を移植し忘れる」cycle が 3 段で degenerate。

### 検出と運用

- **静的検出**: `grep -rEn '\$\(grep [^|]+\|[^|]+wc' <scope>` で pipeline + wc -l の組み合わせを抽出し、`|| true` の有無を確認
- **動的検出**: 0-match を意図的に発生させる mutation test (空 file で grep を呼ぶ) を test fidelity 検証に組み込む ([Mutation Testing Test Fidelity](../patterns/mutation-testing-test-fidelity.md))
- **iteration 用途では別 canonical**: 0/1/N 件の iteration が必要な場合は [`mapfile -t < <(...)`](../patterns/mapfile-process-substitution-pipefail-safe.md) を採用 (process substitution は pipefail を伝播させない)

### 関連 anti-pattern との違い

| Anti-pattern | 範囲 | canonical fix |
|--------------|------|--------------|
| 本ページ (`grep -oE | wc -l` ratchet count) | scalar count 取得 + 0-match 吸収 | `count=$({ grep -oE ... || true; } | wc -l | tr -d ' ')` |
| [grep -c || echo 0 double-print](./grep-c-or-echo-0-double-print.md) | `grep -c` の POSIX 仕様で 0 出力 + exit 1 | `count=$(grep -c ... || true); count=${count:-0}` |
| [bash-local-vs-toplevel-pipefail-asymmetry](./bash-local-vs-toplevel-pipefail-asymmetry.md) | function 内外の pipefail 伝播非対称 | `v=$(... || true) || v=""` |

### 変種: `$(cmd | grep ...)` の no-match が「その次の行の空判定」を到達不能にする

同じ pipefail 伝播が、**assert の直前で診断を消す**形で現れた変種。テストヘルパーが以下のように書かれていた:

```bash
set -euo pipefail
line=$(printf '%s\n' "$OUT" | grep -F "$needle" | tail -1)
[ -z "$line" ] && fail "needle '$needle' not found"     # ← 到達不能な dead branch
```

grep の rc 1 が pipefail で伝播して代入自体が失敗し、`set -e` がスクリプトごと落とす。直後に書いた空判定は **一度も実行されない**。結果、`needle` が消えたとき — すなわち **そのテストが守っている regression が実際に起きたとき** だけ、診断メッセージが出ず以降の assertions も走らない。「守りたい状況でだけ壊れる」最悪の failure mode。

canonical fix はカウント用途と同じく group + `|| true` だが、**握る範囲を grep だけに限定する**のが要点:

```bash
line=$({ printf '%s\n' "$OUT" | grep -F "$needle" || true; } | tail -1)
[ -z "$line" ] && fail "needle '$needle' not found"     # ← 到達可能になる
```

> **`|| var=""` で代入全体を握るのは不可**: `tail` や `printf` の失敗まで飲み込むため、pipeline 内の別の故障が「マッチしなかった」に化ける。

**判定基準**: 「マッチしないこと」が正常系にありうる grep は局所的に無害化し、空判定を次行で必ず assert する。「マッチしないことがありえない」grep（= マッチしなければ即バグ）は `|| true` を付けず errexit に落とすのが正しい。

## 関連ページ

- [`mapfile -t < <(...)` で pipefail safe な iteration を書く](../patterns/mapfile-process-substitution-pipefail-safe.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [Mutation Testing Test Fidelity](../patterns/mutation-testing-test-fidelity.md)
- [set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する](./bare-statement-under-set-e-dead-code-rc-branch.md)

## 追記: 終端 `grep -c` は「0 件」と「検出器の破損」を畳む（PR #2066）

`grep -c` を pipeline の終端に置くと、no-match で rc=1 を返すため pipeline の rc では「0 件」と「途中の異常終了」が区別できない。PR #2066 では結果として、**検出器そのものが壊れたときだけが「実測済みの 0 件」として未実測ゲートをすり抜けた**。計数を同じ awk 内に閉じると rc が意味を持つ。「0 件が実体を反映しているか」を surface する enum を設けるなら、検出器自身の破損もその enum に載る形にする。

同 PR で観測された姉妹形が 2 つある。**`cd ""` は rc=0 を返す** — sandbox 生成の rc を検査していないと、失敗時に空文字列が返り `cd "$SBX" || exit 1` のガードが素通りし、以降の相対パス操作（`git add -A` / `commit` / `rm -f`）がテストプロセスの cwd = リポジトリに対して走る。command substitution で作ったパスは、使う前に rc または非空を検査する。そして**同じ exit code を返す gate が複数あると、exit code だけの assert は当の gate を pin しない** — placeholder residue gate を削除しても後段の別 gate が同じ exit 1 を返すため、テストは緑のまま通った。gate を pin するなら、その gate 固有の診断 marker まで assert する。

## ソース

- [PR #906 fix results (cycle 3)](../../raw/fixes/20260508T174355Z-pr-906.md)
- [PR #906 review results (cycle 4 final)](../../raw/reviews/20260508T175233Z-pr-906.md)
- [PR #2013 review cycle 3 — `$(cmd | grep)` の no-match が直後の空判定を dead branch にする](../../raw/reviews/20260725T032345Z-pr-2013.md)
- [PR #2013 fix results (cycle 3) — grep だけを局所無害化する canonical fix](../../raw/fixes/20260725T033607Z-pr-2013.md)
- [PR #2066 fix results (cycle 3) — 終端 `grep -c` が検出器破損を 0 件に畳む](../../raw/fixes/20260730T195300Z-pr-2066.md)
