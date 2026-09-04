# Fix Targeting Rules

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述は書かない。

Defines how fix targets are determined in the `/rite:iterate` review-fix loop.

## Overview

`/rite:fix` の修正対象は **致命 finding だけ**である。致命の定義は
`verification.measured == true` ∧ `severity ∈ {CRITICAL, HIGH}` ∧ `scope ∈ {current-pr, follow-up}`
（consumer 式の SoT: [severity-levels.md §実測必須ゲート](../../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate)）。
判定は `scripts/review-findings-maps.sh` が決定論で行い、LLM は `[CONTEXT] FIX_FATAL_TRIAGE=` marker を読むだけにする。

致命でない gated finding は**捨てず**に `non_blocking_findings[]` へ `demotion_reason: "non_fatal"` 付きで
移送し、severity は元のまま残す。移送分は fix の修正・reply・auto-select・mergeable countdown の
いずれの対象にもならず、全文は移送先 JSON に残って `/rite:iterate` 5.S の nb-sweep が消化する。

`scope == "nit-noted"` の finding は gated ではないため仕分けの対象外で、従来どおり認知のみ
（PR reply しない。`acknowledged_nit_count` に算入）。**未判定**（gated finding に
`verification.measured` が無い）は blocking にも non-blocking にも倒さず **error で停止**する
（`reason=measured_undetermined`）。

## Fix Target Classification

findings は **致命性**で 1 度だけ振り分けられる。severity × scope の段階表は持たない — 段階を持たせると
どの帯を修正対象にするかの判断が再び LLM 裁量に戻るため。

| 分類 | 条件 | Action |
|------|------|--------|
| **致命 (修正対象)** | `measured == true` ∧ `severity ∈ {CRITICAL, HIGH}` ∧ `scope ∈ {current-pr, follow-up}` | Must fix in this PR |
| **移送済み (非致命)** | 上記以外の gated finding（`measured == true` かつ MEDIUM / LOW-MEDIUM / LOW） | `non_blocking_findings[]` へ移送。修正・reply・auto-select の対象外。件数のみ表示 |
| **nit (認知のみ)** | `scope == "nit-noted"` | 仕分け対象外。no PR reply, no fix commit。`acknowledged_nit_count` に算入 |
| **non-blocking (実測なし)** | `measured == false` | 実測必須ゲートで pr-review 側が既に `non_blocking_findings[]` へ降格済み。fix 対象外 |
| **External review** | severity_map 未登録の未対応コメント（人間レビュアー等） | 実測必須ゲートの対象外。従来どおり blocking |
| **未判定 (error)** | gated finding に `verification.measured` が無い | ステップ 1.2.0 が `[fix:error] reason=measured_undetermined` で停止 |

> **禁止セル**: `severity ∈ {CRITICAL, HIGH}` × `scope == "nit-noted"` は schema invariant #4 違反
> （reviewer 側で reject され fix loop に到達しない）。`LOW × follow-up` は意味論的禁止
> （SoT: [`severity-levels.md` §Severity × Scope Matrix](../../../references/severity-levels.md#severity--scope-matrix)）。

**なぜ reviewer 側で絞らないか**: blocking 閾値を reviewer に持たせると「指摘を隠すほうが後出しより悪い」
という探索方針の書き換えを伴う。reviewer の努力は絞らず、釣り合いは fix 側の仕分けで取る。

**なぜ帰結クラス A/B を致命性の条件に入れないか**: クラス分類は LLM 判定であり、判定不能が A 側へ倒れる。
致命性を決定論に保つため初期条件には入れない。

## Loop Termination

The review-fix loop exits via:

| Exit Type | Condition | Result |
|-----------|-----------|--------|
| **Normal** | 0 blocking findings remaining | `[review:mergeable]` → `/rite:iterate` がループ終了 |
| **Manual abort** | ユーザーが Ctrl+C で中断 | `flow-state` に現 phase が残るので `/rite:recover` で復帰 |
| **Circuit breaker** | 収束トレンドが発散と判定される、または cycle が `safety.max_review_cycles`（既定 15）に到達 | batch は `[iterate:max-cycles-reached]`、対話は `[iterate:max-cycles-stopped]`（**sentinel は発火理由に依らず同一**）。**両モードとも人間に問わず機械的に停止**し非収束の失敗として記録する（マージには進まない）— 詳細は下記散文 |

`/rite:iterate` は「**blocking 指摘ゼロ**（mergeable）までループする」契約を基本とし（blocking = 致命 = `measured == true` かつ `severity ∈ {CRITICAL, HIGH}` かつ `scope ∈ {current-pr, follow-up}` の CONFIRMED 指摘 — SoT は [severity-levels.md §実測必須ゲート](../../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) の consumer 式。非実測指摘と非致命移送分は `non_blocking_findings[]` に記録されたまま残存して正常出口に到達しうる）、加えてサーキットブレーカーを唯一の自動安全網として持つ。発火条件は 2 つで、**主経路は収束トレンドの発散検出**（`hooks/scripts/review-trend-divergence.sh` が永続レビュー JSON の per-cycle blocking 件数から機械判定する）、`safety.max_review_cycles`（既定 15）はそれをすり抜ける非収束を受け止める backstop である（既定 15 では 16 cycle 以上を要する収束中の run にも上限として働く。15 は、従来の 5 cycle 上限が収束中の run を停止した実測に基づいて余裕を持たせた暫定値であり、実運用データで再評価する）。cycle 数上限だけでは努力と無駄を区別できないため格下げした（詳細は [iterate/SKILL.md](../../iterate/SKILL.md) が SoT）。quality-signal escalation / 同一 finding 検出といった細粒度の安全網は持たない。発火時は batch / 対話とも人間に問わず機械的に停止する（発火＝非収束による失敗の記録であり、マージには進まない）: `/rite:batch-run` バッチ実行では当該 Issue を failed 扱いにして次へ進み、対話実行では停止通知を出して終了する。ループの再開は人間が `/rite:iterate {pr}` を明示的に再実行する経路のみ。Ctrl+C による手動中断も従来どおり可能。

`fix.md` ステップ 3 の Root Cause Gate は引き続き **fix commit 側の品質ゲート**として機能する (root-cause-missing fix を reject)。loop 制御とは別経路。

## Caller Detection

**Scope**: このセクションは **fix target 選択**（Phase 2.1、どの findings を修正対象とするか）の caller-based 自動化のみを扱います。

Automatic fix target selection (Phase 2.1) is applied only when `/rite:fix` is called from within the `/rite:iterate` loop:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains an explicit `/rite:iterate` Skill invocation marker in recent context | Within loop → Apply automatic selection (all findings) |
| Conversation history has a record of `rite:fix` itself being called via Skill tool by `/rite:iterate` (= caller chain `iterate → fix`) | Within loop → Apply automatic selection (all findings) |
| Otherwise (user directly entered `/rite:fix` outside of `/rite:iterate`) | Manual execution → Display option selection |

For manual execution, users select targets via interactive options. separate-issue creation の AskUserQuestion 経路は廃止されているため、Phase 2.1 の選択肢は「コードを修正する / accept (認知のみ) / 説明・返信のみ」の 3 択になる (skip → 別 Issue 化の選択肢は提示しない)。
