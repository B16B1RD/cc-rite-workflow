---
title: "入力注入経路のない静的文字列処理連鎖は関数抽出 + 境界行 extract で非 vacuous unit テスト化する"
domain: "patterns"
created: "2026-06-05T18:33:35Z"
updated: "2026-06-09T02:35:18Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260605T181146Z-pr-1281.md"
  - type: "reviews"
    ref: "raw/reviews/20260605T180128Z-pr-1281.md"
  - type: "reviews"
    ref: "raw/reviews/20260605T182035Z-pr-1281-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T010819Z-pr-1314.md"
tags: ["test", "vacuous-assertion", "function-extraction", "mutation-testing", "bash", "unit-test", "awk-boundary-extract", "intentional-asymmetry"]
confidence: high
---

# 入力注入経路のない静的文字列処理連鎖は関数抽出 + 境界行 extract で非 vacuous unit テスト化する

## 概要

hook 内の文字列処理連鎖 (エスケープ等) が **静的入力 (literal な reason 文字列等) のみに適用され、テストから入力を注入する経路が存在しない** 場合、hook 全体の統合テスト (fake jq 等で fallback を発火させる方式) では連鎖を exercise できず、「valid JSON」「raw 制御バイト非漏出」のような assertion が vacuous false positive 化する。解決は **連鎖を関数に抽出し、テスト側で awk 境界行抽出 + eval で関数だけを load して実入力 (C0 制御バイト等) を直接流す** 方式。commit 前に mutation 検証 (核心行削除 → assertion fail) で非 vacuous を runtime 実証する。

## 詳細

### 失敗の構造（cycle 1 で実測）

`pre-tool-bash-guard.sh` の deny フォールバック JSON エスケープ連鎖 (`\\` → `\"` → `\n` → `neutralize_ctrl --c0-only`) は静的な deny reason のみに適用される。対称転記元 (stop-loop-continuation.sh) の TC-16 は handoff 注入経路があるため実 ESC バイトを reason に流して機能を exercise できたが、転記先の TC-116 は注入経路が無く静的 reason のみで fallback を発火させたため、「valid JSON」「no raw ESC byte」の 2 assertion が vacuous 化した:

```bash
# Mutation 実験 (cycle 1 review): エスケープ連鎖の核心 2 行を削除
# 期待: TC-116 の 2 assertion が FAIL
# 実測: 151 passed / 0 failed のまま → vacuous false positive
```

これは [[asymmetric-fix-transcription]] が **テスト assertion レベル** で発生した形態 — 対称転記時は「テストが注入する入力の性質 (静的 vs 動的)」も対称性監査の対象に含める必要がある。

### Canonical 解決手順（fix で確立）

1. **連鎖を関数に抽出する**: エスケープ連鎖を `_bash_guard_escape_deny_reason()` のような名前付き関数に抽出する。production 側の挙動は不変 (呼び出し形のみ変化)。
2. **テスト側で境界行 extract + eval**: hook ファイル全体を source すると副作用 (trap / main 実行) が走るため、awk の範囲指定で関数定義行だけを抽出して eval する:

   ```bash
   func_src=$(awk '/^_bash_guard_escape_deny_reason\(\) \{$/,/^\}$/' "$HOOK_FILE")
   eval "$func_src"
   declare -f _bash_guard_escape_deny_reason >/dev/null || fail "extract 失敗"
   ```

   `declare -f` gate で「抽出に失敗して関数が未定義のまま assertion が空振りする」silent miss を防ぐ。
3. **実入力を直接注入する**: 抽出した関数に実 C0 制御バイト (raw ESC 0x1b、改行、`"` / `\` 等) を含む入力を流し、出力が valid JSON 文字列リテラルとして escape 済みであることを assert する。
4. **mutation 検証を commit 前に実施する**: 隔離 worktree で連鎖の核心行を削除し、追加した assertion が FAIL することを確認してから commit する（核心行削除で 2 assertion fail を実測）。

### Propagation 判断 — テスト可能性の動機が無い側には関数化を伝播しない

stop-loop-continuation.sh の同型インライン連鎖には関数化を **伝播しなかった**: handoff 注入経路があり TC-16 が既に非 vacuous に pin 済み = テスト可能性のための関数抽出という動機が存在しない。構造の非対称 (片方は関数、片方はインライン) が生まれるが機能は同一であり、判断根拠を commit message の decision 行に記録した。[[asymmetric-fix-transcription]] の「同期すべきでない site の識別」（test scope pin 保護と同系）にあたる意図的非対称。

### 討論合意の fix への反映はコメント記録に縮退させる

cycle 1 の「source ガード追加 (fail-closed 化)」という defensive code 提案は、hook 自体が ERR trap で設計上 fail-open + same-privilege boundary という反証で不採用とし、「fail 方向の設計判断をコメントに明文化 + `|| true` 禁止理由の記載」という低コスト対応に縮退させた。root cause は対称転記元に設計根拠コメントがあるのに転記先には用途コメントしかない **コメント非対称** — fail 方向 (fail-open / fail-closed) の判断は対称転記時にコメントごと転記・明文化する。

### 検証の独立再実証 (cycle 2)

cycle 2 の test reviewer は fix 側の mutation claim を鵜呑みにせず、独立に 4 種の mutation 実験 (各エスケープ行の個別削除 + neutralize→cat 置換) を worktree-only pattern で再実施し、4 段連鎖のどの 1 行を壊しても assertion が落ちることを再実証した。fix 側 claim (2 assertion fail) と観測数は異なったが「非 vacuous」という核心の一致を確認して合意 — 詳細は [[mutation-testing-test-fidelity]] を参照。

### detection program 抽出への拡張（0 findings で確認）

本 pattern の「関数抽出」は **検出ロジック (jq filter / detection program) の抽出** にも一般化される。PR #1314 (T-7 behavioral fixture) は `projects-board-drift-check.sh` の jq 検出 program を **コピーではなく awk で実体抽出** し、`gh api graphql` 出力を模した GraphQL-shaped JSON fixture (6 分類ケース) を stdin で流して classification を検証した。これにより、jq 述語の literal を保持したまま周囲の scoping を反転させる semantic break (`$pitem != null` → `== null`、`select($st != "Done")` → `== "Done"`、`.project.number == $pn` board scoping 削除) — 静的 grep (T-5) では literal 一致のため見えない break — が behavioral assert で捕捉される。4 reviewer (test / code-quality / error-handling / security) が全員「可」、mutation 検証で検出能力を実証し 0 findings / 1 cycle mergeable。

確認された 3 つの設計点:

1. **awk marker/terminator boundary で実 program を抽出**: `/jq -r --argjson pn/` を開始 marker、post-marker 最初の `jq_err` 行を terminator として jq filter 本体を byte-complete に抽出する。マーカー一意性・境界選択は固定 +N 行 window ではなく state machine 的に追う ([[awk-bash-block-termination-tracking]] と同系)。抽出失敗時は `[ -z "$jq_prog" ]` fail-safe ガードで明示 FAIL させ silent pass を防ぐ。
2. **fixture 到達不能層は静的 assert で分担補完**: jq fixture では到達できない GraphQL レイヤの break (`projectItems(first: 10)` → `first: 0` は jq 実行前に結果を空にする) は behavioral test では捕捉できないため、`assert_file_contains "$DRIFT_SH" 'projectItems\(first: [1-9]'` の静的 assert で補完する。behavioral test と static assert の責務分担を意図的に設計する。
3. **過検出ガードの絶対値 assert**: 「drift 行が厳密に 2 行」を TAB 担持行カウントで assert し、board-membership scoping 破壊 (not-on-board / other-project の取りこぼし) による over-detection を捕捉する。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)

## ソース

- [PR #1281 fix results (関数抽出 + awk 境界行 extract + 実 C0 入力直接注入で vacuous assertion を非 vacuous 化、mutation 検証で runtime 実証してから commit)](../../raw/fixes/20260605T181146Z-pr-1281.md)
- [PR #1281 review results (cycle 1 — 静的 reason のみで fallback を発火させた TC-116 の 2 assertion が vacuous false positive、mutation 実験で実証)](../../raw/reviews/20260605T180128Z-pr-1281.md)
- [PR #1281 review results (cycle 2 — 独立 mutation 4 種で非 vacuous を再実証し 0 findings 収束)](../../raw/reviews/20260605T182035Z-pr-1281-cycle2.md)
