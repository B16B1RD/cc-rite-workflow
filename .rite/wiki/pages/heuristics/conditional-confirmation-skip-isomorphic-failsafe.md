---
type: "heuristics"
title: "条件付き確認 skip は既存 in-flow 判定と同型にし fail-safe を「確認を出す」側へ倒す"
domain: "heuristics"
promote: rite-plugin
description: "自律ワークフロー（batch / iterate 等）と矛盾する AskUserQuestion を条件付きで skip する機械判定を新設するときは、(1) 判定ロジックを既存の in-flow 判定（`in_e2e_flow` / batch 判定）と同型に流用し新しいシグナルを発明しない、(2) helper / read 失敗時は必ず「確認を出す（安全側）」へ fail-safe する、(3) WARNING の有無は「失敗が正常系か想定外か」で出し分ける。"
created: "2026-07-16T09:37:48+09:00"
updated: "2026-07-16T09:37:48+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260716T002919Z-pr-1868.md"
tags: []
confidence: high
---

# 条件付き確認 skip は既存 in-flow 判定と同型にし fail-safe を「確認を出す」側へ倒す

## 概要

自律ワークフロー（batch / iterate 等）と矛盾する AskUserQuestion を条件付きで skip する機械判定を新設するときは、(1) 判定ロジックを既存の in-flow 判定（`in_e2e_flow` / batch 判定）と同型に流用し新しいシグナルを発明しない、(2) helper / read 失敗時は必ず「確認を出す（安全側）」へ fail-safe する、(3) WARNING の有無は「失敗が正常系か想定外か」で出し分ける。この 3 点を守ると、レビュアーが「既存の実証済みパターンの忠実な複製」と判定でき、確認スキップ機構が危険側（無言で確認を飛ばす）へ倒れない。

## 詳細

**背景**: 起点事例で `/rite:batch-run` の「完全自律（無確認）」宣言と、open ステップ 3.4（計画承認）・pr-review ステップ 3.3（レビュアー構成確認）の AskUserQuestion の矛盾を解消した。open 3.4 には run-queue ベース batch 検出、pr-review 3.3 には flow-state phase-whitelist E2E 検出を追加した。3 レビュアー（prompt-engineer / code-quality / error-handling）が全員「マージ可・指摘 0 件」を返し、その根拠がこの 3 原則の遵守だった。

**1. 判定を既存 in-flow 判定と同型にする（新シグナルを発明しない）**
- open 3.4 の batch 検出は `iterate` ステップ 6 の run-queue batch 判定（`state-path-resolve.sh` / `flow-state.sh path` で session_id 導出 → run-queue の `active` + cursor 一致）をほぼバイト単位で複製した。
- pr-review 3.3 の E2E 検出は `ready` Phase 2.1 の `in_e2e_flow`（phase whitelist `{review, fix, phase5_post_review, phase5_post_fix}` + `active=true`）を byte-identical に複製した。
- どちらを流用するかは「そのステップが何を経由して到達するか」で決まる: open は iterate を経由しないため phase では batch/standalone を区別できず run-queue が唯一の有効シグナル。pr-review は iterate が呼び出し前に `phase=review` を書くため flow-state phase-whitelist が成立する。
- この ~12 行の検出ラッパの重複は、各 skill が state helper（`state-path-resolve.sh` / `flow-state.sh`）の薄いラッパを独立にインライン保持する rite 慣習に沿う。helper へ抽出するのは「新しい抽象の持ち込み」に該当し不適切（`[[shell-script-shared-lib-extraction]]` が扱う hooks/*.sh の共通化とは対象レイヤが異なる — あちらは実行スクリプト、こちらは skill markdown 内の判定ラッパ）。

**2. fail-safe は必ず「確認を出す（安全側）」へ倒す**
- 検出は「確認を出す」を初期値に置き、skip 側へ昇格するのは全条件成立時のみにする。open 3.4 は `plan_mode=interactive` を初期値に置き batch 昇格を全条件 AND で判定、pr-review 3.3 は `in_e2e_flow=false` を初期値に置く。
- session_id 解決不可 / queue 不在 / helper 失敗 / jq 失敗のいずれも、確認を出す側（interactive / standalone）に収束することを実測で確認する。危険側（無言で確認を skip）へ倒れる経路が 1 本も無いことが受入基準。

**3. WARNING の有無は失敗が正常系か想定外かで出し分ける**
- run-queue 判定（iterate 6 / open 3.4）は **queue 不在が standalone の正常系**のため、毎回 WARNING を出すのはノイズ → silent fail-safe（WARNING なし）が正しい。
- flow-state E2E 判定（ready 2.1 / pr-review 3.3）は **E2E 途中の read 失敗が真に想定外**のため、helper 失敗時は stderr へ loud WARNING + `[CONTEXT] STATE_READ_FAILED=1` marker を出す（`[[silent-fallback-observability-via-debug-log]]` の系統）。
- 同じ「fail-safe」でも失敗セマンティクスが異なるため、各判定は正しい sibling（run-queue 系 or flow-state 系）の WARNING 方針に従う。

**補足**: `set -euo pipefail` はこの種の検出ブロックに足さない。`flow-state.sh path` 失敗時にブロックが `[CONTEXT] ...MODE=` marker を emit する前に abort すると、LLM が判定行を得られなくなる。`set -e` なし + marker 常時 emit + 初期値=確認を出す、の組み合わせが全経路で確定的な安全 verdict を保証する。

## 関連ページ

- [resolver / helper 失敗時の silent fallback は debug log で観測性を確保する](../patterns/silent-fallback-observability-via-debug-log.md)

## ソース

- [PR #1868 review results](../../raw/reviews/20260716T002919Z-pr-1868.md)
