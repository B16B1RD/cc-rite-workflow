# Fix Targeting Rules

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述は書かない。

Defines how fix targets are determined in the `/rite:iterate` review-fix loop.

## Overview

修正対象は **fatal** な rite finding に限定する。fatal は `verification.measured == true` かつ `severity ∈ {CRITICAL, HIGH}` かつ `scope ∈ {current-pr, follow-up}`。現行 producer は実測判定不能を `anchor_undetermined` で拒否し、対象 finding IDs の reviewer 出力だけを同 cycle 内で再生成する（共通再試行上限 1 回）。旧 JSON 等で gated finding の measured が未判定、または severity が未知の場合は `[fix:error]` で停止し、元 JSON を変更しない。

## Fix Target Classification

| Finding | Classification | Action |
|---------|----------------|--------|
| measured=true、CRITICAL/HIGH、current-pr/follow-up | Fatal | 修正対象・auto-select・fix commit 対象 |
| gated で measured=false、または MEDIUM/LOW-MEDIUM/LOW | Non-fatal | `non_blocking_findings[]` へ `demotion_reason: non_fatal` で移送し記録のみ |
| scope=nit-noted | Nit (認知のみ) | PR reply・fix commit 対象外、`acknowledged_nit_count` に算入 |
| Resolved | 解決済み | 既存の解決済み判定を維持 |
| 出自を確認できない人間・外部レビュー thread | External review | 既存の個別対応経路を維持 |

移送では severity、scope、id、description、suggestion を維持する。nit への付け替えは行わない。helper は scope enum を厳密に検証し、nit-noted の全フィールドを変更せず保持する。入力アダプターの既存 schema ガードは別段階である。移送結果は永続 JSON・関連 Issue 記録コメント・統合レポート・E2E suffix の 4 経路に接続する。accept / rejection の契約は変更しない。

## Loop Termination

The review-fix loop exits via:

| Exit Type | Condition | Result |
|-----------|-----------|--------|
| **Normal** | 0 blocking findings remaining | `[review:mergeable]` → `/rite:iterate` がループ終了 |
| **Manual abort** | ユーザーが Ctrl+C で中断 | `flow-state` に現 phase が残るので `/rite:recover` で復帰 |
| **Circuit breaker** | 収束トレンドが発散と判定される、または cycle が `safety.max_review_cycles`（既定 15）に到達 | batch は `[iterate:max-cycles-reached]`、対話は `[iterate:max-cycles-stopped]`（**sentinel は発火理由に依らず同一**）。**両モードとも人間に問わず機械的に停止**し非収束の失敗として記録する（マージには進まない）— 詳細は下記散文 |

`/rite:iterate` は「**blocking 指摘ゼロ**（mergeable）までループする」契約を基本とし（fix consumer の blocking = 上記 fatal 指摘 — SoT は [severity-levels.md §実測必須ゲート](../../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate)。非実測指摘はステップ 5.4 に記録されたまま残存して正常出口に到達しうる）、加えてサーキットブレーカーを唯一の自動安全網として持つ。発火条件は 2 つで、**主経路は収束トレンドの発散検出**（`hooks/scripts/review-trend-divergence.sh` が永続レビュー JSON の per-cycle blocking 件数から機械判定する）、`safety.max_review_cycles`（既定 15）はそれをすり抜ける非収束を受け止める backstop である（既定 15 では 16 cycle 以上を要する収束中の run にも上限として働く。15 は、従来の 5 cycle 上限が収束中の run を停止した実測に基づいて余裕を持たせた暫定値であり、実運用データで再評価する）。cycle 数上限だけでは努力と無駄を区別できないため格下げした（詳細は [iterate/SKILL.md](../../iterate/SKILL.md) が SoT）。quality-signal escalation / 同一 finding 検出といった細粒度の安全網は持たない。発火時は batch / 対話とも人間に問わず機械的に停止する（発火＝非収束による失敗の記録であり、マージには進まない）: `/rite:batch-run` バッチ実行では当該 Issue を failed 扱いにして次へ進み、対話実行では停止通知を出して終了する。ループの再開は人間が `/rite:iterate {pr}` を明示的に再実行する経路のみ。Ctrl+C による手動中断も従来どおり可能。

`fix.md` ステップ 3 の Root Cause Gate は引き続き **fix commit 側の品質ゲート**として機能する (root-cause-missing fix を reject)。loop 制御とは別経路。

## Caller Detection

**Scope**: このセクションは **fix target 選択**（Phase 2.1、どの findings を修正対象とするか）の caller-based 自動化のみを扱います。

Automatic fix target selection (Phase 2.1) is applied only when `/rite:fix` is called from within the `/rite:iterate` loop:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains an explicit `/rite:iterate` Skill invocation marker in recent context | Within loop → Apply automatic selection (fatal findings) |
| Conversation history has a record of `rite:fix` itself being called via Skill tool by `/rite:iterate` (= caller chain `iterate → fix`) | Within loop → Apply automatic selection (fatal findings) |
| Otherwise (user directly entered `/rite:fix` outside of `/rite:iterate`) | Manual execution → Display option selection |

For manual execution, users select targets via interactive options. skip → 別 Issue で loop 終了する AskUserQuestion 経路は閉じているため、Phase 2.1 の選択肢は「コードを修正する / accept (認知のみ) / 説明・返信のみ」の 3 択になる。残存 non-blocking の別 Issue 化は機械 routing（`/rite:iterate` 5.S `/rite:fix --nb-sweep` と `/rite:cleanup` の follow-up 起票）が担う。
