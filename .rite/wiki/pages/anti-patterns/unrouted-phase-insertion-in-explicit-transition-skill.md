---
type: "anti-patterns"
title: "明示的 Phase 遷移で駆動する SKILL.md に新規 Phase を挿入する際、既存の終端ルーティング更新漏れで到達不能になる"
domain: "anti-patterns"
promote: rite-plugin
description: "「Proceed to Phase X」のような明示的な遷移指示でフェーズ間を駆動する設計の SKILL.md では、document-order の fall-through は実行モデルではない。新規 Phase を挿入しても、それを指す既存の終端ルーティング（他 Phase の「次は Phase Y へ」という指示）を更新しなければ、文書上の配置に関わらず実行時に到達不能（dead code）になる。"
created: "2026-07-20T07:50:27Z"
updated: "2026-07-20T07:50:27Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260720T071821Z-pr-1925.md"
tags: ["skill-authoring", "phase-routing", "prompt-engineering", "dead-code"]
confidence: medium
---

# 明示的 Phase 遷移で駆動する SKILL.md に新規 Phase を挿入する際、既存の終端ルーティング更新漏れで到達不能になる

## 概要

「Proceed to Phase X」のような明示的な遷移指示でフェーズ間を駆動する設計の SKILL.md では、document-order の fall-through（文書内で上から下に読み進めば自然に次の Phase に到達する、という前提）は実行モデルとして成立していない。新規 Phase を文書中の適切な位置に挿入しても、その Phase を指す既存の終端ルーティングを併せて更新しなければ、実行時にその Phase へ制御が渡る経路が存在せず、到達不能な dead code になる。

## 詳細

`skills/setup/SKILL.md` に新規 Phase 4.8（sandbox write-allowlist 事前案内）を追加した際、この Phase 自体はどこからも "proceed to" されておらず、実行時に到達不能だった。とりわけ `--upgrade` 経路（Step 7b が Phase 4.7 完了後に status 表示して即 exit するのみ）は絶対に到達しない構造になっていた。皮肉なことに、直前の cycle で対処した唯一のシナリオ（`EnterWorktree` 後の `--upgrade` 手動実行）こそが、この到達不能経路そのものだった。

reviewer は grep + 実行フロー追跡（「新規 Phase への参照が見出し自身にしかない」ことの確認、および各既存終端の遷移先名指しの追跡）によって到達不能性を実証した。

**教訓**:

- SKILL.md のような、明示的な遷移指示（"Proceed to Phase X"）で phase 間を駆動する実行モデルを持つドキュメントに新規 Phase を挿入するときは、その Phase への「入口」（どの既存終端から遷移してくるか）を必ず設計し、既存の全終端ルーティングを実際に更新する。
- 新規追加した Phase の直後に文書上「次はこの Phase へ」と書くだけでは不十分。**その新規 Phase を参照すべき既存の全終端**（複数の分岐末尾、複数のエントリポイントなど）を洗い出し、漏れなく更新する。
- レビュー時は「新規 Phase への参照が新規 Phase 自身の見出し以外に存在するか」を grep で確認し、既存の全終端遷移を実際に辿って到達可能性を実証するのが有効な検証手段。

## 関連ページ

- [新規 helper は既存 sibling の安全規約に整合させる（trap・tree 解決・制御文字無害化）](../heuristics/new-helper-conform-to-sibling-safety-conventions.md)

## ソース

- [PR #1925 fix results (cycle 3)](../../raw/fixes/20260720T071821Z-pr-1925.md)
