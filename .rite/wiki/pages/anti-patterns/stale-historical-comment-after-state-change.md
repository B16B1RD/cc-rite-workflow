---
title: "状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)"
domain: "anti-patterns"
description: "config 値の bump (例: `enabled: false → true`) や AC の完了マーク (`⏳ → ✅`) など状態を変更する commit で、同一行 / 近傍のインラインコメント (`default: false` / 「... 後に true 化予定」) が旧値や未来形のまま残置する drift。LLM / reviewer は値そのものは確認するが付随コメントの語法 (時制 / 旧値表記) は scope 外として読み飛ばすため、merge 後 reader が PR HEAD と書かれている内容の矛盾に直面する。過去のレビューで `scope_assignment.enabled: false → true` bump 時にインラインコメント残置 + AC-5 完了マーク `⏳ 実行予定` 残置を cycle 1 で Order-Emphasis Consistency 違反として 7 件検出。canonical 対策: 値変更時の同一行コメント sweep、commit SHA embed で「実行済」明示、rollout strategy comment は時制を「観察主体」に reframe (「予定」→「履歴」)。検出シグナル: config 値変更 / AC マーク変更 / バージョン bump + ±5 行内のインラインコメント / status 注釈の存在。過去のレビューで委譲 refactor の 2 doc-drift mode (comment rot=委譲先 helper 挙動を推測記述 / 用語定義表 stale=control-flow 変更の net-effect で byte-unchanged 行が stale 化、revert test pass) に拡張。"
promote: rite-plugin
created: "2026-05-19T20:10:23Z"
updated: "2026-05-29T15:59:38Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260519T195007Z-pr-1065.md"
  - type: "reviews"
    ref: "raw/reviews/20260519T195734Z-pr-1065-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260519T195351Z-pr-1065.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T145515Z-pr-1201.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T152911Z-pr-1201.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T150155Z-pr-1201.md"
  - type: "fixes"
    ref: "raw/fixes/20260529T153627Z-pr-1201.md"
tags: [config-bump, inline-comment, drift, rollout-strategy, order-emphasis-consistency, delegation-refactor, terminology-table, byte-unchanged-stale]
confidence: high
---

# 状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)

## 概要

config 値の bump (例: `enabled: false → true`) や AC の完了マーク (`⏳ 実行予定 → ✅ 実行済`) など状態を変更する commit で、**同一行 / 近傍のインラインコメント** が旧値や未来形 (`default: false` / `... 後に true 化予定`) のまま残置する drift。LLM / reviewer は値そのものは確認するが付随するインラインコメントの語法 (時制 / 旧値表記) は対象外として読み飛ばすため、merge 後の reader が「PR HEAD と書かれている内容が矛盾」する状態に直面する。起点事例で `scope_assignment.enabled: false → true` bump と AC-5 完了マークの両方で同症状が観測され、cycle 1 で 7 件 finding の Order-Emphasis Consistency 違反として検出。

## 詳細

### 観測された症状

起点事例の `rite-config.yml` AC-5 bump で `scope_assignment.enabled: false → true` を変更した際、同一行末尾のコメントが状態変化を反映しないまま残置:

```yaml
# Before bump (旧 HEAD)
enabled: false           # scope-based routing 全体の opt-in/out (default: false、Issue #1020 で初期導入)

# After bump (新 HEAD) — drift 状態
enabled: true            # scope-based routing 全体の opt-in/out (default: false、Issue #1020 で初期導入)
                         #                                       ^^^^^^^^^^^^^^^^
                         #                                       現値 true に対して非対称
```

同時に PR description の AC-5 状態表記が:

```diff
- AC-5: 検証完了後、`scope_assignment.enabled: true` bump (本 Sub-Issue 内の最後の commit)  ⏳ 実行予定
```

のまま、bump 完了 commit が landed 後も `⏳ 実行予定` 表記が残置していた。

### 失敗 mode

- LLM / reviewer の attention は **値そのもの** (`true` / `false`、`✅` / `⏳`) に向き、付随インラインコメント / status emoji の語法整合性は scope 外として読み飛ばす
- diff 上は「1 行変更」に見えるが意味的には「値変更 + コメント整合性更新 + status 表記更新」の 3 site 修正が必要
- rollout strategy / migration plan を rite-config.yml や CHANGELOG にコメントで残す慣習があると、状態遷移を経た後も「将来計画」表記が残り future-tense として読まれる drift が累積

### canonical 対策

#### Pattern 1: 値変更時の同一行コメント sweep

config bump / AC マーク更新時は値変更と**同一 commit** で:

1. 同一行末尾のインラインコメント (`# default: false`) の語法を新値に合わせて更新
2. 直上 / 直下数行のコメントブロック (rollout strategy 等) の時制を完了形に書き換え
3. PR description / commit body の AC 状態表記 (`⏳ → ✅`) を完了マークに更新

#### Pattern 2: commit SHA embed で「実行済」を明示する

「完了マーク」だけだと将来の読み手が「いつ完了したか」「どこで実行されたか」を遡れない。**完了の証跡として commit SHA を embed** することで Order-Emphasis Consistency を強化:

```diff
- AC-5: 検証完了後、enabled: true bump  ⏳ 実行予定
+ AC-5: ✅ 実行済 (commit 7412b2f9 で bump 完了)
```

reader は commit SHA から `git show 7412b2f9` で実物を確認でき、completion claim と実装の対応が grep evidence として確立する。

#### Pattern 3: rollout strategy comment は時制を「観察主体」に reframe

将来計画を残したい場合は「未来形」ではなく「過去-現在パース可能な観察主体」で記述:

```diff
- # ロールアウト戦略: 初期 false で導入 → 動作検証後に develop merge 時点で同一 PR 内の別 commit で true へ bump
+ # ロールアウト履歴: 初期 false で導入 → #1022 検証 pass 後 (commit 7412b2f9) に true へ bump
```

「予定」「予定」を「履歴」「実施」に置き換えることで、PR cycle 完了後も時制が drift しない。

### 検出シグナル

以下のパターンが diff に現れたら本 anti-pattern の警戒対象:

- config 値変更 (`true ↔ false`、`enabled ↔ disabled`、`auto ↔ manual` 等の boolean / enum flip)
- AC マーク変更 (`⏳ → ✅`、`未着手 → 実装中 → 完了` 等)
- バージョン bump (`0.x → 1.0`)
- いずれも同一行 / 近傍 (±5 行) にインラインコメント / status 注釈が存在する

3 条件が揃った diff では reviewer が「値 + コメント + 状態表記の 3 site 整合性」を grep verify するチェックリスト項目を追加することで decisive に防御可能。

### 委譲 refactor での 2 つの doc-drift mode

inline 実装を helper script へ委譲する refactor（fix.md 4.5.2 を `issue-comment-wm-sync.sh` へ委譲）で、同じ「doc が現実と乖離」する failure が 2 つの異なる mode で surface した:

**Mode A — comment rot (cycle 1): 委譲先 helper の挙動を推測で記述**

委譲時に caller 側へ新規追加したコメントが、委譲先 helper (`issue-comment-wm-update.py`) の edge-case 実挙動を**誤記述**していた (空 changed-files-file → 実際はセクション本文を空文字置換 / placeholder 除去するのに、「placeholder を維持する」と記述)。これは「状態変化後の stale」ではなく **書いた時点から不正確** (helper 実装を Read せず推測で書いた) という mode。対策: **委譲先コンポーネントの挙動を説明するコメントは、推測で書かず helper 実装 (関数本体) を Read して runtime 検証してから書く**。fix も「新たな不正確コメントを生まない」よう helper の実挙動を runtime 確認した上で訂正した。

**Mode B — terminology table stale (cycle 3): control-flow 変更の net-effect で byte-unchanged 行が stale 化**

control-flow 分類を変える refactor (hard-fail-fast → soft-failure、Python sentinel 経路削除) で、reason 表 / routing 表は同期したが、**ステップ5 冒頭の用語定義表 (soft failure / hard fail-fast 行) の例示テキスト** (`current_body 空` / `PATCH 失敗` / `git diff 失敗 (Python sentinel 経路)`) が旧実装前提のまま残置した。重要なのは **当該行が git diff 上 byte 一致 (unchanged) だった** こと — staleness は当該行の変更ではなく**他箇所の control-flow 変更の波及 (net effect)** で生じる。revert test は pass する (PR を revert すれば旧実装に戻り表と整合)。

教訓: diff に出る変更行だけでなく、**「diff に出ない unchanged 行で、他箇所の変更により真実値が変わったもの」も review/sync 対象**。control-flow 分類を変える refactor では reason 表・routing 表に加え「用語定義表」のような副次的説明テーブルの例示も同期 scope に含める (Asymmetric Fix Transcription の説明テーブル版)。3 cycle 連鎖事例は cycle 1=comment rot → cycle 2=stderr 破棄 → cycle 3=用語定義表 stale と、実装の正しさ → 診断品質 → 説明整合性 の順に深掘りされた。

### 関連 anti-pattern との区別

| pattern | scope | 検出 timing |
|---------|-------|------------|
| **Stale historical comment drift** (本 page) | 状態変化後にコメント / 表記が旧値のまま残置 | review / fix 時 |
| [Design doc current HEAD verification](../heuristics/design-doc-current-head-verification.md) | design doc が現 HEAD の component を grep verify せず stale 参照 | design 時 |
| [Asymmetric Fix Transcription](asymmetric-fix-transcription.md) | 同種パターンの multi-location drift | fix 時 |

本 page は「同一 commit 内で値とコメントの整合性が崩れる drift」に focus。複数ファイル / 複数 site への伝播漏れは Asymmetric Fix Transcription、design doc 全体の stale 参照は Design doc current HEAD verification。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [Design doc は現 HEAD の SoT (registration / writer-reader grep) を verify してから書く](../heuristics/design-doc-current-head-verification.md)

## ソース

- [PR #1065 review results](../../raw/reviews/20260519T195007Z-pr-1065.md)
- [PR #1065 review cycle 2](../../raw/reviews/20260519T195734Z-pr-1065-cycle2.md)
- [PR #1065 fix results](../../raw/fixes/20260519T195351Z-pr-1065.md)
- [PR #1201 review cycle 1 (comment rot 検出)](../../raw/reviews/20260529T145515Z-pr-1201.md)
- [PR #1201 review cycle 3 (用語定義表 stale 検出)](../../raw/reviews/20260529T152911Z-pr-1201.md)
- [PR #1201 fix cycle 1 (comment rot 修正 — helper 実挙動 runtime 検証)](../../raw/fixes/20260529T150155Z-pr-1201.md)
- [PR #1201 fix cycle 3 (用語定義表 stale 同期)](../../raw/fixes/20260529T153627Z-pr-1201.md)
