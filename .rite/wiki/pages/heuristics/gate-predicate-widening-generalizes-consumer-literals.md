---
type: "heuristics"
title: "ゲートの判定文を新しい欠落種別へ広げたら、同じ marker を消費する option 表・テンプレート・例示 literal を同じ commit で一般化する"
domain: "heuristics"
description: "ワークフロー定義のゲート（例: commit body の段落有無を検査する Root Cause Gate）の判定文を新しい欠落種別へ広げるとき、同じ missing marker で分岐する option 表の bypass literal・commit メッセージ案テンプレート・chat 例示の 3 消費者を同じ commit で一般化しないと、新種別の欠落が bypass 経路で記録されずに通過し、次 cycle の reviewer が消費者ごとの取りこぼしを 1 件ずつ blocking として出す。"
created: "2026-09-02T18:40:00Z"
generated: { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-02T18:40:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260902T175856Z-pr-2529.md"
  - type: "fixes"
    resource: "raw/fixes/20260902T180431Z-pr-2529.md"
  - type: "reviews"
    resource: "raw/reviews/20260902T181813Z-pr-2529.md"
tags: [skill-authoring, gate, simplification-first, literal-contract]
confidence: high
promote: rite-plugin
---

# ゲートの判定文を新しい欠落種別へ広げたら、同じ marker を消費する option 表・テンプレート・例示 literal を同じ commit で一般化する

## 概要

ワークフロー定義のゲート（例: commit body の段落有無を検査する Root Cause Gate）の判定文を新しい欠落種別へ広げるとき、同じ missing marker で分岐する option 表の bypass literal・commit メッセージ案テンプレート・chat 例示の 3 消費者を同じ commit で一般化しないと、新種別の欠落が bypass 経路で記録されずに通過し、次 cycle の reviewer が消費者ごとの取りこぼしを 1 件ずつ blocking として出す。

## 詳細

### 発生事例

fix スキルの Root Cause Gate（Step 1）を「`根本原因:` 段落の有無」から「Escalation trigger 成立時は `simplification-first:` 段落の有無も判定し、いずれかの欠落を `missing` とする」へ広げた。判定文は 1 文で済んだが、同じ `ROOT_CAUSE_GATE=missing` marker を消費する側は 3 箇所あり、いずれも旧種別の literal を持ったままだった:

- **option 表**: option 2（意図的な補足コミットとして通過）の bypass 段落が `Root cause (bypass): {理由}` 固定。新種別だけが欠落した cycle で option 2 を選ぶと、Root cause の bypass として記録され Step 1 の再実行もなく、追加した判断記録が commit body に一切残らないまま通過する。設計理由に書いた「欠落は既存の missing 経路で止まる」が bypass 経路で成立しない
- **commit メッセージ案テンプレート**: 必須段落一覧には新種別を追記したが、LLM が案を埋めるテンプレート行は旧列挙のまま。trigger 成立 cycle では段落を欠いた案が必ず生成され、ゲートが `missing` を出して option 1 のリトライが既定で 1 回挟まる
- **chat 例示**: 同じ段落の literal 形が chat 例示（`simplification-first: 追加パッチを選択 — 理由:`）と commit 必須形（`simplification-first: 追加 — 理由:`）で併存し、近接する不一致な方をコピーする誘導になる

cycle 1 のレビューで 5 名中 2 名（prompt-engineer / application）が option 表を独立に指摘し、残り 2 消費者も同 reviewer が挙げた。cycle 2 で option 表を「Step 1 が欠落と判定した種別に対応する段落」の 1 行に畳み、NB sweep でテンプレートと例示を単一源に揃えた時点で収束した。

### 一般化

ゲートの判定文（producer）と、その結果 marker で分岐する option 表・テンプレート・例示（consumer）は同じ literal 契約を共有している。producer 側だけ広げると consumer 側の literal は旧種別に固定されたまま残り、新種別が到達した経路で「記録されずに通過する」「必ずリトライが挟まる」「不一致な形をコピーする」のいずれかが起きる。判定文を広げる commit では次を同時に行う:

1. marker を消費する箇所を `grep` で列挙する（option 表・テンプレート・例示・reference の直交主張）
2. option を増やさず「判定が欠落と認めた種別に対応する段落」のように**種別に依存しない 1 行**へ畳む
3. 同じ段落の literal 形は 1 箇所に置き、他は「書式は X と同一」で参照する
4. 静的 pin テストには consumer 側の literal（例: bypass 段落の一般化文）も pin する — producer 側の判定文だけ pin すると consumer の取り残しは検出できない

### 付随して確認された小さな規約

- 静的 pin テストが stderr へ出す診断は、helper の fail 原因（pattern 欠落 / heading drift）を section 抽出の非空で切り分ける。切り分けないと見出し採番変更を「規則文が消えた」と誤断定し、読者を規則文の復元という誤った修正へ誘導する。非空判定は `[ -n "$(awk …)" ]` のコマンド置換で書き、`awk … | grep -q .` を `set -o pipefail` 下で条件式に使わない（64 KiB 超の出力で SIGPIPE により判定が反転する）
- `mktemp` はリポジトリ既存の template 形式 `mktemp "${TMPDIR:-/tmp}/rite-<name>-XXXXXX"` に揃える。`mktemp -p` は BSD mktemp を走らせる CI leg で失敗しうる

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin](./universal-claim-prose-invalidated-by-path-addition.md)
- [Variable Rename が Sentinel Literal Contract を汚染する](../anti-patterns/variable-rename-contaminates-sentinel-literal-contract.md)

## ソース

- [レビュー結果](../../raw/reviews/20260902T175856Z-pr-2529.md)
- [fix 結果](../../raw/fixes/20260902T180431Z-pr-2529.md)
- [レビュー結果](../../raw/reviews/20260902T181813Z-pr-2529.md)
