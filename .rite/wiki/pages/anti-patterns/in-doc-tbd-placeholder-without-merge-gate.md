---
title: "doc 内 _TBD_ placeholder は merge 前 enforcement なしだと長期残留する"
domain: "anti-patterns"
description: "検証結果 doc / 設計書に `_TBD_` / `（追記予定）` / `<!-- TODO: post-hoc 観測 -->` のような placeholder を埋め込み「merge 後に観測値を追記する」設計は、merge 前 enforcement (CI check / pre-commit / required reviewer 等) なしでは長期残留し、後続 reader が「ここに何が来るはずだったか」を context 喪失した状態で読む drift を生む。"
promote: rite-plugin
created: "2026-05-19T20:10:23Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260519T195007Z-pr-1065.md"
  - type: "fixes"
    resource: "raw/fixes/20260519T195351Z-pr-1065.md"
tags: [tbd-placeholder, post-hoc-observation, merge-gate, enforcement, pr-description-tracking]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-19T20:10:23Z" }
---

# doc 内 _TBD_ placeholder は merge 前 enforcement なしだと長期残留する

## 概要

検証結果 doc / 設計書に `_TBD_` / `（追記予定）` / `<!-- TODO: post-hoc 観測 -->` のような placeholder を埋め込み「merge 後に観測値を追記する」設計は、merge 前 enforcement (CI check / pre-commit / required reviewer 等) なしでは長期残留し、後続 reader が「ここに何が来るはずだったか」を context 喪失した状態で読む drift を生む。PR #1065 で `docs/verification-results/middle-refactor-2026-05-20.md` の Section 4 (検証項目 1-3 の live dogfooding 結果欄) が `_TBD_` placeholder のまま commit され、cycle 1 review で MEDIUM finding として検出された事例。

## 詳細

### 観測された症状

起点事例で当該 PR の review-fix サイクル自身が「検証項目 1-3 の live dogfooding 検証」の役割を担う設計だったため、検証結果 doc に以下のような placeholder を埋め込んだ:

```markdown
### 項目 1: 合成 nit-only PR (3 cycle)

- 期待: 1 cycle で nit reply 全件、Issue 化 0、2 cycle 即 mergeable
- 実測: _TBD_  ← 本 PR の review-fix で確定
```

設計意図としては「PR review-fix が完了したら observation を追記して final commit する」だったが、(a) その追記を強制する CI check は存在しない、(b) reviewer も「TBD は意図的 placeholder」として通すコンセンサスがあれば見過ごす、(c) PR merge 後に追記する責務が誰にあるか contract 化されていない、という 3 つの enforcement gap で long-term に残留するリスクがある。

### 失敗 mode

- doc 内 placeholder は **literal 文字列** であり、CI / lint で「TBD が残っているなら fail」のような構造的 enforcement を追加するコストが高い (どの TBD が「意図的」でどれが「埋め忘れ」か区別できない)
- PR description のチェックリストや review checklist で人力 enforce する設計は「reviewer が見落とす」mode で容易に bypass される
- merge 後の追記は「別 PR / amend commit / direct push」のいずれかになるが、いずれも別 review pass を経ない経路のため、追記時に新たな typo / 事実誤認が混入しても検出されない
- post-hoc 観測 = "実測値" 系の placeholder は時間が経つほど元 context (期待値 / 設計意図) を再現するコストが上がり、最終的に「何のための placeholder か分からない」状態に劣化する

### canonical 対策

#### Pattern 1: doc 外で追跡する (recommended)

post-hoc 観測は doc 末尾の placeholder ではなく、**PR description のチェックリスト + follow-up Issue** で追跡する:

```markdown
# PR description (本 PR)

## 補足

本 PR の review-fix サイクル自体が、検証項目 1-3 の **live dogfooding 検証** の役割も担う。
観測結果は merge 後に follow-up Issue #{N} で集約予定 (現 PR の doc 本体には placeholder を残さない)。
```

doc 本体は「期待値 + 設計意図」までで完結させ、observation phase は外部 (Issue / 別 doc / wiki raw source) で追跡する。Wiki Ingest を運用しているプロジェクトでは raw source 経由で自動的に経験則化される経路が確立済み（本ページ自身がその raw source 経由で生成されている）。

#### Pattern 2: placeholder を残すなら CI で強制する

どうしても doc 内 placeholder で残したい場合は、merge 前 enforcement を構造化する:

- `_TBD_` 文字列を含むファイルが diff にあれば CI fail (`grep -F '_TBD_' docs/`)
- placeholder には期限 metadata を付ける (`_TBD: by 2026-06-01_`)
- 期限切れ placeholder は scheduled job で Issue を自動起票

ただしこの方式は CI 設定 + 期限 metadata 規約 + scheduled job という 3 layer の維持コストが発生するため、Pattern 1 (doc 外追跡) が前提的に低コスト。

#### Pattern 3: merge 後追記が必須なら「N/A」を採用する

検証 N/A や「データ不在のため代替手法で trace」のように、観測値が永遠に確定しない経路では `_TBD_` ではなく N/A + 代替手法明示で commit する:

```diff
- 実測: _TBD_  ← post-hoc 観測予定
+ 実測: N/A (reviews 不在のため、静的 trace S5/S6/S13 で代替)
```

「placeholder のまま」と「N/A」は読者の解釈負荷が大きく異なる。前者は「あとで埋まる」期待を残し、後者は「ここで完結」を宣言する。

### 検出シグナル

以下のパターンが doc diff に現れたら本 anti-pattern の警戒対象:

- `_TBD_` / `_TODO_` / `<!-- TBD -->` / `（追記予定）` / `（後述）` のような未完了 marker
- placeholder の追記責務が doc 内に明示されていない (誰が / いつ / どの commit で埋めるか不明)
- merge 前 enforcement (CI / pre-commit / required reviewer) が PR 描写上 absent
- placeholder の周辺に「post-hoc」「dogfooding」「merge 後」「review-fix サイクル中」のような時制依存表現

4 条件のうち 2 つ以上該当する場合、reviewer は「placeholder を doc 内に残す代わりに PR description / follow-up Issue / N/A 採用のいずれかを推奨」する MEDIUM 指摘を行うべき。

### Wiki Ingest との接続

本 anti-pattern は Wiki Ingest 経由で観測値を経験則化するプロジェクトでは特に Pattern 1 (doc 外追跡) が機能する。raw source (`reviews/` / `fixes/` / `retrospectives/`) に観測を残せば、`/rite:wiki:ingest` が自動的に Wiki page に統合し、後続 PR から `/rite:wiki:query` で参照可能になる。doc 本体に placeholder を残す代わりに Wiki への蓄積で trace を確保する設計は、本 anti-pattern を構造的に回避する手段として推奨。

## 関連ページ

- [状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)](./stale-historical-comment-after-state-change.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)

## ソース

- [レビュー結果](../../raw/reviews/20260519T195007Z-pr-1065.md)
- [fix 結果](../../raw/fixes/20260519T195351Z-pr-1065.md)
