---
type: "anti-patterns"
title: "明示的 Phase 遷移で駆動する SKILL.md に新規 Phase を挿入する際、既存の終端ルーティング更新漏れで到達不能になる"
domain: "anti-patterns"
promote: rite-plugin
description: "「Proceed to Phase X」のような明示的な遷移指示でフェーズ間を駆動する設計の SKILL.md では、document-order の fall-through（文書内で上から下に読み進めば自然に次の Phase に到達する、という前提）は実行モデルとして成立していない。"
created: "2026-07-20T07:50:27Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260720T071821Z-pr-1925.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T151507Z-pr-2822.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T151345Z-pr-3183.md"
  - type: "fixes"
    resource: "raw/fixes/20260926T152317Z-pr-3183.md"
tags: ["skill-authoring", "phase-routing", "prompt-engineering", "dead-code"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T15:24:48Z" }
verified:
  - { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-15T00:45:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T15:24:48Z" }
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

### 再発: 分岐表の行が旧遷移先のまま残る

batch-run にステップ 1.5（再開段階の振り分け）を挿入し、ステップ 2 の冒頭に「1.5 の marker が open のときのみ実行する」と前提を書いたが、ステップ 1 の分岐表の `process` 行は「→ ステップ 2（open）へ」のままだった。2 名の reviewer が独立に「分岐表を機械レールとして辿る実行者は 1.5 を飛ばして open を呼ぶ」と指摘した。

新ステップの冒頭に前提文を置いても、既存の**分岐表の行**がその新ステップを名指ししていなければ経路は繋がらない。修正は `process` 行を「run 起動後の最初の process は 1.5 へ、再入は 2 へ」に書き換え、その行を静的 pin（行頭の `| \`process\` |` から新ステップ番号までを 1 本の ERE で固定）で守ること。pin の ERE で表のパイプを `\|` にエスケープしないと交替になり、pin 自体が空虚に真になる。

### 再発: ループの途中に段を足すと、終端を指す指示が複数箇所に散っている

レビューループの「mergeable の後」に、PR 内で扱える推奨を fix へ渡す段を差し込んだ変更で、実測付きの blocking が 6 件出た。原因はすべて、差し込んだ段が既存の終端と噛み合っていないことだった。

- **終端を指す指示の更新漏れ**: ループの終端を実行者に伝える文言は、Stop hook の差し戻し文言、sub-skill が書く次アクション、契約文書にある sentinel の意味、と複数の場所に分かれている。一部だけ新しい段を指すように直すと、turn 終了や compact の後に古い終端へ戻される。差し込み位置の直前にある sentinel ごとに、終端を指す文言を列挙して同時に直す。
- **前段の成果物が無いことを異常として扱う**: 保存済みレビュー結果のディレクトリは、保存したときに初めて作られる。これを「無い = エラー」とすると、初回にだけ現れる正常な状態でループが止まる。過去の記録を数えるような処理では、置き場が無いことを空集合として扱えるかを先に確かめる。
- **後続の検証を始められるかを確かめずに差し込む**: 修正を差し込む段は、その後に次のレビューを始められること（cycle 上限に達していないこと）を先に確かめる。確かめないと、上限の mergeable で修正を始め、未レビューの HEAD を残して止まる。満たさないときは差し込まず、従来の記録経路に残す。
- **複合条件の一部が固定されていない**: 上限判定のような複合条件は、各項を 1 つだけ外す変異ごとに負の対照テストを置く。変異が赤になるのを確かめてから pin したとみなす。

## 関連ページ

- [新規 helper は既存 sibling の安全規約に整合させる（trap・tree 解決・制御文字無害化）](../heuristics/new-helper-conform-to-sibling-safety-conventions.md)
- [再開の振り分け先は phase 名の対応ではなく、遷移先スキルの入口契約（前提 phase と完了 sentinel）で決める](../heuristics/resume-dispatch-target-must-satisfy-downstream-entry-contract.md)

## ソース

- [fix 結果](../../raw/fixes/20260720T071821Z-pr-1925.md)
- [レビュー結果](../../raw/reviews/20260914T151507Z-pr-2822.md)
- [レビュー結果](../../raw/reviews/20260926T151345Z-pr-3183.md)
- [fix 結果](../../raw/fixes/20260926T152317Z-pr-3183.md)
