---
type: "heuristics"
title: "セッション単位の state を読む案内は、同じ session_id で入る入口を基準に選ぶ — テストはホストの入力形で呼ぶ"
domain: "heuristics"
promote: rite-plugin
description: "起動時の案内がセッション単位の state ファイルを読むとき、案内を出せるのは同じ session_id で起動した入口だけである。別経路の対象 source を流用すると実際の入口が抜け、harness が session id を事前設定するテストではその欠落が見えない。"
created: "2026-09-27T10:47:38Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T20:35:06Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T11:07:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T20:35:06Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T102947Z-pr-3259.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T103549Z-pr-3259.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T104751Z-pr-3259.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T105748Z-pr-3259.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T202752Z-pr-3340.md"
tags: ["hooks", "session-id", "resume", "test-input-shape"]
confidence: high
---

# セッション単位の state を読む案内は、同じ session_id で入る入口を基準に選ぶ — テストはホストの入力形で呼ぶ

## 概要

起動時の案内がセッション単位の state ファイルを読むとき、案内を出せるのは同じ session_id で起動した入口だけである。別経路の対象 source を流用すると実際の入口が抜け、harness が session id を事前設定するテストではその欠落が見えない。

## 詳細

ホストは startup / clear では新しい session_id を渡し、同じ id を引き継ぐのは resume である。停止した run の停止理由を起動時に案内する処理が、既存のリセット経路の対象 source（startup / clear）を流用したため、案内が出るべき resume が対象から外れ、実際のどの入口でも案内が出なかった。

テストの harness は payload に session_id を渡さず、sid を事前設定して hook を呼んでいた。このため実入口では到達しない分岐が green になっていた。同じ修正を検証した reviewer のうち、harness の入力をそのまま使った者は解消と判定し、実ホストの payload 形（session_id 付き）で再現した者は未解消と判定した。判定の食い違いは、各自が使った入力の形を突き合わせると決着した。

- 案内の対象 source は「同じ session_id で起動する入口」から選ぶ。別経路（リセット等）の対象 source を流用しない
- hook のテストはホストと同じ入力の形（ホスト種別と payload の session_id）で呼ぶ
- 新しい session_id の起動では案内が出ないことも対照として固定し、案内の範囲をテストで示す
- reviewer 間で解消判定が割れたら、結論ではなく各自が使った入力の形を突き合わせる

同じ修正の次の cycle では、複数の reviewer がホストの実入力形（runtime の session_id と payload だけ）と harness 形の両方で再現し、解消に合意した。入力の形を変えても同じ結論になることを確かめると、fixture に依存した green と区別できる。対照の置き方にも 2 つの規則が残った。

- 条件が複数の起動元を並べる分岐（startup / clear / resume）は、対照を起動元ごとに 1 件ずつ置く。1 つの対照を起動元のリストで回すと、条件の片側だけを外す変更も検出でき、起動元の追加で既存の対照を複製せずに済む
- 実入力形では到達しない入口の組み合わせ（同じ session_id での clear 等）や、変更した分岐に到達しない否定対照（別セッションの state は読まない等）は、題かコメントに「何を固定するか」と「ホストが実際にその入力を作るか」を書く。題が分岐の挙動に見えると、読み手はその対照を仕様と誤読する

### 実入力形へ揃えたら、外した肯定対照が守っていた分岐を実装側で確かめる

ホストが作らない入力形（同じ session_id での clear）で固定していた肯定対照を外し、同じ state のまま session_id だけを変えた起動は無言、という否定対照に置き換えた。テストは実入力形に揃ったが、実装の案内条件には clear の腕が残り、実装コメントも「startup / clear / resume で案内する」と述べたままだった。その腕を消してもテストは通るので、腕を誤って壊す編集は検出されない。

- 肯定対照を外すときは、その対照だけが到達していた実装の分岐とコメントを確かめる。分岐を残すなら残す理由（その入力を作るホストがあるか）を書き、不要なら削除を判断する。テストの変更だけで閉じない
- 否定対照（案内が出ないこと）は、同じ fixture と同じ session_id で肯定を観測する対照を直前に置き、基本 fixture から 1 条件だけを変えて作る。変えた条件以外で黙ることが無いので、空振りを別途疑わずに済む
- 壊れた state を流す対照では、stderr と rc を親シェルで受け取る。サブシェルで代入する helper を経由すると、読み取り失敗の WARNING を確かめられない
- fixture を関数の引数の中のコマンド置換で作ると、生成が失敗しても `set -e` は発火せず空の state が書かれる。フィルタが固定のリテラルなら到達しない経路だが、可変にするなら代入を独立させて失敗を止める

## 関連ページ

- [hook のテストスイートは ambient な session-id 環境変数 (CLAUDE_CODE_SESSION_ID 等) に依存させない (non-hermetic test)](./test-hermeticity-ambient-session-id-env-leak.md)
- [テンプレート準拠の fixture では、生成器が実データで作る構造的逸脱を検出できない](./template-fixture-misses-generator-real-data-deviation.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T102947Z-pr-3259.md)
- [fix 結果](../../raw/fixes/20260927T103549Z-pr-3259.md)
- [実入力形と harness 形の両方で解消を確かめたレビュー結果](../../raw/reviews/20260927T104751Z-pr-3259.md)
- [対照を起動元ごとに置き直した fix 結果](../../raw/fixes/20260927T105748Z-pr-3259.md)
- [肯定対照を外したあと実装の分岐を確かめるレビュー結果](../../raw/reviews/20260927T202752Z-pr-3340.md)
