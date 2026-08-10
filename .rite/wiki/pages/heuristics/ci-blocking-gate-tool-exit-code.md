---
type: "heuristics"
title: "CI lint チェックを blocking gate に昇格するときはツール自身の exit code を gate にする"
domain: "heuristics"
description: "lint / 静的解析ジョブを informational（常時 exit 0）から blocking CI gate へ昇格するとき、gate 判定を「レポート JSON を jq でパースして error 件数を数え、`[ \"$err_count\" -gt 0 ]` で判定する」方式にすると、ツールが実行不能（binary 欠落 / IO エラー / 空レポート）だったときに `err_count=0` と誤認して **silent pass** する経路が残る。"
created: "2026-07-24T13:47:35Z"
updated: "2026-08-01T08:45:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T133654Z-pr-2009.md"
  - type: "reviews"
    ref: "raw/reviews/20260801T083836Z-pr-2080.md"
tags: [ci, blocking-gate, exit-code, fail-loud, lint, silent-pass, version-pinning, devops, continue-on-error, advisory-leg]
confidence: medium
---

# CI lint チェックを blocking gate に昇格するときはツール自身の exit code を gate にする

## 概要

lint / 静的解析ジョブを informational（常時 exit 0）から blocking CI gate へ昇格するとき、gate 判定を「レポート JSON を jq でパースして error 件数を数え、`[ "$err_count" -gt 0 ]` で判定する」方式にすると、ツールが実行不能（binary 欠落 / IO エラー / 空レポート）だったときに `err_count=0` と誤認して **silent pass** する経路が残る。gate はツール自身の exit code（findings があれば非ゼロ）を採用すれば、findings 検出だけでなく invocation 失敗も非ゼロ→ジョブ fail になり **fail-loud** できる。

## 詳細

- **背景（shellcheck の blocking 化）**: shellcheck ジョブを informational（`report` を jq でパースし件数を summary に出して常に `exit 0`）から error severity の blocking gate へ昇格した。gate は `report=$(shellcheck --severity=style --format=json ... 2>/dev/null || true)` を件数集計に使う従来経路は report 用途に残しつつ、判定は別途 `if shellcheck --severity=error "${files[@]}"; then … else exit 1; fi` と**ツールを exit code 目的で再実行**する形にした。`report` 側は `2>/dev/null || true` で握りつぶすが、それは非致命な集計であり、権威判定は suppression の無い gate scan が別に担うため silent failure 化しない（責務分離: report=best-effort / gate=authoritative）。

- **なぜ exit code か**: jq パース方式は「ツールが動いて 0 件」と「ツールが動かず空レポート」を区別できない。前者だけが pass すべきで後者は fail すべきだが、件数比較では両方 0 件になる。exit code は「ツールが動いて 0 件 = 0」「findings あり = 非ゼロ」「実行不能 = 非ゼロ」を構造的に区別する。error-handling reviewer はこの「空レポートで silent pass」を典型的な silent failure として指摘するため、gate は count ではなく exit code に寄せる。

- **`if cmd; then … else exit 1; fi` は errexit/pipefail 非依存**: gate をパイプの無い単純コマンドの `if` 条件に置くと、`if` 条件は errexit 免除で exit code を直接検査するため、`set -e` / `pipefail` の ON/OFF に関わらず fail-loud が成立する（GitHub Actions のデフォルト `run:` シェルは `shell:` 未指定なら `bash -e {0}` = errexit ON・pipefail OFF。`shell: bash` を付けて初めて `-eo pipefail` になる点に注意）。annotation（`echo "::error::…"`）はジョブを fail させず、直後の `exit 1` が fail させる—役割を分ける。

- **非固定ツールバージョンの blocking 化リスク（受容 or pin）**: informational だった頃は runner プリインストール版のツール更新で新しいチェックが追加・昇格しても常時 exit 0 で無害だった。blocking 化すると同じバージョンドリフトが **未変更コード**に対してジョブを非ゼロ終了させ、ブランチへの全 PR を spurious にブロックしうる（発生可能性は低い Hypothetical だが、露出そのものは blocking 化が導入する）。対処は (a) ツールバージョンを固定（SHA ピンの setup アクション / 版指定 install）するか、(b) 「runner 提供版に追従する」受容リスクを step コメント・PR 本文・Decision Log に明示する。どちらを採るかは設計時に決める。

- **ジョブ名変更 = status-check context 名の変更**: 昇格に伴い `name: shellcheck (informational)` → `name: shellcheck` のように informational 表記を外すと、GitHub が報告する status-check の名前が変わる。required status check（branch protection）に旧名で登録済みだと参照が切れるため、required 登録は新名で行う。導入直後で未登録なら安全だが、ジョブ fail が **merge をブロック**するのは branch protection に required として追加された後（リポジトリ管理者の設定、当該 PR の外）である点も併せて認識する。

- **`continue-on-error` の leg が緑でも AC 達成にはならない**（PR #2080）: matrix job の一部に `continue-on-error: ${{ matrix.os == 'macos-latest' }}` が付いていると、その leg が赤でも workflow conclusion は緑になる。「macOS + ubuntu 両 leg 0 FAIL」のような AC を持つ PR で、チェック一覧の緑を根拠に AC 達成と判定すると、実際には advisory leg が落ちていても気づかない。**判定は job 自体の結論**（`gh pr checks <PR>` の各行 / 当該 job のログ本文）で行う。3 レビュアーが独立にこの非対称に言及し、最終的に `gh pr checks` で macOS leg 自体の pass を確認して決着した。逆にこの非対称は設計上の武器にもなる — その platform でしか runtime 再現しない退行に対し、**静的ガードを blocking leg 側に置く**ことで advisory leg に依存せず invariant を gate できる。

## 関連ページ

- [`cmd=$(...) || cmd=""` は非ゼロ終了時に stdout 済みの診断 JSON を空文字列で上書きする](../anti-patterns/command-substitution-fallback-discards-diagnostic-json.md)
- [静的ガードを新設したら、走査面の限界と現存する未カバーサイトをテスト本体のコメントに書く](./static-guard-declare-scan-scope-limits.md)

## ソース

- [PR #2009 review results](../../raw/reviews/20260724T133654Z-pr-2009.md)
- [PR #2080 review results (cycle 3)](../../raw/reviews/20260801T083836Z-pr-2080.md)
