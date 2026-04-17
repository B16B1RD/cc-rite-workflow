---
title: "散文で宣言した設計は対応する実装契約がなければ機能しない"
domain: "anti-patterns"
created: "2026-04-17T04:30:00+00:00"
updated: "2026-04-17T04:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260417T035556Z-pr-559.md"
tags: []
confidence: high
---

# 散文で宣言した設計は対応する実装契約がなければ機能しない

## 概要

設計意図を散文で記述しつつ、それを機能させる実装 / 契約 / consumer が存在しない状態を「Prose-only design」と呼ぶ。pinky-swear な safeguard として残存し、レビュー時に CRITICAL として検出される。PR #559 の 3 CRITICAL + 5 HIGH のうち、4 件が同じ根 (Finding 1/2/4/5) に由来していた。

## 詳細

### 典型パターン

| 形態 | 具体例 (PR #559) |
|------|------|
| 1. 参照変数の未定義 | `fix.md` Phase 3.2.1 の `$commit_body` が Phase 3.2 で一切 export されていないのに grep 入力として使われる。毎回空文字列 → 常に `ROOT_CAUSE_GATE=missing` false-positive 発火 |
| 2. 書式規約の文書化忘れ | gate が `Root cause:` header を期待しているが、`contextual-commits.md` の action type 表に `root-cause(scope)` が列挙されていない。全 commit で gate が発火し続ける |
| 3. sentinel/marker の consumer 不在 | review.md が `[CONTEXT] QUALITY_SIGNAL=3_...` を emit する設計だが、start.md 側に grep 検出 + escalation routing のコードが存在しない。marker が stderr に流れるだけの dead code |
| 4. 散文のみの safeguard | 「100-iteration absolute safety limit」を散文で 2 箇所に記述するが、counter 変数 / `if [ $c -ge 100 ]` 相当のコード / incident emit の bash block がどこにも実装されていない |

### 共通メカニズム

すべての形態に共通する failure mode:

1. **設計レビュー時点では整合している**: 散文を読む限り意図は明確
2. **実装レビュー時に可視化**: レビュアーが「この変数はどこで定義される？」「この marker を grep している箇所は？」と掘ると初めて不在が判明
3. **dogfood 実行で false-positive 発火**: gate や sentinel の場合、毎回誤発火するため本番運用で即座に発覚

### 検出方法

実装レビュー時に以下の確認を必須化する:

- **変数参照**: 散文で言及した shell 変数は、同一 bash block 内 or tempfile 経由で確実に defined されているか (Bash tool は呼び出し間で state を継承しない)
- **書式規約の双方向性**: gate が期待する書式は、その書式を生成する caller 側ドキュメントに必ず列挙する
- **sentinel の consumer trace**: `grep -rn "CONTEXT] {MARKER}="` で consumer 実装が存在するか確認。0 件なら dead code
- **safeguard の実装 trace**: 「N iteration で force-exit する」のような prose があれば、counter 変数と分岐 bash を探索。存在しなければ prose を削除するか実装する

### 対処指針

Prose-only design を発見した場合の 3 択:

1. **実装を追加** (推奨): 最も労力が大きいが設計意図を実現する
2. **Prose を削除 or 意図を変更**: 実装しない / できないなら散文から除去して偽装を解く (例: PR #559 の 100-iteration limit は「意図的に cycle-count 上限を設けない」設計意図へ書き換え)
3. **LLM-semantic check に格上げ**: bash 実装が脆弱な場合、LLM に semantic な判定を委ねる形で明示化 (例: root-cause gate の書式検査を LLM-semantic に移行)

## 関連ページ

- [Exit code semantic preservation: caller は case で語彙を保持する](../patterns/exit-code-semantic-preservation.md)

## ソース

- [PR #559 review results](../../raw/reviews/20260417T035556Z-pr-559.md)
