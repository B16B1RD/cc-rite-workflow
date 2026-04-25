---
title: "Declarative enforcement で LLM の stop_reason: end_turn は抑制できない"
domain: "anti-patterns"
created: "2026-04-25T12:30:00+00:00"
updated: "2026-04-25T12:30:00+00:00"
sources:
  - type: "retrospectives"
    ref: "raw/retrospectives/20260425T122746Z-meta-issue-create-stuck-rootcause.md"
tags: [llm-turn-boundary, declarative-enforcement, stop-reason, end-turn, sub-skill-return, sentinel, mode-b]
confidence: high
---

# Declarative enforcement で LLM の stop_reason: end_turn は抑制できない

## 概要

`/rite:issue:create` の sub-skill return 後の implicit stop を防ぐ目的で、`Anti-pattern` / `Correct-pattern` / `same response turn` / `DO NOT stop` / `IMMEDIATELY` / Step 0 Immediate Bash literal / HTML コメント sentinel / plain-text marker などの **declarative enforcement** を 9 件の Issue (#3 → #651) で累積導入してきたが、本番セッション (`f0d8791d` 2026-04-24 / `f7afee09` 2026-04-21) の `.jsonl` 一次情報で LLM が **これらすべてを emit した上で `stop_reason: end_turn` を選択している** 事実が確認された。declarative enforcement は LLM が「正しい挙動を選ぶ確率を上げる」ものであって「強制する」ものではないため、`end_turn` を抑制したい場合は別の手段 (proactive な構造改訂 / hook 層からの context injection / sub-skill inline 化) が必要。

## 詳細

### 観測された一次情報

`f0d8791d` セッション (PR #654 4-site 対称化マージ 9 時間後) の `.jsonl` line 65:

```json
{
  "stop_reason": "end_turn",
  "content": [{
    "type": "text",
    "text": "[CONTEXT] INTERVIEW_DONE=1; scope=skipped; next=phase_0_6\n> ⏭ 継続中: Phase 0.6 → ...\n<!-- caller: IMMEDIATELY run this as your next tool call (Step 0 Immediate Bash Action — bash command literal in backticks): `bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview --next 'Step 0 Immediate Bash Action fired; proceeding to Phase 0.6. Do NOT stop.' --if-exists --preserve-error-count` THEN (after the bash command above succeeds) continue with Phase 0.6 (Task Decomposition Decision) in the SAME response turn. DO NOT stop. ... -->\n<!-- [interview:skipped] -->"
  }]
}
```

LLM はこのテキストを **emit した上で** turn を閉じている。content には `IMMEDIATELY`, `DO NOT stop`, `SAME response turn`, `Step 0 Immediate Bash Action` という最強の declarative enforcement 句が **すべて含まれている** にもかかわらず `stop_reason: end_turn` が選択された。

`f7afee09` セッション (PR #636 マージ前 10 時間) でも同様の構造で 7 分間隔で 2 回連続 end_turn が観測されており、最新の対策 (4-site 対称化 #654) を全部入れても LLM の選択は変わらない。

### 過去 9 件の対策の効果検証

| Issue | 対策 | declarative の強化方向 | LLM の `end_turn` 選択を変えたか |
|---|---|---|---|
| #525 | 3 層自動継続契約 | 文章規約の階層化 | ❌ |
| #444 | Terminal Completion pattern | sub-skill 自己完結契約 | ❌ |
| #475 | Mode A/B hook 強制 | hook 層追加 | ❌ |
| #552 | Pre-check list + Anti/Correct-pattern | dispatcher と禁止/推奨明文化 | ❌ |
| #561 | HTML コメント sentinel | turn-boundary heuristic 回避試行 | ❌ |
| #622 | whitelist + Pre-flight | phase 遷移 + 前倒し | ❌ |
| #634 | Step 0 + INTERVIEW_DONE marker | concrete bash literal | ❌ |
| #651 | 4-site 対称化 | 同 marker を 4 site で対称配置 | ❌ |

各対策は単体テストで完璧に PASS したが、本番では `stop_reason: end_turn` が選ばれ続けた。

### なぜ declarative では抑制できないか

LLM の `stop_reason` は **モデル内部の確率的選択**で決まる。RLHF training で「ユーザーへの応答の自然な終わり」を強く学習しているため、`<!-- [interview:skipped] -->` のような sentinel emit + 周辺 context (sub-skill が「return しました」的な signal) が「タスク完了感」を強く感じる pattern を構成すると、テキスト中の `DO NOT stop` 指示よりも turn-end heuristic を優先してしまう。

これは prompt engineering の限界というより、**LLM の training 由来の挙動が prompt content に対して必ずしも従順でない**事実。Anthropic の公式 docs にも「instruction following は best-effort で 100% guarantee ではない」と明記されている。

### Anti-pattern としての症状

declarative enforcement が効かないと知らずに「直前の対策が効かない → さらに declarative 層を積む」という反応をすると、N+1 件目の regression が必然的に発生する周期サイクルに陥る。本リポジトリでは過去 2 ヶ月で 9 件 (Issue #3 → #651) の累積を経験した。

### 代替手段 (proactive な構造改訂)

declarative では足りないと判明した場合の選択肢:

| 案 | 内容 | 制御の確実性 |
|---|---|---|
| **A. sub-skill inline 化** | 独立 Skill から caller 内 inline へ統合。Skill tool boundary を物理的に消去 → turn 境界が立たない構造へ | 高 (構造で保証) |
| **B. hook 層 context injection** | PostToolUse hook + `additionalContext` で次 turn の system prompt に強制注入 (Claude Code 公式仕様) | 中 (hook 仕様依存) |
| **C. continue 自動化受容** | end_turn を許容し `/loop` などで `continue` を自動入力 | 中 (運用回避) |
| **D. stop hook の reactive block** | Stop hook で exit 2 + JSON stderr `decision: block` で再起動強制 | 中 (前提条件成立が必須、bug #10412 リスクあり) |

A/B はそれぞれトレードオフ (modular 性 / hook 仕様の調査コスト) があるため、対策決定前に **必ず一次情報で根本仮説検証**を行うこと。

### 検証手順 (declarative が効いていないことの実証)

新規対策を導入する前後で `.jsonl` セッション log の `stop_reason` を取得し統計を取る:

```bash
JSONL=~/.claude/projects/-home-akiyoshi-Projects-personal-cc-rite-workflow/<session-id>.jsonl
jq -c 'select(.type=="assistant" and .message.stop_reason=="end_turn") |
  select(.message.content[]?.text? // "" | test("\\[interview:(skipped|completed)\\]"))' "$JSONL"
```

検出件数が **対策導入後も 0 件にならない**なら、その対策は declarative enforcement の追加層であり root cause を解決していない。

## 関連ページ

- [Fix-induced drift in cumulative defense](fix-induced-drift-in-cumulative-defense.md)
- [Test pin protection theater](test-pin-protection-theater.md)
- [Prose design without backing implementation](prose-design-without-backing-implementation.md)
- [Silent precondition omit disables AND defense chain](silent-precondition-omit-disables-and-defense-chain.md)

## ソース

- [meta-investigation: /rite:issue:create が累積 9 件の対策後も止まり続けた meta-retrospective](../../raw/retrospectives/20260425T122746Z-meta-issue-create-stuck-rootcause.md)
