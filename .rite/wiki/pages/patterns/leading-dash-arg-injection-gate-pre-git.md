---
title: "leading-dash 引数注入 gate は git 操作前に配置し代表 1 値の非 vacuous test で検証する"
domain: "patterns"
created: "2026-06-07T19:38:45Z"
updated: "2026-06-07T19:38:45Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260607T185308Z-pr-1299.md"
tags: ["security", "argument-injection", "leading-dash", "option-injection", "git", "fail-fast", "input-gate", "non-vacuous-test", "differential-test", "sibling-audit"]
confidence: high
---

# leading-dash 引数注入 gate は git 操作前に配置し代表 1 値の非 vacuous test で検証する

## 概要

shell script が外部由来の値 (branch 名等) を `git push -u origin "$v"` のような形で渡す場合、値が `-` で始まると git が option として解釈する argument injection の理論的余地が生まれる。これを塞ぐ `case "$v" in -*) fail` 形式の fail-fast gate は **(1) 引数解析直後・全 git 操作到達前に配置** し、bypass 耐性を入力クラス別に確認する。検証は **(2) 兄弟 script の同型注入経路を grep 監査** し、**(3) 単一 `-*` case の gate は値ごとの分岐を持たないため代表 1 値 (例: `--force`) で挙動立証可能** (境界値網羅は不要)、**(4) rc + ERROR substring + end state の 3 軸非 vacuous assertion で gate 発火を pin** し、**(5) 既存 differential-equivalence test とは gate 非発火値を選んで非干渉に保つ**。security follow-up として `wiki-branch-init.sh` への leading-dash gate 追加が 5 reviewer cross-validation で指摘 0 件・cycle 1 mergeable に収束した実測。

## 詳細

### 1. gate の配置 — 引数解析直後・全 git 操作前

`wiki-branch-init.sh` の leading-`-` sanitization は、引数解析が終わった直後 (全 `git checkout --orphan` / `git push -u origin` 到達前) に `case "$wiki_branch" in -*) ERROR + exit 1` を置く。git 操作に到達してから防御するのでは遅く、最初に値が確定する地点で gate するのが canonical。これは [[validation-chain-fired-reason-by-first-parse-stage]] の「validation chain の発火 reason は最初に入力を parse する段階で決まる」と同型 — gate を最初の parse 段階に置くことで後続の全 git 操作が gate 通過済み入力のみを見る。

### 2. bypass 耐性は入力クラス別に確認する

`-*` gate を入れても、gate に到達しない / gate をすり抜ける入力クラスがある:

| 入力クラス | 挙動 | gate との関係 |
|-----------|------|--------------|
| 空文字列 `""` | `-*` に非該当 | 既存の `-z` (空チェック) へ fall-through (二重防御として正しい) |
| 先頭 whitespace ` -x` | `-*` に非該当 | git が literal refspec 扱いで reject (git 自身の branch name validation が後段防御) |
| leading-`-` (`--force` 等) | `-*` に該当 | 本 gate が fail-fast |

gate を「全 injection を 1 箇所で塞ぐ」と過大主張せず、空文字列は既存 `-z` check、whitespace 先頭は git 自身の validation、という **多層防御のどの層が各クラスを担うか** を明示する。なお `git checkout --orphan` 側は git 自身の branch name validation が leading-`-` を reject することを sandbox 実測で確認済みのため、gate は `git push` 側の理論的余地を git 到達前に前倒しで塞ぐ役割。

### 3. 兄弟 script の同型注入経路を grep 監査する

1 script に gate を入れたら、同じ「外部値を git/外部コマンドへ flag 位置で渡す」パターンを持つ兄弟 script を監査する。起点事例では `projects-items-fetch.sh` を監査し、flag 値渡し + 数値検証で surface なし (注入経路の残存ゼロ) を確認した。[[asymmetric-fix-transcription]] の「対称位置への伝播漏れ」を防ぐ着手時 grep と同系。

### 4. 単一 `-*` case gate は代表 1 値で立証する (境界値網羅は不要)

gate が `case "$v" in -*)` の **単一パターンで値ごとの分岐を持たない** 場合、挙動は「`-` 始まりか否か」の 2 値でしか分岐しない。したがって代表 1 値 (`--force` 等) を流せば該当クラス全体の挙動が立証でき、`-x` / `--foo` / `-` 単独…と境界値を網羅する必要はない。値ごとに異なる処理が分岐する gate でない限り、test を値の数だけ増やすのは over-test。

### 5. 非 vacuous 3 軸 assertion で gate 発火を pin する

gate の test (TC-8) は **rc (exit 1) + ERROR substring (出力に gate のエラー文言) + end state (ブランチが作成されていないこと)** の 3 軸を assert する。rc だけ / メッセージだけの単軸 assert は、別経路で偶然同じ rc が返ると vacuous false positive 化する。「gate が発火し、かつ副作用 (ブランチ作成) が起きていない」を end state で押さえることで、gate の実効性を非 vacuous に pin する ([[static-input-chain-function-extraction-non-vacuous-test]] の非 vacuous 化と同じ動機。あちらは注入経路が無く関数抽出が必要なケース、本件は注入経路 (引数) が直接あるため関数抽出は不要で arg 経由で直接 exercise できる対照ケース)。

### 6. 既存 differential-equivalence test とは gate 非発火値で非干渉に保つ

gate 追加前から存在する differential-equivalence test (TC-D — リファクタ前後の出力等価性を比較) は、**全シナリオが leading-dash 非該当値を使う** ため新 gate が不発火で、差分比較に干渉しない。新規挙動 (gate) の検証は専用 test (TC-8) に分離し、既存の等価性 test には gate を発火させる入力を混ぜない。新規 gate を differential 比較から構造的に分離する設計判断が「gate 追加が既存等価性を壊していない」ことの立証を簡潔にする ([[delegation-refactor-differential-test-equivalence]] の差分テストを既存維持したまま新挙動を別 test で足す形)。

## 関連ページ

- [入力注入経路のない静的文字列処理連鎖は関数抽出 + 境界行 extract で非 vacuous unit テスト化する](./static-input-chain-function-extraction-non-vacuous-test.md)
- [Validation chain の発火 reason は最初に入力を parse する段階で決まる（暗黙 validation が後続 check を unreachable 化）](../heuristics/validation-chain-fired-reason-by-first-parse-stage.md)
- [sanitization 対称性 claim は入力クラス別に runtime byte-level 検証してから書く](../heuristics/symmetry-claim-input-class-runtime-verification.md)

## ソース

- [PR #1299 review results](../../raw/reviews/20260607T185308Z-pr-1299.md)
