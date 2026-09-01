---
type: "anti-patterns"
title: "共有リソースの type/名前空間を再利用する新機能は、既存消費者のコード内契約（コメント明示の不変条件）を見落として生存中のリソースを破壊しうる"
domain: "anti-patterns"
promote: rite-plugin
description: "新機能実装で既存の共有リソース（reap manifest の type 名前空間等）を再利用する際、その共有リソースの既存消費者（別のロジック段）が持つ契約——多くはコード内コメントで明示された不変条件——を確認しないまま実装すると、共有リソースの解釈が衝突し、既存の健全なリソースが無警告で破壊されうる。"
created: "2026-07-23T04:14:28Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T053153Z-pr-2498.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T055639Z-pr-2498.md"
  - type: "reviews"
    resource: "raw/reviews/20260723T005459Z-pr-1974.md"
  - type: "fixes"
    resource: "raw/fixes/20260723T010449Z-pr-1974.md"
  - type: "reviews"
    resource: "raw/reviews/20260723T020925Z-pr-1974-cycle2.md"
tags: ["shared-resource-contract", "namespace-reuse", "reap-manifest", "existing-consumer-verification", "mutation-testing", "cross-validation", "marker-prefix-glob-scope"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-01T20:33:00+09:00" }
---

# 共有リソースの type/名前空間を再利用する新機能は、既存消費者のコード内契約（コメント明示の不変条件）を見落として生存中のリソースを破壊しうる

## 概要

新機能実装で既存の共有リソース（reap manifest の type 名前空間等）を再利用する際、その共有リソースの既存消費者（別のロジック段）が持つ契約——多くはコード内コメントで明示された不変条件——を確認しないまま実装すると、共有リソースの解釈が衝突し、既存の健全なリソースが無警告で破壊されうる。cycle 1 で、error-handling reviewer の実機再現と prompt-engineer reviewer の文書整合性チェックという異なるアプローチが同一の根本原因に収束し、CRITICAL として確定した。

## 詳細

### 発生した構造

`rite-tmp-artifact.sh` の reap manifest は `<type>\t<value>` 形式で `branch` / `worktree` 等の type を持つ。`pr-cycle-cleanup.sh` の Step 4.5 は `worktree` type のエントリを「ephemeral tmp artifact 専用」という暗黙契約のもとで **ungated に reap（無条件削除）** する設計だった。この契約はコード内コメントには明示されていたが、実装コード自体には type ごとの意味論を強制する仕組みがなかった。

新機能（sandbox 環境で worktree 削除が失敗した場合に manifest へ記録する）を実装する際、既存の `worktree` type をそのまま再利用してしまうと、live claim を持つ健全なセッション worktree が Step 4.5 の ungated pass で警告なしに完全削除される。scratch 環境での実機再現によりこの破壊が確認された。

### 検出のクロスバリデーション

- **error-handling reviewer**: scratch 環境で実際に「live claim を持つ worktree が type=worktree で manifest 記録される」シナリオを再現し、Step 4.5 実行で削除されることを実機確認
- **prompt-engineer reviewer**: 独立して、コード内コメントに明示された「`worktree` type は ephemeral tmp artifact 専用」契約と、新機能の記録ロジックの意味論的な不一致を文書レベルで発見

異なるアプローチ（実機再現 vs 文書整合性）が同一の根本原因に収束したことで、単一レビュアーでは見逃されうる契約違反が高い確信度で確定した。

### 修正方針

型名を再利用せず **専用 type を新設**（本件では `session_worktree`）し、既存消費者（Step 4.5）の case 文が未知 type として自然にスキップする設計を採用した。これにより既存ロジックを一切変更せず、新機能を安全に分離できる。専用 type 側には別途、既に消滅したパスのみを drop する self-heal 専用の case arm を新設し、reap は行わずに Step 5（gated reap、self-exclusion / claim-liveness / live-cwd gate 通過後のみ）へ委譲する設計とした。

### 実装が進化するとコメントが追随しない risk（cycle 2 での追加検出）

cycle 1 修正後、cycle 2 レビューで test / prompt-engineer reviewer が独立に、修正内容に対するさらなる MEDIUM 指摘を発見した。1 つは新機能実装後にコメントを段階的に追加する過程（後から専用 case arm を追加する等）でコメントが実装に追随せず自己矛盾を残すリスクで、**複数ファイルに複製されたコメントは特に drift しやすい**（本件では `cleanup/SKILL.md` / `pr-cycle-cleanup.sh` / `rite-tmp-artifact.sh` の 3 ファイルに同一趣旨のコメントが複製されていた）。もう 1 つは producer 側（recorder + guard）の discriminating test coverage 欠如で、安全ゲート（`{pr_merged}=true` guard）を剥がす mutation がテストスイートを無検知で通過することが mutation test で実証された（詳細は [[mutation-testing-test-fidelity]] 適用 10 参照）。

### 教訓

1. **新機能で既存の共有リソースの型/名前空間を再利用する前に、その型の全消費者（他のロジック段）の契約を確認する** — コード内コメントに書かれた不変条件であっても、型を再利用する新規実装者がそれを見落とすリスクは構造的に存在する
2. **専用 type/namespace の新設は既存契約に触れない安全な分離策** — 既存消費者のロジックを変更せず、未知 type の自然な no-op スキップに委ねられる
3. **実機再現とドキュメント整合性チェックという異なる検出アプローチのクロスバリデーション** が、単一アプローチでは見逃されうる契約違反を高確信度で確定させる
4. **複数ファイルに複製されたコメントは実装の段階的進化に追随せず drift しやすい** — 新契約を宣言するコメントは重複させず、SoT を明示するか、複製箇所すべてを同一 PR 内で同期する

### 破壊しない場合でも「不発コード」になる

consumer 契約の確認を怠った結果は、生存中リソースの破壊だけではない。**consumer が一度も受理しない記録**を書き続ける不発コードも同じ原因から生まれる。

ある PR では reap manifest へ `session_worktree` type の記録を追加したが、consumer（`pr-cycle-cleanup.sh`）の bypass 条件は `_corpse -eq 1`（削除試行が失敗した痕跡）を要求していた。追加した経路は削除を一度も試行しないため worktree は健全で、記録は**永久に参照されない**。しかも同じ修正が、既に機能していた別経路（ステップ 5 の `branch` type 記録による age guard バイパス）を「機能しない」と案内文で否定していた。

**新しい type / key を既存機構へ流し込む前に、consumer が何を条件にそれを消費するかを読む**。読む対象は type の名前ではなく、consumer 側の受理条件そのもの（if 文・case arm）である。

### 消費側が glob で family を絞っているなら、prefix を共有した時点で分離は成立しない

同じ構造が marker の名前空間でも起きる。消費側が `PREFIX_*` の glob で marker family を scope している設計に対し、**同じ prefix を持つ新 marker**（`--dry-run` 用など）を足すと、その marker は判定表のどの行にも一致せず、しかし family には取り込まれるため fallback（「marker が無いとき」の行）にも落ちない。結果は未定義状態——実行していないのに完了とも未確認とも判定されない。

コード内コメントに「この marker は family を分離している」と書いても分離は成立しない。**消費側の scope 規則が glob である以上、分離できるのは prefix そのものを変えることだけ**である（`DRY_RUN_` のように別 prefix にする）。

自問は type 名前空間の場合と同一: 新しい名前を既存機構へ流し込む前に、**consumer が何を条件にそれを拾うか**（glob か完全一致か、どの範囲を family と見なすか）を読む。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [Canonical helper bypass: 既存集約 helper を bypass して inline 再実装する](./canonical-helper-bypass.md)

## ソース

- [PR #1974 review results (cycle 1, CRITICAL 検出)](../../raw/reviews/20260723T005459Z-pr-1974.md)
- [PR #1974 fix results (cycle 1, 専用 type 新設による修正)](../../raw/fixes/20260723T010449Z-pr-1974.md)
- [PR #1974 review results (cycle 2, コメント drift 追加検出)](../../raw/reviews/20260723T020925Z-pr-1974-cycle2.md)
- [PR #2150 fix results (cycle 2: consumer の corpse 条件を読まず不発記録を追加)](../../raw/fixes/20260808T070139Z-pr-2150-cycle2.md)
- [PR #2498 review results / fix results (同 prefix の新 marker が消費側 glob に取り込まれ未定義状態を作る)](../../raw/reviews/20260901T053153Z-pr-2498.md)
