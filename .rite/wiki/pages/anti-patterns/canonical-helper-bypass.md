---
title: "Canonical helper bypass: 既存集約 helper を bypass して inline 再実装する"
domain: "anti-patterns"
description: "過去の review-fix loop で抽出された canonical helper (例: `_mktemp-stderr-guard.sh`) がある領域に新規実装を追加する際、helper を呼び出す代わりに inline で再実装してしまう anti-pattern。"
promote: rite-plugin
created: "2026-05-01T03:27:29Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260430T204843Z-pr-756.md"
  - type: "reviews"
    resource: "raw/reviews/20260516T032759Z-pr-989.md"
  - type: "reviews"
    resource: "raw/reviews/20260729T004127Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T004628Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T035608Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T073316Z-pr-2044.md"
tags: ["dry-violation", "helper-bypass", "doctrine-drift", "filter-symmetry", "stderr-passthrough", "test-helper-symmetry"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-29T21:32:36+09:00" }
---

# Canonical helper bypass: 既存集約 helper を bypass して inline 再実装する

## 概要

過去の review-fix loop で抽出された canonical helper (例: `_mktemp-stderr-guard.sh`) がある領域に新規実装を追加する際、helper を呼び出す代わりに inline で再実装してしまう anti-pattern。helper が解決した anti-pattern (Asymmetric Fix Transcription / mktemp 失敗 silent / stderr 取りこぼし等) が再導入され、過去 cycle で確立した doctrine がこの 1 PR で silent に巻き戻る。3 reviewer 独立合意の HIGH cross-validation で検出されることが多い。

## 詳細

### 発生事例（cycle 1）

起点事例が `lifecycle 4 hooks` に stderr pass-through 化を追加した際、`_resolve-flow-state-path.sh` の helper invocation で stderr を tempfile に退避する mktemp + filter ロジックを **inline で再実装** した。一方、累積 14 回目の cycle 9 F-02 で同じ目的の集約 helper `_mktemp-stderr-guard.sh` が既に extract されており、4 hook 全てで helper 呼び出しに置換すれば 1 行ずつで完結する状態だった。

3 reviewer (error-handling / code-quality / test) が独立に「集約 helper bypass = cycle 43 F-09 anti-pattern の再導入」として HIGH 検出。具体的には:

- mktemp 失敗時の WARNING 文言が helper と inline で 2 site に分散 (cycle 43 F-09 で集約済み)
- stderr filter literal (`'^WARNING:|^  |^jq: '` と `'^WARNING:|^ERROR:'`) が helper canonical と inline 実装で asymmetric mirror
- 4 hooks 横断で同じ inline 実装が複製され、Asymmetric Fix Transcription の温床になる

### 失敗の構造

1. 新規実装着手時に「既存 canonical helper が無いか」の grep を省略
2. 過去 review-fix loop で reviewer が苦労して抽出した集約成果が知識として継承されていない (commit 前 grep self-check の省略)
3. inline 実装がそれっぽく動くため初回 cycle では LLM reviewer も bypass を見抜けない
4. cross-validation reviewer の cycle 後段で「重複コード = 集約 helper の存在を grep で確認すべき」を 3 reviewer 独立検出
5. 集約 helper への置換 fix を行う cycle が追加発生し、本来 1 PR で済む変更が 2-3 cycle に膨らむ

### filter doctrine drift sub-pattern

helper bypass が起きる時、しばしば「doctrine の片側 mirror」が同時発生する。本件では `state-read.sh:148` の手本 filter が `'^WARNING:|^  |^jq: '` (multi-line WARNING continuation の `^  ` 行と jq parse error の `^jq:` 行を保全) なのに対し、inline 実装は `'^WARNING:|^ERROR:'` のみ採用し、multi-line continuation と jq parse error を silent drop していた。

- doctrine を mirror する claim を書く時は **filter literal / helper invocation の両方を mirror** すべき
- 片側 mirror は doctrine 不完全であり「stderr pass-through 化」claim が部分的にしか実現していない
- canonical filter literal は `state-read.sh:148` のような **named SoT site** を grep で特定し、新実装でも同じ literal を使う

### test helper bypass sub-pattern（cycle 1）

production code に限らず **test helper** でも同型に発火する。test helper 事例の cycle 1 で `stop-create-interview-block.test.sh` TC-10 が既存の `build_stop_payload` helper を使わず inline で `jq -n --arg cwd ... '{hook_event_name: "Stop", cwd: $cwd, ...}'` を再構築した結果、code-quality reviewer が MEDIUM finding として検出 (TC-1〜TC-9 sibling との helper symmetry 違反)。修正 cycle で `payload=$(build_stop_payload "$SBX/sub" false)` に置換し sibling と対称化。

新規 TC を追加する際の必須 self-check:

- 同 file 内の sibling TC (TC-1, TC-2, ...) が共通 helper を呼び出していないか `grep -nE 'payload=\$\(.*\)' <test_file>` で確認
- helper の signature が新 TC のニーズに合わない場合は **helper を拡張** し inline 再実装ではなく helper API を一貫させる
- LLM レビュー時間を待たず **commit 前 grep** で 5+ 箇所の同型 inline 構築を検出する

test helper bypass は production helper bypass と異なり「production 影響なし」と過小評価されがちだが、(a) sibling test の future 変更時の sync drift 入口、(b) TC ごとの payload literal drift で test の identification power が低下、という 2 段階で silent regression に効く。

### Detection Heuristic

新規実装着手前の必須 self-check:

```bash
# 1. 既存 helper の存在確認 (grep + git log search)
grep -rn '_mktemp-stderr-guard\|stderr-guard\|stderr_guard' plugins/rite/hooks/
git log --all --oneline -- plugins/rite/hooks/ | grep -iE 'helper|extract|集約'

# 2. 同型 inline 実装の重複検出
grep -rn 'mktemp.*2>/dev/null.*||' plugins/rite/hooks/ | wc -l
# 4 site 以上 → 集約 helper の存在を疑う

# 3. canonical filter literal の参照
grep -nE "'\\^WARNING:|filter.*pass-through" plugins/rite/hooks/state-read.sh
# canonical site の literal を確認 (cycle 41 F-01 doctrine)
```

### 経験則の適用

本 anti-pattern は以下の既存経験則を束ねる cross-cutting pattern:

- **Asymmetric Fix Transcription**: helper bypass で対称位置への伝播が失われる
- **DRY 集約助手の効果記述は『何が集約され、何が依然分散しているか』を明示する**: helper の効果を overstate して「集約済み」と誤解する逆方向
- **canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する**: filter literal を片側 mirror する drift と同型

### 対処の canonical pattern

1. **新規実装前の helper grep 必須化**: 関連領域に集約 helper が存在しないか `grep -rn` で確認。存在すれば helper 経由を default とする
2. **commit message での helper 言及**: helper を使った場合は commit message に literal helper 名を書き、reviewer が grep で確認できるようにする
3. **inline 再実装が必要な場合の justification**: helper を意図的に bypass する場合は commit message / PR body で「なぜ helper 経由でなく inline か」を明示する。reviewer が cross-validation で判断可能にする
4. **filter literal の SoT pin**: stderr filter / regex literal は canonical site (`state-read.sh:148` 等) からコピーし、PR review で「literal 一致」を確認する

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [DRY 集約助手の効果記述は『何が集約され、何が依然分散しているか』を明示する](./dry-helper-aggregation-effect-overstate.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)

## ソース

- [PR #756 cycle 1 review (3 reviewer 独立合意 HIGH cross-validation)](../../raw/reviews/20260430T204843Z-pr-756.md)
- [PR #989 cycle 1 review (test helper bypass: TC-10 inline jq vs build_stop_payload helper、code-quality MEDIUM)](../../raw/reviews/20260516T030954Z-pr-989.md)
- [PR #989 cycle 2 review (修正検証: build_stop_payload 経由化で sibling symmetry 復元、blocking 0 件)](../../raw/reviews/20260516T032759Z-pr-989.md)

## 変種: canonical パターンを「参照した」が、参照先の失敗経路まで写していない

helper の呼び出しを bypass する形だけでなく、**canonical パターンを引用しながら参照先の分岐を落とす**形でも同じ損失が起きる。

- 「canonical な stderr 退避パターンと同型」と称して tempfile 方式を写したが、参照先が持つ「mktemp 失敗時の `2>&1` フォールバック」を落とした。結果、mktemp が失敗すると**実在する診断を自分で捨てる**動作になった。
- 新設した診断 capture 経路が、`control-char-neutralize.sh` の header が SoT として宣言している `head -N | neutralize_ctrl --keep-newline | sed ... >&2` を参照せず素の pipe で書かれ、制御文字（ESC / C1）が端末へ素通しする経路を新設した。

> **教訓**: canonical パターンを参照するときは**参照先の失敗経路まで読む**。「正常系が同じ形」であることは同型の根拠にならない。診断出力の経路を新設するときは、同種の既存 emission site が従っている canonical idiom を先に grep する。

## 変種: 人間に渡す手順で SoT helper を「同等品」に置き換える

復旧手順の中で `state-path-resolve.sh` の代わりに `git rev-parse --show-toplevel` を書いた。linked worktree では前者が main checkout へ unify するのに対し後者は worktree root を返すため、復旧コマンドが rc=0・無出力で別ディレクトリに stray な state を作り、直すべき対象は手つかずで残る。

> **教訓**: 「同じ値が得られそうな標準コマンド」は worktree・symlink・sandbox のいずれかで必ず分岐する。SoT helper を呼び、さらに**対象ファイルの実在を gate にして空振りを明示エラーへ倒す**。詳細は [agent が人間に渡す復旧コマンドは、人間の実行コンテキストで正しいかを検証する](../heuristics/recovery-command-verified-in-human-execution-context.md) を参照。

なお本 PR では「bash コメントの rationale を `references/` へ退避すべきか」で 2 レビュアーの見解が割れたが、反対側の論拠「`references/` 新設は『新しい構造を持ち込まない』に反する」は `fix/references/` / `pr-review/references/` が既存であることを grep で確認して否定できた。**「新構造か既存パターンか」はリポジトリを grep すれば決着する** — 規約同士の衝突に見えるものが事実確認で解けることがある。

## ソース（追記分）

- [PR #2044 review results (cycle 3) — canonical パターンの分岐落ち](../../raw/reviews/20260729T004127Z-pr-2044.md)
- [PR #2044 fix results (cycle 3) — 参照先の失敗経路まで写す](../../raw/fixes/20260729T004628Z-pr-2044.md)
- [PR #2044 fix results — 新設 capture が canonical idiom を参照しない](../../raw/fixes/20260729T035608Z-pr-2044.md)
- [PR #2044 fix results (cycle 4) — SoT helper を同等品に置き換えない](../../raw/fixes/20260729T073316Z-pr-2044.md)
